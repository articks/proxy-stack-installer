#!/usr/bin/env bash
#
# Recreate /root/proxy-credentials.txt without reinstalling the proxy stack.
#
# Managed installation (created by install-proxy-stack.sh):
#   sudo bash rebuild-proxy-credentials.sh
#
# Older/manual installation without /etc/proxy-stack/credentials.env:
#   sudo bash rebuild-proxy-credentials.sh --domain d1.example.com \
#     [--ipv6-domain d2.example.com]
#
# If neither the state file nor the old credentials file contains the SOCKS5
# password, add --rotate-socks-password. This is an explicit breaking change
# for existing SOCKS5 clients.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly STATE_FILE="/etc/proxy-stack/credentials.env"
readonly OUTPUT_FILE="/root/proxy-credentials.txt"
readonly MTPROXY_ENV="/etc/mtproxy/mtproxy.env"
readonly TPROXY_SERVER_CONFIG="/etc/tproxy-server/config.json"
readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly HAPP_DIR="/var/www/faketls/happ"

DOMAIN=""
DOMAIN_IPV6=""
PUBLIC_IPV4=""
PUBLIC_IPV6=""
RAW_SECRET=""
SOCKS_USER="socksproxy"
SOCKS_PASSWORD=""
VLESS_UUID=""
VLESS_WS_PATH=""
HAPP_SUBSCRIPTION_ID=""
REQUESTED_SUBSCRIPTION_ID=""
ACTIVE_SUBSCRIPTION_FILE=""
MANAGED_INSTALL=0
ROTATE_SOCKS_PASSWORD=0
PRINT_OUTPUT=0
TEMPORARY_OUTPUT=""

log() {
  printf '[proxy-credentials] %s\n' "$*"
}

die() {
  printf '[proxy-credentials] ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${TEMPORARY_OUTPUT}" && -f "${TEMPORARY_OUTPUT}" ]]; then
    rm -f -- "${TEMPORARY_OUTPUT}"
  fi
}

trap cleanup EXIT

usage() {
  cat <<'USAGE'
Usage:
  sudo bash rebuild-proxy-credentials.sh [options]

Options:
  --domain DOMAIN           IPv4 domain for an older/manual installation.
  --ipv6-domain DOMAIN      Optional IPv6-only domain for a manual install.
  --subscription-id ID      Select the active Happ subscription on a manual
                            server when several subscription files exist.
  --rotate-socks-password   Generate a new SOCKS5 password and apply it.
  --print                   Print the recreated credentials file to stdout.
  -h, --help                Show this help.

No domain arguments are needed on servers installed by
install-proxy-stack.sh because the script reads
/etc/proxy-stack/credentials.env.

For an older/manual server, --domain is required. The existing SOCKS5
password is reused from /root/proxy-credentials.txt when possible. If that
file is missing and no persistent state exists, use --rotate-socks-password.
USAGE
}

validate_domain() {
  local value=$1
  local label
  local -a labels

  [[ ${#value} -le 253 ]] || die "Domain name is longer than 253 characters."
  [[ "${value}" == *.* ]] || die "Use a fully-qualified domain such as proxy.example.com."
  [[ "${value}" =~ ^[a-z0-9.-]+$ ]] || die "Domain contains unsupported characters: ${value}"
  [[ "${value}" != .* && "${value}" != *. && "${value}" != *..* ]] || \
    die "Malformed domain: ${value}"

  IFS='.' read -r -a labels <<<"${value}"
  for label in "${labels[@]}"; do
    [[ -n "${label}" && ${#label} -le 63 ]] || die "Malformed DNS label in ${value}."
    [[ "${label}" != -* && "${label}" != *- ]] || \
      die "DNS labels cannot start or end with '-': ${value}"
  done
}

state_value() {
  local key=$1
  awk -F= -v wanted="${key}" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' "${STATE_FILE}"
}

existing_output_value() {
  local key=$1
  awk -F': ' -v wanted="${key}" '$1 == wanted {print $2; exit}' "${OUTPUT_FILE}"
}

resolve_single_record() {
  local record_type=$1
  local domain=$2
  local -a records

  mapfile -t records < <(dig +short "${record_type}" "${domain}" | awk 'NF' | sort -u)
  [[ ${#records[@]} -eq 1 ]] || \
    die "${domain} must have exactly one ${record_type} record; found ${#records[@]}."
  printf '%s\n' "${records[0]}"
}

canonical_ipv6() {
  python3 -c 'import ipaddress,sys; print(ipaddress.IPv6Address(sys.argv[1]))' "$1" 2>/dev/null
}

vless_uri() {
  local address=$1
  local tls_domain=$2
  local title=$3
  local encoded_path="%2F${VLESS_WS_PATH#/}"

  printf 'vless://%s@%s:9443?encryption=none&security=tls&sni=%s&fp=chrome&alpn=http%%2F1.1&type=ws&host=%s&path=%s#%s' \
    "${VLESS_UUID}" "${address}" "${tls_domain}" "${tls_domain}" "${encoded_path}" "${title}"
}

update_managed_socks_password() {
  local replacement_file

  replacement_file="$(mktemp /etc/proxy-stack/.credentials.XXXXXX)"
  awk -v password="${SOCKS_PASSWORD}" '
    /^SOCKS_PASSWORD=/ {print "SOCKS_PASSWORD=" password; found=1; next}
    {print}
    END {if (!found) print "SOCKS_PASSWORD=" password}
  ' "${STATE_FILE}" >"${replacement_file}"
  install -o root -g root -m 0600 "${replacement_file}" "${STATE_FILE}"
  rm -f -- "${replacement_file}"
}

load_managed_state() {
  local requested_domain=$1
  local requested_ipv6_domain=$2

  MANAGED_INSTALL=1
  DOMAIN="$(state_value DOMAIN)"
  DOMAIN_IPV6="$(state_value DOMAIN_IPV6)"
  RAW_SECRET="$(state_value RAW_SECRET)"
  SOCKS_USER="$(state_value SOCKS_USER)"
  SOCKS_PASSWORD="$(state_value SOCKS_PASSWORD)"
  VLESS_UUID="$(state_value VLESS_UUID)"
  VLESS_WS_PATH="$(state_value VLESS_WS_PATH)"
  HAPP_SUBSCRIPTION_ID="$(state_value HAPP_SUBSCRIPTION_ID)"

  [[ -z "${requested_domain}" || "${requested_domain}" == "${DOMAIN}" ]] || \
    die "--domain does not match ${STATE_FILE}."
  [[ -z "${requested_ipv6_domain}" || "${requested_ipv6_domain}" == "${DOMAIN_IPV6}" ]] || \
    die "--ipv6-domain does not match ${STATE_FILE}."
  [[ -z "${REQUESTED_SUBSCRIPTION_ID}" || "${REQUESTED_SUBSCRIPTION_ID}" == "${HAPP_SUBSCRIPTION_ID}" ]] || \
    die "--subscription-id does not match ${STATE_FILE}."
}

select_active_subscription() {
  local file
  local -a files=()

  [[ -d "${HAPP_DIR}" ]] || die "Happ subscription directory is missing: ${HAPP_DIR}"

  if ((MANAGED_INSTALL)); then
    ACTIVE_SUBSCRIPTION_FILE="${HAPP_DIR}/${HAPP_SUBSCRIPTION_ID}.txt"
    [[ -f "${ACTIVE_SUBSCRIPTION_FILE}" ]] || \
      die "Managed Happ subscription is missing: ${ACTIVE_SUBSCRIPTION_FILE}"
    return
  fi

  if [[ -n "${REQUESTED_SUBSCRIPTION_ID}" ]]; then
    [[ "${REQUESTED_SUBSCRIPTION_ID}" =~ ^[0-9a-f]{32,64}$ ]] || \
      die "Invalid --subscription-id; expected 32-64 lowercase hexadecimal characters."
    ACTIVE_SUBSCRIPTION_FILE="${HAPP_DIR}/${REQUESTED_SUBSCRIPTION_ID}.txt"
    [[ -f "${ACTIVE_SUBSCRIPTION_FILE}" ]] || \
      die "Selected Happ subscription does not exist: ${ACTIVE_SUBSCRIPTION_FILE}"
    HAPP_SUBSCRIPTION_ID="${REQUESTED_SUBSCRIPTION_ID}"
    return
  fi

  while IFS= read -r -d '' file; do
    files+=("${file}")
  done < <(find "${HAPP_DIR}" -maxdepth 1 -type f -name '*.txt' -print0 | sort -z)

  [[ ${#files[@]} -gt 0 ]] || die "No Happ subscription files were found in ${HAPP_DIR}."
  [[ ${#files[@]} -eq 1 ]] || \
    die "Several Happ subscriptions exist. Re-run with --subscription-id for the active one."

  ACTIVE_SUBSCRIPTION_FILE="${files[0]}"
  HAPP_SUBSCRIPTION_ID="$(basename "${ACTIVE_SUBSCRIPTION_FILE}" .txt)"
}

load_manual_state() {
  local requested_domain=$1
  local requested_ipv6_domain=$2

  [[ -n "${requested_domain}" ]] || \
    die "${STATE_FILE} is missing; provide --domain for this older/manual installation."

  DOMAIN="${requested_domain}"
  DOMAIN_IPV6="${requested_ipv6_domain}"
  [[ -r "${MTPROXY_ENV}" ]] || die "MTProto state is missing: ${MTPROXY_ENV}"
  [[ -r "${XRAY_CONFIG}" ]] || die "Xray configuration is missing: ${XRAY_CONFIG}"

  RAW_SECRET="$(awk 'match($0, /[0-9a-fA-F]{32}/) {print tolower(substr($0, RSTART, RLENGTH)); exit}' "${MTPROXY_ENV}")"
  VLESS_UUID="$(jq -r '[.inbounds[]?.settings.clients[]?.id // empty][0] // empty' "${XRAY_CONFIG}")"
  VLESS_WS_PATH="$(jq -r '[.inbounds[]? | select(.streamSettings.network == "ws") | .streamSettings.wsSettings.path // empty][0] // empty' "${XRAY_CONFIG}")"

  if [[ -r "${OUTPUT_FILE}" ]]; then
    SOCKS_USER="$(existing_output_value Username)"
    SOCKS_PASSWORD="$(existing_output_value Password)"
  fi
}

validate_state() {
  validate_domain "${DOMAIN}"
  if [[ -n "${DOMAIN_IPV6}" ]]; then
    validate_domain "${DOMAIN_IPV6}"
  fi

  [[ "${RAW_SECRET}" =~ ^[0-9a-f]{32}$ ]] || die "Invalid MTProto raw secret."
  [[ "${SOCKS_USER}" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || die "Invalid SOCKS5 username."
  [[ "${VLESS_UUID}" =~ ^[0-9a-fA-F-]{36}$ ]] || die "Invalid VLESS UUID."
  [[ -z "${VLESS_WS_PATH}" || "${VLESS_WS_PATH}" == /* ]] || die "Invalid VLESS WebSocket path."

  if ((MANAGED_INSTALL)); then
    [[ "${SOCKS_PASSWORD}" =~ ^[0-9a-f]{32}$ ]] || die "Invalid SOCKS5 password in ${STATE_FILE}."
    [[ "${VLESS_WS_PATH}" =~ ^/[0-9a-f]{32}$ ]] || die "Invalid VLESS path in ${STATE_FILE}."
    [[ "${HAPP_SUBSCRIPTION_ID}" =~ ^[0-9a-f]{40}$ ]] || \
      die "Invalid Happ subscription ID in ${STATE_FILE}."
  elif ((ROTATE_SOCKS_PASSWORD == 0)); then
    [[ -n "${SOCKS_PASSWORD}" && "${SOCKS_PASSWORD}" != *[[:space:]]* ]] || \
      die "The current SOCKS5 password is unavailable. Re-run with --rotate-socks-password."
  fi
}

rotate_socks_password() {
  getent passwd "${SOCKS_USER}" >/dev/null || die "SOCKS5 account does not exist: ${SOCKS_USER}"
  SOCKS_PASSWORD="$(openssl rand -hex 16)"
  printf '%s:%s\n' "${SOCKS_USER}" "${SOCKS_PASSWORD}" | chpasswd
  if ((MANAGED_INSTALL)); then
    update_managed_socks_password
  fi
  log "SOCKS5 password rotated; existing SOCKS5 clients must be updated."
}

build_subscription_output() {
  local profile_names

  profile_names="$(grep '^vless://' "${ACTIVE_SUBSCRIPTION_FILE}" | sed 's/.*#//' | paste -sd ',' - || true)"
  printf 'Profiles: %s\n' "${profile_names:-VLESS}"
  printf 'Primary URL: https://%s/happ/%s.txt\n' "${DOMAIN}" "${HAPP_SUBSCRIPTION_ID}"
  printf 'Direct 9443 URL: https://%s:9443/happ/%s.txt\n' "${DOMAIN}" "${HAPP_SUBSCRIPTION_ID}"
  printf 'Server file: %s\n' "${ACTIVE_SUBSCRIPTION_FILE}"
}

build_manual_vless_output() {
  local output=""

  while IFS= read -r uri; do
    [[ -n "${uri}" ]] || continue
    if [[ "${output}" != *"${uri}"* ]]; then
      output+="${uri}\n\n"
    fi
  done < <(grep '^vless://' "${ACTIVE_SUBSCRIPTION_FILE}" || true)

  if [[ -z "${output}" && -n "${VLESS_WS_PATH}" ]]; then
    output+="$(vless_uri "${DOMAIN}" "${DOMAIN}" "${DOMAIN}-VLESS-WS-IPv4")\n\n"
  fi

  printf '%b' "${output}"
}

write_credentials() {
  local domain_hex_ipv4
  local domain_hex_ipv6=""
  local faketls_secret_ipv4
  local faketls_secret_ipv6=""
  local legacy_secret
  local subscription_output
  local vless_output
  local web_proxy_output=""

  domain_hex_ipv4="$(printf '%s' "${DOMAIN}" | xxd -p -c 256)"
  faketls_secret_ipv4="ee${RAW_SECRET}${domain_hex_ipv4}"
  legacy_secret="dd${RAW_SECRET}"
  subscription_output="$(build_subscription_output)"

  if ((MANAGED_INSTALL)); then
    vless_output="$(vless_uri "${DOMAIN}" "${DOMAIN}" "${DOMAIN}-VLESS-WS-IPv4")"
  else
    vless_output="$(build_manual_vless_output)"
  fi

  if [[ -r "${TPROXY_SERVER_CONFIG}" && -r /etc/tproxy-server/profiles.json ]] && \
    jq -e --arg domain "${DOMAIN}" '.public_hostname == $domain' "${TPROXY_SERVER_CONFIG}" >/dev/null && \
    jq -e --arg secret "dd${RAW_SECRET}" \
      '.profiles | any(.secret == $secret)' /etc/tproxy-server/profiles.json >/dev/null; then
    web_proxy_output="$(cat <<EOF

Telegram WEB Proxy (experimental)
Type: WEB Proxy
Hostname: ${DOMAIN}
Port: 443 (fixed by the protocol)
Secret: ${legacy_secret}
Link: tg://webproxy?server=${DOMAIN}&secret=${legacy_secret}
EOF
)"
  fi

  TEMPORARY_OUTPUT="$(mktemp /root/.proxy-credentials.XXXXXX)"
  cat >"${TEMPORARY_OUTPUT}" <<EOF
PROXY CONFIGURATION
Generated: $(date --iso-8601=seconds)
Source: $([[ ${MANAGED_INSTALL} -eq 1 ]] && printf 'installer state' || printf 'active legacy/manual configuration')

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
${web_proxy_output}

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
Path: ${VLESS_WS_PATH:-see URI}

VLESS client URI(s):
${vless_output}

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
EOF

  if [[ -n "${DOMAIN_IPV6}" ]]; then
    domain_hex_ipv6="$(printf '%s' "${DOMAIN_IPV6}" | xxd -p -c 256)"
    faketls_secret_ipv6="ee${RAW_SECRET}${domain_hex_ipv6}"
    cat >>"${TEMPORARY_OUTPUT}" <<EOF

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
EOF
  fi

  cat >>"${TEMPORARY_OUTPUT}" <<EOF

HAPP SUBSCRIPTIONS

${subscription_output:-No subscription files were found.}
ADMINISTRATION

Credentials file: ${OUTPUT_FILE}
Persistent installer state: ${STATE_FILE}
MTProto state: ${MTPROXY_ENV}
Teleproxy config: /etc/mtproxy/teleproxy.toml
Telegram WEB Proxy config: ${TPROXY_SERVER_CONFIG}
SOCKS5 config: /etc/danted.conf
Xray config: ${XRAY_CONFIG}
Happ subscription directory: ${HAPP_DIR}

Refresh timer: systemctl list-timers mtproxy-config-refresh.timer
Logs: journalctl -u teleproxy -u tproxy-server -u mtproxy -u mtproxy-ipv6 -u danted -u xray -u nginx --no-pager -n 150

SSH private keys are intentionally not stored in this file.
Security note: ordinary SOCKS5 is authenticated but is not encrypted by itself.
EOF

  install -o root -g root -m 0600 "${TEMPORARY_OUTPUT}" "${OUTPUT_FILE}"
  rm -f -- "${TEMPORARY_OUTPUT}"
  TEMPORARY_OUTPUT=""
}

main() {
  local requested_domain=""
  local requested_ipv6_domain=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)
        [[ $# -ge 2 ]] || die "--domain requires a value."
        requested_domain=$2
        shift 2
        ;;
      --ipv6-domain)
        [[ $# -ge 2 ]] || die "--ipv6-domain requires a value."
        requested_ipv6_domain=$2
        shift 2
        ;;
      --subscription-id)
        [[ $# -ge 2 ]] || die "--subscription-id requires a value."
        REQUESTED_SUBSCRIPTION_ID=$2
        shift 2
        ;;
      --rotate-socks-password)
        ROTATE_SOCKS_PASSWORD=1
        shift
        ;;
      --print)
        PRINT_OUTPUT=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done

  [[ ${EUID} -eq 0 ]] || die "Run this script as root."

  for command_name in awk basename dig find getent grep install jq mktemp openssl python3 sed sort xxd; do
    command -v "${command_name}" >/dev/null 2>&1 || die "Required command is missing: ${command_name}"
  done

  if [[ -r "${STATE_FILE}" ]]; then
    load_managed_state "${requested_domain}" "${requested_ipv6_domain}"
  else
    load_manual_state "${requested_domain}" "${requested_ipv6_domain}"
  fi

  validate_state
  select_active_subscription
  PUBLIC_IPV4="$(resolve_single_record A "${DOMAIN}")"
  if [[ -n "${DOMAIN_IPV6}" ]]; then
    PUBLIC_IPV6="$(canonical_ipv6 "$(resolve_single_record AAAA "${DOMAIN_IPV6}")")" || \
      die "${DOMAIN_IPV6} returned an invalid IPv6 address."
  fi

  if ((ROTATE_SOCKS_PASSWORD)); then
    rotate_socks_password
  fi

  write_credentials
  log "Credentials recreated at ${OUTPUT_FILE} with mode 0600."

  if ((PRINT_OUTPUT)); then
    cat "${OUTPUT_FILE}"
  fi
}

main "$@"
