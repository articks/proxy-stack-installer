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
  mkdir -p "${WORK_DIR}/tproxy-server-${TPROXY_SERVER_COMMIT}" "${WORK_DIR}/xray-release"
  printf 'module example.test\n' >"${WORK_DIR}/tproxy-server-${TPROXY_SERVER_COMMIT}/go.mod"
  printf 'xray candidate\n' >"${WORK_DIR}/xray-release/xray"
  chmod 0755 "${WORK_DIR}/xray-release/xray"
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
[[ -s "${WORK_DIR}/mtproxy.candidate" && -s "${WORK_DIR}/webproxy.candidate" && -s "${WORK_DIR}/xray.candidate" ]]
[[ "$(<"${PROXY_TEST_DIR}/go.calls")" == tests ]]
printf 'PASS staging builds candidates without writing live markers\n'

# The rollback operates only on these fixture files; systemctl/rm are mocked.
UPGRADE_BACKUP="${PROXY_TEST_DIR}/backup"
UPGRADE_FILES=("${PROXY_TEST_DIR}/live" "${STATE_DIR}/tproxy-server.go-version")
UPGRADE_UNITS=(mtproxy.service xray.service tproxy-server.service mtproxy-ipv6.service)
mkdir -p "${UPGRADE_BACKUP}/files${PROXY_TEST_DIR}"
printf 'old binary\n' >"${UPGRADE_BACKUP}/files${PROXY_TEST_DIR}/live"
printf 'new binary\n' >"${PROXY_TEST_DIR}/live"
systemctl() { (IFS=' '; printf '%s\n' "$*" >>"${PROXY_TEST_DIR}/systemctl.calls"); }
rm() {
  [[ $# == 3 && "$1" == -f && "$2" == -- && "$3" == "${STATE_DIR}/tproxy-server.go-version" ]] || return 1
  printf 'removed new marker\n' >"${PROXY_TEST_DIR}/removed-marker"
}
REFRESH_TIMER_WAS_ACTIVE=1
restore_upgrade
[[ "$(<"${PROXY_TEST_DIR}/live")" == 'old binary' && -f "${PROXY_TEST_DIR}/removed-marker" ]]
grep -q 'stop .*mtproxy-ipv6.service' "${PROXY_TEST_DIR}/systemctl.calls"
grep -q 'start .*mtproxy-ipv6.service' "${PROXY_TEST_DIR}/systemctl.calls"
printf 'PASS rollback restores binaries, absent marker and IPv6 unit\n'

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
