#!/usr/bin/env bash
# Isolated regression tests: no root, network, services or live files are used.
set -Eeuo pipefail
TEST_REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CREDENTIALS_TEST_DIR="$(mktemp -d /tmp/proxy-credentials-tests.XXXXXX)"
trap 'case "${CREDENTIALS_TEST_DIR}" in /tmp/proxy-credentials-tests.*) command rm -rf -- "${CREDENTIALS_TEST_DIR}";; esac' EXIT

test_source_options="$(set +o)"
test_source_ifs="${IFS}"
test_source_umask="$(umask)"
test_source_trap="$(trap -p EXIT)"
# shellcheck source=rebuild-proxy-credentials.sh
source "${TEST_REPO}/rebuild-proxy-credentials.sh"
[[ "$(set +o)" == "${test_source_options}" ]]
[[ "${IFS}" == "${test_source_ifs}" && "$(umask)" == "${test_source_umask}" ]]
[[ "$(trap -p EXIT)" == "${test_source_trap}" ]]
[[ -z "${DOMAIN}" && -z "${TEMPORARY_OUTPUT}" && "${MANAGED_INSTALL}" == 0 ]]
printf 'PASS sourcing has no root/network/service calls and preserves options, umask and traps\n'

unexpected_live_call() {
  printf 'unexpected live call\n' >>"${CREDENTIALS_TEST_DIR}/unexpected-live-call"
  return 1
}
systemctl() { unexpected_live_call; }
dig() { unexpected_live_call; }
chpasswd() { unexpected_live_call; }
openssl() { unexpected_live_call; }
getent() { unexpected_live_call; }
date() { printf '2026-11-10T12:00:00+00:00\n'; }
install() {
  local -a arguments=("$@")
  local source_file="${arguments[${#arguments[@]}-2]}"
  local destination="${arguments[${#arguments[@]}-1]}"
  [[ "${destination}" == "${CREDENTIALS_TEST_DIR}/"* ]] || return 1
  command cp "${source_file}" "${destination}"
  command chmod 0600 "${destination}"
}

fixture() {
  local name=$1
  local fixture_dir="${CREDENTIALS_TEST_DIR}/${name}"
  mkdir -p "${fixture_dir}/happ" "${fixture_dir}/mtproxy"
  STATE_FILE="${fixture_dir}/credentials.env"
  OUTPUT_FILE="${fixture_dir}/proxy-credentials.txt"
  MTPROXY_ENV="${fixture_dir}/mtproxy/mtproxy.env"
  MTG_CONFIG="${fixture_dir}/mtproxy/mtg.toml"
  TPROXY_SERVER_CONFIG="${fixture_dir}/no-webproxy.json"
  TPROXY_SERVER_PROFILES="${fixture_dir}/no-webproxy-profiles.json"
  XRAY_CONFIG="${fixture_dir}/xray.json"
  HAPP_DIR="${fixture_dir}/happ"
  HAPP_SUBSCRIPTION_ID="0123456789abcdef0123456789abcdef01234567"
  ACTIVE_SUBSCRIPTION_FILE="${HAPP_DIR}/${HAPP_SUBSCRIPTION_ID}.txt"
  REQUESTED_SUBSCRIPTION_ID=""
  DOMAIN="proxy.example.com"
  DOMAIN_IPV6=""
  PUBLIC_IPV4="203.0.113.10"
  PUBLIC_IPV6=""
  RAW_SECRET="00112233445566778899aabbccddeeff"
  SOCKS_USER="socksproxy"
  SOCKS_PASSWORD="ffeeddccbbaa99887766554433221100"
  VLESS_UUID="00112233-4455-4677-8899-aabbccddeeff"
  VLESS_WS_PATH="/0123456789abcdef0123456789abcdef"
  VLESS_TLS_FINGERPRINT=""
  STATE_HAS_VLESS_TLS_FINGERPRINT=0
  MANAGED_INSTALL=0
  ROTATE_SOCKS_PASSWORD=0
  PRINT_OUTPUT=0
  TEMPORARY_OUTPUT=""
}

seed_state() {
  local fingerprint=$1
  cat >"${STATE_FILE}" <<EOF
DOMAIN=${DOMAIN}
DOMAIN_IPV6=${DOMAIN_IPV6}
RAW_SECRET=${RAW_SECRET}
SOCKS_USER=${SOCKS_USER}
SOCKS_PASSWORD=${SOCKS_PASSWORD}
VLESS_UUID=${VLESS_UUID}
VLESS_WS_PATH=${VLESS_WS_PATH}
HAPP_SUBSCRIPTION_ID=${HAPP_SUBSCRIPTION_ID}
EOF
  if [[ "${fingerprint}" != absent ]]; then
    printf 'VLESS_TLS_FINGERPRINT=%s\n' "${fingerprint}" >>"${STATE_FILE}"
  fi
}

seed_profile() {
  local fingerprint=$1
  local query_fingerprint=""
  [[ "${fingerprint}" == absent ]] || query_fingerprint="&fp=${fingerprint}"
  printf 'vless://%s@203.0.113.10:443?encryption=none&security=tls&sni=proxy.example.com%s&type=ws&host=proxy.example.com&path=%%2F0123456789abcdef0123456789abcdef#fixture\n' \
    "${VLESS_UUID}" "${query_fingerprint}" >"${ACTIVE_SUBSCRIPTION_FILE}"
}

load_fixture() {
  load_managed_state "" ""
  validate_state
  select_active_subscription
  load_vless_fingerprint
}

expect_failure() {
  if ("$@") 2>/dev/null; then
    printf 'Expected rejection from %s\n' "$1" >&2
    return 1
  fi
}

fixture edge
seed_state edge
seed_profile edge
printf 'secret = "private-mtg-fixture-value"\n' >"${MTG_CONFIG}"
test_unchanged="$(cksum "${STATE_FILE}" "${ACTIVE_SUBSCRIPTION_FILE}" "${MTG_CONFIG}")"
load_fixture
write_credentials
grep -q 'vless://.*@proxy.example.com:443?.*&fp=edge&' "${OUTPUT_FILE}"
grep -q 'vless://.*@203.0.113.10:443?.*&fp=edge&' "${OUTPUT_FILE}"
grep -q 'vless://.*@203.0.113.10:9443?.*&fp=edge&' "${OUTPUT_FILE}"
grep -q '^TLS fingerprint: edge$' "${OUTPUT_FILE}"
grep -Fq "MTG config: ${MTG_CONFIG}" "${OUTPUT_FILE}"
grep -Fxq "MTProto state: ${STATE_FILE}" "${OUTPUT_FILE}"
grep -Fq 'FakeTLS service: teleproxy.service (compatibility service name)' "${OUTPUT_FILE}"
expect_failure grep -q 'private-mtg-fixture-value' "${OUTPUT_FILE}"
[[ "$(cksum "${STATE_FILE}" "${ACTIVE_SUBSCRIPTION_FILE}" "${MTG_CONFIG}")" == "${test_unchanged}" ]]
[[ "${RAW_SECRET}" == 00112233445566778899aabbccddeeff ]]
[[ "${SOCKS_PASSWORD}" == ffeeddccbbaa99887766554433221100 ]]
[[ "${VLESS_UUID}" == 00112233-4455-4677-8899-aabbccddeeff ]]
[[ "${VLESS_WS_PATH}" == /0123456789abcdef0123456789abcdef ]]
printf 'PASS Edge domain/IP/reserve URIs, MTG metadata and unchanged credentials/profiles\n'

fixture legacy-safari
seed_state absent
seed_profile absent
test_unchanged="$(cksum "${STATE_FILE}" "${ACTIVE_SUBSCRIPTION_FILE}")"
load_fixture
write_credentials
[[ "${VLESS_TLS_FINGERPRINT}" == safari ]]
grep -q '&fp=safari&' "${OUTPUT_FILE}"
[[ "$(cksum "${STATE_FILE}" "${ACTIVE_SUBSCRIPTION_FILE}")" == "${test_unchanged}" ]]
printf 'PASS legacy state without fp retains Safari fallback without state migration\n'

fixture legacy-active
seed_state absent
seed_profile firefox
test_unchanged="$(cksum "${STATE_FILE}" "${ACTIVE_SUBSCRIPTION_FILE}")"
load_fixture
write_credentials
[[ "${VLESS_TLS_FINGERPRINT}" == firefox ]]
grep -q '&fp=firefox&' "${OUTPUT_FILE}"
[[ "$(cksum "${STATE_FILE}" "${ACTIVE_SUBSCRIPTION_FILE}")" == "${test_unchanged}" ]]
printf 'PASS legacy state reads the active profile fingerprint without key rotation\n'

fixture native-hello
seed_state HelloChrome_Auto
seed_profile HelloChrome_Auto
load_fixture
[[ "$(vless_uri "${DOMAIN}" "${DOMAIN}" fixture)" == *'&fp=HelloChrome_Auto&'* ]]
validate_vless_fingerprint unsafe
printf 'PASS safe native HelloName and standard Xray unsafe fingerprint\n'

fixture mismatch
seed_state edge
seed_profile safari
printf 'existing credentials\n' >"${OUTPUT_FILE}"
test_unchanged="$(cksum "${STATE_FILE}" "${ACTIVE_SUBSCRIPTION_FILE}" "${OUTPUT_FILE}")"
expect_failure load_fixture
[[ "$(cksum "${STATE_FILE}" "${ACTIVE_SUBSCRIPTION_FILE}" "${OUTPUT_FILE}")" == "${test_unchanged}" ]]
printf 'PASS state/active fingerprint mismatch fails before writing anything\n'

fixture malicious-state
# Deliberately preserve the injection as literal test data, never execute it.
# shellcheck disable=SC2016
seed_state 'edge";$(touch /tmp/should-not-exist)'
seed_profile edge
expect_failure load_fixture
seed_state ''
expect_failure load_fixture
seed_state edge
printf 'VLESS_TLS_FINGERPRINT=safari\n' >>"${STATE_FILE}"
expect_failure load_fixture
printf 'PASS malicious, empty and duplicate stored fingerprints are rejected\n'

fixture malicious-active
seed_state absent
seed_profile 'edge%22%3B%24%28touch%20something%29'
expect_failure load_fixture
seed_profile 'edge&fp=safari'
expect_failure load_fixture
printf 'PASS URL-encoded injection and duplicate fp query parameters are rejected\n'

fixture mixed-active
seed_state absent
seed_profile edge
printf 'vless://%s@proxy.example.com:443?security=tls&fp=safari&type=ws#other\n' \
  "${VLESS_UUID}" >>"${ACTIVE_SUBSCRIPTION_FILE}"
expect_failure load_fixture
printf 'PASS ambiguous active profile fingerprints are not guessed\n'

fixture wrong-active-uuid
seed_state edge
VLESS_UUID="11223344-5566-4788-99aa-bbccddeeff00"
seed_profile edge
expect_failure load_fixture
fixture wrong-active-path
seed_state edge
seed_profile edge
sed 's/path=%2F0123456789abcdef0123456789abcdef/path=%2Faaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' \
  "${ACTIVE_SUBSCRIPTION_FILE}" >"${HAPP_DIR}/changed.txt"
mv "${HAPP_DIR}/changed.txt" "${ACTIVE_SUBSCRIPTION_FILE}"
expect_failure load_fixture
printf '# no active VLESS URI\n' >"${ACTIVE_SUBSCRIPTION_FILE}"
expect_failure load_fixture
printf 'PASS mismatched UUID/path and missing managed profiles do not produce invented access\n'

fixture manual-reality
VLESS_WS_PATH=""
test_manual_uri="vless://${VLESS_UUID}@203.0.113.10:443?security=reality&fp=edge&type=tcp&sni=example.org&pbk=fixture-key#active-reality"
printf '%s\n' "${test_manual_uri}" >"${ACTIVE_SUBSCRIPTION_FILE}"
test_unchanged="$(cksum "${ACTIVE_SUBSCRIPTION_FILE}")"
load_vless_fingerprint
write_credentials
grep -Fxq "${test_manual_uri}" "${OUTPUT_FILE}"
if grep '^vless://' "${OUTPUT_FILE}" | grep -q 'type=ws'; then
  printf 'FAIL invented manual WebSocket profile\n' >&2
  exit 1
fi
[[ "$(grep -c '^vless://' "${OUTPUT_FILE}")" == 1 ]]
[[ "$(cksum "${ACTIVE_SUBSCRIPTION_FILE}")" == "${test_unchanged}" ]]
printf 'PASS manual active URI stays exact without guessed WS/IP/reserve alternatives\n'

[[ ! -e "${CREDENTIALS_TEST_DIR}/unexpected-live-call" ]]
printf 'All credentials regression tests passed.\n'
