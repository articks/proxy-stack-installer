#!/usr/bin/env bash
#
# Deploy on a clean Ubuntu/Debian VPS:
#   - Fake-TLS MTProto on TCP/443 (MTG + a real nginx TLS backend)
#   - Telegram WEB Proxy over HTTPS/443 (tproxy-server behind nginx)
#   - legacy random-padding MTProto on TCP/8443 (official Telegram MTProxy)
#   - authenticated SOCKS5 on TCP/1080 (Dante, TCP CONNECT only)
#   - VLESS over WebSocket + TLS on TCP/443 (via MTG/nginx) and TCP/9443
#   - a ready-to-import Happ subscription for the VLESS endpoint
#   - Let's Encrypt renewal and daily Telegram relay-config refresh timers
#
# Usage:
#   sudo bash install-proxy-stack.sh ipv4.example.com [ipv6.example.com]
#
# The first domain must have exactly one public A record pointing directly to
# this server and no AAAA record. When supplied, the second domain must have
# exactly one AAAA record assigned to this server and no A record. Cloudflare/CDN
# proxying must be disabled for both names.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly MTG_VERSION="2.3.0"
readonly MTG_SHA256_AMD64="11c038ea5eeebd5d49148048975c24f7b0c4fa4c1cf4f15a2410203e2da01812"
readonly MTPROXY_COMMIT="69f2f083b57bbd94932cb9f4f32155f33e719ff1"
readonly TPROXY_SERVER_COMMIT="c8adb8b7c6b7fc46c12ae3acb68be9070c26a8e8"
readonly TPROXY_SERVER_SHA256_AMD64="a78b48f536180143dd7005785ca397310c36ee0b132e19949a45d64f586ab549"
readonly GO_VERSION="1.26.10"
readonly GO_SHA256_AMD64="ccfe7ae822d2c2f41f4fe7c956199967a4dac22d0ee0d2b2bfdb440aab3b20c5"
readonly XRAY_VERSION="26.11.9"
readonly XRAY_SHA256_AMD64="b651f7e1d9966ee2c1b1ee1bf8b52c72771824d3065dce96bbc8bcc19ed95f82"

readonly STATE_DIR="/etc/proxy-stack"
readonly STATE_FILE="${STATE_DIR}/credentials.env"
readonly INSTALL_MARKER="${STATE_DIR}/installed"
readonly FRONTEND_METADATA="${STATE_DIR}/frontend.env"
readonly CREDENTIALS_OUTPUT="/root/proxy-credentials.txt"
readonly MTPROXY_DIR="/etc/mtproxy"
# Kept only to recognize an existing C frontend during a non-migrating upgrade.
readonly TELEPROXY_BIN="/usr/local/bin/teleproxy"
readonly MTG_BIN="/usr/local/bin/mtg"
readonly MTG_CONFIG="${MTPROXY_DIR}/mtg.toml"
readonly MTG_IPV6_CONFIG="${MTPROXY_DIR}/mtg-ipv6.toml"
readonly MTPROXY_BIN="/usr/local/bin/mtproto-proxy"
readonly TPROXY_SERVER_BIN="/usr/local/bin/tproxy-server"
readonly TPROXY_SERVER_DIR="/etc/tproxy-server"
readonly TPROXY_SERVER_CONFIG="${TPROXY_SERVER_DIR}/config.json"
readonly TPROXY_SERVER_PROFILES="${TPROXY_SERVER_DIR}/profiles.json"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly XRAY_CONFIG_DIR="/usr/local/etc/xray"
readonly XRAY_CONFIG="${XRAY_CONFIG_DIR}/config.json"
readonly REFRESH_BIN="/usr/local/sbin/mtproxy-config-refresh"
readonly NGINX_ROOT="/var/www/faketls"
readonly NGINX_SITE="/etc/nginx/sites-available/proxy-stack.conf"
readonly NGINX_SITE_LINK="/etc/nginx/sites-enabled/proxy-stack.conf"

WORK_DIR=""
DOMAIN=""
DOMAIN_IPV6=""
PUBLIC_IPV4=""
PUBLIC_IPV6=""
ENABLE_IPV6=0
RAW_SECRET=""
SOCKS_USER="socksproxy"
SOCKS_PASSWORD=""
VLESS_UUID=""
VLESS_WS_PATH=""
HAPP_SUBSCRIPTION_ID=""
VLESS_TLS_FINGERPRINT="edge"
FAKETLS_ENGINE="mtg"
XRAY_TEST_PID=""
GO_BIN=""

log() {
  printf '\n[proxy-stack] %s\n' "$*"
}

warn() {
  printf '\n[proxy-stack] WARNING: %s\n' "$*" >&2
}

die() {
  printf '\n[proxy-stack] ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${XRAY_TEST_PID}" ]]; then
    kill "${XRAY_TEST_PID}" 2>/dev/null || true
    wait "${XRAY_TEST_PID}" 2>/dev/null || true
  fi
  if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" && "${WORK_DIR}" == /tmp/proxy-stack.* ]]; then
    rm -rf -- "${WORK_DIR}"
  fi
}

on_error() {
  local exit_code=$?
  local line_no=$1
  printf '\n[proxy-stack] Installation failed at line %s (exit %s).\n' "${line_no}" "${exit_code}" >&2
  printf '[proxy-stack] Inspect logs with: journalctl -u teleproxy -u tproxy-server -u mtproxy -u danted -u xray -u nginx --no-pager -n 150\n' >&2
  exit "${exit_code}"
}

usage() {
  cat <<'USAGE'
Usage:
  sudo bash install-proxy-stack.sh ipv4.example.com [ipv6.example.com]

Examples:
  sudo bash install-proxy-stack.sh d1.example.com
  sudo bash install-proxy-stack.sh d1.example.com d2.example.com

The first DNS name must have one A record pointing directly to this VPS and no
AAAA record. The optional second name must have one AAAA record assigned to the
VPS and no A record. IPv6 is not configured when the second name is omitted.
Do not enable Cloudflare/CDN proxying for either name.
USAGE
}

validate_domain() {
  local value=$1
  local label
  local -a labels

  [[ ${#value} -le 253 ]] || die "Domain name is longer than 253 characters."
  [[ "${value}" == *.* ]] || die "Use a fully-qualified domain such as proxy.example.com."
  [[ "${value}" =~ ^[a-z0-9.-]+$ ]] || die "Domain contains unsupported characters: ${value}"
  [[ "${value}" != .* && "${value}" != *. && "${value}" != *..* ]] || die "Malformed domain: ${value}"

  IFS='.' read -r -a labels <<<"${value}"
  for label in "${labels[@]}"; do
    [[ -n "${label}" && ${#label} -le 63 ]] || die "Malformed DNS label in ${value}."
    [[ "${label}" != -* && "${label}" != *- ]] || die "DNS labels cannot start or end with '-': ${value}"
  done

  [[ "${labels[-1]}" =~ ^[a-z][a-z0-9-]*[a-z0-9]$ || "${labels[-1]}" =~ ^[a-z]$ ]] || \
    die "The top-level domain looks invalid: ${value}"
}

is_ipv4() {
  local value=$1
  local octet
  local -a octets

  IFS='.' read -r -a octets <<<"${value}"
  [[ ${#octets[@]} -eq 4 ]] || return 1
  for octet in "${octets[@]}"; do
    [[ "${octet}" =~ ^[0-9]{1,3}$ ]] || return 1
    ((10#${octet} <= 255)) || return 1
  done
}

canonical_ipv6() {
  python3 -c 'import ipaddress,sys; print(ipaddress.IPv6Address(sys.argv[1]))' "$1" 2>/dev/null
}

validate_vless_fingerprint() {
  local value=$1
  [[ ${#value} -le 64 ]] || die "VLESS TLS fingerprint is too long."
  case "${value}" in
    chrome|firefox|safari|ios|android|edge|360|qq|random|randomized|unsafe) ;;
    *) [[ "${value}" =~ ^Hello[A-Za-z0-9_]+$ ]] || die "Invalid VLESS TLS fingerprint."
  esac
}

state_value() {
  local key=$1
  awk -F= -v wanted="${key}" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' "${STATE_FILE}"
}

check_existing_domains() {
  # Run before backups, package work or service shutdown on a managed host.
  [[ -f "${STATE_FILE}" ]] || return 0
  [[ "$(state_value DOMAIN)" == "${DOMAIN}" && "$(state_value DOMAIN_IPV6)" == "${DOMAIN_IPV6}" ]] || \
    die "This server was initialized for different domains; refusing to replace them."
}

write_atomic() {
  local mode=$1
  local destination=$2
  local temporary

  temporary="$(mktemp "${WORK_DIR}/file.XXXXXX")"
  cat >"${temporary}"
  install -D -o root -g root -m "${mode}" "${temporary}" "${destination}"
}

backup_if_present() {
  local source=$1
  local backup_dir=$2

  if [[ -e "${source}" || -L "${source}" ]]; then
    cp -a -- "${source}" "${backup_dir}/"
  fi
}

port_is_listening() {
  local port=$1
  command -v ss >/dev/null 2>&1 || return 1
  ss -H -ltn | awk -v suffix=":${port}" '$4 ~ suffix "$" {found=1} END {exit !found}'
}

check_clean_ports() {
  local port

  if [[ -f "${STATE_FILE}" ]]; then
    systemctl stop teleproxy.service teleproxy-ipv6.service tproxy-server.service mtproxy-ipv6.service mtproxy.service danted.service xray.service 2>/dev/null || true
  fi

  for port in 443 8443 9443 1080 8080 8081 8444 8888 8889 10000; do
    if [[ ("${port}" == "8444" || "${port}" == "9443") && -f "${STATE_FILE}" && -f "${NGINX_SITE}" ]] && \
      systemctl is-active --quiet nginx.service; then
      continue
    fi
    if port_is_listening "${port}"; then
      ss -H -ltnp | awk -v suffix=":${port}" '$4 ~ suffix "$" {print}' >&2 || true
      die "TCP port ${port} is already occupied. Run this installer on a clean VPS or free the port first."
    fi
  done
  if ((ENABLE_IPV6)) && port_is_listening 8890; then
    die "TCP port 8890 is already occupied; it is required for loopback IPv6 MTG metrics."
  fi

  if port_is_listening 80 && ! systemctl is-active --quiet nginx.service; then
    ss -H -ltnp | awk '$4 ~ /:80$/ {print}' >&2 || true
    die "TCP port 80 is occupied by something other than nginx. It is required for Let's Encrypt."
  fi
}

install_packages() {
  local package
  local -a missing_packages=()
  local -a required_packages=(
    build-essential
    ca-certificates
    certbot
    curl
    dante-server
    dnsutils
    git
    iproute2
    jq
    libssl-dev
    nginx
    openssl
    python3
    socat
    tar
    ufw
    unzip
    xxd
    zlib1g-dev
  )

  log "Installing operating-system packages"
  for package in "${required_packages[@]}"; do
    if [[ "$(dpkg-query -W -f='${db:Status-Abbrev}' "${package}" 2>/dev/null || true)" != "ii " ]]; then
      missing_packages+=("${package}")
    fi
  done

  if ((${#missing_packages[@]})); then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends "${missing_packages[@]}"
  else
    log "All required operating-system packages are already installed"
  fi

  systemctl stop danted.service 2>/dev/null || true
}

discover_public_ipv4() {
  local endpoint
  local candidate

  for endpoint in \
    "https://api.ipify.org" \
    "https://ifconfig.me/ip" \
    "https://icanhazip.com"; do
    candidate="$(curl -4fsS --connect-timeout 8 --max-time 15 "${endpoint}" 2>/dev/null | tr -d '[:space:]' || true)"
    if is_ipv4 "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

check_dns() {
  local -a ipv4_records
  local -a ipv4_domain_ipv6_records
  local -a ipv6_domain_ipv4_records
  local -a ipv6_records
  local candidate
  local canonical_candidate
  local canonical_dns_ipv6
  local matched_ipv6=0

  log "Checking DNS before requesting a certificate"
  PUBLIC_IPV4="$(discover_public_ipv4)" || die "Could not determine this server's public IPv4 address."

  mapfile -t ipv4_records < <(dig +short A "${DOMAIN}" | awk '/^[0-9.]+$/ {print}' | sort -u)
  mapfile -t ipv4_domain_ipv6_records < <(dig +short AAAA "${DOMAIN}" | awk '/:/{print}' | sort -u)

  [[ ${#ipv4_records[@]} -gt 0 ]] || die "${DOMAIN} has no visible A record yet."
  [[ ${#ipv4_domain_ipv6_records[@]} -eq 0 ]] || \
    die "IPv4 domain ${DOMAIN} has an AAAA record (${ipv4_domain_ipv6_records[*]}). Remove it."
  [[ ${#ipv4_records[@]} -eq 1 && "${ipv4_records[0]}" == "${PUBLIC_IPV4}" ]] || \
    die "${DOMAIN} resolves to '${ipv4_records[*]}', but this VPS is ${PUBLIC_IPV4}. Point one DNS-only A record to ${PUBLIC_IPV4} and wait for propagation."

  log "IPv4 DNS is correct: ${DOMAIN} -> ${PUBLIC_IPV4}"
  ip -4 -o address show | awk -v wanted="${PUBLIC_IPV4}" \
    '{sub(/\/.*/, "", $4); if ($4 == wanted) found=1} END {exit !found}' || \
    die "Public IPv4 ${PUBLIC_IPV4} must be assigned to this VPS for the dedicated MTG listener."

  ((ENABLE_IPV6)) || return 0

  mapfile -t ipv6_domain_ipv4_records < <(dig +short A "${DOMAIN_IPV6}" | awk '/^[0-9.]+$/ {print}' | sort -u)
  mapfile -t ipv6_records < <(dig +short AAAA "${DOMAIN_IPV6}" | awk '/:/{print}' | sort -u)
  [[ ${#ipv6_domain_ipv4_records[@]} -eq 0 ]] || \
    die "IPv6 domain ${DOMAIN_IPV6} has an A record (${ipv6_domain_ipv4_records[*]}). Remove it."
  [[ ${#ipv6_records[@]} -eq 1 ]] || \
    die "${DOMAIN_IPV6} must have exactly one AAAA record; found '${ipv6_records[*]}'."

  canonical_dns_ipv6="$(canonical_ipv6 "${ipv6_records[0]}")" || \
    die "${DOMAIN_IPV6} returned an invalid IPv6 address: ${ipv6_records[0]}"
  while read -r candidate; do
    [[ -n "${candidate}" ]] || continue
    canonical_candidate="$(canonical_ipv6 "${candidate}")" || continue
    if [[ "${canonical_candidate}" == "${canonical_dns_ipv6}" ]]; then
      matched_ipv6=1
      break
    fi
  done < <(ip -6 -o address show scope global | awk '{sub(/\/.*/, "", $4); print $4}')

  ((matched_ipv6)) || \
    die "${DOMAIN_IPV6} resolves to ${canonical_dns_ipv6}, but that address is not assigned to this VPS."
  PUBLIC_IPV6="${canonical_dns_ipv6}"
  log "IPv6 DNS is correct: ${DOMAIN_IPV6} -> ${PUBLIC_IPV6}"
}

load_or_create_credentials() {
  local saved_domain
  local saved_domain_ipv6
  local fingerprint_fields
  local rewrite_state=0

  install -d -o root -g root -m 0700 "${STATE_DIR}"

  if [[ -f "${STATE_FILE}" ]]; then
    saved_domain="$(state_value DOMAIN)"
    [[ "${saved_domain}" == "${DOMAIN}" ]] || \
      die "This server was initialized for ${saved_domain}; refusing to replace it with ${DOMAIN}."
    saved_domain_ipv6="$(state_value DOMAIN_IPV6)"
    [[ "${saved_domain_ipv6}" == "${DOMAIN_IPV6}" ]] || \
      die "This server was initialized with IPv6 domain '${saved_domain_ipv6:-none}'; refusing to replace it with '${DOMAIN_IPV6:-none}'."
    RAW_SECRET="$(state_value RAW_SECRET)"
    SOCKS_USER="$(state_value SOCKS_USER)"
    SOCKS_PASSWORD="$(state_value SOCKS_PASSWORD)"
    VLESS_UUID="$(state_value VLESS_UUID)"
    VLESS_WS_PATH="$(state_value VLESS_WS_PATH)"
    HAPP_SUBSCRIPTION_ID="$(state_value HAPP_SUBSCRIPTION_ID)"
    VLESS_TLS_FINGERPRINT="$(state_value VLESS_TLS_FINGERPRINT)"
    fingerprint_fields="$(awk '/^VLESS_TLS_FINGERPRINT=/ {count++} END {print count+0}' "${STATE_FILE}")"
    if [[ "${fingerprint_fields}" == 0 ]]; then
      VLESS_TLS_FINGERPRINT="edge"
      rewrite_state=1
    elif [[ "${fingerprint_fields}" != 1 ]]; then
      die "Duplicate VLESS TLS fingerprint fields in ${STATE_FILE}."
    fi
    validate_vless_fingerprint "${VLESS_TLS_FINGERPRINT}"
    [[ "${RAW_SECRET}" =~ ^[0-9a-f]{32}$ ]] || die "Invalid RAW_SECRET in ${STATE_FILE}."
    [[ "${SOCKS_USER}" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || die "Invalid SOCKS_USER in ${STATE_FILE}."
    [[ "${SOCKS_PASSWORD}" =~ ^[0-9a-f]{32}$ ]] || die "Invalid SOCKS_PASSWORD in ${STATE_FILE}."
    if [[ ! "${VLESS_UUID}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]; then
      VLESS_UUID="$(< /proc/sys/kernel/random/uuid)"
      rewrite_state=1
    fi
    if [[ ! "${VLESS_WS_PATH}" =~ ^/[0-9a-f]{32}$ ]]; then
      VLESS_WS_PATH="/$(openssl rand -hex 16)"
      rewrite_state=1
    fi
    if [[ ! "${HAPP_SUBSCRIPTION_ID}" =~ ^[0-9a-f]{32,64}$ ]]; then
      HAPP_SUBSCRIPTION_ID="$(openssl rand -hex 20)"
      rewrite_state=1
    fi
  else
    RAW_SECRET="$(openssl rand -hex 16)"
    SOCKS_PASSWORD="$(openssl rand -hex 16)"
    VLESS_UUID="$(< /proc/sys/kernel/random/uuid)"
    VLESS_WS_PATH="/$(openssl rand -hex 16)"
    HAPP_SUBSCRIPTION_ID="$(openssl rand -hex 20)"
    rewrite_state=1
  fi

  if ((rewrite_state)); then
    write_atomic 0600 "${STATE_FILE}" <<EOF
DOMAIN=${DOMAIN}
DOMAIN_IPV6=${DOMAIN_IPV6}
RAW_SECRET=${RAW_SECRET}
SOCKS_USER=${SOCKS_USER}
SOCKS_PASSWORD=${SOCKS_PASSWORD}
VLESS_UUID=${VLESS_UUID}
VLESS_WS_PATH=${VLESS_WS_PATH}
HAPP_SUBSCRIPTION_ID=${HAPP_SUBSCRIPTION_ID}
VLESS_TLS_FINGERPRINT=${VLESS_TLS_FINGERPRINT}
EOF
    log "Saved proxy credentials and the TLS fingerprint (existing secrets are reused)"
  else
    log "Reusing the existing client credentials"
  fi
}

install_mtg() {
  local target_bin="${1:-${MTG_BIN}}"
  local archive="${WORK_DIR}/mtg-${MTG_VERSION}-linux-amd64.tar.gz"
  local extract_dir="${WORK_DIR}/mtg-release"
  local archive_member="mtg-${MTG_VERSION}-linux-amd64/mtg"

  [[ "$(uname -m)" == "x86_64" ]] || \
    die "This installer currently supports x86_64 only because the official legacy MTProxy is x86-specific."

  log "Installing MTG ${MTG_VERSION} with SHA-256 verification"
  curl -fL --retry 4 --retry-all-errors --connect-timeout 15 --max-time 180 \
    "https://github.com/9seconds/mtg/releases/download/v${MTG_VERSION}/mtg-${MTG_VERSION}-linux-amd64.tar.gz" \
    -o "${archive}"
  printf '%s  %s\n' "${MTG_SHA256_AMD64}" "${archive}" | sha256sum --check --status
  install -d -o root -g root -m 0755 "${extract_dir}"
  tar -C "${extract_dir}" -xzf "${archive}" -- "${archive_member}"
  [[ -x "${extract_dir}/${archive_member}" && ! -L "${extract_dir}/${archive_member}" ]] || \
    die "The MTG archive did not contain the expected regular executable."
  install -o root -g root -m 0755 "${extract_dir}/${archive_member}" "${target_bin}"
  if [[ "${target_bin}" == "${MTG_BIN}" ]]; then
    printf '%s\n' "${MTG_VERSION}" | write_atomic 0600 "${STATE_DIR}/mtg.version"
    printf '%s\n' "${MTG_SHA256_AMD64}" | write_atomic 0600 "${STATE_DIR}/mtg.archive.sha256"
  fi
}

install_official_mtproxy() {
  local target_bin="${1:-${MTPROXY_BIN}}"
  local source_dir="${WORK_DIR}/MTProxy"
  local jobs

  if [[ "${target_bin}" == "${MTPROXY_BIN}" && -x "${MTPROXY_BIN}" && -f "${STATE_DIR}/mtproxy.commit" ]] && \
    [[ "$(<"${STATE_DIR}/mtproxy.commit")" == "${MTPROXY_COMMIT}" ]]; then
    log "Official MTProxy ${MTPROXY_COMMIT:0:12} is already installed"
    return
  fi

  log "Building official Telegram MTProxy at pinned commit ${MTPROXY_COMMIT:0:12}"
  git init --quiet "${source_dir}"
  git -C "${source_dir}" remote add origin https://github.com/TelegramMessenger/MTProxy.git
  git -C "${source_dir}" fetch --quiet --depth 1 origin "${MTPROXY_COMMIT}"
  git -C "${source_dir}" checkout --quiet --detach FETCH_HEAD

  jobs="$(nproc)"
  ((jobs > 4)) && jobs=4
  make -C "${source_dir}" -j "${jobs}"
  install -o root -g root -m 0755 "${source_dir}/objs/bin/mtproto-proxy" "${target_bin}"
  if [[ "${target_bin}" == "${MTPROXY_BIN}" ]]; then
    printf '%s\n' "${MTPROXY_COMMIT}" | write_atomic 0600 "${STATE_DIR}/mtproxy.commit"
  fi
}

select_go_toolchain() {
  local go_archive="${WORK_DIR}/go${GO_VERSION}.linux-amd64.tar.gz"
  local go_root="/opt/go${GO_VERSION}"

  # Always use the patched, pinned toolchain rather than any older Go on PATH.
  if [[ ! -x "${go_root}/bin/go" ]]; then
    log "Installing Go ${GO_VERSION} for Telegram WEB Proxy"
    curl -fL --retry 4 --retry-all-errors --connect-timeout 15 --max-time 180 \
      "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o "${go_archive}"
    printf '%s  %s\n' "${GO_SHA256_AMD64}" "${go_archive}" | sha256sum --check --status
    install -d -o root -g root -m 0755 "${go_root}"
    tar -C "${go_root}" --strip-components=1 -xzf "${go_archive}"
  fi

  GO_BIN="${go_root}/bin/go"
  [[ "$(GOTOOLCHAIN=local "${GO_BIN}" env GOVERSION)" == "go${GO_VERSION}" ]] || \
    die "The Go toolchain in ${go_root} does not match the pinned version."
}

install_tproxy_server() {
  local target_bin="${1:-${TPROXY_SERVER_BIN}}"
  local archive="${WORK_DIR}/tproxy-server.tar.gz"
  local source_dir="${WORK_DIR}/tproxy-server-${TPROXY_SERVER_COMMIT}"

  if [[ "${target_bin}" == "${TPROXY_SERVER_BIN}" && -x "${TPROXY_SERVER_BIN}" && \
        -f "${STATE_DIR}/tproxy-server.commit" && -f "${STATE_DIR}/tproxy-server.go-version" ]] && \
    [[ "$(<"${STATE_DIR}/tproxy-server.commit")" == "${TPROXY_SERVER_COMMIT}" && \
       "$(<"${STATE_DIR}/tproxy-server.go-version")" == "${GO_VERSION}" ]]; then
    log "Telegram WEB Proxy relay ${TPROXY_SERVER_COMMIT:0:12} is already installed"
    return
  fi

  select_go_toolchain
  log "Building Telegram WEB Proxy relay at pinned commit ${TPROXY_SERVER_COMMIT:0:12}"
  curl -fL --retry 4 --retry-all-errors --connect-timeout 15 --max-time 180 \
    "https://github.com/telegramdesktop/tproxy-server/archive/${TPROXY_SERVER_COMMIT}.tar.gz" \
    -o "${archive}"
  printf '%s  %s\n' "${TPROXY_SERVER_SHA256_AMD64}" "${archive}" | sha256sum --check --status
  tar -C "${WORK_DIR}" -xzf "${archive}"
  [[ -f "${source_dir}/go.mod" ]] || die "The Telegram WEB Proxy source archive is incomplete."

  # Upstream has a permission test that intentionally creates a 0444 file.
  # The installer's protective 0077 umask would silently turn it into 0400
  # and invalidate the test fixture, so run only the test subprocess at 0022.
  # Noninteractive/systemd-run deployments may have no HOME. Keep both caches
  # in the bounded build workspace instead of depending on the login shell.
  (umask 0022; cd "${source_dir}" && GOCACHE="${WORK_DIR}/go-build" GOPATH="${WORK_DIR}/go" \
    GOTOOLCHAIN=local "${GO_BIN}" test ./...)
  (cd "${source_dir}" && GOCACHE="${WORK_DIR}/go-build" GOPATH="${WORK_DIR}/go" \
    CGO_ENABLED=0 GOTOOLCHAIN=local "${GO_BIN}" build -trimpath -ldflags='-s -w' \
    -o "${WORK_DIR}/tproxy-server" ./cmd/tproxy-server)
  install -o root -g root -m 0755 "${WORK_DIR}/tproxy-server" "${target_bin}"
  if [[ "${target_bin}" == "${TPROXY_SERVER_BIN}" ]]; then
    printf '%s\n' "${TPROXY_SERVER_COMMIT}" | write_atomic 0600 "${STATE_DIR}/tproxy-server.commit"
    printf '%s\n' "${GO_VERSION}" | write_atomic 0600 "${STATE_DIR}/tproxy-server.go-version"
  fi
}

install_xray() {
  local target_bin="${1:-${XRAY_BIN}}"
  local archive="${WORK_DIR}/Xray-linux-64.zip"
  local extract_dir="${WORK_DIR}/xray-release"
  local download_url

  [[ "$(uname -m)" == "x86_64" ]] || \
    die "This installer currently supports Xray on x86_64 only."

  log "Installing Xray ${XRAY_VERSION} with SHA-256 verification"
  download_url="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-64.zip"
  curl -fL --retry 4 --retry-all-errors --connect-timeout 15 --max-time 180 \
    "${download_url}" -o "${archive}"
  printf '%s  %s\n' "${XRAY_SHA256_AMD64}" "${archive}" | sha256sum --check --status

  install -d -o root -g root -m 0755 "${extract_dir}"
  unzip -q "${archive}" -d "${extract_dir}"
  [[ -x "${extract_dir}/xray" ]] || die "The Xray archive did not contain an executable xray binary."
  install -o root -g root -m 0755 "${extract_dir}/xray" "${target_bin}"
}

install_refresh_timer() {
  install -d -o root -g root -m 0755 "${MTPROXY_DIR}"

  write_atomic 0755 "${REFRESH_BIN}" <<'REFRESH_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly target_dir="/etc/mtproxy"
work_dir="$(mktemp -d /run/mtproxy-refresh.XXXXXX)"
trap 'rm -rf -- "${work_dir}"' EXIT

curl -fL --retry 5 --retry-all-errors --connect-timeout 15 --max-time 120 \
  https://core.telegram.org/getProxySecret -o "${work_dir}/proxy-secret"
curl -fL --retry 5 --retry-all-errors --connect-timeout 15 --max-time 120 \
  https://core.telegram.org/getProxyConfig -o "${work_dir}/proxy-multi.conf"

[[ -s "${work_dir}/proxy-secret" && -s "${work_dir}/proxy-multi.conf" ]]

changed=0
if [[ ! -f "${target_dir}/proxy-secret" ]] || ! cmp -s "${work_dir}/proxy-secret" "${target_dir}/proxy-secret"; then
  install -o root -g root -m 0600 "${work_dir}/proxy-secret" "${target_dir}/proxy-secret"
  changed=1
fi
if [[ ! -f "${target_dir}/proxy-multi.conf" ]] || ! cmp -s "${work_dir}/proxy-multi.conf" "${target_dir}/proxy-multi.conf"; then
  install -o root -g root -m 0644 "${work_dir}/proxy-multi.conf" "${target_dir}/proxy-multi.conf"
  changed=1
fi

if ((changed)); then
  units=(mtproxy.service)
  # MTG has its own Telegram connection logic and does not read these files.
  # Keep the old C frontend compatible without interrupting an MTG frontend.
  if systemctl show teleproxy.service -p ExecStart --value 2>/dev/null | \
    grep -Fq '/usr/local/bin/teleproxy'; then
    units+=(teleproxy.service)
  fi
  for unit in "${units[@]}"; do
    if systemctl is-active --quiet "${unit}"; then
      systemctl restart "${unit}"
    fi
  done
fi
REFRESH_SCRIPT

  write_atomic 0644 "/etc/systemd/system/mtproxy-config-refresh.service" <<EOF
[Unit]
Description=Refresh Telegram MTProxy relay configuration
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=${REFRESH_BIN}
EOF

  write_atomic 0644 "/etc/systemd/system/mtproxy-config-refresh.timer" <<'EOF'
[Unit]
Description=Daily refresh of Telegram MTProxy relay configuration

[Timer]
OnCalendar=daily
RandomizedDelaySec=2h
Persistent=true
Unit=mtproxy-config-refresh.service

[Install]
WantedBy=timers.target
EOF

  log "Downloading current Telegram relay configuration"
  "${REFRESH_BIN}"
}

configure_firewall() {
  local ssh_port
  local -a ssh_ports
  local -a public_ports=(80 443 8443 9443 1080)
  local public_port

  log "Configuring UFW"
  mapfile -t ssh_ports < <(/usr/sbin/sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -nu || true)
  ((${#ssh_ports[@]} > 0)) || ssh_ports=(22)

  if ((ENABLE_IPV6)) && [[ -f /etc/default/ufw ]]; then
    sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
  fi

  ufw default deny incoming
  ufw default allow outgoing
  for ssh_port in "${ssh_ports[@]}"; do
    # Preserve administrative access over every address family already
    # managed by UFW, even when the optional proxy IPv6 stack is disabled.
    ufw allow "${ssh_port}/tcp"
  done
  for public_port in "${public_ports[@]}"; do
    ufw allow proto tcp from 0.0.0.0/0 to 0.0.0.0/0 port "${public_port}"
    if ((ENABLE_IPV6)); then
      ufw allow proto tcp from ::/0 to ::/0 port "${public_port}"
    fi
  done
  ufw --force enable
}

configure_nginx_and_certificate() {
  local server_names="${DOMAIN}"
  local nginx_http_ipv6=""
  local nginx_tls_ipv6=""
  local -a certbot_domains=(--domain "${DOMAIN}")
  local certificate_needs_issue=0

  if ((ENABLE_IPV6)); then
    server_names+=" ${DOMAIN_IPV6}"
    nginx_http_ipv6="    listen [::]:80;"
    nginx_tls_ipv6="    listen [::]:9443 ssl;"
    certbot_domains+=(--domain "${DOMAIN_IPV6}")
  fi

  log "Configuring the public HTTP challenge endpoint"
  install -d -o www-data -g www-data -m 0755 "${NGINX_ROOT}/.well-known/acme-challenge"
  rm -f /etc/nginx/sites-enabled/default

  write_atomic 0644 "${NGINX_SITE}" <<EOF
map \$http_upgrade \$proxy_stack_connection {
    default upgrade;
    ''      '';
}

server {
    listen 80;
${nginx_http_ipv6}
    server_name ${server_names};

    location ^~ /.well-known/acme-challenge/ {
        root ${NGINX_ROOT};
        default_type text/plain;
    }

    location / {
        return 200 "Proxy endpoint is being configured.\n";
        add_header Content-Type text/plain;
    }
}
EOF
  ln -sfn "${NGINX_SITE}" "${NGINX_SITE_LINK}"
  nginx -t
  systemctl enable --now nginx.service
  systemctl reload nginx.service

  if [[ ! -s "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]] || \
    ! openssl x509 -checkend 86400 -noout -in "/etc/letsencrypt/live/${DOMAIN}/cert.pem"; then
    certificate_needs_issue=1
  elif ! openssl x509 -noout -checkhost "${DOMAIN}" -in "/etc/letsencrypt/live/${DOMAIN}/cert.pem" >/dev/null; then
    certificate_needs_issue=1
  elif ((ENABLE_IPV6)) && \
    ! openssl x509 -noout -checkhost "${DOMAIN_IPV6}" -in "/etc/letsencrypt/live/${DOMAIN}/cert.pem" >/dev/null; then
    certificate_needs_issue=1
  fi

  if ((certificate_needs_issue)); then
    log "Requesting a Let's Encrypt certificate for ${DOMAIN}"
    certbot certonly \
      --webroot \
      --webroot-path "${NGINX_ROOT}" \
      --cert-name "${DOMAIN}" \
      --expand \
      "${certbot_domains[@]}" \
      --non-interactive \
      --agree-tos \
      --register-unsafely-without-email \
      --keep-until-expiring
  else
    log "Reusing the existing valid Let's Encrypt certificate"
  fi

  write_atomic 0644 "${NGINX_ROOT}/index.html" <<EOF
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Welcome</title></head>
<body><main><h1>Welcome</h1><p>${DOMAIN}</p></main></body>
</html>
EOF

  write_atomic 0644 "${NGINX_SITE}" <<EOF
map \$http_upgrade \$proxy_stack_connection {
    default upgrade;
    ''      '';
}

server {
    listen 80;
${nginx_http_ipv6}
    server_name ${server_names};

    location ^~ /.well-known/acme-challenge/ {
        root ${NGINX_ROOT};
        default_type text/plain;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 127.0.0.1:8444 ssl http2 default_server;
    server_name ${server_names};
    server_tokens off;
    access_log off;
    client_max_body_size 2m;

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_ecdh_curve X25519:prime256v1;
    ssl_conf_command Ciphersuites TLS_AES_128_GCM_SHA256;

    location = ${VLESS_WS_PATH} {
        proxy_pass http://127.0.0.1:10000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 1d;
        proxy_send_timeout 1d;
    }

    location ^~ /happ/ {
        root ${NGINX_ROOT};
        default_type text/plain;
        add_header Cache-Control "no-cache" always;
        try_files \$uri =404;
    }

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$proxy_stack_connection;
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_read_timeout 1d;
        proxy_send_timeout 1d;
    }
}

server {
    listen 9443 ssl;
${nginx_tls_ipv6}
    server_name ${server_names};
    server_tokens off;

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:VlessTls:10m;
    ssl_session_timeout 10m;

    root ${NGINX_ROOT};

    location = ${VLESS_WS_PATH} {
        proxy_pass http://127.0.0.1:10000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 1d;
        proxy_send_timeout 1d;
    }

    location ^~ /happ/ {
        default_type text/plain;
        add_header Cache-Control "no-cache" always;
        try_files \$uri =404;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

  write_atomic 0755 "/etc/letsencrypt/renewal-hooks/deploy/proxy-stack-reload" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
nginx -t
systemctl reload nginx.service
if systemctl show teleproxy.service -p ExecStart --value 2>/dev/null | \
  grep -Fq '/usr/local/bin/teleproxy'; then
  systemctl try-restart teleproxy.service
fi
EOF

  nginx -t
  systemctl reload nginx.service
  systemctl enable --now certbot.timer 2>/dev/null || warn "certbot.timer was not available; certbot's packaged cron job may be in use instead."
}

configure_dante() {
  local external_interface
  local dante_ipv6_internal=""
  local dante_ipv6_blocks=""

  log "Configuring authenticated SOCKS5"
  external_interface="$(ip -4 route show default | awk 'NR == 1 {for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')"
  [[ -n "${external_interface}" && -d "/sys/class/net/${external_interface}" ]] || \
    die "Could not determine the default IPv4 network interface."

  if id "${SOCKS_USER}" >/dev/null 2>&1; then
    usermod --shell /usr/sbin/nologin "${SOCKS_USER}"
  else
    useradd --system --no-create-home --shell /usr/sbin/nologin "${SOCKS_USER}"
  fi
  printf '%s:%s\n' "${SOCKS_USER}" "${SOCKS_PASSWORD}" | chpasswd

  if ((ENABLE_IPV6)); then
    dante_ipv6_internal="internal: :: port = 1080"
    dante_ipv6_blocks="$(cat <<EOF
socks block { from: 0/0 to: ::/128 }
socks block { from: 0/0 to: ::1/128 }
socks block { from: 0/0 to: fc00::/7 }
socks block { from: 0/0 to: fe80::/10 }
socks block { from: 0/0 to: ff00::/8 }
socks block { from: 0/0 to: ${PUBLIC_IPV6}/128 }
EOF
)"
  fi

  write_atomic 0644 "/etc/danted.conf" <<EOF
logoutput: syslog
internal: 0.0.0.0 port = 1080
${dante_ipv6_internal}
external: ${external_interface}

clientmethod: none
socksmethod: username

user.privileged: root
user.unprivileged: nobody
user.libwrap: nobody

client pass {
    from: 0/0 to: 0/0
    log: connect disconnect error
}

socks block { from: 0/0 to: 0.0.0.0/8 }
socks block { from: 0/0 to: 10.0.0.0/8 }
socks block { from: 0/0 to: 100.64.0.0/10 }
socks block { from: 0/0 to: 127.0.0.0/8 }
socks block { from: 0/0 to: 169.254.0.0/16 }
socks block { from: 0/0 to: 172.16.0.0/12 }
socks block { from: 0/0 to: 192.0.0.0/24 }
socks block { from: 0/0 to: 192.0.2.0/24 }
socks block { from: 0/0 to: 192.168.0.0/16 }
socks block { from: 0/0 to: 198.18.0.0/15 }
socks block { from: 0/0 to: 198.51.100.0/24 }
socks block { from: 0/0 to: 203.0.113.0/24 }
socks block { from: 0/0 to: 224.0.0.0/4 }
socks block { from: 0/0 to: 240.0.0.0/4 }
socks block { from: 0/0 to: ${PUBLIC_IPV4}/32 }
${dante_ipv6_blocks}

socks pass {
    from: 0/0 to: 0/0
    command: connect
    protocol: tcp
    socksmethod: username
    log: connect disconnect error
}
EOF

  /usr/sbin/danted -V -f /etc/danted.conf
}

vless_uri() {
  local address=$1
  local tls_domain=$2
  local title=$3
  local port=${4:-443}
  local encoded_path="%2F${VLESS_WS_PATH#/}"

  validate_vless_fingerprint "${VLESS_TLS_FINGERPRINT}"
  printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=%s&alpn=http%%2F1.1&type=ws&host=%s&path=%s#%s' \
    "${VLESS_UUID}" "${address}" "${port}" "${tls_domain}" "${VLESS_TLS_FINGERPRINT}" \
    "${tls_domain}" "${encoded_path}" "${title}"
}

configure_xray() {
  log "Configuring VLESS WebSocket backend"
  install -d -o root -g root -m 0755 "${XRAY_CONFIG_DIR}"

  write_atomic 0644 "${XRAY_CONFIG}" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-ws-10000",
      "listen": "127.0.0.1",
      "port": 10000,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${VLESS_UUID}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "${VLESS_WS_PATH}"
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ]
}
EOF

  "${XRAY_BIN}" run -test -config "${XRAY_CONFIG}"

  write_atomic 0644 "/etc/systemd/system/xray.service" <<EOF
[Unit]
Description=Xray VLESS WebSocket backend
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=nobody
Group=nogroup
ExecStart=${XRAY_BIN} run -config ${XRAY_CONFIG}
Restart=on-failure
RestartSec=3s
LimitNOFILE=65536
NoNewPrivileges=true
PrivateDevices=true
PrivateTmp=true
ProtectControlGroups=true
ProtectHome=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectSystem=full
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
EOF
}

configure_tproxy_server() {
  local token_key="${TPROXY_SERVER_DIR}/token.key"
  local temporary_key="${WORK_DIR}/tproxy-token.key"

  log "Configuring Telegram WEB Proxy relay"
  if ! id tproxy >/dev/null 2>&1; then
    useradd --system --home /nonexistent --shell /usr/sbin/nologin tproxy
  fi
  install -d -o root -g tproxy -m 0750 "${TPROXY_SERVER_DIR}"

  if [[ -L "${token_key}" ]] || { [[ -e "${token_key}" ]] && [[ ! -f "${token_key}" ]]; }; then
    die "Telegram WEB Proxy token key must be a regular file: ${token_key}"
  fi
  if [[ ! -e "${token_key}" ]]; then
    openssl rand 32 >"${temporary_key}"
    install -o tproxy -g tproxy -m 0400 "${temporary_key}" "${token_key}"
  fi
  [[ "$(wc -c <"${token_key}")" -eq 32 ]] || \
    die "Telegram WEB Proxy token key must contain exactly 32 bytes."
  chown tproxy:tproxy "${token_key}"
  chmod 0400 "${token_key}"

  write_atomic 0640 "${TPROXY_SERVER_CONFIG}" <<EOF
{
  "public_hostname": "${DOMAIN}",
  "listen": "127.0.0.1:8080",
  "admin_listen": "127.0.0.1:8081",
  "public_dir": "${NGINX_ROOT}",
  "static_routes": "exact",
  "token_key_file": "${token_key}",
  "profiles_file": "/run/credentials/tproxy-server.service/profiles.json"
}
EOF
  chown root:tproxy "${TPROXY_SERVER_CONFIG}"

  write_atomic 0400 "${TPROXY_SERVER_PROFILES}" <<EOF
{"profiles":[{"name":"default","secret":"dd${RAW_SECRET}","backend":"127.0.0.1:8443","carrier_mode":"websocket"}]}
EOF
  chown root:tproxy "${TPROXY_SERVER_PROFILES}"

  "${TPROXY_SERVER_BIN}" -config "${TPROXY_SERVER_CONFIG}" \
    -profiles-file "${TPROXY_SERVER_PROFILES}" -check

  write_atomic 0644 "/etc/systemd/system/tproxy-server.service" <<EOF
[Unit]
Description=Telegram WEB Proxy HTTPS transport relay
After=network-online.target mtproxy.service
Wants=network-online.target mtproxy.service

[Service]
Type=simple
User=tproxy
Group=tproxy
LoadCredential=profiles.json:${TPROXY_SERVER_PROFILES}
ExecStart=${TPROXY_SERVER_BIN} -config ${TPROXY_SERVER_CONFIG}
Restart=on-failure
RestartSec=3s
TimeoutStopSec=20s
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateDevices=true
PrivateTmp=true
ProtectClock=true
ProtectControlGroups=true
ProtectHome=true
ProtectHostname=true
ProtectKernelLogs=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectProc=invisible
ProtectSystem=strict
ProcSubset=pid
ReadOnlyPaths=-${NGINX_ROOT}
RestrictAddressFamilies=AF_INET AF_INET6
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
CapabilityBoundingSet=
IPAddressDeny=any
IPAddressAllow=localhost
SystemCallArchitectures=native
SystemCallFilter=@system-service
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
}

write_happ_subscription() {
  local subscription_dir="${NGINX_ROOT}/happ"
  local subscription_file="${subscription_dir}/${HAPP_SUBSCRIPTION_ID}.txt"

  log "Writing the Happ VLESS subscription"
  install -d -o root -g root -m 0755 "${subscription_dir}"

  if ((ENABLE_IPV6)); then
    write_atomic 0644 "${subscription_file}" <<EOF
#proxy-enable: 1
#fragmentation-enable: 0
$(vless_uri "${PUBLIC_IPV4}" "${DOMAIN}" "${DOMAIN}-VLESS-WS-443-IPv4")
$(vless_uri "${PUBLIC_IPV4}" "${DOMAIN}" "${DOMAIN}-VLESS-WS-9443-IPv4" 9443)
$(vless_uri "[${PUBLIC_IPV6}]" "${DOMAIN_IPV6}" "${DOMAIN_IPV6}-VLESS-WS-443-IPv6")
$(vless_uri "[${PUBLIC_IPV6}]" "${DOMAIN_IPV6}" "${DOMAIN_IPV6}-VLESS-WS-9443-IPv6" 9443)
EOF
  else
    write_atomic 0644 "${subscription_file}" <<EOF
#proxy-enable: 1
#fragmentation-enable: 0
$(vless_uri "${PUBLIC_IPV4}" "${DOMAIN}" "${DOMAIN}-VLESS-WS-443-IPv4")
$(vless_uri "${PUBLIC_IPV4}" "${DOMAIN}" "${DOMAIN}-VLESS-WS-9443-IPv4" 9443)
EOF
  fi
}

write_mtg_config() {
  local config_file=$1
  local domain=$2
  local bind_address=$3
  local public_ip_key=$4
  local public_ip=$5
  local prefer_ip=$6
  local stats_port=$7
  local domain_hex

  domain_hex="$(printf '%s' "${domain}" | xxd -p -c 256)"
  write_atomic 0600 "${config_file}" <<EOF
debug = false
secret = "ee${RAW_SECRET}${domain_hex}"
bind-to = "${bind_address}:443"
prefer-ip = "${prefer_ip}"
${public_ip_key} = "${public_ip}"
auto-update = false

[domain-fronting]
host = "127.0.0.1"
port = 8444

[network]
dns = ""

# Match the previous frontend's client policy. Authentication and the default
# anti-replay checks remain enabled; external blocklists are not required.
[defense.blocklist]
enabled = false

[stats.prometheus]
enabled = true
bind-to = "127.0.0.1:${stats_port}"
http-path = "/stats"
metric-prefix = "mtg"
EOF
}

write_mtg_unit() {
  local unit_name=$1
  local config_file=$2
  local family=$3

  write_atomic 0644 "/etc/systemd/system/${unit_name}" <<EOF
[Unit]
Description=MTG FakeTLS MTProto frontend (${family}, compatible service name)
Wants=network-online.target
After=network-online.target nginx.service
Requires=nginx.service

[Service]
Type=simple
User=mtg
Group=mtg
EnvironmentFile=
WorkingDirectory=${MTPROXY_DIR}
LoadCredential=mtg.toml:${config_file}
ExecStart=${MTG_BIN} run %d/mtg.toml
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateDevices=true
PrivateTmp=true
ProtectControlGroups=true
ProtectHome=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectSystem=full
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictSUIDSGID=true
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
}

verify_mtg_config() {
  local config_file=$1
  local family=$2
  local private_log="${STATE_DIR}/mtg-doctor-${family}.log"

  # doctor checks the EE secret, fronting TLS, Telegram, DNS and time without
  # binding the live listener. Never dump a private configuration/error log.
  if ! "${MTG_BIN}" doctor "${config_file}" >"${private_log}" 2>&1; then
    chmod 0600 "${private_log}"
    die "MTG doctor failed for ${family}; inspect the root-only ${private_log}."
  fi
  chmod 0600 "${private_log}"
}

configure_mtg_frontends() {
  local ipv6_metadata=""
  if id mtg >/dev/null 2>&1; then
    [[ "$(id -u mtg)" != 0 && "$(id -gn mtg)" == mtg && \
       "$(getent passwd mtg | cut -d: -f7)" == /usr/sbin/nologin ]] || \
      die "An existing mtg account is not the dedicated unprivileged service account."
  else
    useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin mtg
  fi

  # MTG checks the SNI embedded in each EE secret. Separate exact-IP listeners
  # are required for the two domain names, without Go wildcard dual-stack binds.
  write_mtg_config "${MTG_CONFIG}" "${DOMAIN}" "${PUBLIC_IPV4}" \
    public-ipv4 "${PUBLIC_IPV4}" only-ipv4 8888
  write_mtg_unit teleproxy.service "${MTG_CONFIG}" IPv4
  verify_mtg_config "${MTG_CONFIG}" ipv4

  if ((ENABLE_IPV6)); then
    write_mtg_config "${MTG_IPV6_CONFIG}" "${DOMAIN_IPV6}" "[${PUBLIC_IPV6}]" \
      public-ipv6 "${PUBLIC_IPV6}" prefer-ipv6 8890
    write_mtg_unit teleproxy-ipv6.service "${MTG_IPV6_CONFIG}" IPv6
    verify_mtg_config "${MTG_IPV6_CONFIG}" ipv6
    ipv6_metadata="$(printf '%s\n' 'FAKETLS_IPV6_SERVICE=teleproxy-ipv6.service' \
      "FAKETLS_IPV6_CONFIG=${MTG_IPV6_CONFIG}")"
  fi

  write_atomic 0600 "${FRONTEND_METADATA}" <<EOF
FAKETLS_ENGINE=mtg
FAKETLS_SERVICE=teleproxy.service
FAKETLS_CONFIG=${MTG_CONFIG}
FAKETLS_BINARY=${MTG_BIN}
VLESS_TLS_FINGERPRINT=${VLESS_TLS_FINGERPRINT}
${ipv6_metadata}
EOF
}

install_proxy_services() {
  local backup_dir=${1:-}
  local compatibility_dropin=/etc/systemd/system/teleproxy.service.d/90-proxy-stack-mtg.conf

  write_atomic 0600 "${STATE_DIR}/services.env" <<EOF
DOMAIN=${DOMAIN}
DOMAIN_IPV6=${DOMAIN_IPV6}
RAW_SECRET=${RAW_SECRET}
EOF

  configure_mtg_frontends
  # Fold our earlier host-local override into the canonical unit. Preserve it
  # in the installation backup; unrelated operator drop-ins are never removed.
  if [[ -f "${compatibility_dropin}" ]] && \
    grep -Fxq '# Proxy Stack MTG compatible frontend' "${compatibility_dropin}"; then
    [[ -d "${backup_dir}" ]] || die "A backup directory is required to retire the previous MTG override."
    mv -- "${compatibility_dropin}" "${backup_dir}/retired-mtg-override.conf"
  fi

  write_atomic 0644 "/etc/systemd/system/mtproxy.service" <<EOF
[Unit]
Description=Official Telegram MTProxy (legacy random-padding endpoint)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
EnvironmentFile=${STATE_DIR}/services.env
WorkingDirectory=${MTPROXY_DIR}
ExecStart=${MTPROXY_BIN} -u nobody -p 8889 -H 8443 -S \${RAW_SECRET} --http-stats --aes-pwd ${MTPROXY_DIR}/proxy-secret ${MTPROXY_DIR}/proxy-multi.conf -M 1
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
NoNewPrivileges=true
PrivateDevices=true
PrivateTmp=true
ProtectControlGroups=true
ProtectHome=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectSystem=full
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
EOF

  if ((ENABLE_IPV6)); then
    write_atomic 0644 "/etc/systemd/system/mtproxy-ipv6.service" <<'EOF'
[Unit]
Description=IPv6 frontend for Telegram MTProto Proxy
Wants=network-online.target
After=network-online.target mtproxy.service
Requires=mtproxy.service

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP6-LISTEN:8443,ipv6only=1,reuseaddr,fork,nodelay TCP4:127.0.0.1:8443,nodelay
Restart=always
RestartSec=2s
User=nobody
NoNewPrivileges=true
PrivateTmp=true
ProtectControlGroups=true
ProtectHome=true
ProtectKernelTunables=true
ProtectSystem=strict
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
EOF
  fi

  systemctl daemon-reload
  systemctl enable mtproxy-config-refresh.timer mtproxy.service teleproxy.service tproxy-server.service danted.service xray.service
  if ((ENABLE_IPV6)); then
    systemctl enable mtproxy-ipv6.service teleproxy-ipv6.service
  fi
  systemctl restart nginx.service
  systemctl restart danted.service
  systemctl restart xray.service
  systemctl restart mtproxy.service
  systemctl restart tproxy-server.service
  if ((ENABLE_IPV6)); then
    systemctl restart mtproxy-ipv6.service
    systemctl restart teleproxy-ipv6.service
  fi
  systemctl restart teleproxy.service
  systemctl start mtproxy-config-refresh.timer
}

retry() {
  local attempts=$1
  local delay=$2
  local count
  shift 2

  for ((count = 1; count <= attempts; count++)); do
    if "$@"; then
      return 0
    fi
    sleep "${delay}"
  done
  return 1
}

web_proxy_capability() {
  printf 'tdesktop-web-proxy-bridge-v1\n%s' "${DOMAIN}" | \
    openssl dgst -sha256 -mac HMAC -macopt "hexkey:dd${RAW_SECRET}" -binary | \
    openssl base64 -A | tr '+/' '-_' | tr -d '='
}

verify_web_proxy_endpoint() {
  local bridge_capability
  local bootstrap_token
  local session_token
  local http_code
  local bridge_page="${WORK_DIR}/web-proxy-bridge.html"
  local hello_frame="${WORK_DIR}/web-proxy-hello.bin"
  local welcome_frame="${WORK_DIR}/web-proxy-welcome.bin"
  local session_headers="${WORK_DIR}/web-proxy-session.headers"
  local websocket_headers="${WORK_DIR}/web-proxy-websocket.headers"

  bridge_capability="$(web_proxy_capability)"
  retry 12 1 curl -fsS --max-time 8 --resolve "${DOMAIN}:443:${PUBLIC_IPV4}" \
    "https://${DOMAIN}/?bridge=${bridge_capability}" -o "${bridge_page}"
  bootstrap_token="$(sed -n 's/.*bootstrap="\([A-Za-z0-9_-]\{43\}\)".*/\1/p' "${bridge_page}" | head -n 1)"
  [[ "${bootstrap_token}" =~ ^[A-Za-z0-9_-]{43}$ ]] || \
    die "Telegram WEB Proxy bridge page did not contain a valid bootstrap token."

  printf '100000000000000101' | xxd -r -p >"${hello_frame}"
  http_code="$(curl -sS --max-time 8 --resolve "${DOMAIN}:443:${PUBLIC_IPV4}" \
    -D "${session_headers}" -o "${welcome_frame}" -w '%{http_code}' \
    -H "Authorization: Bearer ${bootstrap_token}" \
    -H 'Content-Type: application/octet-stream' \
    --data-binary "@${hello_frame}" "https://${DOMAIN}/api/v1/session")"
  [[ "${http_code}" == 200 && "$(xxd -p -c 256 "${welcome_frame}")" == 1100000000000000 ]] || \
    die "Telegram WEB Proxy refused a carrier session."
  awk 'BEGIN {IGNORECASE=1} {sub(/\r$/, "")} $0 == "X-Carrier-Mode: websocket" {found=1} END {exit !found}' \
    "${session_headers}" || \
    die "Telegram WEB Proxy returned an unexpected carrier mode."
  session_token="$(awk 'BEGIN {IGNORECASE=1} /^X-Session-Token:/ {gsub(/\r/, ""); print $2; exit}' "${session_headers}")"
  [[ "${session_token}" =~ ^[A-Za-z0-9_-]{43}$ ]] || \
    die "Telegram WEB Proxy did not return a valid session token."

  curl -sS --http1.1 --max-time 2 --resolve "${DOMAIN}:443:${PUBLIC_IPV4}" \
    -D "${websocket_headers}" -o /dev/null \
    -H 'Connection: Upgrade' \
    -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    -H "Origin: https://${DOMAIN}" \
    -H "Sec-WebSocket-Protocol: tproxy-v1.${session_token}" \
    "https://${DOMAIN}/api/v1/ws" 2>/dev/null || true
  grep -Eq '^HTTP/1\.[01] 101([[:space:]]|$)' "${websocket_headers}" || \
    die "Telegram WEB Proxy WebSocket upgrade failed."
  grep -Fqi "Sec-WebSocket-Protocol: tproxy-v1.${session_token}" "${websocket_headers}" || \
    die "Telegram WEB Proxy WebSocket subprotocol was not accepted."
}

verify_vless_endpoint() {
  local address=$1
  local tls_domain=$2
  local server_port=$3
  local socks_port=$4
  local check_url=$5
  local expected_address=$6
  local client_config="${WORK_DIR}/xray-client-${socks_port}.json"
  local client_log="${WORK_DIR}/xray-client-${socks_port}.log"
  local result=""
  local attempt

  validate_vless_fingerprint "${VLESS_TLS_FINGERPRINT}"
  cat >"${client_config}" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": ${socks_port},
      "protocol": "socks",
      "settings": {
        "udp": false
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${address}",
            "port": ${server_port},
            "users": [
              {
                "id": "${VLESS_UUID}",
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${tls_domain}",
          "allowInsecure": false,
          "fingerprint": "${VLESS_TLS_FINGERPRINT}",
          "alpn": [
            "http/1.1"
          ]
        },
        "wsSettings": {
          "path": "${VLESS_WS_PATH}",
          "headers": {
            "Host": "${tls_domain}"
          }
        }
      }
    }
  ]
}
EOF

  "${XRAY_BIN}" run -test -config "${client_config}" >/dev/null
  "${XRAY_BIN}" run -config "${client_config}" >"${client_log}" 2>&1 &
  XRAY_TEST_PID=$!

  for ((attempt = 1; attempt <= 15; attempt++)); do
    result="$(curl -fsS --connect-timeout 5 --max-time 15 \
      --proxy "socks5h://127.0.0.1:${socks_port}" "${check_url}" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ -n "${result}" ]] && break
    sleep 1
  done

  kill "${XRAY_TEST_PID}" 2>/dev/null || true
  wait "${XRAY_TEST_PID}" 2>/dev/null || true
  XRAY_TEST_PID=""

  if [[ "${expected_address}" == *:* ]]; then
    result="$(canonical_ipv6 "${result}")" || {
      cat "${client_log}" >&2
      die "VLESS IPv6 test returned an invalid address: ${result}"
    }
    expected_address="$(canonical_ipv6 "${expected_address}")"
  fi

  if [[ "${result}" != "${expected_address}" ]]; then
    cat "${client_log}" >&2
    die "VLESS test through ${address}:${server_port} returned '${result}' instead of '${expected_address}'."
  fi
}

verify_services() {
  local service
  local socks_result
  local -a services=(
    nginx.service
    danted.service
    xray.service
    mtproxy.service
    tproxy-server.service
    teleproxy.service
    mtproxy-config-refresh.timer
  )

  if ((ENABLE_IPV6)); then
    services+=(mtproxy-ipv6.service)
    if [[ "${FAKETLS_ENGINE}" == mtg ]]; then
      services+=(teleproxy-ipv6.service)
    fi
  fi

  log "Verifying services and local endpoints"
  for service in "${services[@]}"; do
    systemctl is-active --quiet "${service}" || {
      systemctl --no-pager --full status "${service}" >&2 || true
      die "${service} is not active."
    }
  done

  retry 12 1 curl -fsS --max-time 5 http://127.0.0.1:8888/stats >/dev/null
  if ((ENABLE_IPV6)) && [[ "${FAKETLS_ENGINE}" == mtg ]]; then
    retry 12 1 curl -fsS --max-time 5 http://127.0.0.1:8890/stats >/dev/null
  fi
  retry 12 1 curl -fsS --max-time 5 http://127.0.0.1:8889/stats >/dev/null
  retry 12 1 curl -fsS --max-time 5 http://127.0.0.1:8081/healthz >/dev/null
  retry 12 1 curl -fsS --max-time 5 http://127.0.0.1:8081/readyz >/dev/null
  retry 12 1 curl -fsS --max-time 8 --resolve "${DOMAIN}:443:${PUBLIC_IPV4}" "https://${DOMAIN}/" >/dev/null
  retry 12 1 curl -fsS --max-time 8 --resolve "${DOMAIN}:443:${PUBLIC_IPV4}" \
    "https://${DOMAIN}/happ/${HAPP_SUBSCRIPTION_ID}.txt" >/dev/null
  retry 12 1 curl -fsS --max-time 8 --resolve "${DOMAIN}:9443:127.0.0.1" \
    "https://${DOMAIN}:9443/happ/${HAPP_SUBSCRIPTION_ID}.txt" >/dev/null

  verify_web_proxy_endpoint

  socks_result="$(curl -4fsS --connect-timeout 10 --max-time 30 \
    --proxy "socks5h://${SOCKS_USER}:${SOCKS_PASSWORD}@127.0.0.1:1080" \
    https://api.ipify.org | tr -d '[:space:]')"
  [[ "${socks_result}" == "${PUBLIC_IPV4}" ]] || \
    die "SOCKS5 test returned '${socks_result}' instead of '${PUBLIC_IPV4}'."

  verify_vless_endpoint "${PUBLIC_IPV4}" "${DOMAIN}" 443 10991 \
    "https://api.ipify.org" "${PUBLIC_IPV4}"
  verify_vless_endpoint "${PUBLIC_IPV4}" "${DOMAIN}" 9443 10993 \
    "https://api.ipify.org" "${PUBLIC_IPV4}"

  if ((ENABLE_IPV6)); then
    retry 12 1 curl -gfsS --max-time 8 --resolve "${DOMAIN_IPV6}:443:[${PUBLIC_IPV6}]" \
      "https://${DOMAIN_IPV6}/" >/dev/null
    socks_result="$(curl -fsS --connect-timeout 10 --max-time 30 \
      --proxy "socks5h://${SOCKS_USER}:${SOCKS_PASSWORD}@[::1]:1080" \
      https://api.ipify.org | tr -d '[:space:]')"
    [[ "${socks_result}" == "${PUBLIC_IPV4}" ]] || \
      die "SOCKS5 test through the IPv6 listener returned '${socks_result}' instead of '${PUBLIC_IPV4}'."
    verify_vless_endpoint "${PUBLIC_IPV6}" "${DOMAIN_IPV6}" 443 10992 \
      "https://api6.ipify.org" "${PUBLIC_IPV6}"
    verify_vless_endpoint "${PUBLIC_IPV6}" "${DOMAIN_IPV6}" 9443 10994 \
      "https://api6.ipify.org" "${PUBLIC_IPV6}"
  fi
}

write_credentials_output() {
  local domain_hex_ipv4
  local domain_hex_ipv6=""
  local faketls_secret_ipv4
  local faketls_secret_ipv6=""
  local ipv6_output=""
  local legacy_secret

  domain_hex_ipv4="$(printf '%s' "${DOMAIN}" | xxd -p -c 256)"
  faketls_secret_ipv4="ee${RAW_SECRET}${domain_hex_ipv4}"
  legacy_secret="dd${RAW_SECRET}"

  if ((ENABLE_IPV6)); then
    domain_hex_ipv6="$(printf '%s' "${DOMAIN_IPV6}" | xxd -p -c 256)"
    faketls_secret_ipv6="ee${RAW_SECRET}${domain_hex_ipv6}"
    ipv6_output="$(cat <<EOF

VIA IPV6 DOMAIN

MTProto FakeTLS (primary)
Type: MTProto
Server: ${DOMAIN_IPV6}
Port: 443
Secret: ${faketls_secret_ipv6}

MTProto legacy (reserve)
Type: MTProto
Server: ${DOMAIN_IPV6}
Port: 8443
Secret: ${legacy_secret}

SOCKS5
Type: SOCKS5
Server: ${DOMAIN_IPV6}
Port: 1080
Username: ${SOCKS_USER}
Password: ${SOCKS_PASSWORD}

Happ SOCKS URI:
socks://${SOCKS_USER}:${SOCKS_PASSWORD}@${DOMAIN_IPV6}:1080#SOCKS5-IPv6

VLESS WebSocket + TLS
Type: VLESS
Server: ${DOMAIN_IPV6}
Ports: 443 (primary), 9443 (reserve)
UUID: ${VLESS_UUID}
Transport: WebSocket
TLS/SNI/Host: ${DOMAIN_IPV6}
TLS Fingerprint: ${VLESS_TLS_FINGERPRINT}
Path: ${VLESS_WS_PATH}

VLESS URI (primary):
$(vless_uri "${DOMAIN_IPV6}" "${DOMAIN_IPV6}" "${DOMAIN_IPV6}-VLESS-WS-443-IPv6")

VLESS URI (reserve):
$(vless_uri "${DOMAIN_IPV6}" "${DOMAIN_IPV6}" "${DOMAIN_IPV6}-VLESS-WS-9443-IPv6" 9443)

VIA IPV6 ADDRESS

MTProto FakeTLS (primary)
Type: MTProto
Server: ${PUBLIC_IPV6}
Port: 443
Secret: ${faketls_secret_ipv6}

MTProto legacy (reserve)
Type: MTProto
Server: ${PUBLIC_IPV6}
Port: 8443
Secret: ${legacy_secret}

SOCKS5
Type: SOCKS5
Server: ${PUBLIC_IPV6}
Port: 1080
Username: ${SOCKS_USER}
Password: ${SOCKS_PASSWORD}

Happ SOCKS URI:
socks://${SOCKS_USER}:${SOCKS_PASSWORD}@[${PUBLIC_IPV6}]:1080#SOCKS5-IPv6-IP

VLESS URI (primary):
$(vless_uri "[${PUBLIC_IPV6}]" "${DOMAIN_IPV6}" "${DOMAIN_IPV6}-VLESS-WS-443-IPv6-IP")

VLESS URI (reserve):
$(vless_uri "[${PUBLIC_IPV6}]" "${DOMAIN_IPV6}" "${DOMAIN_IPV6}-VLESS-WS-9443-IPv6-IP" 9443)

Happ VLESS subscription over IPv6:
https://${DOMAIN_IPV6}/happ/${HAPP_SUBSCRIPTION_ID}.txt
EOF
)"
  fi

  write_atomic 0600 "${CREDENTIALS_OUTPUT}" <<EOF
PROXY CONFIGURATION
Generated: $(date --iso-8601=seconds)

VIA IPV4 DOMAIN

MTProto FakeTLS (primary)
Type: MTProto
Server: ${DOMAIN}
Port: 443
Secret: ${faketls_secret_ipv4}

MTProto legacy (reserve)
Type: MTProto
Server: ${DOMAIN}
Port: 8443
Secret: ${legacy_secret}

Telegram WEB Proxy (experimental)
Type: WEB Proxy
Hostname: ${DOMAIN}
Port: 443 (fixed by the protocol)
Secret: ${legacy_secret}
Link: tg://webproxy?server=${DOMAIN}&secret=${legacy_secret}

SOCKS5
Type: SOCKS5
Server: ${DOMAIN}
Port: 1080
Username: ${SOCKS_USER}
Password: ${SOCKS_PASSWORD}

Happ SOCKS URI:
socks://${SOCKS_USER}:${SOCKS_PASSWORD}@${DOMAIN}:1080#SOCKS5-IPv4

VLESS WebSocket + TLS
Type: VLESS
Server: ${DOMAIN}
Ports: 443 (primary), 9443 (reserve)
UUID: ${VLESS_UUID}
Transport: WebSocket
TLS/SNI/Host: ${DOMAIN}
TLS Fingerprint: ${VLESS_TLS_FINGERPRINT}
Path: ${VLESS_WS_PATH}

VLESS URI (primary):
$(vless_uri "${DOMAIN}" "${DOMAIN}" "${DOMAIN}-VLESS-WS-443-IPv4")

VLESS URI (reserve):
$(vless_uri "${DOMAIN}" "${DOMAIN}" "${DOMAIN}-VLESS-WS-9443-IPv4" 9443)

Happ VLESS subscription:
https://${DOMAIN}/happ/${HAPP_SUBSCRIPTION_ID}.txt

VIA IPV4 ADDRESS

MTProto FakeTLS (primary)
Type: MTProto
Server: ${PUBLIC_IPV4}
Port: 443
Secret: ${faketls_secret_ipv4}

MTProto legacy (reserve)
Type: MTProto
Server: ${PUBLIC_IPV4}
Port: 8443
Secret: ${legacy_secret}

SOCKS5
Type: SOCKS5
Server: ${PUBLIC_IPV4}
Port: 1080
Username: ${SOCKS_USER}
Password: ${SOCKS_PASSWORD}

Happ SOCKS URI:
socks://${SOCKS_USER}:${SOCKS_PASSWORD}@${PUBLIC_IPV4}:1080#SOCKS5-IPv4-IP

VLESS URI (primary):
$(vless_uri "${PUBLIC_IPV4}" "${DOMAIN}" "${DOMAIN}-VLESS-WS-443-IPv4-IP")

VLESS URI (reserve):
$(vless_uri "${PUBLIC_IPV4}" "${DOMAIN}" "${DOMAIN}-VLESS-WS-9443-IPv4-IP" 9443)
${ipv6_output}

ADMINISTRATION
Credentials file: ${CREDENTIALS_OUTPUT}
FakeTLS engine: MTG ${MTG_VERSION} (service name: teleproxy.service)
FakeTLS config: ${MTG_CONFIG}
FakeTLS IPv6 config (only when enabled): ${MTG_IPV6_CONFIG}
Xray config: ${XRAY_CONFIG}
Telegram WEB Proxy config: ${TPROXY_SERVER_CONFIG}
Happ subscription file: ${NGINX_ROOT}/happ/${HAPP_SUBSCRIPTION_ID}.txt
FakeTLS stats (Prometheus): curl http://127.0.0.1:8888/stats
FakeTLS IPv6 stats (only when enabled): curl http://127.0.0.1:8890/stats
Legacy stats: curl http://127.0.0.1:8889/stats
WEB Proxy health: curl http://127.0.0.1:8081/readyz
Refresh timer: systemctl list-timers mtproxy-config-refresh.timer
Logs: journalctl -u teleproxy -u teleproxy-ipv6 -u tproxy-server -u mtproxy -u danted -u xray -u nginx --no-pager -n 150

Security note: ordinary SOCKS5 is authenticated but not itself encrypted.
EOF

  printf '\n'
  cat "${CREDENTIALS_OUTPUT}"
}

main() {
  local backup_dir

  if [[ ${#} -lt 1 || ${#} -gt 2 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    [[ ${#} -eq 1 && ("${1:-}" == "-h" || "${1:-}" == "--help") ]] && exit 0
    exit 2
  fi
  [[ ${EUID} -eq 0 ]] || die "Run this script as root: sudo bash $0 ipv4.example.com [ipv6.example.com]"
  [[ -d /run/systemd/system ]] || die "This server is not running systemd."
  [[ -r /etc/os-release ]] || die "Cannot identify the operating system."

  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" || "${ID:-}" == "debian" ]] || \
    die "Supported systems are Ubuntu and Debian; detected ${ID:-unknown}."

  DOMAIN="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  DOMAIN="${DOMAIN%.}"
  validate_domain "${DOMAIN}"
  if [[ -n "${2:-}" ]]; then
    DOMAIN_IPV6="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
    DOMAIN_IPV6="${DOMAIN_IPV6%.}"
    validate_domain "${DOMAIN_IPV6}"
    [[ "${DOMAIN_IPV6}" != "${DOMAIN}" ]] || die "IPv4 and IPv6 domains must be different."
    ENABLE_IPV6=1
  fi
  check_existing_domains

  WORK_DIR="$(mktemp -d /tmp/proxy-stack.XXXXXX)"
  backup_dir="/root/proxy-stack-backup-$(date +%Y%m%d-%H%M%S)"
  install -d -o root -g root -m 0700 "${backup_dir}"
  backup_if_present "/etc/danted.conf" "${backup_dir}"
  backup_if_present "${NGINX_SITE}" "${backup_dir}"
  backup_if_present "/etc/systemd/system/teleproxy.service" "${backup_dir}"
  backup_if_present "/etc/systemd/system/teleproxy-ipv6.service" "${backup_dir}"
  backup_if_present "/etc/systemd/system/teleproxy.service.d" "${backup_dir}"
  backup_if_present "/etc/systemd/system/teleproxy-ipv6.service.d" "${backup_dir}"
  backup_if_present "${MTPROXY_DIR}" "${backup_dir}"
  backup_if_present "${STATE_DIR}" "${backup_dir}"
  backup_if_present "${CREDENTIALS_OUTPUT}" "${backup_dir}"
  backup_if_present "${MTG_BIN}" "${backup_dir}"
  backup_if_present "${TELEPROXY_BIN}" "${backup_dir}"
  backup_if_present "/etc/systemd/system/mtproxy.service" "${backup_dir}"
  backup_if_present "/etc/systemd/system/mtproxy-ipv6.service" "${backup_dir}"
  backup_if_present "/etc/systemd/system/tproxy-server.service" "${backup_dir}"
  backup_if_present "${TPROXY_SERVER_DIR}" "${backup_dir}"
  backup_if_present "/etc/systemd/system/xray.service" "${backup_dir}"
  backup_if_present "${XRAY_CONFIG}" "${backup_dir}"

  check_clean_ports
  install_packages
  check_clean_ports
  check_dns
  load_or_create_credentials
  install_mtg "${MTG_BIN}"
  install_official_mtproxy "${MTPROXY_BIN}"
  install_tproxy_server "${TPROXY_SERVER_BIN}"
  install_xray "${XRAY_BIN}"
  install_refresh_timer
  configure_firewall
  configure_nginx_and_certificate
  configure_dante
  configure_xray
  configure_tproxy_server
  write_happ_subscription
  install_proxy_services "${backup_dir}"
  verify_services

  printf '%s\n' "domain_ipv4=${DOMAIN}" "public_ipv4=${PUBLIC_IPV4}" \
    "domain_ipv6=${DOMAIN_IPV6}" "public_ipv6=${PUBLIC_IPV6}" \
    "installed_at=$(date --iso-8601=seconds)" | write_atomic 0600 "${INSTALL_MARKER}"
  write_credentials_output

  log "Installation completed successfully. Keep ${CREDENTIALS_OUTPUT} private."
  log "Pre-installation backups, if any, are in ${backup_dir}."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  trap cleanup EXIT
  trap 'on_error ${LINENO}' ERR
  main "$@"
fi
