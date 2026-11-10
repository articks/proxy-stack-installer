#!/usr/bin/env bash
# Update managed MTProxy/Web Proxy/Xray binaries without rewriting client access.
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=install-proxy-stack.sh
source "${SCRIPT_DIR}/install-proxy-stack.sh"

UPGRADE_BACKUP=""
UPGRADE_ACTIVATED=0
UPGRADE_SUCCESS=0
REFRESH_TIMER_WAS_ACTIVE=0
UPGRADE_MTG_IPV6=0
UPGRADE_FRONTEND_METADATA=""
declare -a UPGRADE_BINARIES=("${MTPROXY_BIN}" "${TPROXY_SERVER_BIN}" "${XRAY_BIN}")
declare -a UPGRADE_FILES=(
  "${MTPROXY_BIN}"
  "${TPROXY_SERVER_BIN}"
  "${XRAY_BIN}"
  "${STATE_DIR}/mtproxy.commit"
  "${STATE_DIR}/tproxy-server.commit"
  "${STATE_DIR}/tproxy-server.go-version"
)
declare -a OPTIONAL_UPGRADE_MARKERS=("${STATE_DIR}/tproxy-server.go-version")
declare -a PROTECTED_FILES=()
declare -a UPGRADE_UNITS=(tproxy-server.service xray.service mtproxy.service)

frontend_value() {
  local key=$1
  awk -F= -v wanted="${key}" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' "${UPGRADE_FRONTEND_METADATA}"
}

service_exec_path() {
  local unit=$1
  local description
  local path_pattern='(^|[[:space:]{])path=([^[:space:];]+)'
  description="$(systemctl show --property=ExecStart --value "${unit}")" || return 1
  [[ "${description}" =~ ${path_pattern} ]] || return 1
  printf '%s\n' "${BASH_REMATCH[2]}"
}

detect_upgrade_frontend() {
  local executable
  local metadata_engine=""
  local metadata_fingerprint=""
  local expected_config
  local expected_binary
  local ipv6_service=""
  local ipv6_config=""

  UPGRADE_MTG_IPV6=0
  UPGRADE_FRONTEND_METADATA="${1:-${FRONTEND_METADATA}}"
  executable="$(service_exec_path teleproxy.service)" || \
    die "Cannot identify the configured FakeTLS service executable."
  case "${executable}" in
    "${TELEPROXY_BIN}")
      FAKETLS_ENGINE=teleproxy
      expected_config="${MTPROXY_DIR}/teleproxy.toml"
      expected_binary="${TELEPROXY_BIN}"
      ;;
    "${MTG_BIN}")
      FAKETLS_ENGINE=mtg
      expected_config="${MTG_CONFIG}"
      expected_binary="${MTG_BIN}"
      ;;
    *) die "Unknown FakeTLS frontend executable; refusing an automatic migration." ;;
  esac

  if [[ -e "${UPGRADE_FRONTEND_METADATA}" || -L "${UPGRADE_FRONTEND_METADATA}" ]]; then
    [[ -f "${UPGRADE_FRONTEND_METADATA}" && ! -L "${UPGRADE_FRONTEND_METADATA}" ]] || \
      die "FakeTLS frontend metadata must be a regular file."
    metadata_engine="$(frontend_value FAKETLS_ENGINE)"
    [[ "${metadata_engine}" == "${FAKETLS_ENGINE}" && \
       "$(frontend_value FAKETLS_SERVICE)" == teleproxy.service && \
       "$(frontend_value FAKETLS_CONFIG)" == "${expected_config}" && \
       "$(frontend_value FAKETLS_BINARY)" == "${expected_binary}" ]] || \
      die "FakeTLS metadata conflicts with the active service; refusing an automatic migration."
    metadata_fingerprint="$(frontend_value VLESS_TLS_FINGERPRINT)"
    ipv6_service="$(frontend_value FAKETLS_IPV6_SERVICE)"
    ipv6_config="$(frontend_value FAKETLS_IPV6_CONFIG)"
  elif [[ "${FAKETLS_ENGINE}" == mtg ]]; then
    die "The MTG frontend has no managed frontend metadata."
  fi

  if [[ -n "${VLESS_TLS_FINGERPRINT:-}" && -n "${metadata_fingerprint}" && \
        "${VLESS_TLS_FINGERPRINT}" != "${metadata_fingerprint}" ]]; then
    die "The existing VLESS fingerprint disagrees with frontend metadata."
  fi
  VLESS_TLS_FINGERPRINT="${metadata_fingerprint:-${VLESS_TLS_FINGERPRINT:-safari}}"
  validate_vless_fingerprint "${VLESS_TLS_FINGERPRINT}"

  if [[ "${FAKETLS_ENGINE}" == mtg ]] && ((ENABLE_IPV6)); then
    [[ "${ipv6_service}" == teleproxy-ipv6.service && "${ipv6_config}" == "${MTG_IPV6_CONFIG}" ]] || \
      die "The MTG IPv6 frontend is missing its managed metadata."
    [[ "$(service_exec_path teleproxy-ipv6.service)" == "${MTG_BIN}" ]] || \
      die "The MTG IPv6 metadata conflicts with its service executable."
    UPGRADE_MTG_IPV6=1
  elif [[ -n "${ipv6_service}" || -n "${ipv6_config}" ]]; then
    die "Unexpected IPv6 frontend metadata; refusing to guess which service to update."
  fi
}

set_upgrade_components() {
  UPGRADE_BINARIES=("${MTPROXY_BIN}" "${TPROXY_SERVER_BIN}" "${XRAY_BIN}")
  UPGRADE_FILES=(
    "${UPGRADE_BINARIES[@]}" "${STATE_DIR}/mtproxy.commit"
    "${STATE_DIR}/tproxy-server.commit" "${STATE_DIR}/tproxy-server.go-version"
  )
  OPTIONAL_UPGRADE_MARKERS=("${STATE_DIR}/tproxy-server.go-version")
  UPGRADE_UNITS=(tproxy-server.service xray.service mtproxy.service)
  if ((ENABLE_IPV6)); then
    UPGRADE_UNITS+=(mtproxy-ipv6.service)
  fi
  if [[ "${FAKETLS_ENGINE}" == mtg ]]; then
    UPGRADE_BINARIES+=("${MTG_BIN}")
    UPGRADE_FILES+=("${MTG_BIN}" "${STATE_DIR}/mtg.version" "${STATE_DIR}/mtg.archive.sha256")
    OPTIONAL_UPGRADE_MARKERS+=("${STATE_DIR}/mtg.version" "${STATE_DIR}/mtg.archive.sha256")
    UPGRADE_UNITS+=(teleproxy.service)
    if ((UPGRADE_MTG_IPV6)); then
      UPGRADE_UNITS+=(teleproxy-ipv6.service)
    fi
  fi
}

is_optional_upgrade_marker() {
  local path=$1
  local marker
  for marker in "${OPTIONAL_UPGRADE_MARKERS[@]}"; do
    [[ "${path}" != "${marker}" ]] || return 0
  done
  return 1
}

read_upgrade_state() {
  [[ -r "${STATE_FILE}" && -r "${INSTALL_MARKER}" ]] || \
    die "This server has no completed proxy-stack installation."
  DOMAIN="$(state_value DOMAIN)"
  DOMAIN_IPV6="$(state_value DOMAIN_IPV6)"
  RAW_SECRET="$(state_value RAW_SECRET)"
  SOCKS_USER="$(state_value SOCKS_USER)"
  SOCKS_PASSWORD="$(state_value SOCKS_PASSWORD)"
  VLESS_UUID="$(state_value VLESS_UUID)"
  VLESS_WS_PATH="$(state_value VLESS_WS_PATH)"
  HAPP_SUBSCRIPTION_ID="$(state_value HAPP_SUBSCRIPTION_ID)"
  VLESS_TLS_FINGERPRINT="$(state_value VLESS_TLS_FINGERPRINT)"
  ENABLE_IPV6=0
  PUBLIC_IPV6=""
  validate_domain "${DOMAIN}"
  [[ "${RAW_SECRET}" =~ ^[0-9a-f]{32}$ ]] || die "Invalid existing MTProto secret; refusing to regenerate it."
  [[ "${SOCKS_USER}" =~ ^[a-z_][a-z0-9_-]*$ && "${SOCKS_PASSWORD}" =~ ^[0-9a-f]{32}$ ]] || die "Invalid existing SOCKS credentials."
  [[ "${VLESS_UUID}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || die "Invalid existing VLESS UUID."
  [[ "${VLESS_WS_PATH}" =~ ^/[0-9a-f]{32}$ && "${HAPP_SUBSCRIPTION_ID}" =~ ^[0-9a-f]{32,64}$ ]] || die "Invalid existing WebSocket path or subscription ID."
  PUBLIC_IPV4="$(awk -F= '$1 == "public_ipv4" {print $2; exit}' "${INSTALL_MARKER}")"
  is_ipv4 "${PUBLIC_IPV4}" || die "Invalid IPv4 in the installation marker."
  if [[ -n "${DOMAIN_IPV6}" ]]; then
    validate_domain "${DOMAIN_IPV6}"
    ENABLE_IPV6=1
    PUBLIC_IPV6="$(awk -F= '$1 == "public_ipv6" {print $2; exit}' "${INSTALL_MARKER}")"
    PUBLIC_IPV6="$(canonical_ipv6 "${PUBLIC_IPV6}")" || die "Invalid existing IPv6 address."
  fi
  detect_upgrade_frontend "${FRONTEND_METADATA}"
  set_upgrade_components
}

set_protected_files() {
  local unit
  local path
  local dropin_directory="${1:-/etc/systemd/system}"
  PROTECTED_FILES=(
    "${STATE_FILE}" "${INSTALL_MARKER}" "${STATE_DIR}/services.env"
    "${CREDENTIALS_OUTPUT}" "${XRAY_CONFIG}" "${TPROXY_SERVER_CONFIG}"
    "${TPROXY_SERVER_PROFILES}" "${TPROXY_SERVER_DIR}/token.key"
    /etc/danted.conf "${NGINX_SITE}"
    "${NGINX_ROOT}/happ/${HAPP_SUBSCRIPTION_ID}.txt"
    /etc/systemd/system/teleproxy.service /etc/systemd/system/mtproxy.service
    /etc/systemd/system/tproxy-server.service /etc/systemd/system/xray.service
    /root/.ssh/authorized_keys
  )
  if ((ENABLE_IPV6)); then
    PROTECTED_FILES+=(/etc/systemd/system/mtproxy-ipv6.service)
  fi
  if [[ -f "${UPGRADE_FRONTEND_METADATA}" || -L "${UPGRADE_FRONTEND_METADATA}" ]]; then
    PROTECTED_FILES+=("${UPGRADE_FRONTEND_METADATA}")
  fi
  if [[ "${FAKETLS_ENGINE}" == mtg ]]; then
    PROTECTED_FILES+=("${MTG_CONFIG}")
    if [[ -e "${MTPROXY_DIR}/teleproxy.toml" || -L "${MTPROXY_DIR}/teleproxy.toml" ]]; then
      PROTECTED_FILES+=("${MTPROXY_DIR}/teleproxy.toml")
    fi
    if ((UPGRADE_MTG_IPV6)); then
      PROTECTED_FILES+=("${MTG_IPV6_CONFIG}" /etc/systemd/system/teleproxy-ipv6.service)
    fi
  else
    PROTECTED_FILES+=("${MTPROXY_DIR}/teleproxy.toml")
  fi
  # An operator may select MTG through a host-local service drop-in. Preserve it,
  # along with any overrides of the other services whose binaries are updated.
  for unit in teleproxy.service "${UPGRADE_UNITS[@]}"; do
    for path in "${dropin_directory}/${unit}.d/"*.conf; do
      [[ -e "${path}" || -L "${path}" ]] || continue
      PROTECTED_FILES+=("${path}")
    done
  done
}

backup_upgrade() {
  local path
  UPGRADE_BACKUP="$(mktemp -d /root/proxy-stack-upgrade-XXXXXXXX)"
  install -d -m 0700 "${UPGRADE_BACKUP}/files"
  for path in "${UPGRADE_FILES[@]}"; do
    if [[ -e "${path}" || -L "${path}" ]]; then
      [[ -f "${path}" && ! -L "${path}" ]] || die "Unexpected update target: ${path}"
      cp -a --parents -- "${path}" "${UPGRADE_BACKUP}/files/"
    fi
  done
  for path in "${PROTECTED_FILES[@]}"; do
    [[ -f "${path}" && ! -L "${path}" ]] || die "Expected regular managed file: ${path}"
    cp -a --parents -- "${path}" "${UPGRADE_BACKUP}/files/"
  done
  sha256sum -- "${PROTECTED_FILES[@]}" >"${UPGRADE_BACKUP}/protected.sha256"
  stat -c '%a:%u:%g %n' -- "${PROTECTED_FILES[@]}" >"${UPGRADE_BACKUP}/protected.permissions"
  # Detect another operator changing binaries while the candidates are built.
  sha256sum -- "${UPGRADE_BINARIES[@]}" >"${UPGRADE_BACKUP}/binaries.sha256"
  printf 'domain=%s\nxray=%s\nmtproxy=%s\ntproxy=%s\ngo=%s\n' \
    "${DOMAIN}" "${XRAY_VERSION}" "${MTPROXY_COMMIT}" "${TPROXY_SERVER_COMMIT}" "${GO_VERSION}" \
    >"${UPGRADE_BACKUP}/target-versions.txt"
  printf 'frontend=%s\n' "${FAKETLS_ENGINE}" >>"${UPGRADE_BACKUP}/target-versions.txt"
  if [[ "${FAKETLS_ENGINE}" == mtg ]]; then
    printf 'mtg=%s\n' "${MTG_VERSION}" >>"${UPGRADE_BACKUP}/target-versions.txt"
  fi
  log "Rollback backup: ${UPGRADE_BACKUP}"
}

verify_protected_files() {
  sha256sum --check --status "${UPGRADE_BACKUP}/protected.sha256" || \
    die "Client credentials or configuration changed during the update."
  stat -c '%a:%u:%g %n' -- "${PROTECTED_FILES[@]}" >"${WORK_DIR}/protected.permissions"
  cmp -s "${UPGRADE_BACKUP}/protected.permissions" "${WORK_DIR}/protected.permissions" || \
    die "Permissions of a protected configuration file changed."
}

verify_mtg_candidate() {
  local candidate_bin=$1
  local config_file=$2
  local family=$3
  # The private backup survives cleanup, unlike the staging directory. Doctor
  # diagnostics can include configuration details and must never reach stdout.
  local private_log="${UPGRADE_BACKUP}/mtg-candidate-doctor-${family}.log"
  if ! "${candidate_bin}" doctor "${config_file}" >"${private_log}" 2>&1; then
    chmod 0600 "${private_log}"
    die "MTG candidate doctor failed for ${family}; inspect the root-only ${private_log}."
  fi
  chmod 0600 "${private_log}"
}

restore_upgrade() {
  local path
  local failed=0
  warn "Update failed; restoring the previous binaries from ${UPGRADE_BACKUP}."
  systemctl stop "${UPGRADE_UNITS[@]}" || failed=1
  for path in "${UPGRADE_FILES[@]}"; do
    if [[ -f "${UPGRADE_BACKUP}/files${path}" ]]; then
      cp -a -- "${UPGRADE_BACKUP}/files${path}" "${path}" || failed=1
    elif is_optional_upgrade_marker "${path}"; then
      # Older/manual installations may not have build or archive markers.
      rm -f -- "${path}" || failed=1
    else
      warn "Missing rollback file for ${path}; manual recovery is required."
      failed=1
    fi
  done
  systemctl start "${UPGRADE_UNITS[@]}" || failed=1
  if ((REFRESH_TIMER_WAS_ACTIVE)); then
    systemctl start mtproxy-config-refresh.timer || failed=1
  fi
  for path in "${UPGRADE_UNITS[@]}"; do
    systemctl is-active --quiet "${path}" || failed=1
  done
  ((failed == 0)) && warn "Previous binaries restored; client configuration was not rewritten."
  return "${failed}"
}

upgrade_exit() {
  local result=$?
  trap - EXIT
  set +e
  if ((UPGRADE_ACTIVATED && !UPGRADE_SUCCESS)); then
    restore_upgrade || warn "Automatic rollback was incomplete; inspect ${UPGRADE_BACKUP}."
    ((result != 0)) || result=1
  fi
  cleanup
  exit "${result}"
}

upgrade_main() {
  local unit
  local command_name
  [[ ${#} -eq 0 ]] || die "Usage: sudo bash upgrade-proxy-stack.sh (on the server to update)"
  [[ ${EUID} -eq 0 && -d /run/systemd/system ]] || die "Run this updater as root on the managed VPS."
  [[ "$(uname -m)" == x86_64 ]] || die "This updater supports x86_64 only."
  for command_name in flock curl sha256sum git make gcc tar unzip jq python3 openssl; do
    command -v "${command_name}" >/dev/null || die "Missing build prerequisite: ${command_name}"
  done
  exec 9>/run/lock/proxy-stack-upgrade.lock
  flock -n 9 || die "Another proxy-stack update is running."
  read_upgrade_state
  set_protected_files /etc/systemd/system
  for unit in teleproxy danted nginx mtproxy-config-refresh.timer "${UPGRADE_UNITS[@]}"; do
    systemctl is-active --quiet "${unit}" || die "Existing service ${unit} is not healthy; diagnose before upgrading."
  done
  [[ -f "${STATE_DIR}/mtproxy.commit" && -f "${STATE_DIR}/tproxy-server.commit" ]] || die "Missing installed component markers."
  WORK_DIR="$(mktemp -d /tmp/proxy-stack.XXXXXX)"
  backup_upgrade
  log "Building verified candidates while the existing services keep running"
  install_official_mtproxy "${WORK_DIR}/mtproto-proxy.candidate"
  install_tproxy_server "${WORK_DIR}/tproxy-server.candidate"
  install_xray "${WORK_DIR}/xray.candidate"
  if [[ "${FAKETLS_ENGINE}" == mtg ]]; then
    install_mtg "${WORK_DIR}/mtg.candidate"
    verify_mtg_candidate "${WORK_DIR}/mtg.candidate" "${MTG_CONFIG}" ipv4
    if ((UPGRADE_MTG_IPV6)); then
      verify_mtg_candidate "${WORK_DIR}/mtg.candidate" "${MTG_IPV6_CONFIG}" ipv6
    fi
  fi
  "${WORK_DIR}/xray.candidate" run -test -config "${XRAY_CONFIG}"
  "${WORK_DIR}/tproxy-server.candidate" -config "${TPROXY_SERVER_CONFIG}" -profiles-file "${TPROXY_SERVER_PROFILES}" -check
  verify_protected_files
  sha256sum --check --status "${UPGRADE_BACKUP}/binaries.sha256" || die "A running component was changed by another process."
  log "Activating candidates without changing ports, profiles, secrets or subscriptions"
  REFRESH_TIMER_WAS_ACTIVE=1
  UPGRADE_ACTIVATED=1
  systemctl stop mtproxy-config-refresh.timer mtproxy-config-refresh.service
  systemctl stop "${UPGRADE_UNITS[@]}"
  install -o root -g root -m 0755 "${WORK_DIR}/mtproto-proxy.candidate" "${MTPROXY_BIN}"
  install -o root -g root -m 0755 "${WORK_DIR}/tproxy-server.candidate" "${TPROXY_SERVER_BIN}"
  install -o root -g root -m 0755 "${WORK_DIR}/xray.candidate" "${XRAY_BIN}"
  if [[ "${FAKETLS_ENGINE}" == mtg ]]; then
    install -o root -g root -m 0755 "${WORK_DIR}/mtg.candidate" "${MTG_BIN}"
    printf '%s\n' "${MTG_VERSION}" | write_atomic 0600 "${STATE_DIR}/mtg.version"
    printf '%s\n' "${MTG_SHA256_AMD64}" | write_atomic 0600 "${STATE_DIR}/mtg.archive.sha256"
  fi
  printf '%s\n' "${MTPROXY_COMMIT}" | write_atomic 0600 "${STATE_DIR}/mtproxy.commit"
  printf '%s\n' "${TPROXY_SERVER_COMMIT}" | write_atomic 0600 "${STATE_DIR}/tproxy-server.commit"
  printf '%s\n' "${GO_VERSION}" | write_atomic 0600 "${STATE_DIR}/tproxy-server.go-version"
  systemctl start "${UPGRADE_UNITS[@]}"
  systemctl start mtproxy-config-refresh.timer
  verify_services
  verify_protected_files
  printf 'verified_at=%s\n' "$(date --iso-8601=seconds)" >"${UPGRADE_BACKUP}/completed"
  UPGRADE_SUCCESS=1
  log "Upgrade verified successfully for ${DOMAIN}. Credentials and configuration are unchanged."
  log "Previous binaries and configuration snapshots remain in ${UPGRADE_BACKUP}."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  # EXIT is required: die() exits directly and does not necessarily fire ERR.
  trap upgrade_exit EXIT
  trap 'printf "[proxy-stack] Upgrade failed at line %s.\n" "${LINENO}" >&2' ERR
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  upgrade_main "$@"
fi
