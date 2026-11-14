#!/usr/bin/env bash
# Surge VLESS 订阅分版与 Snell 版本判定
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() { echo "not ok - $*" >&2; exit 1; }
pass() { echo "ok - $*"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected [$1] == [$2]: $3"; }
assert_has() { [[ "$1" == *"$2"* ]] || fail "missing [$2]: $3"; }
assert_not() { [[ "$1" != *"$2"* ]] || fail "unexpected [$2]: $3"; }

export SONGBOX_SOURCE_ONLY=1
export SONGBOX_CFG_DIR="$TEST_ROOT/etc/vless-reality"
mkdir -p "$SONGBOX_CFG_DIR"

# shellcheck source=../songbox.sh
source "$ROOT_DIR/songbox.sh"

# 离线桩：固定地址/国家，证书视为自签
_log() { :; }
get_ipv4() { echo "203.0.113.10"; }
get_ipv6() { echo ""; }
get_ip_country() { echo "JP"; }
_cert_real_for() { return 1; }
_instance_addr() { echo "$2"; }
_node_label() { echo "JP-${1}${3:+-$3}"; }

REALITY='{"port":443,"sni":"www.example.com","public_key":"PUBKEY","short_id":"abcd","users":[{"name":"u1","secret":"11111111-1111-1111-1111-111111111111"}]}'
VISION='{"port":8443,"sni":"v.example.com","users":[{"name":"u1","secret":"22222222-2222-2222-2222-222222222222"}]}'
WS='{"port":2083,"sni":"w.example.com","path":"/ws","users":[{"name":"u1","secret":"33333333-3333-3333-3333-333333333333"}]}'
SNELL6='{"port":7177,"psk":"abcdefghijklmnop1234","version":"6","mode":"unshaped","tfo":false}'

db_all_protocols() { printf '%s\n' vless-reality vless-vision vless-ws snell-v6; }
db_instances() {
    case "$2" in
        vless-reality) echo "$REALITY" ;;
        vless-vision)  echo "$VISION" ;;
        vless-ws)      echo "$WS" ;;
        snell-v6)      echo "$SNELL6" ;;
    esac
}

line=$(_surge_vless_line vless-reality "$REALITY" "203.0.113.10" "R" "11111111-1111-1111-1111-111111111111")
assert_eq "$line" "R = vless, 203.0.113.10, 443, username=11111111-1111-1111-1111-111111111111, flow=xtls-rprx-vision, sni=www.example.com, reality-public-key=PUBKEY, reality-short-id=abcd" "REALITY line"
line=$(_surge_vless_line vless-vision "$VISION" "203.0.113.10" "V" "x")
assert_has "$line" "tls=true" "Vision uses TLS"
assert_has "$line" "flow=xtls-rprx-vision" "Vision flow"
assert_has "$line" "skip-cert-verify=true" "self-signed Vision skips verification"
line=$(_surge_vless_line vless-ws "$WS" "203.0.113.10" "W" "x")
assert_has "$line" "ws=true, ws-path=/ws, ws-headers=Host:w.example.com" "WS transport"
assert_not "$line" "flow=" "WS has no Vision flow"
pass "Surge VLESS lines follow the Surge manual parameters"

compat=$(gen_surge_sub)
full=$(gen_surge_vless_sub)
assert_not "$compat" "= vless," "compat profile excludes VLESS"
assert_has "$compat" "= snell," "compat profile keeps Snell"
assert_has "$compat" "mode=unshaped" "Snell v6 mode carried into Surge"
assert_has "$compat" "tfo=false" "explicit TFO off preserved"
assert_has "$full" "JP-vless-reality-u1 = vless," "VLESS profile includes REALITY"
assert_has "$full" "JP-vless-ws-u1 = vless," "VLESS profile includes WS"
assert_has "$full" "= snell," "VLESS profile keeps Snell"
group=$(grep '^Proxy = select' <<<"$full")
assert_has "$group" "JP-vless-vision-u1" "VLESS nodes join the proxy group"
group=$(grep '^Proxy = select' <<<"$compat")
assert_not "$group" "vless" "compat proxy group has no VLESS names"
pass "Surge subscription splits into compat and VLESS profiles"

_snell_needs_upgrade "6.0.0rc2" "6.0.0" || fail "rc2 should upgrade to 6.0.0"
_snell_needs_upgrade "6.0.0b4" "6.0.0rc2" || fail "b4 should upgrade to rc2"
_snell_needs_upgrade "6.0.0" "6.0.0" && fail "same version must not upgrade"
_snell_needs_upgrade "6.0.1" "6.0.0" && fail "newer local must not downgrade"
_snell_needs_upgrade "未安装" "6.0.0" && fail "missing binary is not an upgrade"
_snell_is_prerelease "6.0.0rc2" || fail "rc2 is prerelease"
_snell_is_prerelease "6.0.0" && fail "6.0.0 is a release"
pass "Snell version helpers order beta < rc < release"

echo "all Surge VLESS / Snell v6 tests passed"
