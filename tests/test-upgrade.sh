#!/usr/bin/env bash
# Isolated regression tests: no root, network, services or live files are used.
set -Eeuo pipefail
TEST_REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PROXY_TEST_DIR="$(mktemp -d /tmp/proxy-stack-tests.XXXXXX)"
export PROXY_TEST_DIR
trap 'case "${PROXY_TEST_DIR}" in /tmp/proxy-stack-tests.*) rm -rf -- "${PROXY_TEST_DIR}";; esac' EXIT

# shellcheck source=upgrade-proxy-stack.sh
source "${TEST_REPO}/upgrade-proxy-stack.sh"
# Sourcing must not install anything or take ownership of the caller's EXIT trap.
trap 'case "${PROXY_TEST_DIR}" in /tmp/proxy-stack-tests.*) command rm -rf -- "${PROXY_TEST_DIR}";; esac' EXIT
[[ "${UPGRADE_ACTIVATED}" == 0 && -z "${DOMAIN}" && -z "${UPGRADE_BACKUP}" ]]
printf 'PASS source does not execute installer or updater\n'

array_has() {
  local expected=$1
  local item
  shift
  for item in "$@"; do
    [[ "${item}" != "${expected}" ]] || return 0
  done
  return 1
}

expect_absent() {
  if array_has "$@"; then
    printf 'Unexpected array member: %s\n' "$1" >&2
    return 1
  fi
  return 0
}

# Frontend selection must follow the effective executable, never a new-install
# default or the mere presence of a stale MTG binary/configuration.
TEST_FRONTEND_PATH="${TELEPROXY_BIN}"
TEST_IPV6_FRONTEND_PATH="${MTG_BIN}"
systemctl() {
  [[ "$1" == show ]] || return 1
  local unit="${4}"
  local executable="${TEST_FRONTEND_PATH}"
  [[ "${unit}" != teleproxy-ipv6.service ]] || executable="${TEST_IPV6_FRONTEND_PATH}"
  printf '{ path=%s ; argv[]=%s run /run/credentials/%s/config.toml ; ignore_errors=no ; }\n' \
    "${executable}" "${executable}" "${unit}"
}
ENABLE_IPV6=0
VLESS_TLS_FINGERPRINT=""
detect_upgrade_frontend "${PROXY_TEST_DIR}/absent-frontend.env"
set_upgrade_components
[[ "${FAKETLS_ENGINE}" == teleproxy && "${VLESS_TLS_FINGERPRINT}" == safari ]]
expect_absent "${MTG_BIN}" "${UPGRADE_BINARIES[@]}"
expect_absent teleproxy.service "${UPGRADE_UNITS[@]}"
expect_absent teleproxy-ipv6.service "${UPGRADE_UNITS[@]}"
ENABLE_IPV6=1
set_upgrade_components
array_has mtproxy-ipv6.service "${UPGRADE_UNITS[@]}"
expect_absent teleproxy-ipv6.service "${UPGRADE_UNITS[@]}"
printf 'PASS legacy Teleproxy and its existing fingerprint are not migrated\n'

write_frontend_fixture() {
  local ipv6=$1
  printf 'FAKETLS_ENGINE=mtg\nFAKETLS_SERVICE=teleproxy.service\nFAKETLS_CONFIG=%s\nFAKETLS_BINARY=%s\nVLESS_TLS_FINGERPRINT=edge\n' \
    "${MTG_CONFIG}" "${MTG_BIN}" >"${PROXY_TEST_DIR}/frontend.env"
  if ((ipv6)); then
    printf 'FAKETLS_IPV6_SERVICE=teleproxy-ipv6.service\nFAKETLS_IPV6_CONFIG=%s\n' \
      "${MTG_IPV6_CONFIG}" >>"${PROXY_TEST_DIR}/frontend.env"
  fi
}
write_frontend_fixture 0
TEST_FRONTEND_PATH="${MTG_BIN}"
ENABLE_IPV6=0
VLESS_TLS_FINGERPRINT=""
detect_upgrade_frontend "${PROXY_TEST_DIR}/frontend.env"
set_upgrade_components
[[ "${FAKETLS_ENGINE}" == mtg && "${VLESS_TLS_FINGERPRINT}" == edge && "${UPGRADE_MTG_IPV6}" == 0 ]]
array_has "${MTG_BIN}" "${UPGRADE_BINARIES[@]}"
array_has "${STATE_DIR}/mtg.version" "${UPGRADE_FILES[@]}"
array_has "${STATE_DIR}/mtg.archive.sha256" "${UPGRADE_FILES[@]}"
array_has teleproxy.service "${UPGRADE_UNITS[@]}"
expect_absent teleproxy-ipv6.service "${UPGRADE_UNITS[@]}"
printf 'PASS managed MTG is detected even before version markers exist\n'

write_frontend_fixture 1
ENABLE_IPV6=1
VLESS_TLS_FINGERPRINT=edge
detect_upgrade_frontend "${PROXY_TEST_DIR}/frontend.env"
set_upgrade_components
[[ "${UPGRADE_MTG_IPV6}" == 1 ]]
array_has mtproxy-ipv6.service "${UPGRADE_UNITS[@]}"
array_has teleproxy-ipv6.service "${UPGRADE_UNITS[@]}"
mkdir -p "${PROXY_TEST_DIR}/units/teleproxy.service.d" "${PROXY_TEST_DIR}/units/teleproxy-ipv6.service.d"
printf '[Service]\n# host-local override\n' >"${PROXY_TEST_DIR}/units/teleproxy.service.d/90-mtg.conf"
printf '[Service]\n# IPv6 override\n' >"${PROXY_TEST_DIR}/units/teleproxy-ipv6.service.d/90-mtg.conf"
set_protected_files "${PROXY_TEST_DIR}/units"
array_has "${MTG_CONFIG}" "${PROTECTED_FILES[@]}"
array_has "${MTG_IPV6_CONFIG}" "${PROTECTED_FILES[@]}"
array_has "${PROXY_TEST_DIR}/frontend.env" "${PROTECTED_FILES[@]}"
array_has "${PROXY_TEST_DIR}/units/teleproxy.service.d/90-mtg.conf" "${PROTECTED_FILES[@]}"
array_has "${PROXY_TEST_DIR}/units/teleproxy-ipv6.service.d/90-mtg.conf" "${PROTECTED_FILES[@]}"
printf 'PASS MTG IPv6 and host-local drop-ins are protected\n'

expect_frontend_failure() {
  local executable=$1
  local fingerprint=$2
  local ipv6=$3
  local ipv6_executable=${4:-${executable}}
  local result=0
  bash -c '
    source "$1"
    TEST_EXECUTABLE=$3
    TEST_IPV6_EXECUTABLE=$6
    service_exec_path() {
      if [[ "$1" == teleproxy-ipv6.service ]]; then
        printf "%s\n" "${TEST_IPV6_EXECUTABLE}"
      else
        printf "%s\n" "${TEST_EXECUTABLE}"
      fi
    }
    VLESS_TLS_FINGERPRINT=$4
    ENABLE_IPV6=$5
    detect_upgrade_frontend "$2"
  ' _ "${TEST_REPO}/upgrade-proxy-stack.sh" "${PROXY_TEST_DIR}/frontend.env" \
    "${executable}" "${fingerprint}" "${ipv6}" "${ipv6_executable}" >/dev/null 2>&1 || result=$?
  [[ "${result}" != 0 ]]
}
expect_frontend_failure "${TELEPROXY_BIN}" edge 1
expect_frontend_failure "${MTG_BIN}" safari 1
expect_frontend_failure "${MTG_BIN}" edge 1 "${TELEPROXY_BIN}"
write_frontend_fixture 0
expect_frontend_failure "${MTG_BIN}" edge 1
printf 'PASS mismatched frontend, fingerprint and IPv6 metadata fail closed\n'

UPGRADE_BACKUP="${PROXY_TEST_DIR}/doctor-logs"
mkdir -p "${UPGRADE_BACKUP}"
private_mtg_candidate() {
  [[ "$1" == doctor && "$2" == "${MTG_CONFIG}" ]] || return 1
  printf 'private-doctor-output\n'
  printf 'private-doctor-error\n' >&2
}
verify_mtg_candidate private_mtg_candidate "${MTG_CONFIG}" ipv4 \
  >"${PROXY_TEST_DIR}/doctor.stdout" 2>"${PROXY_TEST_DIR}/doctor.stderr"
[[ ! -s "${PROXY_TEST_DIR}/doctor.stdout" && ! -s "${PROXY_TEST_DIR}/doctor.stderr" ]]
[[ "$(ls -l "${UPGRADE_BACKUP}/mtg-candidate-doctor-ipv4.log")" == -rw-------* ]]
grep -Fxq private-doctor-output "${UPGRADE_BACKUP}/mtg-candidate-doctor-ipv4.log"
grep -Fxq private-doctor-error "${UPGRADE_BACKUP}/mtg-candidate-doctor-ipv4.log"
result=0
bash -c '
  source "$1"
  UPGRADE_BACKUP="${PROXY_TEST_DIR}/doctor-logs"
  private_mtg_candidate() { printf "private-doctor-failure\n"; return 1; }
  verify_mtg_candidate private_mtg_candidate "${MTG_CONFIG}" ipv6
' _ "${TEST_REPO}/upgrade-proxy-stack.sh" \
  >"${PROXY_TEST_DIR}/doctor-failed.stdout" 2>"${PROXY_TEST_DIR}/doctor-failed.stderr" || result=$?
[[ "${result}" != 0 && ! -s "${PROXY_TEST_DIR}/doctor-failed.stdout" ]]
if grep -Fq private-doctor-failure "${PROXY_TEST_DIR}/doctor-failed.stderr"; then
  printf 'MTG doctor failure details leaked to stderr\n' >&2
  exit 1
fi
grep -Fq root-only "${PROXY_TEST_DIR}/doctor-failed.stderr"
grep -Fxq private-doctor-failure "${UPGRADE_BACKUP}/mtg-candidate-doctor-ipv6.log"
printf 'PASS MTG candidate doctor output remains in private logs\n'

ln -s "${PROXY_TEST_DIR}/missing-target" "${PROXY_TEST_DIR}/dangling-marker"
result=0
bash -c '
  source "$1"
  mktemp() { printf "%s\n" "${PROXY_TEST_DIR}/symlink-backup"; }
  install() { command mkdir -p "${PROXY_TEST_DIR}/symlink-backup/files"; }
  UPGRADE_FILES=("${PROXY_TEST_DIR}/dangling-marker")
  backup_upgrade
' _ "${TEST_REPO}/upgrade-proxy-stack.sh" \
  >"${PROXY_TEST_DIR}/symlink.stdout" 2>"${PROXY_TEST_DIR}/symlink.stderr" || result=$?
[[ "${result}" != 0 ]]
grep -q 'Unexpected update target:' "${PROXY_TEST_DIR}/symlink.stderr"
printf 'PASS backup rejects dangling-symlink update targets\n'

WORK_DIR="${PROXY_TEST_DIR}/build"
mkdir -p "${WORK_DIR}"
write_atomic() { printf 'unexpected live marker write\n' >&2; return 1; }
git() { :; }
nproc() { printf '1\n'; }
uname() { printf 'x86_64\n'; }
make() {
  mkdir -p "${WORK_DIR}/MTProxy/objs/bin"
  printf 'mtproxy candidate\n' >"${WORK_DIR}/MTProxy/objs/bin/mtproto-proxy"
}
curl() { :; }
sha256sum() { :; }
tar() {
  mkdir -p "${WORK_DIR}/tproxy-server-${TPROXY_SERVER_COMMIT}" "${WORK_DIR}/xray-release" \
    "${WORK_DIR}/mtg-release/mtg-${MTG_VERSION}-linux-amd64"
  printf 'module example.test\n' >"${WORK_DIR}/tproxy-server-${TPROXY_SERVER_COMMIT}/go.mod"
  printf 'xray candidate\n' >"${WORK_DIR}/xray-release/xray"
  chmod 0755 "${WORK_DIR}/xray-release/xray"
  printf 'mtg candidate\n' >"${WORK_DIR}/mtg-release/mtg-${MTG_VERSION}-linux-amd64/mtg"
  chmod 0755 "${WORK_DIR}/mtg-release/mtg-${MTG_VERSION}-linux-amd64/mtg"
}
unzip() { :; }
install() {
  local -a install_args=("$@")
  local destination="${install_args[${#install_args[@]}-1]}"
  local source_file="${install_args[${#install_args[@]}-2]}"
  [[ "${destination}" == "${PROXY_TEST_DIR}/"* ]] || return 1
  if [[ "$1" == -d ]]; then
    command mkdir -p "${destination}"
    return
  fi
  command cp "${source_file}" "${destination}"
}
fake_go() {
  [[ "${GOCACHE:-}" == "${WORK_DIR}/go-build" && "${GOPATH:-}" == "${WORK_DIR}/go" ]] || return 1
  if [[ "$1" == test ]]; then
    printf 'tests\n' >>"${PROXY_TEST_DIR}/go.calls"
  elif [[ "$1" == build ]]; then
    while (($#)); do
      if [[ "$1" == -o ]]; then
        printf 'web proxy candidate\n' >"$2"
        break
      fi
      shift
    done
  else
    return 1
  fi
}
select_go_toolchain() { GO_BIN=fake_go; }

install_official_mtproxy "${WORK_DIR}/mtproxy.candidate"
install_tproxy_server "${WORK_DIR}/webproxy.candidate"
install_xray "${WORK_DIR}/xray.candidate"
install_mtg "${WORK_DIR}/mtg.candidate"
[[ -s "${WORK_DIR}/mtproxy.candidate" && -s "${WORK_DIR}/webproxy.candidate" && \
   -s "${WORK_DIR}/xray.candidate" && -s "${WORK_DIR}/mtg.candidate" ]]
[[ "$(<"${PROXY_TEST_DIR}/go.calls")" == tests ]]
printf 'PASS staging builds candidates with explicit Go caches and without live marker writes\n'

# The rollback operates only on these fixture files; systemctl/rm are mocked.
UPGRADE_BACKUP="${PROXY_TEST_DIR}/backup"
UPGRADE_FILES=("${PROXY_TEST_DIR}/live" "${PROXY_TEST_DIR}/mtg-live" \
  "${STATE_DIR}/tproxy-server.go-version" "${STATE_DIR}/mtg.version" "${STATE_DIR}/mtg.archive.sha256")
OPTIONAL_UPGRADE_MARKERS=("${STATE_DIR}/tproxy-server.go-version" "${STATE_DIR}/mtg.version" "${STATE_DIR}/mtg.archive.sha256")
UPGRADE_UNITS=(mtproxy.service xray.service tproxy-server.service mtproxy-ipv6.service teleproxy.service teleproxy-ipv6.service)
mkdir -p "${UPGRADE_BACKUP}/files${PROXY_TEST_DIR}"
printf 'old binary\n' >"${UPGRADE_BACKUP}/files${PROXY_TEST_DIR}/live"
printf 'new binary\n' >"${PROXY_TEST_DIR}/live"
printf 'old mtg binary\n' >"${UPGRADE_BACKUP}/files${PROXY_TEST_DIR}/mtg-live"
printf 'new mtg binary\n' >"${PROXY_TEST_DIR}/mtg-live"
systemctl() { (IFS=' '; printf '%s\n' "$*" >>"${PROXY_TEST_DIR}/systemctl.calls"); }
rm() {
  [[ $# == 3 && "$1" == -f && "$2" == -- ]] || return 1
  is_optional_upgrade_marker "$3" || return 1
  printf '%s\n' "$3" >>"${PROXY_TEST_DIR}/removed-marker"
}
REFRESH_TIMER_WAS_ACTIVE=1
restore_upgrade
[[ "$(<"${PROXY_TEST_DIR}/live")" == 'old binary' && -f "${PROXY_TEST_DIR}/removed-marker" ]]
[[ "$(<"${PROXY_TEST_DIR}/mtg-live")" == 'old mtg binary' ]]
grep -Fxq "${STATE_DIR}/tproxy-server.go-version" "${PROXY_TEST_DIR}/removed-marker"
grep -Fxq "${STATE_DIR}/mtg.version" "${PROXY_TEST_DIR}/removed-marker"
grep -Fxq "${STATE_DIR}/mtg.archive.sha256" "${PROXY_TEST_DIR}/removed-marker"
grep -q 'stop .*mtproxy-ipv6.service' "${PROXY_TEST_DIR}/systemctl.calls"
grep -q 'start .*mtproxy-ipv6.service' "${PROXY_TEST_DIR}/systemctl.calls"
grep -q 'stop .*teleproxy-ipv6.service' "${PROXY_TEST_DIR}/systemctl.calls"
grep -q 'start .*teleproxy-ipv6.service' "${PROXY_TEST_DIR}/systemctl.calls"
printf 'PASS rollback restores MTG/binaries, absent markers and both IPv6 units\n'

run_exit_case() {
  local active=$1 success=$2 result=$3 expected=$4
  command rm -f "${PROXY_TEST_DIR}/exit.rollback"
  local actual=0
  bash -c '
    source "$1"
    cleanup() { :; }
    restore_upgrade() { printf "rollback\n" >"${PROXY_TEST_DIR}/exit.rollback"; }
    UPGRADE_ACTIVATED=$2
    UPGRADE_SUCCESS=$3
    trap upgrade_exit EXIT
    die "intentional test failure"
  ' _ "${TEST_REPO}/upgrade-proxy-stack.sh" "${active}" "${success}" 2>/dev/null || actual=$?
  [[ "${actual}" == "${result}" ]]
  if [[ "${expected}" == yes ]]; then
    [[ -f "${PROXY_TEST_DIR}/exit.rollback" ]]
  else
    [[ ! -e "${PROXY_TEST_DIR}/exit.rollback" ]]
  fi
}
run_exit_case 0 0 1 no
run_exit_case 1 0 1 yes
run_exit_case 1 1 1 no
printf 'PASS EXIT handles direct die before activation, after activation and after success\n'
printf 'All upgrade regression tests passed.\n'
