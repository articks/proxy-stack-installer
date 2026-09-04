#!/usr/bin/env bash
#
# Deploy on a clean Ubuntu/Debian VPS:
#   - Fake-TLS MTProto on TCP/443 (Teleproxy + a real nginx TLS backend)
#   - Telegram WEB Proxy over HTTPS/443 (tproxy-server behind nginx)
#   - legacy random-padding MTProto on TCP/8443 (official Telegram MTProxy)
#   - authenticated SOCKS5 on TCP/1080 (Dante, TCP CONNECT only)
#   - VLESS over WebSocket + TLS on TCP/9443 (Xray behind nginx)
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

readonly TELEPROXY_VERSION="4.16.1"
readonly TELEPROXY_SHA256_AMD64="6afbc40af530e61e4b6275f630dde947f29e84b6e72b22a43a83f5f5ce36d340"
readonly MTPROXY_COMMIT="f36d8af769ffaeac36978d38c2c0f6d1104c2137"
readonly TPROXY_SERVER_COMMIT="f7a6acc4d536a787d442fd7df3ba4ebfd728f406"
readonly TPROXY_SERVER_SHA256_AMD64="9a235e27e43881f3186004143452d3145175b975195661bba38a3ced2ea5571e"
readonly GO_VERSION="1.26.5"
readonly GO_SHA256_AMD64="5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053"
readonly XRAY_VERSION="26.3.27"
readonly XRAY_SHA256_AMD64="23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae"

readonly STATE_DIR="/etc/proxy-stack"
readonly STATE_FILE="${STATE_DIR}/credentials.env"
readonly INSTALL_MARKER="${STATE_DIR}/installed"
readonly CREDENTIALS_OUTPUT="/root/proxy-credentials.txt"
readonly MTPROXY_DIR="/etc/mtproxy"
readonly TELEPROXY_BIN="/usr/local/bin/teleproxy"
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

trap cleanup EXIT
trap 'on_error ${LINENO}' ERR

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

state_value() {
  local key=$1
  awk -F= -v wanted="${key}" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' "${STATE_FILE}"
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
    systemctl stop teleproxy.service tproxy-server.service mtproxy-ipv6.service mtproxy.service danted.service xray.service 2>/dev/null || true
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
    if [[ ! "${HAPP_SUBSCRIPTION_ID}" =~ ^[0-9a-f]{40}$ ]]; then
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
EOF
    log "Generated and saved proxy credentials"
  else
    log "Reusing the existing client credentials"
  fi
}

install_teleproxy() {
  local download_url
  local downloaded_binary="${WORK_DIR}/teleproxy-linux-amd64"

  [[ "$(uname -m)" == "x86_64" ]] || \
    die "This installer currently supports x86_64 only because the official legacy MTProxy is x86-specific."

  log "Installing Teleproxy ${TELEPROXY_VERSION} with SHA-256 verification"
  download_url="https://github.com/teleproxy/teleproxy/releases/download/v${TELEPROXY_VERSION}/teleproxy-linux-amd64"
  curl -fL --retry 4 --retry-all-errors --connect-timeout 15 --max-time 180 \
    "${download_url}" -o "${downloaded_binary}"
  printf '%s  %s\n' "${TELEPROXY_SHA256_AMD64}" "${downloaded_binary}" | sha256sum --check --status
  install -o root -g root -m 0755 "${downloaded_binary}" "${TELEPROXY_BIN}"
}

install_official_mtproxy() {
  local source_dir="${WORK_DIR}/MTProxy"
  local jobs

  if [[ -x "${MTPROXY_BIN}" && -f "${STATE_DIR}/mtproxy.commit" ]] && \
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
  install -o root -g root -m 0755 "${source_dir}/objs/bin/mtproto-proxy" "${MTPROXY_BIN}"
  printf '%s\n' "${MTPROXY_COMMIT}" | write_atomic 0600 "${STATE_DIR}/mtproxy.commit"
}

select_go_toolchain() {
  local go_minor=""
  local go_archive="${WORK_DIR}/go${GO_VERSION}.linux-amd64.tar.gz"
  local go_root="/opt/go${GO_VERSION}"

  if command -v go >/dev/null 2>&1; then
    go_minor="$(go env GOVERSION 2>/dev/null | sed -E 's/^go1\.([0-9]+).*/\1/')"
    if [[ "${go_minor}" =~ ^[0-9]+$ ]] && ((go_minor >= 20)); then
      GO_BIN="$(command -v go)"
      return
    fi
  fi

  if [[ ! -x "${go_root}/bin/go" ]]; then
    log "Installing Go ${GO_VERSION} for Telegram WEB Proxy"
    curl -fL --retry 4 --retry-all-errors --connect-timeout 15 --max-time 180 \
      "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o "${go_archive}"
    printf '%s  %s\n' "${GO_SHA256_AMD64}" "${go_archive}" | sha256sum --check --status
    install -d -o root -g root -m 0755 "${go_root}"
    tar -C "${go_root}" --strip-components=1 -xzf "${go_archive}"
  fi

  GO_BIN="${go_root}/bin/go"
}

install_tproxy_server() {
  local archive="${WORK_DIR}/tproxy-server.tar.gz"
  local source_dir="${WORK_DIR}/tproxy-server-${TPROXY_SERVER_COMMIT}"

  if [[ -x "${TPROXY_SERVER_BIN}" && -f "${STATE_DIR}/tproxy-server.commit" ]] && \
    [[ "$(<"${STATE_DIR}/tproxy-server.commit")" == "${TPROXY_SERVER_COMMIT}" ]]; then
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
  (umask 0022; cd "${source_dir}" && "${GO_BIN}" test ./...)
  (cd "${source_dir}" && CGO_ENABLED=0 "${GO_BIN}" build -trimpath -ldflags='-s -w' \
    -o "${WORK_DIR}/tproxy-server" ./cmd/tproxy-server)
  install -o root -g root -m 0755 "${WORK_DIR}/tproxy-server" "${TPROXY_SERVER_BIN}"
  printf '%s\n' "${TPROXY_SERVER_COMMIT}" | write_atomic 0600 "${STATE_DIR}/tproxy-server.commit"
}

install_xray() {
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
  install -o root -g root -m 0755 "${extract_dir}/xray" "${XRAY_BIN}"
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
  for unit in mtproxy.service teleproxy.service; do
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
systemctl try-restart teleproxy.service
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
  local encoded_path="%2F${VLESS_WS_PATH#/}"

  printf 'vless://%s@%s:9443?encryption=none&security=tls&sni=%s&fp=chrome&alpn=http%%2F1.1&type=ws&host=%s&path=%s#%s' \
    "${VLESS_UUID}" "${address}" "${tls_domain}" "${tls_domain}" "${encoded_path}" "${title}"
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
$(vless_uri "${PUBLIC_IPV4}" "${DOMAIN}" "${DOMAIN}-VLESS-WS-IPv4")
$(vless_uri "[${PUBLIC_IPV6}]" "${DOMAIN_IPV6}" "${DOMAIN_IPV6}-VLESS-WS-IPv6")
EOF
  else
    write_atomic 0644 "${subscription_file}" <<EOF
#proxy-enable: 1
#fragmentation-enable: 0
$(vless_uri "${PUBLIC_IPV4}" "${DOMAIN}" "${DOMAIN}-VLESS-WS-IPv4")
EOF
  fi
}

install_proxy_services() {
  local teleproxy_ipv6="false"
  local teleproxy_domain_entries="  { name = \"${DOMAIN}\", backend = \"127.0.0.1:8444\" },"

  if ((ENABLE_IPV6)); then
    teleproxy_ipv6="true"
    teleproxy_domain_entries+=$'\n'"  { name = \"${DOMAIN_IPV6}\", backend = \"127.0.0.1:8444\" },"
  fi

  write_atomic 0600 "${STATE_DIR}/services.env" <<EOF
DOMAIN=${DOMAIN}
DOMAIN_IPV6=${DOMAIN_IPV6}
RAW_SECRET=${RAW_SECRET}
EOF

  # Teleproxy 4.16.1 does not enable its documented default MSS clamp when
  # all options are supplied only via CLI. Load it explicitly from TOML and
  # use the TOML domain table for a separate local camouflage backend.
  write_atomic 0644 "${MTPROXY_DIR}/teleproxy.toml" <<EOF
mss_clamp = true
ipv6 = ${teleproxy_ipv6}

domain = [
${teleproxy_domain_entries}
]
EOF

  write_atomic 0644 "/etc/systemd/system/teleproxy.service" <<EOF
[Unit]
Description=Teleproxy Fake-TLS MTProto proxy
Wants=network-online.target
After=network-online.target nginx.service
Requires=nginx.service

[Service]
Type=simple
EnvironmentFile=${STATE_DIR}/services.env
WorkingDirectory=${MTPROXY_DIR}
ExecStart=${TELEPROXY_BIN} --config ${MTPROXY_DIR}/teleproxy.toml -u nobody -p 8888 -H 443 -S \${RAW_SECRET} --http-stats --aes-pwd ${MTPROXY_DIR}/proxy-secret ${MTPROXY_DIR}/proxy-multi.conf -M 1
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
    systemctl enable mtproxy-ipv6.service
  fi
  systemctl restart nginx.service
  systemctl restart danted.service
  systemctl restart xray.service
  systemctl restart mtproxy.service
  systemctl restart tproxy-server.service
  if ((ENABLE_IPV6)); then
    systemctl restart mtproxy-ipv6.service
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
  retry 12 1 curl -fsS --max-time 8 --resolve "${DOMAIN}:443:127.0.0.1" \
    "https://${DOMAIN}/?bridge=${bridge_capability}" -o "${bridge_page}"
  bootstrap_token="$(sed -n 's/.*bootstrap="\([A-Za-z0-9_-]\{43\}\)".*/\1/p' "${bridge_page}" | head -n 1)"
  [[ "${bootstrap_token}" =~ ^[A-Za-z0-9_-]{43}$ ]] || \
    die "Telegram WEB Proxy bridge page did not contain a valid bootstrap token."

  printf '100000000000000101' | xxd -r -p >"${hello_frame}"
  http_code="$(curl -sS --max-time 8 --resolve "${DOMAIN}:443:127.0.0.1" \
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

  curl -sS --http1.1 --max-time 2 --resolve "${DOMAIN}:443:127.0.0.1" \
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
  local socks_port=$3
  local check_url=$4
  local expected_address=$5
  local client_config="${WORK_DIR}/xray-client-${socks_port}.json"
  local client_log="${WORK_DIR}/xray-client-${socks_port}.log"
  local result=""
  local attempt

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
            "port": 9443,
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
          "fingerprint": "chrome",
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
    die "VLESS test through ${address}:9443 returned '${result}' instead of '${expected_address}'."
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
  fi

  log "Verifying services and local endpoints"
  for service in "${services[@]}"; do
    systemctl is-active --quiet "${service}" || {
      systemctl --no-pager --full status "${service}" >&2 || true
      die "${service} is not active."
    }
  done

  retry 12 1 curl -fsS --max-time 5 http://127.0.0.1:8888/stats >/dev/null
  retry 12 1 curl -fsS --max-time 5 http://127.0.0.1:8889/stats >/dev/null
  retry 12 1 curl -fsS --max-time 5 http://127.0.0.1:8081/healthz >/dev/null
  retry 12 1 curl -fsS --max-time 5 http://127.0.0.1:8081/readyz >/dev/null
  retry 12 1 curl -fsS --max-time 8 --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/" >/dev/null
  retry 12 1 curl -fsS --max-time 8 --resolve "${DOMAIN}:443:127.0.0.1" \
    "https://${DOMAIN}/happ/${HAPP_SUBSCRIPTION_ID}.txt" >/dev/null
  retry 12 1 curl -fsS --max-time 8 --resolve "${DOMAIN}:9443:127.0.0.1" \
    "https://${DOMAIN}:9443/happ/${HAPP_SUBSCRIPTION_ID}.txt" >/dev/null

  verify_web_proxy_endpoint

  socks_result="$(curl -4fsS --connect-timeout 10 --max-time 30 \
    --proxy "socks5h://${SOCKS_USER}:${SOCKS_PASSWORD}@127.0.0.1:1080" \
    https://api.ipify.org | tr -d '[:space:]')"
  [[ "${socks_result}" == "${PUBLIC_IPV4}" ]] || \
    die "SOCKS5 test returned '${socks_result}' instead of '${PUBLIC_IPV4}'."

  verify_vless_endpoint "${PUBLIC_IPV4}" "${DOMAIN}" 10991 \
    "https://api.ipify.org" "${PUBLIC_IPV4}"

  if ((ENABLE_IPV6)); then
    retry 12 1 curl -gfsS --max-time 8 --resolve "${DOMAIN_IPV6}:443:[::1]" \
      "https://${DOMAIN_IPV6}/" >/dev/null
    socks_result="$(curl -fsS --connect-timeout 10 --max-time 30 \
      --proxy "socks5h://${SOCKS_USER}:${SOCKS_PASSWORD}@[::1]:1080" \
      https://api.ipify.org | tr -d '[:space:]')"
    [[ "${socks_result}" == "${PUBLIC_IPV4}" ]] || \
      die "SOCKS5 test through the IPv6 listener returned '${socks_result}' instead of '${PUBLIC_IPV4}'."
    verify_vless_endpoint "${PUBLIC_IPV6}" "${DOMAIN_IPV6}" 10992 \
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
Port: 9443
UUID: ${VLESS_UUID}
Transport: WebSocket
TLS/SNI/Host: ${DOMAIN_IPV6}
Path: ${VLESS_WS_PATH}

VLESS URI:
$(vless_uri "${DOMAIN_IPV6}" "${DOMAIN_IPV6}" "${DOMAIN_IPV6}-VLESS-WS-IPv6")

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

VLESS URI:
$(vless_uri "[${PUBLIC_IPV6}]" "${DOMAIN_IPV6}" "${DOMAIN_IPV6}-VLESS-WS-IPv6-IP")

Happ VLESS subscription over IPv6:
https://${DOMAIN_IPV6}:9443/happ/${HAPP_SUBSCRIPTION_ID}.txt
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
Port: 9443
UUID: ${VLESS_UUID}
Transport: WebSocket
TLS/SNI/Host: ${DOMAIN}
Path: ${VLESS_WS_PATH}

VLESS URI:
$(vless_uri "${DOMAIN}" "${DOMAIN}" "${DOMAIN}-VLESS-WS-IPv4")

Happ VLESS subscription:
https://${DOMAIN}:9443/happ/${HAPP_SUBSCRIPTION_ID}.txt

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

VLESS URI:
$(vless_uri "${PUBLIC_IPV4}" "${DOMAIN}" "${DOMAIN}-VLESS-WS-IPv4-IP")
${ipv6_output}

ADMINISTRATION
Credentials file: ${CREDENTIALS_OUTPUT}
Xray config: ${XRAY_CONFIG}
Telegram WEB Proxy config: ${TPROXY_SERVER_CONFIG}
Happ subscription file: ${NGINX_ROOT}/happ/${HAPP_SUBSCRIPTION_ID}.txt
FakeTLS stats: curl http://127.0.0.1:8888/stats
Legacy stats: curl http://127.0.0.1:8889/stats
WEB Proxy health: curl http://127.0.0.1:8081/readyz
Refresh timer: systemctl list-timers mtproxy-config-refresh.timer
Logs: journalctl -u teleproxy -u tproxy-server -u mtproxy -u danted -u xray -u nginx --no-pager -n 150

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

  WORK_DIR="$(mktemp -d /tmp/proxy-stack.XXXXXX)"
  backup_dir="/root/proxy-stack-backup-$(date +%Y%m%d-%H%M%S)"
  install -d -o root -g root -m 0700 "${backup_dir}"
  backup_if_present "/etc/danted.conf" "${backup_dir}"
  backup_if_present "${NGINX_SITE}" "${backup_dir}"
  backup_if_present "/etc/systemd/system/teleproxy.service" "${backup_dir}"
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
  install_teleproxy
  install_official_mtproxy
  install_tproxy_server
  install_xray
  install_refresh_timer
  configure_firewall
  configure_nginx_and_certificate
  configure_dante
  configure_xray
  configure_tproxy_server
  write_happ_subscription
  install_proxy_services
  verify_services

  printf '%s\n' "domain_ipv4=${DOMAIN}" "public_ipv4=${PUBLIC_IPV4}" \
    "domain_ipv6=${DOMAIN_IPV6}" "public_ipv6=${PUBLIC_IPV6}" \
    "installed_at=$(date --iso-8601=seconds)" | write_atomic 0600 "${INSTALL_MARKER}"
  write_credentials_output

  log "Installation completed successfully. Keep ${CREDENTIALS_OUTPUT} private."
  log "Pre-installation backups, if any, are in ${backup_dir}."
}

main "$@"
