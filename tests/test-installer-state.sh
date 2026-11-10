#!/usr/bin/env bash
# Exercise real state loading with only hard-coded paths remapped into fixtures.
set -Eeuo pipefail
TEST_REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_TEST_DIR="$(mktemp -d /tmp/proxy-stack-state-tests.XXXXXX)"
trap 'case "${STATE_TEST_DIR}" in /tmp/proxy-stack-state-tests.*) command rm -rf -- "${STATE_TEST_DIR}";; esac' EXIT

for state_case in fresh edge legacy safari legacy_subscription empty duplicate malicious domain_mismatch; do
  case_root="${STATE_TEST_DIR}/${state_case}"
  mkdir -p "${case_root}/state" "${case_root}/work"
  bash -s -- "${TEST_REPO}" "${case_root}" "${state_case}" <<'STATE_CASE'
set -Eeuo pipefail
test_repo=$1
fixture_root=$2
scenario=$3
printf '00000000-0000-4000-8000-000000000099\n' >"${fixture_root}/uuid"
# Only filesystem constants change: the production loader and validation code
# run unchanged. The UUID fixture also keeps these tests portable to macOS.
sed -e "s|^readonly STATE_DIR=.*|readonly STATE_DIR=\"${fixture_root}/state\"|" \
  -e "s|/proc/sys/kernel/random/uuid|${fixture_root}/uuid|g" "${test_repo}/install-proxy-stack.sh" \
  >"${fixture_root}/installer.fixture.sh"
# shellcheck source=install-proxy-stack.sh
source "${fixture_root}/installer.fixture.sh"
WORK_DIR="${fixture_root}/work"
DOMAIN=proxy.example.com
DOMAIN_IPV6=""
RAW_SECRET=00000000000000000000000000000001
SOCKS_PASSWORD=00000000000000000000000000000002
VLESS_UUID=00000000-0000-4000-8000-000000000001
VLESS_WS_PATH=/00000000000000000000000000000003
HAPP_SUBSCRIPTION_ID=0000000000000000000000000000000000000004
if [[ "${scenario}" == legacy_subscription ]]; then
  HAPP_SUBSCRIPTION_ID=00000000000000000000000000000004
fi
install() {
  [[ "$1" == -d ]] || return 1
  local -a arguments=("$@")
  local destination="${arguments[${#arguments[@]}-1]}"
  [[ "${destination}" == "${fixture_root}/"* ]] || return 1
  command mkdir -p "${destination}"
}
write_atomic() {
  [[ "$2" == "${fixture_root}/"* && "$1" == 0600 ]] || return 1
  command cat >"$2"
  command chmod 0600 "$2"
}
openssl() {
  [[ "${scenario}" == fresh && "$1" == rand && "$2" == -hex ]] || return 1
  case "$3" in
    16) printf '00000000000000000000000000000002\n' ;;
    20) printf '0000000000000000000000000000000000000004\n' ;;
    *) return 1 ;;
  esac
}
systemctl() { printf 'unexpected call\n' >"${fixture_root}/systemctl.called"; return 1; }

if [[ "${scenario}" != fresh ]]; then
  command cat >"${STATE_FILE}" <<EOF
DOMAIN=${DOMAIN}
DOMAIN_IPV6=${DOMAIN_IPV6}
RAW_SECRET=${RAW_SECRET}
SOCKS_USER=${SOCKS_USER}
SOCKS_PASSWORD=${SOCKS_PASSWORD}
VLESS_UUID=${VLESS_UUID}
VLESS_WS_PATH=${VLESS_WS_PATH}
HAPP_SUBSCRIPTION_ID=${HAPP_SUBSCRIPTION_ID}
EOF
  case "${scenario}" in
    legacy) ;;
    safari) printf 'VLESS_TLS_FINGERPRINT=safari\n' >>"${STATE_FILE}" ;;
    empty) printf 'VLESS_TLS_FINGERPRINT=\n' >>"${STATE_FILE}" ;;
    duplicate) printf 'VLESS_TLS_FINGERPRINT=edge\nVLESS_TLS_FINGERPRINT=safari\n' >>"${STATE_FILE}" ;;
    malicious) printf 'VLESS_TLS_FINGERPRINT=edge&allowInsecure=1\n' >>"${STATE_FILE}" ;;
    *) printf 'VLESS_TLS_FINGERPRINT=edge\n' >>"${STATE_FILE}" ;;
  esac
  before_state="$(cksum "${STATE_FILE}")"
  before_auth="$(grep -v '^VLESS_TLS_FINGERPRINT=' "${STATE_FILE}")"
fi

case "${scenario}" in
  domain_mismatch)
    DOMAIN=other.example.com
    if (check_existing_domains) 2>/dev/null; then exit 1; fi
    [[ ! -e "${fixture_root}/systemctl.called" ]]
    [[ "$(cksum "${STATE_FILE}")" == "${before_state}" ]]
    ;;
  empty|duplicate|malicious)
    if (load_or_create_credentials) >/dev/null 2>&1; then exit 1; fi
    [[ "$(cksum "${STATE_FILE}")" == "${before_state}" ]]
    ;;
  *)
    check_existing_domains
    load_or_create_credentials >/dev/null
    [[ -s "${STATE_FILE}" ]]
    if [[ "${scenario}" == safari ]]; then
      [[ "$(state_value VLESS_TLS_FINGERPRINT)" == safari ]]
    else
      [[ "$(state_value VLESS_TLS_FINGERPRINT)" == edge ]]
    fi
    if [[ "${scenario}" == edge || "${scenario}" == safari || "${scenario}" == legacy_subscription ]]; then
      [[ "$(cksum "${STATE_FILE}")" == "${before_state}" ]]
    fi
    if [[ "${scenario}" == fresh ]]; then
      [[ "$(state_value VLESS_UUID)" == 00000000-0000-4000-8000-000000000099 ]]
    else
      [[ "$(grep -v '^VLESS_TLS_FINGERPRINT=' "${STATE_FILE}")" == "${before_auth}" ]]
    fi
    ;;
esac
printf 'PASS installer state: %s\n' "${scenario}"
STATE_CASE
done
printf 'All installer state regression tests passed.\n'
