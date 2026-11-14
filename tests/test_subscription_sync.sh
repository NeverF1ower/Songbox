#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() { echo "not ok - $*" >&2; exit 1; }
pass() { echo "ok - $*"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected [$1] == [$2]: $3"; }

export SONGBOX_SOURCE_ONLY=1
export SONGBOX_CFG_DIR="$TEST_ROOT/etc/vless-reality"
mkdir -p "$SONGBOX_CFG_DIR"

# shellcheck source=../songbox.sh
source "$ROOT_DIR/songbox.sh"

# Keep the test independent of network access and of the full protocol renderer.
_log() { :; }
chmod() { return 0; }
gen_uuid() { echo "11111111-2222-3333-4444-555555555555"; }
REVISION=1
gen_v2ray_sub() { printf 'base64-revision-%s\n' "$REVISION"; }
gen_clash_sub() { printf 'clash-revision-%s\n' "$REVISION"; }
gen_surge_sub() { printf 'surge-revision-%s\n' "$REVISION"; }
gen_surge_vless_sub() { printf 'surge-vless-revision-%s\n' "$REVISION"; }

generate_sub_files || fail "generation failed while subscription service was disabled"
[[ ! -e "$SONGBOX_CFG_DIR/sub.info" ]] || fail "file generation unexpectedly enabled the public service"
uuid=$(cat "$SONGBOX_CFG_DIR/sub_uuid")
dir="$SONGBOX_CFG_DIR/subscription/$uuid"
assert_eq "$(cat "$dir/base64")" "base64-revision-1" "initial Base64 subscription"
assert_eq "$(cat "$dir/clash.yaml")" "clash-revision-1" "initial Clash subscription"
assert_eq "$(cat "$dir/surge.conf")" "surge-revision-1" "initial Surge subscription"
assert_eq "$(cat "$dir/surge-vless.conf")" "surge-vless-revision-1" "initial Surge VLESS subscription"
pass "local subscription files are generated without enabling Nginx"

REVISION=2
_refresh_subscription_files
assert_eq "$(cat "$dir/base64")" "base64-revision-2" "refreshed Base64 subscription"
assert_eq "$(cat "$dir/clash.yaml")" "clash-revision-2" "refreshed Clash subscription"
assert_eq "$(cat "$dir/surge.conf")" "surge-revision-2" "refreshed Surge subscription"
assert_eq "$(cat "$dir/surge-vless.conf")" "surge-vless-revision-2" "refreshed Surge VLESS subscription"
[[ ! -e "$SONGBOX_CFG_DIR/sub.info" ]] || fail "refresh unexpectedly enabled the public service"
pass "configuration refresh updates all generated formats while service stays disabled"

gen_clash_sub() { return 1; }
REVISION=broken
if generate_sub_files; then
    fail "generation unexpectedly succeeded with a failed renderer"
fi
assert_eq "$(cat "$dir/base64")" "base64-revision-2" "failed refresh preserves Base64 subscription"
assert_eq "$(cat "$dir/clash.yaml")" "clash-revision-2" "failed refresh preserves Clash subscription"
assert_eq "$(cat "$dir/surge.conf")" "surge-revision-2" "failed refresh preserves Surge subscription"
assert_eq "$(cat "$dir/surge-vless.conf")" "surge-vless-revision-2" "failed refresh preserves Surge VLESS subscription"
pass "failed rendering leaves the previous subscription set intact"

gen_clash_sub() { printf 'clash-revision-%s\n' "$REVISION"; }
db_all_protocols() { echo "vless-reality"; }
REVISION=3
rm -f "$dir/clash.yaml" "$dir/surge-vless.conf"
ensure_subscription_files
assert_eq "$(cat "$dir/base64")" "base64-revision-3" "upgrade self-heal Base64 subscription"
assert_eq "$(cat "$dir/clash.yaml")" "clash-revision-3" "upgrade self-heal Clash subscription"
assert_eq "$(cat "$dir/surge.conf")" "surge-revision-3" "upgrade self-heal Surge subscription"
assert_eq "$(cat "$dir/surge-vless.conf")" "surge-vless-revision-3" "upgrade self-heal Surge VLESS subscription"
pass "an existing installation self-heals missing subscription files"

for fn in do_install uninstall_specific_protocol _add_user check_and_disable_expired \
          manage_users manage_tfo manage_certificates set_node_name \
          manage_handshake_sni update_core_menu do_restore; do
    declare -f "$fn" | grep -q '_refresh_subscription_files' ||
        fail "$fn does not refresh subscription files"
done
if grep -nE '\[\[ -f "\$CFG/sub\.info" \]\].*(generate_sub_files|_refresh_subscription_files)' \
        "$ROOT_DIR/songbox.sh"; then
    fail "subscription refresh is still gated by the public-service state"
fi
pass "protocol and user mutation paths refresh independently of public-service state"

echo "all subscription synchronization tests passed"
