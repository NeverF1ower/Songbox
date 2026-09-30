#!/usr/bin/env bash
# 重启持久化回归：sysctl 真实加载顺序、启动后覆盖检测、模块持久化、启动后复核服务。
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail() { echo "not ok - $*" >&2; exit 1; }
pass() { echo "ok - $*"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected [$2], got [$1]"; }
assert_contains() { grep -qF -- "$2" <<<"$1" || fail "$3: missing [$2] in: $1"; }
assert_missing() { ! grep -qF -- "$2" <<<"$1" || fail "$3: unexpected [$2] in: $1"; }
write_file() { mkdir -p "${1%/*}"; printf '%s\n' "${@:2}" >"$1"; }
reset_conf() { rm -rf "${T:?}/etc" "${T:?}/run" "${T:?}/lib" "${T:?}/sysctl.conf"; mkdir -p "$T/etc" "$T/run" "$T/lib"; }

export SONGBOX_SOURCE_ONLY=1
export SONGBOX_CFG_DIR="$T/config"
export SONGBOX_TEST_SYSCTL_CONF="$T/etc/99-zz-vless-tuning.conf"
export SONGBOX_TEST_SYSCTL_LEGACY="$T/legacy.conf"
export SONGBOX_TEST_BBR_MODULE_CONF="$T/modules-load/99-vless-bbr.conf"
export SONGBOX_TEST_SYSCTL_DIRS="$T/etc $T/run $T/lib"
export SONGBOX_TEST_SYSCTL_MAIN="$T/sysctl.conf"
export SONGBOX_TEST_GUARD_UNIT="$T/systemd/songbox-sysctl.service"
export SONGBOX_TEST_GUARD_OPENRC="$T/init.d/songbox-sysctl"
export SONGBOX_TEST_SYSTEMD_RUN="$T/run-systemd"
export SONGBOX_TUNING_PROC_ROOT="$T/proc"
mkdir -p "$T/systemd" "$T/init.d" "$T/run-systemd" "$SONGBOX_TUNING_PROC_ROOT/self"
# shellcheck source=../songbox.sh
source "$ROOT_DIR/songbox.sh"
_log() { :; }
_ask_yes() { return 0; }
_ensure_sysctl_boot_load() { return 0; }
_reload_system_sysctl() { return 0; }

declare -A ACTUAL=()
declare -A MODINFO=()
SYSCTL_ENABLED_RC=0
SYSTEMCTL_CALLS=()
RC_CALLS=()
AVAILABLE="reno cubic bbr"
sysctl() {
    local key line value
    case "$1" in
        -n)
            key="$2"
            if [[ -n "${ACTUAL[$key]+x}" ]]; then echo "${ACTUAL[$key]}"; return 0; fi
            case "$key" in
                net.ipv4.tcp_available_congestion_control) echo "$AVAILABLE" ;;
                net.netfilter.nf_conntrack_count) echo 0 ;;
                fs.file-max) echo 9223372036854775807 ;;
                *) echo 0 ;;
            esac ;;
        -p)
            while IFS= read -r line; do
                [[ "$line" == *" = "* && "$line" != \#* ]] || continue
                key=${line%% = *}; value=${line#* = }
                ACTUAL[$key]="$value"
            done <"$2" ;;
        *) fail "unexpected sysctl call: $*" ;;
    esac
}
modinfo() { [[ "$1" == -F && -n "${MODINFO[$3]+x}" ]] || return 1; echo "${MODINFO[$3]}"; }
modprobe() { return 1; }
getconf() { echo 4096; }
systemctl() {
    SYSTEMCTL_CALLS+=("$*")
    [[ "$1" == is-enabled ]] && return "$SYSCTL_ENABLED_RC"
    return 0
}
rc-update() {
    RC_CALLS+=("$*")
    [[ "$1" == show ]] && echo " songbox-sysctl | boot"
    return 0
}
rc-service() { return 0; }
# shellcheck disable=SC2034  # 由被 source 的 _build_recommended_sysctl 读取
detect_vps_capabilities() {
    VPS_MEM_MB=1024; VPS_MEM_KB=$(( 1024 * 1024 )); VPS_HOST_MEM_MB=1024
    VPS_CPU_THREADS=1; VPS_CPU_CORES=1; VPS_LINK_MBPS=0; VPS_PAGE_SIZE=4096
    VPS_HAS_IPV4=true; VPS_HAS_IPV6="${TEST_V6:-false}"
    VPS_IPV6_IFACES="${TEST_V6_IFACES:-}"; VPS_IPV6_DEFAULT_IF=""
}
DISTRO=debian

# ── 1. 与 systemd-sysctl/procps 一致的加载顺序 ────────────────────────────────
reset_conf
write_file "$T/lib/50-b.conf" "net.x = lib"
write_file "$T/etc/50-b.conf" "net.x = etc"
write_file "$T/lib/10-a.conf" "net.a = 1"
write_file "$T/etc/99-kejilion-optimize.conf" "net.core.default_qdisc = fq"
write_file "$T/etc/99-zz-vless-tuning.conf" "net.ipv4.tcp_congestion_control = bbr"
write_file "$T/run/99-zzz-cloud.conf" "net.ipv4.tcp_congestion_control = cubic"
write_file "$T/lib/99-zzzz-vendor.conf" "net.core.default_qdisc = pfifo_fast"
write_file "$T/sysctl.conf" "# 空"
expected=$(printf '%s\n' "$T/lib/10-a.conf" "$T/etc/50-b.conf" "$T/etc/99-kejilion-optimize.conf" \
    "$T/etc/99-zz-vless-tuning.conf" "$T/run/99-zzz-cloud.conf" "$T/lib/99-zzzz-vendor.conf" "$T/sysctl.conf")
assert_eq "$(_sysctl_config_files)" "$expected" "全目录按文件名排序、同名取高优先级目录、sysctl.conf 最后"
pass "sysctl 配置文件顺序与系统一致（跨 /etc /run /usr/lib，sysctl.conf 最后）"

# ── 2. 解析：注释、"-" 前缀、斜杠写法、无空格赋值 ─────────────────────────────
reset_conf
write_file "$T/etc/60-variants.conf" \
    "# 注释" "; 另一种注释" "" \
    "-net.core.default_qdisc = fq_codel" \
    "net/ipv4/tcp_congestion_control=cubic" \
    "net.ipv4.tcp_rmem =   4096   131072   67108864  " \
    "  net.core.somaxconn = 1024" \
    "not a setting line"
write_file "$T/etc/99-zz-vless-tuning.conf" "net.core.default_qdisc = fq"
scan=$(_sysctl_scan_all)
assert_contains "$scan" $'60-variants.conf\tnet.core.default_qdisc\tfq_codel' "行首 - 前缀被识别"
assert_contains "$scan" $'60-variants.conf\tnet.ipv4.tcp_congestion_control\tcubic' "斜杠写法被规范化"
assert_contains "$scan" $'60-variants.conf\tnet.ipv4.tcp_rmem\t4096 131072 67108864' "多余空白被折叠"
assert_contains "$scan" $'60-variants.conf\tnet.core.somaxconn\t1024' "行首缩进被容忍"
assert_missing "$scan" "注释" "注释行被忽略"
assert_missing "$scan" "not a setting" "非赋值行被忽略"
assert_contains "$(_sysctl_sources net.core.default_qdisc)" "60-variants.conf" "带 - 前缀的声明能被发现"
assert_missing "$(_sysctl_sources net.core.default_qdisc)" "99-zz-vless-tuning.conf" "不把本脚本自己算作其它来源"
assert_contains "$(_sysctl_sources net/ipv4/tcp_congestion_control)" "60-variants.conf" "查询键的斜杠写法同样有效"
pass "解析覆盖注释、- 前缀、斜杠写法与空白，且排除本脚本文件"

# ── 3. 启动后覆盖检测：重启时会被谁改回什么 ───────────────────────────────────
reset_conf
write_file "$T/etc/99-kejilion-optimize.conf" "net.ipv4.tcp_congestion_control = cubic"   # 排在前面，不会覆盖
write_file "$T/etc/99-zz-vless-tuning.conf" \
    "net.core.default_qdisc = fq" "net.ipv4.tcp_congestion_control = bbr" "net.core.rmem_max = 67108864" \
    "net.core.somaxconn = 15280"
write_file "$T/run/99-zzz-cloud.conf" "net.ipv4.tcp_congestion_control = cubic" "net.core.somaxconn = 15280"
write_file "$T/lib/99-zzzz-vendor.conf" "-net.core.default_qdisc = pfifo_fast"
write_file "$T/sysctl.conf" "net/core/rmem_max = 16777216"
conflicts=$(_sysctl_boot_conflicts)
assert_contains "$conflicts" $'net.ipv4.tcp_congestion_control\tbbr\tcubic\t'"$T/run/99-zzz-cloud.conf" "/run 里排在后面的 cubic 被发现"
assert_contains "$conflicts" $'net.core.default_qdisc\tfq\tpfifo_fast\t'"$T/lib/99-zzzz-vendor.conf" "/usr/lib 里带 - 前缀的 pfifo_fast 被发现"
assert_contains "$conflicts" $'net.core.rmem_max\t67108864\t16777216\t'"$T/sysctl.conf" "/etc/sysctl.conf 最后应用并覆盖缓冲上限"
assert_missing "$conflicts" "somaxconn" "后加载但值相同的不算冲突"
write_file "$T/sysctl.conf" "net/core/rmem_max = 16777216" "net.ipv4.tcp_congestion_control = bbr"
assert_missing "$(_sysctl_boot_conflicts)" "tcp_congestion_control" "最终值又改回 bbr 时不算冲突"
rm -f "$T/etc/99-zz-vless-tuning.conf"
assert_eq "$(_sysctl_boot_conflicts)" "" "本脚本文件不存在时没有冲突"
pass "启动后覆盖检测按系统顺序判定最终值"

# ── 4. 内核模块持久化：内置的不写，可加载的写入 ───────────────────────────────
MODINFO=([tcp_bbr]="(builtin)" [nf_conntrack]="/lib/modules/6.1/kernel/net/netfilter/nf_conntrack.ko.xz")
_persist_tuning_modules tcp_bbr nf_conntrack 'bad name;rm'
assert_eq "${TUNING_MODULES[*]}" "nf_conntrack" "内置 BBR 不写、非法名被丢弃"
assert_contains "$(cat "$BBR_MODULE_CONF")" "nf_conntrack" "modules-load 写入 nf_conntrack"
assert_missing "$(cat "$BBR_MODULE_CONF")" "tcp_bbr" "内置模块不写入"
MODINFO=([tcp_bbr]="/lib/modules/6.1/kernel/net/ipv4/tcp_bbr.ko")
_persist_tuning_modules tcp_bbr nf_conntrack
assert_eq "${TUNING_MODULES[*]}" "tcp_bbr" "BBR 是可加载模块时写入，即使这次无需 modprobe"
MODINFO=()
printf 'nf_conntrack 200000 3 - Live 0x0\n' >"$SONGBOX_TUNING_PROC_ROOT/modules"
_persist_tuning_modules tcp_bbr nf_conntrack
assert_eq "${TUNING_MODULES[*]}" "nf_conntrack" "无 modinfo 时退回已加载模块列表"
: >"$SONGBOX_TUNING_PROC_ROOT/modules"
_persist_tuning_modules tcp_bbr nf_conntrack
[[ ! -e "$BBR_MODULE_CONF" ]] || fail "没有可持久化的模块时应清除旧文件"
pass "模块持久化区分内置/可加载，并拒绝非法模块名"

# ── 5. 启动后复核服务：systemd ───────────────────────────────────────────────
DISTRO=debian
SYSTEMCTL_CALLS=()
_install_boot_guard tcp_bbr nf_conntrack || fail "systemd 复核服务安装失败"
unit=$(cat "$BOOT_GUARD_UNIT")
assert_contains "$unit" "After=systemd-modules-load.service systemd-sysctl.service" "在系统 sysctl 之后"
assert_contains "$unit" "Before=network-pre.target" "在网络配置之前（default_qdisc 只影响之后创建的队列）"
assert_contains "$unit" "ExecStartPre=-/sbin/modprobe -a -q tcp_bbr nf_conntrack" "先加载模块，失败不阻断（回退到绝对路径）"
assert_contains "$unit" "ExecStart=-/sbin/sysctl -e -p ${SYSCTL_CONF}" "重放本脚本文件，忽略缺失项"
assert_contains "$unit" "ConditionPathExists=${SYSCTL_CONF}" "配置文件被删除后自动跳过"
assert_contains "${SYSTEMCTL_CALLS[*]}" "enable --now ${BOOT_GUARD_NAME}.service" "立即启用并运行一次以暴露单元错误"
SYSCTL_ENABLED_RC=0; assert_eq "$(_boot_guard_state)" enabled "已启用状态"
SYSCTL_ENABLED_RC=1; assert_eq "$(_boot_guard_state)" installed "已安装未启用状态"
SYSCTL_ENABLED_RC=0
_install_boot_guard >/dev/null 2>&1 || fail "无模块时安装失败"
assert_missing "$(cat "$BOOT_GUARD_UNIT")" "ExecStartPre" "无模块时不写 modprobe"
rmdir "$T/run-systemd"
if _install_boot_guard tcp_bbr >/dev/null 2>&1; then fail "没有 systemd 时应返回失败"; fi
mkdir "$T/run-systemd"
pass "systemd 复核服务的顺序、模块预加载、条件与启用行为"

# ── 6. 启动后复核服务：OpenRC ────────────────────────────────────────────────
DISTRO=alpine
RC_CALLS=()
_install_boot_guard tcp_bbr || fail "OpenRC 复核服务安装失败"
init=$(cat "$BOOT_GUARD_OPENRC")
assert_contains "$init" "after sysctl modules" "在 sysctl 与 modules 之后"
assert_contains "$init" "before net" "在网络之前"
assert_contains "$init" "for m in tcp_bbr; do /sbin/modprobe -q" "预加载模块"
assert_contains "$init" "/sbin/sysctl -e -p \"${SYSCTL_CONF}\"" "重放本脚本文件"
[[ -x "$BOOT_GUARD_OPENRC" ]] || fail "init 脚本应可执行"
assert_contains "${RC_CALLS[*]}" "add ${BOOT_GUARD_NAME} boot" "加入 boot 运行级"
assert_eq "$(_boot_guard_state)" enabled "OpenRC 状态"
_remove_boot_guard
[[ ! -e "$BOOT_GUARD_OPENRC" ]] || fail "移除后不应残留 init 脚本"
assert_eq "$(_boot_guard_state)" none "移除后状态"
DISTRO=debian
pass "OpenRC 复核服务的顺序、模块预加载与移除"

# ── 7. 写入后统一持久化 + 覆盖报告 ───────────────────────────────────────────
reset_conf
MODINFO=([tcp_bbr]="/lib/modules/x/tcp_bbr.ko" [nf_conntrack]="/lib/modules/x/nf_conntrack.ko")
# shellcheck disable=SC2034  # 由被 source 的 _finalize_tuning_persistence 读取
BBR_ALGORITHM=bbr
write_file "$T/etc/99-zz-vless-tuning.conf" \
    "net.ipv4.tcp_congestion_control = bbr" "net.netfilter.nf_conntrack_max = 61120"
write_file "$T/run/99-zzz-cloud.conf" "net.ipv4.tcp_congestion_control = cubic"
_finalize_tuning_persistence 2>/dev/null
assert_contains "$(cat "$BBR_MODULE_CONF")" "tcp_bbr" "BBR 模块被持久化"
assert_contains "$(cat "$BBR_MODULE_CONF")" "nf_conntrack" "conntrack 键存在时持久化 nf_conntrack（否则重启后该键写入失败）"
assert_contains "$(cat "$BOOT_GUARD_UNIT")" "modprobe -a -q tcp_bbr nf_conntrack" "复核服务预加载同一批模块"
report=$(_report_boot_conflicts 2>&1)
assert_contains "$report" "net.ipv4.tcp_congestion_control" "报告点名被覆盖的 BBR 项"
assert_contains "$report" "${BOOT_GUARD_NAME} 在开机时重放" "已启用复核服务时说明会被覆盖回来"
SYSCTL_ENABLED_RC=1
report=$(_report_boot_conflicts 2>&1)
assert_contains "$report" "重启后会被排在本脚本之后的配置改回" "无兜底时明确警告"
SYSCTL_ENABLED_RC=0
write_file "$T/etc/99-zz-vless-tuning.conf" "net.core.rmem_max = 67108864"
# shellcheck disable=SC2034  # 由被 source 的 _finalize_tuning_persistence 读取
BBR_ALGORITHM=bbr
_finalize_tuning_persistence 2>/dev/null
assert_missing "$(cat "$BBR_MODULE_CONF" 2>/dev/null)" "tcp_bbr" "文件里没有 BBR 项时不持久化 BBR 模块"
pass "写入后统一持久化模块与复核服务，并如实报告覆盖风险"

# ── 8. missing-only：BBR 关键项被声明为别的值时必须接管 ───────────────────────
reset_conf
ACTUAL=()
mkdir -p "$T/proc/sys/net/core"
touch "$T/proc/sys/net/core/netdev_budget" "$T/proc/sys/net/core/netdev_budget_usecs"
MODINFO=([tcp_bbr]="(builtin)")
write_file "$T/etc/99-kejilion-optimize.conf" "net.core.default_qdisc = fq" "net.core.rmem_max = 16777216"
write_file "$T/run/99-zzz-cloud.conf" "net.ipv4.tcp_congestion_control = cubic"
apply_tuning_missing_only >/dev/null 2>&1
ours=$(cat "$SYSCTL_CONF")
assert_contains "$ours" "net.ipv4.tcp_congestion_control = bbr" "别的文件把 cc 设为 cubic 时由本脚本接管"
assert_missing "$ours" "net.core.default_qdisc" "qdisc 已是 fq 则跳过，不重复写"
assert_missing "$ours" "net.core.rmem_max" "非关键项被声明过仍保持'补齐'语义"
write_file "$T/run/99-zzz-cloud.conf" "net.ipv4.tcp_congestion_control = bbr"
rm -f "$SYSCTL_CONF"
apply_tuning_missing_only >/dev/null 2>&1
assert_missing "$(cat "$SYSCTL_CONF")" "net.ipv4.tcp_congestion_control" "其它文件最终值已是 bbr 时不接管"
pass "missing-only 只在关键项与推荐值冲突时接管"

# ── 9. 参数修正：只上调 netdev budget；不强行改写被设为 0 的 accept_ra ────────
reset_conf
ACTUAL=()
ACTUAL[net.core.netdev_budget_usecs]=8000
ACTUAL[net.core.netdev_budget]=600
_build_recommended_sysctl
assert_eq "${REC_SYSCTL[net.core.netdev_budget_usecs]}" 8000 "单核不把 8000 降到 2000"
assert_eq "${REC_SYSCTL[net.core.netdev_budget]}" 600 "已有更大的 budget 不下调"
ACTUAL[net.core.netdev_budget_usecs]=0
ACTUAL[net.core.netdev_budget]=0
_build_recommended_sysctl
assert_eq "${REC_SYSCTL[net.core.netdev_budget_usecs]}" 2000 "读不到现值时仍用公式"
TEST_V6=true; TEST_V6_IFACES="eth0 eth1 eth2"
for i in eth0 eth1 eth2; do mkdir -p "$T/proc/sys/net/ipv6/conf/$i"; done
echo 0 >"$T/proc/sys/net/ipv6/conf/eth0/accept_ra"
echo 1 >"$T/proc/sys/net/ipv6/conf/eth1/accept_ra"
echo 2 >"$T/proc/sys/net/ipv6/conf/eth2/accept_ra"
_build_recommended_sysctl
[[ -z "${REC_SYSCTL[net.ipv6.conf.eth0.accept_ra]+x}" ]] || fail "管理员显式关闭 RA 的网卡不应被改回接受"
assert_eq "${REC_SYSCTL[net.ipv6.conf.eth1.accept_ra]}" 2 "仍在使用 RA 的网卡补成 2"
assert_eq "${REC_SYSCTL[net.ipv6.conf.eth2.accept_ra]}" 2 "已是 2 的网卡保持"
TEST_V6=false
pass "netdev budget 只上调；accept_ra 不覆盖显式关闭的网卡"

# ── 10. 移除：配置、模块文件与复核服务一并清理 ────────────────────────────────
reset_conf
write_file "$T/etc/99-zz-vless-tuning.conf" "net.core.rmem_max = 67108864"
mkdir -p "${BBR_MODULE_CONF%/*}"; echo tcp_bbr >"$BBR_MODULE_CONF"
# shellcheck disable=SC2034  # DISTRO 由被 source 的服务函数读取
DISTRO=debian; SYSCTL_ENABLED_RC=0
_install_boot_guard tcp_bbr >/dev/null 2>&1
remove_tuning >/dev/null 2>&1
[[ ! -e "$SYSCTL_CONF" && ! -e "$BBR_MODULE_CONF" && ! -e "$BOOT_GUARD_UNIT" ]] || fail "移除后不应残留配置、模块文件或服务单元"
pass "移除网络调优会同时清理模块文件与复核服务"

echo 'all sysctl persistence tests passed'
