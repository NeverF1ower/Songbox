#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() { echo "not ok - $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

export SONGBOX_SOURCE_ONLY=1
export SONGBOX_CFG_DIR="$TEST_ROOT/etc/vless-reality"
export SONGBOX_SYSTEM_SCRIPT="$TEST_ROOT/usr/local/bin/songbox.sh"
export SONGBOX_LEGACY_SYSTEM_SCRIPT="$TEST_ROOT/usr/local/bin/vless-server.sh"
mkdir -p "$(dirname "$SONGBOX_SYSTEM_SCRIPT")" "$SONGBOX_CFG_DIR"

# shellcheck source=../songbox.sh
source "$ROOT_DIR/songbox.sh"

[[ "$SCRIPT_NAME" == "songbox" ]] || fail "SCRIPT_NAME is not songbox"
[[ "$VERSION" == "0.1.4" ]] || fail "unexpected release version: $VERSION"
[[ "$SYSTEM_SCRIPT" == */songbox.sh ]] || fail "canonical path is not songbox.sh"
[[ "$LEGACY_SYSTEM_SCRIPT" == */vless-server.sh ]] || fail "legacy path was removed"
pass "canonical and legacy script identities are present"

urls=$(_script_source_urls)
[[ "$(printf '%s\n' "$urls" | sed -n '1p')" == *NeverF1ower/songbox/main/songbox.sh ]] ||
    fail "new repository is not the primary update source"
printf '%s\n' "$urls" | grep -q 'NeverF1ower/SingsongBox/main/songbox.sh' ||
    fail "legacy repository fallback is missing"
pass "new and legacy update sources are both available"

# Simulate the first run after an old updater overwrites vless-server.sh.
printf '#!/usr/bin/env bash\n' >"$SYSTEM_SCRIPT"
printf '# old installed script\n' >"$LEGACY_SYSTEM_SCRIPT"
LINK_LOG="$TEST_ROOT/links.log"
ln() { printf '%s\n' "$*" >>"$LINK_LOG"; }
_install_script_links "$SYSTEM_SCRIPT" || fail "compatibility link installation failed"
[[ -f "${LEGACY_SYSTEM_SCRIPT}.pre-songbox.bak" ]] || fail "old installed script was not backed up"
grep -Fq -- "-sfn $SYSTEM_SCRIPT $LEGACY_SYSTEM_SCRIPT" "$LINK_LOG" || fail "legacy path link is missing"
grep -Fq -- "-sfn $SYSTEM_SCRIPT /usr/local/bin/vless" "$LINK_LOG" || fail "vless shortcut link is missing"
pass "old installed path migrates without changing the vless shortcut"

if grep -nE 'read[[:space:]]+-rp.*(API Token|Global API Key|Ali Key|Ali Secret|密码|PSK|UUID|分享链接|订阅链接)' \
        "$ROOT_DIR/songbox.sh"; then
    fail "a sensitive prompt still uses visible terminal input"
fi
pass "sensitive prompts do not use visible read input"

for page in status.html docs.html portfolio.html; do
    [[ -s "$ROOT_DIR/assets/decoy-sites/$page" ]] || fail "missing decoy page: $page"
done
pass "repository-owned decoy pages are present"

echo "all naming and compatibility tests passed"
