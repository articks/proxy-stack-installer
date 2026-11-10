#!/usr/bin/env bash
# Offline generated-config regression tests. No root, network or real services.
set -Eeuo pipefail
TEST_REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER_TEST_DIR="$(mktemp -d /tmp/proxy-stack-installer-tests.XXXXXX)"
trap 'case "${INSTALLER_TEST_DIR}" in /tmp/proxy-stack-installer-tests.*) command rm -rf -- "${INSTALLER_TEST_DIR}";; esac' EXIT
saved_exit_trap="$(trap -p EXIT)"
# shellcheck source=install-proxy-stack.sh
source "${TEST_REPO}/install-proxy-stack.sh"
[[ "$(trap -p EXIT)" == "${saved_exit_trap}" && -z "${DOMAIN}" ]]
[[ "${VLESS_TLS_FINGERPRINT}" == edge && "${FAKETLS_ENGINE}" == mtg ]]
printf 'PASS source does not run installation or replace caller cleanup\n'

WORK_DIR="${INSTALLER_TEST_DIR}/work"
mkdir -p "${WORK_DIR}"
DOMAIN=proxy.example.com
DOMAIN_IPV6=proxy6.example.com
PUBLIC_IPV4=203.0.113.10
PUBLIC_IPV6=2001:db8::10
RAW_SECRET=00000000000000000000000000000001
SOCKS_PASSWORD=00000000000000000000000000000002
VLESS_UUID=00000000-0000-4000-8000-000000000001
VLESS_WS_PATH=/00000000000000000000000000000003
HAPP_SUBSCRIPTION_ID=0000000000000000000000000000000000000004
GENERATED_ROOT=""

write_atomic() {
  local mode=$1 destination=$2
  [[ "${destination}" == /* && "${destination}" != *'..'* ]]
  mkdir -p "${GENERATED_ROOT}${destination%/*}"
  command cat >"${GENERATED_ROOT}${destination}"
  chmod "${mode}" "${GENERATED_ROOT}${destination}"
}
install() {
  [[ "$1" == -d ]] || return 1
  local -a arguments=("$@")
  local destination="${arguments[${#arguments[@]}-1]}"
  mkdir -p "${GENERATED_ROOT}${destination}"
}
id() { return 1; }
useradd() { (IFS=' '; printf '%s\n' "$*" >>"${GENERATED_ROOT}/useradd.calls"); }
verify_mtg_config() {
  [[ -s "${GENERATED_ROOT}$1" ]]
  printf '%s\n' "$1" >>"${GENERATED_ROOT}/doctor.calls"
}
systemctl() { (IFS=' '; printf '%s\n' "$*" >>"${GENERATED_ROOT}/systemctl.calls"); }
date() { printf '2026-11-10T12:00:00+00:00\n'; }
cat() {
  if [[ $# == 1 && "$1" == "${CREDENTIALS_OUTPUT}" ]]; then
    command cat "${GENERATED_ROOT}${CREDENTIALS_OUTPUT}"
  else
    command cat "$@"
  fi
}
assert_absent() {
  if "$@"; then
    printf 'FAIL unexpected matching value\n' >&2
    return 1
  fi
}

render() {
  local name=$1
  ENABLE_IPV6=$2
  GENERATED_ROOT="${INSTALLER_TEST_DIR}/${name}"
  mkdir -p "${GENERATED_ROOT}"
  install_proxy_services
  write_happ_subscription
  write_credentials_output >/dev/null
}

render ipv4 0
v4_config="${GENERATED_ROOT}${MTG_CONFIG}"
v4_unit="${GENERATED_ROOT}/etc/systemd/system/teleproxy.service"
subscription="${GENERATED_ROOT}${NGINX_ROOT}/happ/${HAPP_SUBSCRIPTION_ID}.txt"
credentials="${GENERATED_ROOT}${CREDENTIALS_OUTPUT}"
ee4="ee${RAW_SECRET}$(printf '%s' "${DOMAIN}" | xxd -p -c 256)"
grep -Fxq "secret = \"${ee4}\"" "${v4_config}"
grep -Fxq "bind-to = \"${PUBLIC_IPV4}:443\"" "${v4_config}"
grep -Fxq 'bind-to = "127.0.0.1:8888"' "${v4_config}"
[[ ! -e "${GENERATED_ROOT}${MTG_IPV6_CONFIG}" ]]
[[ ! -e "${GENERATED_ROOT}/etc/systemd/system/teleproxy-ipv6.service" ]]
assert_absent grep -q 'teleproxy-ipv6' "${GENERATED_ROOT}/systemctl.calls"
[[ "$(grep -c '^vless://' "${subscription}")" == 2 ]]
grep -q ':443?.*&fp=edge&' "${subscription}"
grep -q ':9443?.*&fp=edge&' "${subscription}"
assert_absent grep -q '\[2001:db8' "${subscription}"
[[ "$(grep -c '^vless://.*&fp=edge&' "${credentials}")" == 4 ]]
printf 'PASS IPv4-only MTG and both Edge profiles without IPv6 artifacts\n'

for expected in 'User=mtg' 'Group=mtg' 'EnvironmentFile=' \
  "LoadCredential=mtg.toml:${MTG_CONFIG}" "ExecStart=${MTG_BIN} run %d/mtg.toml" \
  'AmbientCapabilities=CAP_NET_BIND_SERVICE' 'CapabilityBoundingSet=CAP_NET_BIND_SERVICE' \
  'NoNewPrivileges=true' 'UMask=0077'; do
  grep -Fxq "${expected}" "${v4_unit}"
done
assert_absent grep -q "${RAW_SECRET}" "${v4_unit}"
assert_absent grep -q '0.0.0.0:443\|\[::\]:443' "${v4_config}"
assert_absent grep -qi 'allowInsecure\|skipCertVerify' "${subscription}"
[[ "$(wc -l <"${GENERATED_ROOT}/doctor.calls" | tr -d ' ')" == 1 ]]
python3 - "${v4_config}" "${credentials}" "${GENERATED_ROOT}${FRONTEND_METADATA}" <<'PY'
import os,stat,sys
for path in sys.argv[1:]:
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
PY
printf 'PASS private EE config, LoadCredential and minimal binding capability\n'

render dual_stack 1
v6_config="${GENERATED_ROOT}${MTG_IPV6_CONFIG}"
ee6="ee${RAW_SECRET}$(printf '%s' "${DOMAIN_IPV6}" | xxd -p -c 256)"
[[ "${ee4}" != "${ee6}" ]]
grep -Fxq "secret = \"${ee4}\"" "${GENERATED_ROOT}${MTG_CONFIG}"
grep -Fxq "secret = \"${ee6}\"" "${v6_config}"
grep -Fxq "bind-to = \"[${PUBLIC_IPV6}]:443\"" "${v6_config}"
grep -Fxq 'bind-to = "127.0.0.1:8890"' "${v6_config}"
grep -Fxq 'prefer-ip = "prefer-ipv6"' "${v6_config}"
grep -Fq 'enable mtproxy-ipv6.service teleproxy-ipv6.service' "${GENERATED_ROOT}/systemctl.calls"
grep -Fxq 'restart teleproxy-ipv6.service' "${GENERATED_ROOT}/systemctl.calls"
grep -Fxq "FAKETLS_IPV6_CONFIG=${MTG_IPV6_CONFIG}" "${GENERATED_ROOT}${FRONTEND_METADATA}"
subscription="${GENERATED_ROOT}${NGINX_ROOT}/happ/${HAPP_SUBSCRIPTION_ID}.txt"
[[ "$(grep -c '^vless://' "${subscription}")" == 4 ]]
[[ "$(grep -c '^vless://.*&fp=edge&' "${subscription}")" == 4 ]]
[[ "$(wc -l <"${GENERATED_ROOT}/doctor.calls" | tr -d ' ')" == 2 ]]
printf 'PASS two domain-bound EE secrets, separate IPv6 service and four Edge profiles\n'

for fingerprint in edge safari chrome firefox ios android 360 qq random randomized unsafe HelloChrome_106_Shuffle; do
  validate_vless_fingerprint "${fingerprint}"
done
for fingerprint in '' 'edge&allowInsecure=1' 'edge"' 'edge;echo'; do
  if (validate_vless_fingerprint "${fingerprint}") 2>/dev/null; then
    printf 'FAIL invalid fingerprint accepted\n' >&2
    exit 1
  fi
done
printf 'PASS fingerprint whitelist and query/shell/JSON injection rejection\n'

# The same input must render identical key/profile parameters on a rerun.
before_parameters="$(cksum "${GENERATED_ROOT}${MTG_CONFIG}" "${v6_config}" "${subscription}")"
install_proxy_services
write_happ_subscription
[[ "$(cksum "${GENERATED_ROOT}${MTG_CONFIG}" "${v6_config}" "${subscription}")" == "${before_parameters}" ]]
printf 'PASS repeat rendering preserves secrets and subscription parameters\n'

# Runtime-generated scripts must not restart MTG for files it never reads.
grep -Fq "grep -Fq '/usr/local/bin/teleproxy'" "${TEST_REPO}/install-proxy-stack.sh"
# Match the literal shell variable in the generated state/metadata templates.
# shellcheck disable=SC2016
[[ "$(grep -c 'VLESS_TLS_FINGERPRINT=\${VLESS_TLS_FINGERPRINT}' "${TEST_REPO}/install-proxy-stack.sh")" -ge 2 ]]
printf 'All installer regression tests passed.\n'
