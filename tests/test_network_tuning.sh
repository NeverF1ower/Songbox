#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
fail() { echo "not ok - $*" >&2; exit 1; }
pass() { echo "ok - $*"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected $2, got $1"; }

export SONGBOX_SOURCE_ONLY=1
export SONGBOX_CFG_DIR="$TEST_ROOT/config"
export SONGBOX_TEST_SYSCTL_CONF="$TEST_ROOT/sysctl.d/99-zz-vless-tuning.conf"
export SONGBOX_TEST_SYSCTL_LEGACY="$TEST_ROOT/legacy.conf"
export SONGBOX_TEST_BBR_MODULE_CONF="$TEST_ROOT/modules.conf"
export SONGBOX_TUNING_PROC_ROOT="$TEST_ROOT/proc"
export SONGBOX_TUNING_BOOT_ROOT="$TEST_ROOT/boot"
export SONGBOX_TUNING_MODULES_ROOT="$TEST_ROOT/modules"
mkdir -p "$TEST_ROOT/sysctl.d" "$SONGBOX_TUNING_PROC_ROOT/self"
# shellcheck source=../songbox.sh
source "$ROOT_DIR/songbox.sh"
_log() { :; }

declare -A ACTUAL=()
AVAILABLE="reno cubic bbr"
EXISTING_BUFFER=0
CT_COUNT=0
FS_MAX=9223372036854775807
APPLY_FAIL_KEY=""
BACKUP_FAIL=false
BACKUP_CALLED=false
sysctl() {
    local key value line failed=0
    case "$1" in
        -n)
            key="$2"
            if [[ -n "${ACTUAL[$key]+x}" ]]; then echo "${ACTUAL[$key]}"; return 0; fi
            case "$key" in
                net.ipv4.tcp_available_congestion_control) echo "$AVAILABLE" ;;
                net.netfilter.nf_conntrack_count) echo "$CT_COUNT" ;;
                fs.file-max) echo "$FS_MAX" ;;
                net.core.rmem_max|net.core.wmem_max) echo "$EXISTING_BUFFER" ;;
                net.ipv4.tcp_rmem|net.ipv4.tcp_wmem) echo "4096 65536 $EXISTING_BUFFER" ;;
                *) echo "${ACTUAL[$key]:-0}" ;;
            esac ;;
        -p)
            : >"$TEST_ROOT/apply-order"
            while IFS= read -r line; do
                [[ "$line" == *" = "* && "$line" != \#* ]] || continue
                key=${line%% = *}; value=${line#* = }
                echo "$key" >>"$TEST_ROOT/apply-order"
                if [[ "$key" == "$APPLY_FAIL_KEY" ]]; then failed=1
                else ACTUAL[$key]="$value"
                fi
            done <"$2"
            return "$failed" ;;
        *) fail "unexpected sysctl mutation: $*" ;;
    esac
}
modinfo() { return 1; }
modprobe() { return 1; }
getconf() {
    case "$1" in
        PAGESIZE) echo "${TEST_PAGE_SIZE:-4096}" ;;
        *) echo 16 ;;
    esac
}
tar() { BACKUP_CALLED=true; [[ "$BACKUP_FAIL" == false ]]; }
_ask_yes() { return 0; }
_sysctl_sources() { [[ "${TEST_EXISTING_SOURCE:-false}" == true ]] && echo "$TEST_ROOT/vendor.conf"; }

for key in net/core/netdev_budget net/core/netdev_budget_usecs net/ipv4/tcp_notsent_lowat \
    net/ipv4/tcp_syncookies net/ipv4/tcp_fastopen net/netfilter/nf_conntrack_max \
    net/netfilter/nf_conntrack_udp_timeout net/netfilter/nf_conntrack_udp_timeout_stream; do
    mkdir -p "$SONGBOX_TUNING_PROC_ROOT/sys/${key%/*}"
    touch "$SONGBOX_TUNING_PROC_ROOT/sys/$key"
done

# CONFIG_HZ 下限：HZ=250 的 8000us 不应被单核策略压到非法的 2000us。
mkdir -p "$SONGBOX_TUNING_BOOT_ROOT"
kernel_config="$SONGBOX_TUNING_BOOT_ROOT/config-$(uname -r)"
ACTUAL[net.core.netdev_budget_usecs]=8000
for spec in '100 20000' '250 8000' '300 6666' '1000 2000'; do
    read -r hz expected <<<"$spec"
    printf 'CONFIG_HZ=%s\n' "$hz" >"$kernel_config"
    _recommend_netdev_budget_usecs 2000
    assert_eq "$RECO_NETDEV_USECS" "$expected" "CONFIG_HZ=$hz polling floor"
done
_recommend_netdev_budget_usecs 8000
assert_eq "$RECO_NETDEV_USECS" 8000 "CPU target above HZ floor retained"
printf 'CONFIG_HZ=250\n' | gzip >"$SONGBOX_TUNING_PROC_ROOT/config.gz"
_recommend_netdev_budget_usecs 2000
assert_eq "$RECO_NETDEV_USECS" 8000 "proc config.gz takes precedence"
rm -f "$SONGBOX_TUNING_PROC_ROOT/config.gz" "$kernel_config"
_recommend_netdev_budget_usecs 2000
assert_eq "$RECO_NETDEV_USECS" 8000 "unknown HZ preserves valid current value"
printf 'CONFIG_HZ=0\n' >"$kernel_config"
_recommend_netdev_budget_usecs 2000
assert_eq "$RECO_NETDEV_USECS" 8000 "invalid HZ uses current budget"
rm -f "$kernel_config"
unset 'ACTUAL[net.core.netdev_budget_usecs]'
_recommend_netdev_budget_usecs 2000
assert_eq "$RECO_NETDEV_USECS" 20000 "unreadable budget uses conservative fallback"
pass "NAPI recommendations respect CONFIG_HZ and preserve valid values when HZ is unknown"

# 检查实际资源探测函数，包括父级约束，而非只给参数生成器灌入内存数字。
CG="$TEST_ROOT/cgroup2"
mkdir -p "$CG/parent/child"
printf 'MemTotal: 8388608 kB\nSwapTotal: 8388608 kB\n' >"$SONGBOX_TUNING_PROC_ROOT/meminfo"
printf '0::/parent/child\n' >"$SONGBOX_TUNING_PROC_ROOT/self/cgroup"
printf '1 0 0:1 / %s rw - cgroup2 cgroup rw\n' "$CG" >"$SONGBOX_TUNING_PROC_ROOT/self/mountinfo"
echo 1073741824 >"$CG/parent/child/memory.max"
echo 268435456 >"$CG/parent/memory.high"
echo max >"$CG/memory.max"
echo '800000 100000' >"$CG/parent/child/cpu.max"
echo '200000 100000' >"$CG/parent/cpu.max"
echo 0-15 >"$CG/parent/child/cpuset.cpus.effective"
VPS_CPU_THREADS=16
_detect_tuning_resources
assert_eq "$VPS_MEM_MB" 256 "v2 parent memory.high"
assert_eq "$VPS_CPU_THREADS" 2 "v2 parent CPU quota"
assert_eq "$VPS_SWAP_MB" 8192 "Swap reported separately"
assert_eq "$VPS_RESOURCE_LIMITED" true "resource limit visible"
echo '50000 100000' >"$CG/parent/cpu.max"
VPS_CPU_THREADS=16
_detect_tuning_resources
assert_eq "$VPS_CPU_THREADS" 1 "fractional CPU quota"
echo 'max 100000' >"$CG/parent/cpu.max"
echo '1,3-4' >"$CG/parent/child/cpuset.cpus.effective"
VPS_CPU_THREADS=16
_detect_tuning_resources
assert_eq "$VPS_CPU_THREADS" 3 "cpuset range/list counting"
pass "cgroup v2 parent memory, quota, cpuset and Swap handling"

# v1 的 mount root 与进程 cgroup 路径不同；unlimited 哨兵不算真实可用内存。
CG1="$TEST_ROOT/cgroup1"
mkdir -p "$CG1/memory/child" "$CG1/cpu/child" "$CG1/cpuset/child"
printf '2:memory:/tenant/child\n3:cpu,cpuacct:/tenant/child\n4:cpuset:/tenant/child\n' >"$SONGBOX_TUNING_PROC_ROOT/self/cgroup"
{
    printf '2 0 0:2 /tenant %s/memory rw - cgroup cgroup rw,memory\n' "$CG1"
    printf '3 0 0:3 /tenant %s/cpu rw - cgroup cgroup rw,cpu,cpuacct\n' "$CG1"
    printf '4 0 0:4 /tenant %s/cpuset rw - cgroup cgroup rw,cpuset\n' "$CG1"
} >"$SONGBOX_TUNING_PROC_ROOT/self/mountinfo"
echo 9223372036854771712 >"$CG1/memory/child/memory.limit_in_bytes"
echo 134217728 >"$CG1/memory/memory.limit_in_bytes"
echo -1 >"$CG1/cpu/child/cpu.cfs_quota_us"
echo 100000 >"$CG1/cpu/child/cpu.cfs_period_us"
echo 0-1 >"$CG1/cpuset/cpuset.cpus"
VPS_CPU_THREADS=16
TEST_PAGE_SIZE=65536
_detect_tuning_resources
assert_eq "$VPS_MEM_MB" 128 "v1 mount root translation and sentinel"
assert_eq "$VPS_CPU_THREADS" 2 "v1 inherited cpuset"
assert_eq "$VPS_PAGE_SIZE" 65536 "non-4KiB pages"
pass "cgroup v1 mount roots, unlimited sentinels and 64KiB pages"

# cgroup namespace 路径不可见时仍读取可见挂载根的限制。
printf '0::/../../unavailable\n' >"$SONGBOX_TUNING_PROC_ROOT/self/cgroup"
printf '1 0 0:1 / %s rw - cgroup2 cgroup rw\n' "$CG" >"$SONGBOX_TUNING_PROC_ROOT/self/mountinfo"
echo 67108864 >"$CG/memory.max"
VPS_CPU_THREADS=16
_detect_tuning_resources
assert_eq "$VPS_MEM_MB" 64 "namespace root fallback"
: >"$SONGBOX_TUNING_PROC_ROOT/self/cgroup"
: >"$SONGBOX_TUNING_PROC_ROOT/meminfo"
_detect_tuning_resources
assert_eq "$VPS_MEM_KNOWN" false "unknown memory detected"
assert_eq "$VPS_MEM_MB" 64 "unknown memory uses protection"
pass "namespace fallback and unreadable memory fail conservatively"

printf 'MemTotal: 8388608 kB\nSwapTotal: 0 kB\n' >"$SONGBOX_TUNING_PROC_ROOT/meminfo"
printf '0::/\n' >"$SONGBOX_TUNING_PROC_ROOT/self/cgroup"
printf '1 0 0:1 /tenant/container %s rw - cgroup2 cgroup rw\n' "$CG" >"$SONGBOX_TUNING_PROC_ROOT/self/mountinfo"
VPS_CPU_THREADS=16
_detect_tuning_resources
assert_eq "$VPS_MEM_MB" 64 "namespace path relative to non-root mount"
echo 0 >"$CG/memory.high"
_detect_tuning_resources
assert_eq "$VPS_MEM_MB" 1 "zero v2 memory.high protects memory"
pass "namespace-relative mount roots and zero memory.high"

# 真实能力探测：双栈分离出口、veth @peer、VLAN 名称和未知速率。
export SONGBOX_TUNING_SYS_ROOT="$TEST_ROOT/sys"
mkdir -p "$SONGBOX_TUNING_SYS_ROOT/class/net/eth0" "$SONGBOX_TUNING_SYS_ROOT/class/net/eth0.100"
mkdir -p "$SONGBOX_TUNING_PROC_ROOT/sys/net/ipv6/conf/eth0.100"
touch "$SONGBOX_TUNING_PROC_ROOT/sys/net/ipv6/conf/eth0.100/accept_ra"
echo 1000 >"$SONGBOX_TUNING_SYS_ROOT/class/net/eth0/speed"
echo 10000 >"$SONGBOX_TUNING_SYS_ROOT/class/net/eth0.100/speed"
echo 1500 >"$SONGBOX_TUNING_SYS_ROOT/class/net/eth0.100/mtu"
TEST_IPV4=true
ip() {
    case "$*" in
        '-4 -o addr show scope global') [[ "$TEST_IPV4" == true ]] && echo '2: eth0@if4 inet 192.0.2.2/24 scope global eth0' ;;
        '-6 -o addr show scope global')
            echo '3: eth0.100@eth0 inet6 2001:db8::2/64 scope global'
            echo '4: bad0 inet6 2001:db8:1::2/64 scope global tentative' ;;
        '-4 route show default') [[ "$TEST_IPV4" == true ]] && echo 'default via 192.0.2.1 dev eth0' ;;
        '-6 route show default') echo 'default via fe80::1 dev eth0.100' ;;
    esac
}
_build_recommended_sysctl
assert_eq "$VPS_LINK_MBPS" 10000 "fastest dual-stack outlet used"
assert_eq "$VPS_IPV6_IFACES" eth0.100 "peer suffix and tentative address handling"
assert_eq "${REC_SYSCTL[net.ipv6.conf.eth0/100.accept_ra]}" 2 "VLAN interface RA enabled"
assert_eq "$VPS_MTU" 1500 "outlet MTU detected"
TEST_IPV4=false
echo -1 >"$SONGBOX_TUNING_SYS_ROOT/class/net/eth0.100/speed"
# The sourced implementation is available here; the later definition is a test stub.
# shellcheck disable=SC2218
detect_vps_capabilities
assert_eq "$VPS_HAS_IPV4" false "IPv6-only detection"
assert_eq "$VPS_LINK_MBPS" 0 "unknown virtual speed not treated as bandwidth"
unset -f ip
pass "real outlet detection handles dual stack, veth peers, VLAN RA and unknown speeds"

# 参数策略场景；除资源探测外仍执行真实的生成、算法选择、写入、回读逻辑。
# Fixtures below are consumed by sourced songbox functions.
# shellcheck disable=SC2034
detect_vps_capabilities() {
    VPS_MEM_MB="$TEST_MEM"; VPS_MEM_KB=$(( TEST_MEM * 1024 ))
    VPS_HOST_MEM_MB="$TEST_MEM"; VPS_CPU_THREADS="$TEST_CPU"; VPS_CPU_CORES="$TEST_CPU"
    VPS_LINK_MBPS="${TEST_LINK:-0}"; VPS_PAGE_SIZE="${TEST_PAGE_SIZE:-4096}"
    VPS_HAS_IPV4=true; VPS_HAS_IPV6="${TEST_V6:-false}"
    VPS_IPV6_IFACES=""; VPS_IPV6_DEFAULT_IF=""
}
TEST_PAGE_SIZE=4096
for TEST_MEM in 32 64 127 128 256 512 1024 2048 8192 32768; do
    for TEST_CPU in 1 2 16; do
        _build_recommended_sysctl
        buffer=${REC_SYSCTL[net.core.rmem_max]}
        assert_eq "${REC_SYSCTL[net.core.wmem_max]}" "$buffer" "symmetric core ceiling"
        assert_eq "${REC_SYSCTL[net.ipv4.tcp_rmem]##* }" "$buffer" "TCP receive ceiling"
        assert_eq "${REC_SYSCTL[net.ipv4.tcp_wmem]##* }" "$buffer" "TCP send ceiling"
        if (( TEST_MEM >= 128 )); then
            (( buffer >= 33554432 )) || fail "$TEST_MEM MiB/$TEST_CPU CPUs missed 32MiB floor"
            (( buffer <= TEST_MEM * 1048576 / 4 )) || fail "buffer exceeded memory budget"
        else
            (( buffer < 33554432 )) || fail "tiny machine lost protection"
        fi
        conntrack=${REC_SYSCTL[net.netfilter.nf_conntrack_max]}
        (( conntrack * 1024 <= TEST_MEM * 1048576 / 16 )) || fail "NAT budget inflated by CPU"
        assert_eq "${REC_SYSCTL[net.ipv4.tcp_moderate_rcvbuf]}" 1 "autotuning enabled"
        assert_eq "${REC_SYSCTL[net.ipv4.tcp_window_scaling]}" 1 "window scaling enabled"
        assert_eq "${REC_SYSCTL[net.ipv4.tcp_sack]}" 1 "SACK enabled"
        assert_eq "${REC_SYSCTL[fs.file-max]}" "$FS_MAX" "existing file limit not lowered"
    done
done
pass "30 memory/CPU combinations honor the 128MiB boundary and 32MiB floor"

TEST_MEM=955; TEST_CPU=1
printf 'CONFIG_HZ=250\n' >"$kernel_config"
_build_recommended_sysctl
assert_eq "${REC_SYSCTL[net.core.netdev_budget_usecs]}" 8000 "single CPU HZ=250 generates a writable budget"
rm -f "$kernel_config"
ACTUAL[net.core.netdev_budget_usecs]=8000
_build_recommended_sysctl
assert_eq "${REC_SYSCTL[net.core.netdev_budget_usecs]}" 8000 "unknown HZ keeps live 8000us in generated table"
unset 'ACTUAL[net.core.netdev_budget_usecs]'
pass "955MiB single-CPU tuning table accepts live 8000us instead of recommending illegal 2000us"

TEST_MEM=2048; TEST_CPU=1; TEST_LINK=10000
_build_recommended_sysctl
assert_eq "${REC_SYSCTL[net.core.rmem_max]}" 536870912 "10Gbps link headroom"
TEST_MEM=128
_build_recommended_sysctl
assert_eq "${REC_SYSCTL[net.core.rmem_max]}" 33554432 "10Gbps on 128MiB stays bounded"
TEST_LINK=0; TEST_MEM=1024; EXISTING_BUFFER=134217728
_build_recommended_sysctl
assert_eq "${REC_SYSCTL[net.core.rmem_max]}" "$EXISTING_BUFFER" "larger valid current ceiling retained"
EXISTING_BUFFER=0; TEST_PAGE_SIZE=65536; TEST_MEM=128
_build_recommended_sysctl
assert_eq "${REC_SYSCTL[net.ipv4.tcp_mem]}" '256 512 1024' "TCP pages use actual page size"
assert_eq "${REC_SYSCTL[net.ipv4.udp_mem]}" '64 128 256' "UDP pages use actual page size"
CT_COUNT=20000
_build_recommended_sysctl
assert_eq "${REC_SYSCTL[net.netfilter.nf_conntrack_max]}" 26024 "active NAT connections retain growth headroom"
CT_COUNT=0; TEST_PAGE_SIZE=4096
pass "fast/unknown links, existing ceilings, actual page sizes and active NAT connections"

AVAILABLE='reno cubic bbr bbr2 bbr3'
_build_recommended_sysctl
assert_eq "${REC_SYSCTL[net.ipv4.tcp_congestion_control]}" bbr3 "explicit bbr3 selected"
AVAILABLE='reno cubic bbr bbr2'
_build_recommended_sysctl
assert_eq "${REC_SYSCTL[net.ipv4.tcp_congestion_control]}" bbr2 "explicit bbr2 selected"
AVAILABLE='reno cubic bbr'
_build_recommended_sysctl
assert_eq "${REC_SYSCTL[net.ipv4.tcp_congestion_control]}" bbr "standard bbr name retained"
TEST_V6=true
_build_recommended_sysctl
assert_eq "${REC_SYSCTL[net.ipv6.conf.all.accept_ra]}" 2 "IPv6 RA retained under forwarding"
assert_eq "$(_recommended_keys_apply_order | head -1)" net.ipv4.ip_forward "forwarding reset precedes TCP settings"
TEST_V6=false
_build_recommended_sysctl
[[ -z "${REC_SYSCTL[net.ipv6.conf.all.forwarding]+x}" ]] || fail "IPv4-only host got IPv6 forwarding"
pass "BBR algorithm priority and IPv4/dual-stack apply ordering"

_ensure_sysctl_boot_load() { return 0; }
TEST_MEM=512; TEST_CPU=1
echo '# original config' >"$SYSCTL_CONF"
BACKUP_FAIL=true
if apply_tuning_full >/dev/null 2>&1; then fail "failed backup allowed full apply"; fi
assert_eq "$(cat "$SYSCTL_CONF")" '# original config' "failed backup left file untouched"
BACKUP_FAIL=false; AVAILABLE='reno cubic'
apply_tuning_full >/dev/null 2>&1 || fail "BBR unavailable blocked all tuning"
assert_eq "$BACKUP_CALLED" true "full apply backed up configuration"
grep -q '^net.core.rmem_max = 67108864$' "$SYSCTL_CONF" || fail "full apply did not write adaptive ceiling"
! grep -q '^net.ipv4.tcp_congestion_control' "$SYSCTL_CONF" || fail "unsupported BBR was written"
assert_eq "$(head -1 "$TEST_ROOT/apply-order")" net.ipv4.ip_forward "generated file apply order"

_verify_tuning_applied >/dev/null 2>&1 || fail "valid applied configuration did not verify"
ACTUAL[net.ipv4.tcp_moderate_rcvbuf]=0
if _verify_tuning_applied >/dev/null 2>&1; then fail "failed parameter readback was reported as success"; fi
pass "full apply backs up, falls back without BBR, and detects mismatched readback"

TEST_EXISTING_SOURCE=true
rm -f "$SYSCTL_CONF"
apply_tuning_missing_only >/dev/null 2>&1 || fail "missing-only existing source handling failed"
[[ ! -f "$SYSCTL_CONF" ]] || fail "missing-only overwrote existing declared settings"
TEST_EXISTING_SOURCE=false
AVAILABLE='reno cubic bbr'
APPLY_FAIL_KEY=net.ipv4.tcp_moderate_rcvbuf
apply_tuning_missing_only >/dev/null 2>&1 && fail "failed sysctl application passed verification"
pass "missing-only preserves declared settings and surfaces sysctl failure"
echo 'all network tuning tests passed'
