#!/bin/bash
#
# 本脚本会保存代理凭据与私钥，统一使用私有文件权限
umask 077

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 1) )); then
    echo "错误: 本脚本需要 Bash 4.1 或更高版本（当前: ${BASH_VERSION:-unknown}）" >&2
    exit 1
fi

#═══════════════════════════════════════════════════════════════════════════════
#  songbox v0.1.3 [Sing-box 统一内核]
#
#  架构:
#    • Sing-box 内核: 承载除 Snell 外的全部协议（TCP/TLS/QUIC 统一管理）
#    • Snell 独立进程: 闭源协议，保留独立二进制 + 可选 ShadowTLS 前置
#
#  支持协议:
#    VLESS-REALITY / VLESS-Vision / VLESS-WS(+TLS) / VLESS-WS-CF(无TLS)
#    VMess-WS / Trojan / Trojan-WS / Hysteria2 / TUIC v5 / AnyTLS
#    Shadowsocks 2022 / Shadowsocks(传统) / SOCKS5 / NaïveProxy
#    ShadowTLS+SS2022（Sing-box 原生）
#    Snell v4 / v5 / v6 / Snell+ShadowTLS（独立进程）
#
#  适配: Alpine / Debian / Ubuntu / CentOS
#
#  本地补丁 snell-fix1（未合并回上游，运行「检查脚本更新」会被覆盖）:
#    1. Snell 版本不再硬编码，改为读官方发布说明动态解析，可用
#       SNELL_V4/5/6_VERSION 环境变量强制指定；保底版本仅在取不到列表时使用
#    2. Surge 客户端行补 v6 的 mode=（漏掉会导致 mode 不一致 → 静默超时）
#    3. 订阅里的 tfo 改为读数据库，不再硬编码 tfo=true
#    4. v6 推荐 DNS 按本机是否有 IPv6 出口自适应
#    5. allow_port 识别 INPUT 默认策略 DROP/REJECT，并同步处理 ip6tables
#    6. Snell 多端口实例时明确告警（单配置文件限制，未根治）
#═══════════════════════════════════════════════════════════════════════════════

readonly VERSION="0.1.3"
readonly AUTHOR="NeverF1ower"
readonly SCRIPT_NAME="songbox"
readonly CUSTOM_BUILD="backup-v2+compat-upgrade+realm+subscription-sync+sb-1.14"

#───────────────────────────────────────────────────────────────────────────────
# 脚本更新地址（保留 VLESS_* 环境变量，兼容已安装的旧版本）
#───────────────────────────────────────────────────────────────────────────────
SCRIPT_RAW_URL="${SONGBOX_SCRIPT_RAW_URL:-${VLESS_SCRIPT_RAW_URL:-https://raw.githubusercontent.com/NeverF1ower/songbox/main/songbox.sh}}"
REPO_URL="${SONGBOX_REPO_URL:-${VLESS_REPO_URL:-https://github.com/NeverF1ower/songbox}}"
readonly LEGACY_SCRIPT_RAW_URL="https://raw.githubusercontent.com/NeverF1ower/SingsongBox/main/songbox.sh"
readonly SYSTEM_SCRIPT="${SONGBOX_SYSTEM_SCRIPT:-/usr/local/bin/songbox.sh}"
readonly LEGACY_SYSTEM_SCRIPT="${SONGBOX_LEGACY_SYSTEM_SCRIPT:-/usr/local/bin/vless-server.sh}"

# SONGBOX_CFG_DIR 仅用于隔离测试；正常安装仍沿用旧目录，保证原 VPS 无缝升级。
readonly CFG="${SONGBOX_CFG_DIR:-/etc/vless-reality}"
readonly DB_FILE="$CFG/db.json"
readonly DB_LOCK_FILE="$CFG/.db.lock"
readonly SB_CONFIG="$CFG/singbox.json"
readonly SB_BIN="${SONGBOX_SB_BIN:-/usr/local/bin/sing-box}"
readonly SB_SVC="vless-singbox"
readonly REALM_DIR="$CFG/realm"
readonly REALM_BIN="$REALM_DIR/realm"
readonly REALM_CONF="$REALM_DIR/config.toml"
readonly REALM_VERSION_FILE="$REALM_DIR/version"
readonly REALM_SVC="vless-realm"
readonly REALM_REPO="zhboner/realm"
readonly RULESET_DIR="$CFG/ruleset"
readonly LOG_FILE="/var/log/vless-server.log"
# 不内置任何第三方或私人邮箱；如需默认值可显式设置 VLESS_ACME_EMAIL
readonly ACME_DEFAULT_EMAIL="${VLESS_ACME_EMAIL:-}"
readonly SSL_DIR="$CFG/certs"
readonly SSL_META="$CFG/cert_meta"
readonly DNS_API_CONF="$CFG/dns_api.conf"
readonly SB_MIN_VERSION="1.11"

readonly CURL_TIMEOUT_FAST=5
readonly CURL_TIMEOUT_NORMAL=10
readonly LATENCY_TEST_URL="https://www.gstatic.com/generate_204"
readonly LATENCY_PARALLEL="${LATENCY_PARALLEL:-4}"
readonly SUBSCRIPTION_MAX_BYTES=10485760

# 协议归属
readonly SINGBOX_PROTOCOLS="vless-reality vless-vision vless-ws vless-ws-notls vmess-ws trojan trojan-ws hy2 tuic anytls ss2022 ss-legacy socks naive ss2022-shadowtls"
readonly SNELL_PROTOCOLS="snell snell-v5 snell-v6 snell-shadowtls snell-v5-shadowtls"
# 支持多用户的协议
readonly MULTIUSER_PROTOCOLS="vless-reality vless-vision vless-ws vless-ws-notls vmess-ws trojan trojan-ws hy2 tuic anytls ss2022 ss2022-shadowtls socks naive"

R='\e[31m'; G='\e[32m'; Y='\e[33m'; C='\e[36m'; M='\e[35m'; W='\e[97m'; D='\e[2m'; NC='\e[0m'
set -o pipefail

_CACHED_IPV4=""; _CACHED_IPV6=""

#═══════════════════════════════════════════════════════════════════════════════
# 日志与 UI
#═══════════════════════════════════════════════════════════════════════════════
_log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >>"$LOG_FILE" 2>/dev/null
}

init_log() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
    touch "$LOG_FILE" 2>/dev/null
    chmod 600 "$LOG_FILE" 2>/dev/null || true
    local size
    size=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
    if [[ "$size" -gt 5242880 ]]; then
        local tmp; tmp=$(mktemp "${LOG_FILE}.rot.XXXXXX") || return 0
        tail -n 800 "$LOG_FILE" >"$tmp" 2>/dev/null && chmod 600 "$tmp" && mv "$tmp" "$LOG_FILE" || rm -f "$tmp"
    fi
    _log INFO "===== 脚本启动 v${VERSION} ====="
}

_line()  { echo -e "${D}─────────────────────────────────────────────${NC}" >&2; }
_dline() { echo -e "${C}═════════════════════════════════════════════${NC}" >&2; }
_info()  { echo -e "  ${C}▸${NC} $1" >&2; }
_ok()    { echo -e "  ${G}✓${NC} $1" >&2; _log OK "$1"; }
_err()   { echo -e "  ${R}✗${NC} $1" >&2; _log ERROR "$1"; }
_warn()  { echo -e "  ${Y}!${NC} $1" >&2; _log WARN "$1"; }
_item()  { echo -e "  ${G}$1${NC}) $2" >&2; }
_pause() { echo "" >&2; read -rp "  按回车继续..." _; }

_header() {
    clear; echo "" >&2
    _dline
    echo -e "      ${W}${SCRIPT_NAME}${NC}  ${C}v${VERSION}${NC} ${Y}[Sing-box 内核]${NC}" >&2
    echo -e "      ${D}作者: ${AUTHOR}   快捷命令: vless${NC}" >&2
    [[ -n "$REPO_URL" ]] && echo -e "      ${D}${REPO_URL}${NC}" >&2
    _dline
}

check_root() { [[ $EUID -ne 0 ]] && { _err "请使用 root 权限运行"; exit 1; }; }
check_cmd()  { command -v "$1" &>/dev/null; }

# 端口是否有监听：优先 ss，退回 netstat，最后用 /dev/tcp 实连
# 精简镜像可能没有 iproute2，直接依赖 ss 会误判为"无监听"
_port_listening() {
    local p="$1"
    [[ -z "$p" ]] && return 1
    if command -v ss >/dev/null 2>&1; then
        ss -tuln 2>/dev/null | grep -qE ":${p}[^0-9]" && return 0
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -tuln 2>/dev/null | grep -qE ":${p}[[:space:]]" && return 0
    fi
    # 整个探测放在子 shell 里完成：描述符随子 shell 退出自动关闭。
    # 千万别在父 shell 里 exec 3<&- —— exec 失败会让非交互 shell 直接退出，
    # 把调用方的整个菜单流程静默掐断。
    if (exec 3<>/dev/tcp/127.0.0.1/"$p") >/dev/null 2>&1; then return 0; fi
    return 1
}
check_installed() { [[ -f "$DB_FILE" ]]; }
is_paused()  { [[ -f "$CFG/paused" ]]; }

#═══════════════════════════════════════════════════════════════════════════════
# 系统检测与服务管理
#═══════════════════════════════════════════════════════════════════════════════
if [[ -f /etc/alpine-release ]]; then DISTRO="alpine"
elif [[ -f /etc/redhat-release ]]; then DISTRO="centos"
elif grep -qi ubuntu /etc/os-release 2>/dev/null; then DISTRO="ubuntu"
else DISTRO="debian"; fi

if ! check_cmd yum && check_cmd dnf; then yum() { dnf "$@"; }; fi

declare -A SVC_PROC=(
    [vless-singbox]="sing-box"
    [vless-snell]="snell-server"
    [vless-snell-v5]="snell-server-v5"
    [vless-snell-v6]="snell-server-v6"
    [vless-snell-shadowtls]="shadow-tls"
    [vless-snell-v5-shadowtls]="shadow-tls"
    [vless-realm]="realm"
    [nginx]="nginx"
)

_pgrep() {
    local proc="$1"; [[ -n "$proc" ]] || return 1
    if check_cmd pgrep; then
        if [[ "$DISTRO" == "alpine" ]]; then
            pgrep "$proc" >/dev/null 2>&1 && return 0
            pgrep -f "$proc" >/dev/null 2>&1 && return 0
        else
            pgrep -x "$proc" >/dev/null 2>&1 && return 0
        fi
    fi
    check_cmd pidof && pidof "$proc" >/dev/null 2>&1 && return 0
    local d comm
    for d in /proc/[0-9]*; do
        [[ -r "$d/comm" ]] || continue
        IFS= read -r comm <"$d/comm" 2>/dev/null || continue
        [[ "$comm" == "$proc" ]] && return 0
    done
    return 1
}

svc() {
    local action="$1" name="$2"
    if [[ "$DISTRO" == "alpine" ]]; then
        case "$action" in
            start|restart) rc-service "$name" "$action" ;;
            stop)    rc-service "$name" stop &>/dev/null ;;
            enable)  rc-update add "$name" default &>/dev/null ;;
            disable) rc-update del "$name" default &>/dev/null ;;
            status)
                rc-service "$name" status &>/dev/null && return 0
                [[ -f "/run/${name}.pid" ]] && kill -0 "$(cat "/run/${name}.pid" 2>/dev/null)" 2>/dev/null && return 0
                local p="${SVC_PROC[$name]:-}"; [[ -n "$p" ]] && _pgrep "$p" && return 0
                return 1 ;;
        esac
    else
        case "$action" in
            start|restart)
                systemctl "$action" "$name" || { systemctl status "$name" --no-pager -l 2>/dev/null | tail -20; return 1; } ;;
            stop|enable|disable) systemctl "$action" "$name" &>/dev/null ;;
            status)
                local st; st=$(systemctl is-active "$name" 2>/dev/null)
                [[ "$st" == active || "$st" == activating ]] ;;
        esac
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
# 参数校验
#═══════════════════════════════════════════════════════════════════════════════
_is_valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }

_is_valid_ipv4() {
    local v="$1" o; local -a p
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS='.' read -r -a p <<<"$v"
    for o in "${p[@]}"; do (( 10#$o <= 255 )) || return 1; done
}

_is_valid_ipv6() {
    local v="$1"
    [[ "$v" == *:* && "$v" != *:::* && "$v" =~ ^[0-9a-fA-F:]+$ ]]
}

_is_valid_dns_name() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]
}

_is_valid_host() {
    local v="$1"
    [[ -z "$v" ]] && return 1
    _is_valid_ipv4 "$v" && return 0
    _is_valid_ipv6 "$v" && return 0
    [[ "$v" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]
}

_is_valid_subscription_url() {
    [[ "$1" =~ ^https://[^[:space:]]+$ ]] && return 0
    [[ "${ALLOW_INSECURE_HTTP_SUBSCRIPTIONS:-0}" == "1" && "$1" =~ ^http://[^[:space:]]+$ ]]
}

#═══════════════════════════════════════════════════════════════════════════════
# 网络与生成工具
#═══════════════════════════════════════════════════════════════════════════════
get_ipv4() {
    [[ -n "$_CACHED_IPV4" ]] && { echo "$_CACHED_IPV4"; return; }
    local r
    r=$(curl -4 -sf --connect-timeout 5 https://ip.sb 2>/dev/null || curl -4 -sf --connect-timeout 5 https://ifconfig.me 2>/dev/null)
    [[ -n "$r" ]] && _CACHED_IPV4="$r"
    echo "$r"
}
get_ipv6() {
    [[ -n "$_CACHED_IPV6" ]] && { echo "$_CACHED_IPV6"; return; }
    local r
    r=$(curl -6 -sf --connect-timeout 5 https://ip.sb 2>/dev/null || curl -6 -sf --connect-timeout 5 https://ifconfig.me 2>/dev/null)
    [[ -n "$r" ]] && _CACHED_IPV6="$r"
    echo "$r"
}

get_ip_country() {
    local ip="${1:-}" c
    if [[ -n "$ip" ]]; then
        c=$(curl -sf --connect-timeout 3 "https://ipinfo.io/${ip}/country" 2>/dev/null)
    else
        c=$(curl -sf --connect-timeout 3 "https://ipinfo.io/country" 2>/dev/null)
    fi
    c=$(echo "$c" | tr -d '[:space:]')
    echo "${c:-XX}"
}

_has_ipv6() { [[ -e /proc/net/if_inet6 ]]; }
_can_dual_stack() {
    [[ ! -f /proc/sys/net/ipv6/bindv6only ]] && return 0
    [[ "$(cat /proc/sys/net/ipv6/bindv6only 2>/dev/null || echo 1)" == "0" ]]
}
_listen_addr() { if _has_ipv6 && _can_dual_stack; then echo "::"; else echo "0.0.0.0"; fi; }

_fmt_hostport() {
    if [[ "$1" == *:* ]]; then printf '[%s]:%s' "$1" "$2"; else printf '%s:%s' "$1" "$2"; fi
}

ensure_dual_stack_listen() {
    [[ ! -f /proc/sys/net/ipv6/bindv6only ]] && return 0
    [[ "$(cat /proc/sys/net/ipv6/bindv6only 2>/dev/null)" == "0" ]] && return 0
    _info "配置双栈监听 (net.ipv6.bindv6only=0)..."
    sysctl -w net.ipv6.bindv6only=0 >/dev/null 2>&1
    echo "net.ipv6.bindv6only=0" >/etc/sysctl.d/99-vless-dualstack.conf
    sysctl -p /etc/sysctl.d/99-vless-dualstack.conf >/dev/null 2>&1
}

_has_ipv4_network() {
    if check_cmd ip; then
        ip -4 addr show scope global 2>/dev/null | grep -q 'inet ' &&
            ip -4 route show default 2>/dev/null | grep -q '^default' && return 0
    fi
    # /proc/net/route 的目标 00000000 表示 IPv4 默认路由；不依赖 ping/curl。
    local dest flags
    while read -r _ dest _ flags _; do
        [[ "$dest" == "00000000" && "$flags" =~ ^[0-9A-Fa-f]+$ ]] || continue
        (( (16#$flags & 1) != 0 )) && return 0
    done </proc/net/route 2>/dev/null
    return 1
}

_has_ipv6_network() {
    if check_cmd ip; then
        ip -6 addr show scope global 2>/dev/null | grep -q 'inet6 ' &&
            ip -6 route show default 2>/dev/null | grep -q '^default' && return 0
    fi
    [[ -s /proc/net/if_inet6 ]] && grep -qE '^00000000000000000000000000000000[[:space:]]' \
        /proc/net/ipv6_route 2>/dev/null
}

configure_dns64() {
    _has_ipv4_network && return 0
    if ! _has_ipv6_network; then
        _warn "无法确认当前为纯 IPv6 网络，跳过 DNS64 自动配置"
        return 0
    fi

    # resolv.conf 常由 systemd-resolved、NetworkManager 或容器运行时管理。
    # 覆盖符号链接会破坏系统 DNS，因此只处理普通文件。
    if [[ -L /etc/resolv.conf || ! -f /etc/resolv.conf ]]; then
        _warn "检测到纯 IPv6 网络，但 /etc/resolv.conf 由系统管理，未自动覆盖"
        echo -e "  ${D}请在网络管理器中配置支持 DNS64 的解析器后重试${NC}" >&2
        return 0
    fi

    grep -qE '^nameserver[[:space:]]+(2a00:1098:2b::1|2001:4860:4860::6464)([[:space:]]|$)' \
        /etc/resolv.conf 2>/dev/null && return 0
    _warn "确认当前为纯 IPv6 网络，准备配置 DNS64..."
    [[ ! -e /etc/resolv.conf.songbox.bak ]] && cp -a /etc/resolv.conf /etc/resolv.conf.songbox.bak
    printf 'nameserver 2a00:1098:2b::1\nnameserver 2001:4860:4860::6464\n' >/etc/resolv.conf || {
        _err "DNS64 配置失败，原文件未删除"
        return 1
    }
    _ok "DNS64 已配置（原文件: /etc/resolv.conf.songbox.bak）"
}

sync_time() {
    _info "同步系统时间..."
    local t
    t=$(timeout 5 curl -fsSI --connect-timeout 3 --max-time 5 --proto '=https' https://www.cloudflare.com/ 2>/dev/null |
        awk 'BEGIN{IGNORECASE=1} /^date:/{sub(/^[^:]*:[[:space:]]*/,""); sub(/\r$/,""); print; exit}')
    [[ -n "$t" ]] && date -s "$t" &>/dev/null && { _ok "时间已同步 (HTTPS)"; return 0; }
    check_cmd ntpdate && timeout 5 ntpdate -s pool.ntp.org &>/dev/null && { _ok "时间已同步 (NTP)"; return 0; }
    check_cmd timedatectl && timedatectl set-ntp true &>/dev/null && { _ok "时间已同步 (systemd)"; return 0; }
    _warn "时间同步失败，继续执行"
}

gen_uuid() {
    if [[ -f /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid; return; fi
    check_cmd uuidgen && { uuidgen; return; }
    "$SB_BIN" generate uuid 2>/dev/null && return
    printf '%s-%s-%s-%s-%s\n' "$(openssl rand -hex 4)" "$(openssl rand -hex 2)" \
        "$(openssl rand -hex 2)" "$(openssl rand -hex 2)" "$(openssl rand -hex 6)"
}

gen_password() {
    local len="${1:-16}"
    head -c 48 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c "$len"
}

gen_ss_psk() {  # gen_ss_psk <方法>  -> 生成符合长度的 base64 密钥
    local method="$1" len=16
    [[ "$method" == *"256"* || "$method" == *chacha20* ]] && len=32
    head -c "$len" /dev/urandom | base64 | tr -d '\n'
}

gen_sid() { openssl rand -hex 4; }

ask_password() {
    local length="${1:-16}" prompt="${2:-密码}" pw=""
    while true; do
        read -rsp "  请输入${prompt} (直接回车自动生成): " pw; echo "" >&2
        [[ -z "$pw" ]] && { pw=$(gen_password "$length"); break; }
        [[ "$pw" =~ ^[a-zA-Z0-9._~!@%+=,-]+$ ]] && break
        _err "${prompt}只能包含字母、数字及 . _ ~ ! @ % + = , -"
    done
    echo "$pw"
}

# 敏感值统一关闭终端回显；读取结果只写入指定变量，不写日志、不打印。
_read_secret() {  # _read_secret <变量名> <提示>
    local var_name="$1" prompt="$2" value=""
    IFS= read -rsp "$prompt" value
    echo "" >&2
    printf -v "$var_name" '%s' "$value"
}

#═══════════════════════════════════════════════════════════════════════════════
# 节点命名（国旗 + 节点名 + 协议简称）
#═══════════════════════════════════════════════════════════════════════════════
# 用字面量表而不是 printf '\U'：后者依赖 UTF-8 locale，LANG 未设置时会输出转义串
declare -rA COUNTRY_FLAGS=(
    [SG]="🇸🇬" [HK]="🇭🇰" [JP]="🇯🇵" [KR]="🇰🇷" [TW]="🇹🇼" [CN]="🇨🇳" [US]="🇺🇸" [CA]="🇨🇦"
    [GB]="🇬🇧" [DE]="🇩🇪" [NL]="🇳🇱" [FR]="🇫🇷" [RU]="🇷🇺" [IN]="🇮🇳" [AU]="🇦🇺" [BR]="🇧🇷"
    [TR]="🇹🇷" [IT]="🇮🇹" [ES]="🇪🇸" [SE]="🇸🇪" [CH]="🇨🇭" [PL]="🇵🇱" [FI]="🇫🇮" [NO]="🇳🇴"
    [DK]="🇩🇰" [IE]="🇮🇪" [AT]="🇦🇹" [BE]="🇧🇪" [CZ]="🇨🇿" [HU]="🇭🇺" [RO]="🇷🇴" [UA]="🇺🇦"
    [PT]="🇵🇹" [GR]="🇬🇷" [IL]="🇮🇱" [AE]="🇦🇪" [SA]="🇸🇦" [ZA]="🇿🇦" [EG]="🇪🇬" [NG]="🇳🇬"
    [KE]="🇰🇪" [VN]="🇻🇳" [TH]="🇹🇭" [MY]="🇲🇾" [PH]="🇵🇭" [ID]="🇮🇩" [PK]="🇵🇰" [BD]="🇧🇩"
    [MX]="🇲🇽" [AR]="🇦🇷" [CL]="🇨🇱" [CO]="🇨🇴" [PE]="🇵🇪" [NZ]="🇳🇿" [LU]="🇱🇺" [EE]="🇪🇪"
    [LV]="🇱🇻" [LT]="🇱🇹" [SK]="🇸🇰" [SI]="🇸🇮" [HR]="🇭🇷" [BG]="🇧🇬" [RS]="🇷🇸" [MD]="🇲🇩"
    [IS]="🇮🇸" [MT]="🇲🇹" [CY]="🇨🇾" [LI]="🇱🇮" [MC]="🇲🇨" [AD]="🇦🇩"
)

readonly NODE_NAME_FILE="$CFG/node_name"

_flag_emoji() {
    local cc; cc=$(echo "${1:-}" | tr '[:lower:]' '[:upper:]')
    [[ -n "${COUNTRY_FLAGS[$cc]:-}" ]] && { echo "${COUNTRY_FLAGS[$cc]}"; return 0; }
    echo ""; return 1
}

# 协议在节点名里的简称
declare -rA PROTO_SHORT=(
    [vless-reality]="Reality" [vless-vision]="Vision" [vless-ws]="VLESS-WS"
    [vless-ws-notls]="VLESS-CDN" [vmess-ws]="VMess" [trojan]="Trojan"
    [trojan-ws]="Trojan-WS" [hy2]="Hysteria2" [tuic]="TUIC" [anytls]="AnyTLS"
    [ss2022]="SS2022" [ss-legacy]="SS" [socks]="SOCKS5" [naive]="Naive"
    [ss2022-shadowtls]="SS-STLS" [snell]="Snell" [snell-v5]="Snell5"
    [snell-v6]="Snell6" [snell-shadowtls]="Snell-STLS"
    [snell-v5-shadowtls]="Snell5-STLS"
)
proto_short() { echo "${PROTO_SHORT[$1]:-$1}"; }

# 节点名：未设置时用主机名首段，去掉常见后缀
node_name() {
    if [[ -f "$NODE_NAME_FILE" ]]; then
        local n; n=$(head -1 "$NODE_NAME_FILE" | tr -d '\r')
        [[ -n "$n" ]] && { echo "$n"; return 0; }
    fi
    local h; h=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo node)
    h="${h%%-*}"; h="${h%%.*}"
    h=$(echo "$h" | sed 's/[Vv][Pp][Ss]$//')
    [[ -z "$h" ]] && h="node"
    echo "$h"
}

# YAML / 链接名里不能出现的字符
_sanitize_label() { echo "$1" | tr -d ':#{}[]&*!|>%@`"'"'"'\\' | sed 's/  */ /g;s/^ *//;s/ *$//'; }

# _node_label <协议> <国家码> [用户名]
# 输出形如: 🇸🇬 Legend-Reality  /  🇸🇬 Legend-Reality-bob
_node_label() {
    local proto="$1" cc="${2:-}" user="${3:-}" flag name label
    flag=$(_flag_emoji "$cc") || flag=""
    name=$(node_name)
    # 纯数字的 user 是"无用户列表时用端口回落"的产物；
    # 单实例协议不必带端口后缀，多端口实例才需要区分
    if [[ "$user" =~ ^[0-9]+$ ]]; then
        local ni; ni=$(db_count_instances "$(proto_core "$proto")" "$proto" 2>/dev/null || echo 1)
        [[ "${ni:-1}" -le 1 ]] && user=""
    fi
    label="${name}-$(proto_short "$proto")"
    [[ -n "$user" && "$user" != "default" ]] && label="${label}-${user}"
    [[ -n "$flag" ]] && label="${flag} ${label}"
    [[ -z "$flag" && -n "$cc" && "$cc" != "XX" ]] && label="${cc} ${label}"
    _sanitize_label "$label"
}

readonly COMMON_SNI_LIST=(
    "ads.apple.com" "apps.apple.com" "books.apple.com" "developer.apple.com"
    "guide.apple.com" "iphone.apple.com" "maps.apple.com" "music.apple.com"
    "one.apple.com" "store.apple.com" "support.apple.com" "time.apple.com"
    "tv.apple.com" "www.microsoft.com" "www.lovelive-anime.jp"
)
gen_sni() {
    local idx; idx=$(od -An -tu4 -N4 /dev/urandom 2>/dev/null | tr -d ' '); [[ -z "$idx" ]] && idx=$RANDOM
    echo "${COMMON_SNI_LIST[$((idx % ${#COMMON_SNI_LIST[@]}))]}"
}

gen_ws_path() {
    local ws_path
    ws_path="/$(head -c 24 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 8)"
    [[ -z "$ws_path" || "$ws_path" == "/" ]] && ws_path="/ws$(printf '%04x' $RANDOM)"
    echo "$ws_path"
}

urlencode() {
    local s="$1" i c o=""
    for ((i=0; i<${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in [-_.~a-zA-Z0-9]) o+="$c" ;; *) printf -v c '%%%02x' "'$c"; o+="$c" ;; esac
    done
    echo "$o"
}
urldecode() { printf '%b' "${1//%/\\x}"; }

format_bytes() {
    local b="${1:-0}"
    if   [[ "$b" -ge 1099511627776 ]]; then awk "BEGIN{printf \"%.2f TB\", $b/1099511627776}"
    elif [[ "$b" -ge 1073741824 ]];    then awk "BEGIN{printf \"%.2f GB\", $b/1073741824}"
    elif [[ "$b" -ge 1048576 ]];       then awk "BEGIN{printf \"%.2f MB\", $b/1048576}"
    elif [[ "$b" -ge 1024 ]];          then awk "BEGIN{printf \"%.2f KB\", $b/1024}"
    else echo "${b} B"; fi
}

gen_qr() {
    check_cmd qrencode || { echo "[需安装 qrencode 才能显示二维码]"; return 1; }
    echo "$1" | qrencode -t UTF8 -m 2 2>/dev/null
}

get_ip_suffix() {
    local ip="${1#[}"; ip="${ip%]}"
    if [[ "$ip" == *:* ]]; then echo "v6"; else echo "${ip##*.}"; fi
}

gen_port() {
    local port attempt=0
    while [[ $attempt -lt 100 ]]; do
        port=$(shuf -i 10000-60000 -n 1 2>/dev/null || echo $((RANDOM % 50000 + 10000)))
        if ! ss -tuln 2>/dev/null | grep -qE ":${port}[^0-9]"; then echo "$port"; return 0; fi
        ((attempt++))
    done
    echo "$port"
}

_map_arch() {  # _map_arch "amd64:arm64:armv7"
    local x86 arm64 arm7; IFS=':' read -r x86 arm64 arm7 <<<"$1"
    case "$(uname -m)" in
        x86_64|amd64) echo "$x86" ;;
        aarch64|arm64) echo "$arm64" ;;
        armv7l|armv6l) echo "$arm7" ;;
        *) return 1 ;;
    esac
}

_sha256_file() {
    if check_cmd sha256sum; then sha256sum "$1" | awk '{print $1}'
    elif check_cmd shasum; then shasum -a 256 "$1" | awk '{print $1}'
    else openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'; fi
}

_archive_safe() {  # _archive_safe <file> <zip|tar.gz>
    local f="$1" kind="$2" entries details e type
    case "$kind" in
        zip) entries=$(unzip -Z1 "$f" 2>/dev/null) || return 1 ;;
        tar.gz)
            # tar -tf/-xf 可按文件魔数自动识别 gzip，也兼容旧版未压缩 .tar 备份。
            entries=$(tar -tf "$f" 2>/dev/null) || return 1
            details=$(tar -tvf "$f" 2>/dev/null) || return 1
            while IFS= read -r e; do
                type="${e:0:1}"
                case "$type" in l|h|b|c|p|s) return 1 ;; esac
            done <<<"$details"
            ;;
        *) return 1 ;;
    esac
    while IFS= read -r e; do
        [[ "$e" == *$'\r'* || "$e" == *$'\n'* ]] && return 1
        case "$e" in /*|../*|*/../*|*/..|..|*\\*) return 1 ;; esac
    done <<<"$entries"
}

_tree_safe() {  # 解包后拒绝链接、设备、FIFO、socket 与 setuid/setgid 文件
    local root="$1" bad
    [[ -d "$root" ]] || return 1
    bad=$(find "$root" \( -type l -o -type b -o -type c -o -type p -o -type s -o \
        \( -type f \( -perm -4000 -o -perm -2000 \) \) \) -print -quit 2>/dev/null)
    [[ -z "$bad" ]]
}

#═══════════════════════════════════════════════════════════════════════════════
# 依赖安装
#═══════════════════════════════════════════════════════════════════════════════
check_dependencies() {
    local install_optional="${1:-true}"
    configure_dns64
    local missing=() cmd
    for cmd in curl jq openssl ip ss iptables tar unzip; do check_cmd "$cmd" || missing+=("$cmd"); done
    check_cmd crontab || missing+=("cron")
    if [[ ${#missing[@]} -eq 0 ]]; then
        [[ "$install_optional" == "true" ]] && _install_optional_tools
        return 0
    fi

    _info "安装缺失依赖: ${missing[*]}"
    case "$DISTRO" in
        alpine)
            apk update >/dev/null 2>&1
            apk add --no-cache curl jq openssl coreutils ca-certificates gawk tar unzip \
                iproute2 iptables ip6tables gcompat libc6-compat xz bind-tools >/dev/null 2>&1
            check_cmd crontab || apk add --no-cache cronie >/dev/null 2>&1 || apk add --no-cache dcron >/dev/null 2>&1
            rc-service cronie start >/dev/null 2>&1 || rc-service crond start >/dev/null 2>&1 || true
            rc-update add cronie default >/dev/null 2>&1 || rc-update add crond default >/dev/null 2>&1 || true
            ;;
        centos)
            yum install -y epel-release >/dev/null 2>&1
            yum install -y curl jq openssl ca-certificates cronie tar unzip iproute iptables xz bind-utils >/dev/null 2>&1
            systemctl enable --now crond >/dev/null 2>&1 || true
            ;;
        debian|ubuntu)
            apt-get update -qq >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl jq openssl ca-certificates \
                cron tar unzip iproute2 iptables xz-utils dnsutils >/dev/null 2>&1
            systemctl enable --now cron >/dev/null 2>&1 || true
            ;;
    esac
    for cmd in curl jq openssl ip ss iptables tar unzip; do
        check_cmd "$cmd" || { _err "依赖安装失败: $cmd"; return 1; }
    done
    check_cmd crontab || _warn "计划任务工具未安装，证书续期与过期用户清理将不可用"
    _ok "依赖安装完成"
    [[ "$install_optional" == "true" ]] && _install_optional_tools
    return 0
}

_install_optional_tools() {
    check_cmd qrencode && return 0
    case "$DISTRO" in
        alpine) apk add --no-cache libqrencode-tools >/dev/null 2>&1 || true ;;
        centos) yum install -y qrencode >/dev/null 2>&1 || true ;;
        debian|ubuntu) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qrencode >/dev/null 2>&1 || true ;;
    esac
    check_cmd qrencode || _warn "qrencode 未安装，终端二维码不可用（不影响协议运行）"
    return 0
}
#═══════════════════════════════════════════════════════════════════════════════
#  全局状态数据库 (JSON)
#
#  结构:
#  {
#    "version": "<脚本版本>",
#    "singbox": { "<proto>": [ {port, ..., users:[...]} , ... ] },
#    "snell":   { "<proto>": [ {...} ] },
#    "chain_proxy": { "nodes": [ {...} ] },
#    "balancer_groups": [ {name, strategy, nodes:[]} ],
#    "routing_rules": [ {id, type, outbound, match, ip_version} ],
#    "ip_routing": { "enabled": bool, "rules": [ {inbound_ip, outbound_ip} ] },
#    "routing": { "warp_mode": "wgcf|official|disabled", "direct_ip_version": "as_is" }
#  }
#═══════════════════════════════════════════════════════════════════════════════
DB_LOCK_FD=""; DB_LOCK_DIR_HELD=false

_db_lock_acquire() {
    mkdir -p "$CFG" || return 1
    if check_cmd flock; then
        exec {DB_LOCK_FD}>"$DB_LOCK_FILE" || return 1
        flock -x "$DB_LOCK_FD" || { exec {DB_LOCK_FD}>&-; DB_LOCK_FD=""; return 1; }
        return 0
    fi
    local dir="${DB_LOCK_FILE}.d" owner i
    for ((i=0; i<200; i++)); do
        if mkdir "$dir" 2>/dev/null; then
            printf '%s\n' "$$" >"$dir/pid"; DB_LOCK_DIR_HELD=true; return 0
        fi
        owner=$(cat "$dir/pid" 2>/dev/null || true)
        if [[ "$owner" =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
            rm -f "$dir/pid" 2>/dev/null; rmdir "$dir" 2>/dev/null || true; continue
        fi
        sleep 0.05
    done
    _err "等待数据库锁超时"; return 1
}

_db_lock_release() {
    if [[ -n "$DB_LOCK_FD" ]]; then
        flock -u "$DB_LOCK_FD" 2>/dev/null || true
        exec {DB_LOCK_FD}>&-; DB_LOCK_FD=""
    fi
    if [[ "$DB_LOCK_DIR_HELD" == "true" ]]; then
        rm -f "${DB_LOCK_FILE}.d/pid" 2>/dev/null
        rmdir "${DB_LOCK_FILE}.d" 2>/dev/null || true
        DB_LOCK_DIR_HELD=false
    fi
}

_now_iso() { date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S'; }

init_db() {
    mkdir -p "$CFG" "$RULESET_DIR" || return 1
    chmod 711 "$CFG" 2>/dev/null || true
    _db_lock_acquire || return 1
    if [[ -f "$DB_FILE" ]]; then
        chmod 600 "$DB_FILE" 2>/dev/null || true
        _db_lock_release; return 0
    fi
    local tmp; tmp=$(mktemp "${DB_FILE}.init.XXXXXX") || { _db_lock_release; return 1; }
    if jq -n --arg v "$VERSION" --arg t "$(_now_iso)" \
        '{version:$v,singbox:{},snell:{},chain_proxy:{nodes:[]},balancer_groups:[],
          routing_rules:[],ip_routing:{enabled:false,rules:[]},
          routing:{warp_mode:"disabled",direct_ip_version:"as_is"},
          meta:{created:$t,updated:$t}}' >"$tmp" 2>/dev/null; then
        chmod 600 "$tmp" && mv "$tmp" "$DB_FILE" && { _db_lock_release; return 0; }
    fi
    rm -f "$tmp"; _db_lock_release; return 1
}

_db_apply() {  # _db_apply [jq args...] 'filter'
    [[ -f "$DB_FILE" ]] || init_db || return 1
    _db_lock_acquire || return 1
    local tmp final
    tmp=$(mktemp "${DB_FILE}.a.XXXXXX")   || { _db_lock_release; return 1; }
    final=$(mktemp "${DB_FILE}.f.XXXXXX") || { rm -f "$tmp"; _db_lock_release; return 1; }
    if jq "$@" "$DB_FILE" >"$tmp" 2>/dev/null &&
       jq --arg t "$(_now_iso)" '.meta.updated=$t' "$tmp" >"$final" 2>/dev/null &&
       chmod 600 "$final" && mv "$final" "$DB_FILE"; then
        rm -f "$tmp"; _db_lock_release; return 0
    fi
    rm -f "$tmp" "$final"; _db_lock_release; return 1
}

_db_q() { [[ -f "$DB_FILE" ]] || return 1; jq -r "$@" "$DB_FILE" 2>/dev/null; }

#───────────────────────────────────────────────────────────────────────────────
# 协议注册
#───────────────────────────────────────────────────────────────────────────────
proto_core() {
    local proto_id="$1"
    [[ " $SNELL_PROTOCOLS " == *" $proto_id "* ]] && { echo "snell"; return; }
    echo "singbox"
}

is_multiuser_protocol() { [[ " $MULTIUSER_PROTOCOLS " == *" $1 "* ]]; }

get_protocol_name() {
    case "$1" in
        vless-reality)       echo "VLESS-REALITY" ;;
        vless-vision)        echo "VLESS-Vision" ;;
        vless-ws)            echo "VLESS-WS-TLS" ;;
        vless-ws-notls)      echo "VLESS-WS-CF" ;;
        vmess-ws)            echo "VMess-WS" ;;
        trojan)              echo "Trojan" ;;
        trojan-ws)           echo "Trojan-WS" ;;
        hy2)                 echo "Hysteria2" ;;
        tuic)                echo "TUIC-v5" ;;
        anytls)              echo "AnyTLS" ;;
        ss2022)              echo "SS2022" ;;
        ss-legacy)           echo "Shadowsocks" ;;
        socks)               echo "SOCKS5" ;;
        naive)               echo "NaiveProxy" ;;
        ss2022-shadowtls)    echo "SS2022+ShadowTLS" ;;
        snell)               echo "Snell-v4" ;;
        snell-v5)            echo "Snell-v5" ;;
        snell-v6)            echo "Snell-v6" ;;
        snell-shadowtls)     echo "Snell-v4+ShadowTLS" ;;
        snell-v5-shadowtls)  echo "Snell-v5+ShadowTLS" ;;
        *) echo "$1" ;;
    esac
}

db_exists() { [[ -n "$(_db_q --arg c "$1" --arg p "$2" '.[$c][$p] // empty')" ]]; }
is_protocol_installed() { db_exists "$(proto_core "$1")" "$1"; }

db_list_protocols() { _db_q --arg c "$1" '.[$c] // {} | keys[]'; }
db_all_protocols() { { db_list_protocols singbox; db_list_protocols snell; } | sed '/^$/d' | sort -u; }
get_installed_protocols() { db_all_protocols; }

# 返回协议全部端口实例（每行一个紧凑 JSON）
db_instances() { _db_q -c --arg c "$1" --arg p "$2" '(.[$c][$p] // [])[]'; }
db_list_ports() { _db_q --arg c "$1" --arg p "$2" '(.[$c][$p] // [])[].port'; }
db_count_instances() { _db_q --arg c "$1" --arg p "$2" '(.[$c][$p] // []) | length'; }

# 取第一个实例的字段（用于单实例协议的便捷读取）
db_field() { _db_q --arg c "$1" --arg p "$2" --arg f "$3" '(.[$c][$p] // [])[0][$f] // empty'; }
db_inst_field() {
    _db_q --arg c "$1" --arg p "$2" --arg port "$3" --arg f "$4" \
        '(.[$c][$p] // [])[] | select(.port == ($port|tonumber)) | .[$f] // empty'
}
db_inst() {
    _db_q -c --arg c "$1" --arg p "$2" --arg port "$3" \
        '(.[$c][$p] // [])[] | select(.port == ($port|tonumber))'
}

# db_set_inst_field <core> <proto> <port|all> <field> <value>
db_set_inst_field() {
    local core="$1" proto="$2" port="$3" field="$4" value="$5"
    if [[ "$port" == "all" ]]; then
        _db_apply --arg c "$core" --arg p "$proto" --arg f "$field" --arg v "$value" \
            '.[$c][$p] = ((.[$c][$p] // []) | map(.[$f] = $v))'
    else
        _db_apply --arg c "$core" --arg p "$proto" --arg port "$port" --arg f "$field" --arg v "$value" \
            '.[$c][$p] = ((.[$c][$p] // []) | map(if .port == ($port|tonumber) then .[$f] = $v else . end))'
    fi
}

# build_instance k v k v ...  -> JSON 对象（自动数字识别）
build_instance() {
    local args=() keys=() k v
    while [[ $# -ge 2 ]]; do
        k="$1"; v="$2"; shift 2
        keys+=("$k")
        if [[ "$v" =~ ^[0-9]+$ ]]; then args+=(--argjson "$k" "$v"); else args+=(--arg "$k" "$v"); fi
    done
    local expr="{" first=true
    for k in "${keys[@]}"; do
        [[ "$first" == "true" ]] && first=false || expr+=","
        expr+="\"$k\":\$$k"
    done
    expr+=",\"users\":[]}"
    jq -n "${args[@]}" "$expr"
}

# register_protocol <proto> <json> [replace_port]
register_protocol() {
    local proto="$1" json="$2" replace_port="${3:-}"
    local core; core=$(proto_core "$proto")
    echo "$json" | jq empty 2>/dev/null || { _err "无效的协议配置 JSON"; return 1; }
    if [[ -n "$replace_port" ]]; then
        _db_apply --arg c "$core" --arg p "$proto" --arg port "$replace_port" --argjson cfg "$json" '
            .[$c][$p] = ((.[$c][$p] // []) | map(if .port == ($port|tonumber) then ($cfg + {users: (.users // [])}) else . end))'
    else
        # 同端口已存在时覆盖并顺带清掉历史重复实例，users 沿用第一条
        _db_apply --arg c "$core" --arg p "$proto" --argjson cfg "$json" '
            ($cfg.port) as $np
            | (.[$c][$p] // []) as $old
            | ([$old[] | select(.port == $np)][0].users // []) as $u
            | .[$c][$p] = ([$old[] | select(.port != $np)] + [$cfg + {users: $u}])'
    fi
}

db_remove_port() {
    local core="$1" proto="$2" port="$3"
    _db_apply --arg c "$core" --arg p "$proto" --arg port "$port" '
        .[$c][$p] = ((.[$c][$p] // []) | map(select(.port != ($port|tonumber))))
        | if (.[$c][$p] | length) == 0 then del(.[$c][$p]) else . end'
}

unregister_protocol() {
    local proto="$1" core; core=$(proto_core "$1")
    _db_apply --arg c "$core" --arg p "$proto" 'del(.[$c][$p])'
}

filter_installed() {
    local installed p; installed=$(db_all_protocols) || return 0
    for p in $1; do grep -qx "$p" <<<"$installed" && echo "$p"; done
}
get_singbox_protocols() { filter_installed "$SINGBOX_PROTOCOLS"; }
get_snell_protocols()   { filter_installed "$SNELL_PROTOCOLS"; }

# 端口是否被脚本内其他协议占用（返回协议名）
is_internal_port_occupied() {
    local check="$1" exclude_proto="${2:-}" core proto ports
    for core in singbox snell; do
        for proto in $(db_list_protocols "$core"); do
            [[ "$proto" == "$exclude_proto" ]] && continue
            ports=$(db_list_ports "$core" "$proto")
            if grep -qx "$check" <<<"$ports"; then echo "$proto"; return 0; fi
            # ShadowTLS / Snell 后端端口也需检查
            local bp; bp=$(db_field "$core" "$proto" "backend_port")
            [[ -n "$bp" && "$bp" == "$check" ]] && { echo "${proto}(后端)"; return 0; }
        done
    done
    return 1
}

#───────────────────────────────────────────────────────────────────────────────
# 用户管理（同一协议的用户在其所有端口实例间共享）
#───────────────────────────────────────────────────────────────────────────────
db_list_users() {
    local core="$1" proto="$2"
    _db_q --arg c "$core" --arg p "$proto" \
        '[(.[$c][$p] // [])[].users[]?.name] | unique | .[]'
}
db_count_users() {
    local n; n=$(db_list_users "$1" "$2" | sed '/^$/d' | wc -l | tr -d ' ')
    echo "${n:-0}"
}
db_get_user_field() {
    _db_q --arg c "$1" --arg p "$2" --arg n "$3" --arg f "$4" \
        '[(.[$c][$p] // [])[].users[]? | select(.name == $n)][0][$f] // empty'
}
db_user_exists() { [[ -n "$(db_get_user_field "$1" "$2" "$3" name)" ]]; }

db_users_stats() {  # name|secret|used|quota|enabled|routing|expire
    _db_q --arg c "$1" --arg p "$2" '
        [(.[$c][$p] // [])[].users[]?] | unique_by(.name) | .[] |
        "\(.name)|\(.secret)|\(.used // 0)|\(.quota // 0)|\(.enabled // true)|\(.routing // "")|\(.expire_date // "")"'
}

db_add_user() {  # core proto name secret quotaGB expire_date routing
    local core="$1" proto="$2" name="$3" secret="$4" quota_gb="${5:-0}" expire="${6:-}" routing="${7:-}"
    db_exists "$core" "$proto" || { _err "协议 $proto 不存在"; return 1; }
    is_multiuser_protocol "$proto" || { _err "$(get_protocol_name "$proto") 不支持多用户"; return 1; }
    db_user_exists "$core" "$proto" "$name" && { _err "用户 $name 已存在"; return 1; }
    local quota=0
    [[ "$quota_gb" -gt 0 ]] && quota=$((quota_gb * 1073741824))
    _db_apply --arg c "$core" --arg p "$proto" --arg n "$name" --arg s "$secret" \
        --argjson q "$quota" --arg cr "$(date '+%Y-%m-%d')" --arg e "$expire" --arg r "$routing" '
        .[$c][$p] = ((.[$c][$p] // []) | map(
            .users = ((.users // []) + [{name:$n,secret:$s,quota:$q,used:0,enabled:true,created:$cr,expire_date:$e,routing:$r}])))'
}

db_del_user() {
    _db_apply --arg c "$1" --arg p "$2" --arg n "$3" '
        .[$c][$p] = ((.[$c][$p] // []) | map(.users = ((.users // []) | map(select(.name != $n)))))'
}

db_set_user_field() {  # core proto name field value [json]
    local core="$1" proto="$2" name="$3" field="$4" value="$5" as_json="${6:-}"
    if [[ "$as_json" == "json" ]]; then
        _db_apply --arg c "$core" --arg p "$proto" --arg n "$name" --arg f "$field" --argjson v "$value" '
            .[$c][$p] = ((.[$c][$p] // []) | map(.users = ((.users // []) | map(if .name == $n then .[$f] = $v else . end))))'
    else
        _db_apply --arg c "$core" --arg p "$proto" --arg n "$name" --arg f "$field" --arg v "$value" '
            .[$c][$p] = ((.[$c][$p] // []) | map(.users = ((.users // []) | map(if .name == $n then .[$f] = $v else . end))))'
    fi
}

db_set_user_quota()   { local q=0; [[ "$4" -gt 0 ]] && q=$(( $4 * 1073741824 )); db_set_user_field "$1" "$2" "$3" quota "$q" json; }
db_set_user_enabled() { db_set_user_field "$1" "$2" "$3" enabled "$4" json; }
db_set_user_routing() { db_set_user_field "$1" "$2" "$3" routing "$4"; }
db_set_user_expire()  { db_set_user_field "$1" "$2" "$3" expire_date "$4"; }

db_user_days_left() {
    local e; e=$(db_get_user_field "$1" "$2" "$3" expire_date)
    [[ -z "$e" ]] && { echo ""; return; }
    local today expire
    today=$(date -d "$(date '+%Y-%m-%d')" '+%s' 2>/dev/null || date -j -f '%Y-%m-%d' "$(date '+%Y-%m-%d')" '+%s' 2>/dev/null)
    expire=$(date -d "$e" '+%s' 2>/dev/null || date -j -f '%Y-%m-%d' "$e" '+%s' 2>/dev/null)
    [[ -n "$today" && -n "$expire" ]] && echo $(( (expire - today) / 86400 )) || echo ""
}

db_expired_users() {  # core|proto|name|expire
    local core proto name days enabled
    for core in singbox snell; do
        for proto in $(db_list_protocols "$core"); do
            while IFS= read -r name; do
                [[ -z "$name" ]] && continue
                days=$(db_user_days_left "$core" "$proto" "$name")
                [[ -z "$days" ]] && continue
                if [[ "$days" -lt 0 ]]; then
                    enabled=$(db_get_user_field "$core" "$proto" "$name" enabled)
                    [[ "$enabled" == "true" ]] && echo "${core}|${proto}|${name}|$(db_get_user_field "$core" "$proto" "$name" expire_date)"
                fi
            done < <(db_list_users "$core" "$proto")
        done
    done
}

#───────────────────────────────────────────────────────────────────────────────
# 链式代理节点
#───────────────────────────────────────────────────────────────────────────────
db_chain_nodes()      { _db_q '.chain_proxy.nodes // []'; }
db_chain_node()       { _db_q -c --arg n "$1" '[.chain_proxy.nodes[]? | select(.name == $n)][0] // empty'; }
db_chain_node_names() { _db_q '.chain_proxy.nodes[]?.name'; }
db_chain_exists()     { [[ -n "$(db_chain_node "$1")" ]]; }
db_chain_count()      { _db_q '(.chain_proxy.nodes // []) | length'; }

# 同名节点覆盖而不是追加：重复节点会让 db_chain_node 返回多个对象，
# 进而导致链式出站生成失败、分流规则被整条跳过
db_add_chain_node() {
    echo "$1" | jq empty 2>/dev/null || return 1
    _db_apply --argjson n "$1" '
        ($n.name) as $nm
        | .chain_proxy.nodes = (
            [((.chain_proxy.nodes // [])[] | select(.name != $nm))] + [$n])'
}
db_del_chain_node() {
    _db_apply --arg n "$1" '
        .chain_proxy.nodes = ((.chain_proxy.nodes // []) | map(select(.name != $n)))
        | .routing_rules = ((.routing_rules // []) | map(select(.outbound != ("chain:" + $n))))
        | .balancer_groups = ((.balancer_groups // []) | map(.nodes = ((.nodes // []) | map(select(. != $n)))))'
}
db_rename_chain_node() {
    local old="$1" new="$2"
    db_chain_exists "$old" || return 1
    db_chain_exists "$new" && return 1
    _db_apply --arg o "$old" --arg n "$new" '
        .chain_proxy.nodes = ((.chain_proxy.nodes // []) | map(if .name == $o then .name = $n else . end))
        | .routing_rules = ((.routing_rules // []) | map(if .outbound == ("chain:" + $o) then .outbound = ("chain:" + $n) else . end))
        | .balancer_groups = ((.balancer_groups // []) | map(.nodes = ((.nodes // []) | map(if . == $o then $n else . end))))
        | (.singbox, .snell) |= with_entries(.value |= map(.users = ((.users // []) | map(
              if .routing == ("chain:" + $o) then .routing = ("chain:" + $n) else . end))))'
}
db_set_chain_node_field() {
    _db_apply --arg n "$1" --arg f "$2" --arg v "$3" '
        .chain_proxy.nodes = ((.chain_proxy.nodes // []) | map(if .name == $n then .[$f] = $v else . end))'
}

#───────────────────────────────────────────────────────────────────────────────
# 负载均衡组
#───────────────────────────────────────────────────────────────────────────────
db_balancer_groups() { _db_q '.balancer_groups // []'; }
db_balancer_group()  { _db_q -c --arg n "$1" '.balancer_groups[]? | select(.name == $n)'; }
db_add_balancer_group() {
    local name="$1" strategy="$2"; shift 2
    local nodes_json; nodes_json=$(printf '%s\n' "$@" | jq -R . | jq -s .)
    _db_apply --arg n "$name" --arg s "$strategy" --argjson nodes "$nodes_json" '
        .balancer_groups = ((.balancer_groups // []) | map(select(.name != $n)) + [{name:$n,strategy:$s,nodes:$nodes}])'
}
db_del_balancer_group() {
    _db_apply --arg n "$1" '
        .balancer_groups = ((.balancer_groups // []) | map(select(.name != $n)))
        | .routing_rules = ((.routing_rules // []) | map(select(.outbound != ("balancer:" + $n))))'
}

#───────────────────────────────────────────────────────────────────────────────
# 分流规则
#───────────────────────────────────────────────────────────────────────────────
# 分流预设。match 里的 token 支持:
#   geosite-xxx / geoip-xxx  -> 规则集（自动下载 .srs，失败会剔除并告警）
#   裸域名                    -> domain_suffix
#   IP / CIDR                -> ip_cidr
declare -A ROUTING_PRESETS=(
    #── AI 服务 ────────────────────────────────────────────────────────────────
    [openai]="geosite-openai,openai.com,chatgpt.com,chat.openai.com,ai.com,sora.com,oaistatic.com,oaiusercontent.com"
    [claude]="geosite-anthropic,claude.com,claude.ai,anthropic.com,cdn.usefathom.com"
    #── 流媒体 / 短视频 / Google ───────────────────────────────────────────────
    # Netflix 自有 AS2906/AS40027 网段，用于客户端直接以 IP 发起连接的场景
    [netflix]="geosite-netflix,netflix.com,netflix.net,nflxext.com,nflximg.net,nflxso.net,nflxvideo.net,fast.com,23.246.0.0/18,37.77.184.0/21,45.57.0.0/17,64.120.128.0/17,66.197.128.0/17,108.175.32.0/20,185.2.220.0/22,185.9.188.0/22,192.173.64.0/18,198.38.96.0/19,198.45.48.0/20,207.45.72.0/22,208.75.76.0/22,2a00:86c0::/32,2607:fb10::/32,2620:10c:7000::/44"
    # bamgrid.com / disneystreaming.com 是 Disney 流媒体后端，ESPN+ 亦复用
    [disney]="geosite-disney,disneyplus.com,disney-plus.net,disneystreaming.com,dssott.com,bamgrid.com,starott.com,star-plus.net,cdn.registerdisney.go.com"
    [tiktok]="geosite-tiktok,lf16-effectcdn.byteeffecttos-g.com,lf16-pkgcdn.pitaya-clientai.com,p16-tiktokcdn-com.akamaized.net,trae-api-sg.mchost.guru,bytedapm.com,bytegecko-i18n.com,byteintlapi.com,byteoversea.com,capcut.com,ibytedtos.com,ibyteimg.com,ipstatp.com,isnssdk.com,marscode.com,muscdn.com,musical.ly,sgpstatp.com,snssdk.com,tik-tokapi.com,tiktok.com,tiktokcdn-us.com,tiktokcdn.com,tiktokd.net,tiktokd.org,tiktokmusic.app,tiktokv.com,tiktokv.us,trae.ai,ttwebview.com"
    [google]="geosite-youtube,geosite-google,geosite-google-gemini,geosite-google-deepmind,gemini.google.com,aistudio.google.com,notebooklm.google.com,generativelanguage.googleapis.com,deepmind.google"
    #── 社交 / 开发 ────────────────────────────────────────────────────────────
    [telegram]="geosite-telegram,91.108.4.0/22,91.108.8.0/22,91.108.12.0/22,91.108.16.0/22,91.108.20.0/22,91.108.56.0/22,91.105.192.0/23,95.161.64.0/20,149.154.160.0/20,185.76.151.0/24,2001:67c:4e8::/48,2001:b28:f23c::/48,2001:b28:f23d::/48,2001:b28:f23f::/48,2a0a:f280::/32"
    [github]="geosite-github,geosite-github-copilot,github.com,githubusercontent.com,githubassets.com,githubcopilot.com,github.io,github.dev,ghcr.io,githubapp.com,githubnext.com"
    #── 交易所 / 支付 ──────────────────────────────────────────────────────────
    [exchange]="geosite-binance,geosite-okx,okx.com,okex.com,okexcn.com,oklink.com,coinall.com,binance.com,bnbstatic.com,binancefuture.com,binance.vision,binance.info"
    [bybit]="geosite-bybit,bybit.com,bybit-exchange.com,bybitglobal.com,bycsi.com"
    # 尼日利亚钱包 + 尼日利亚 IP（geoip-ng 会覆盖所有 NG 归属地址）
    [ngwallet]="geoip-ng,gomoney.global,mypaga.com,paga.com,usetimon.com"
    #── 美区 / 英区流媒体 ──────────────────────────────────────────────────────
    [hulu]="geosite-hulu,hulu.com,hulustream.com,huluim.com,prod.hjholdings.tv"
    [espn]="geosite-espn,espn.com,watchespn.com,espncdn.com,espn.go.com,espnplayer.com"
    [paramount]="paramountplus.com,pplusstatic.com,cbs.com,cbsaavideo.com,cbsivideo.com,cbsi.com,cbsnews.com,cbsig.net,cbsi.live.ott.irdeto.com,cbsplaylistserver.aws.syncbak.com,cbsservice.aws.syncbak.com,link.theplatform.com"
    # go.com 同时覆盖 abc.go.com / espn.go.com / disney.go.com
    [abcgo]="geosite-abc,abc.com,abc.go.com,go.com,edgedatg.com,abcotvs.com"
    [prime]="geosite-primevideo,primevideo.com,amazonvideo.com,aiv-cdn.net,aiv-delivery.net,pv-cdn.net,atv-ps.amazon.com,atv-ext.amazon.com,media-amazon.com,fls-na.amazon.com,avodmp4s3ww-a.akamaihd.net"
    [peacock]="peacocktv.com,nbc.com,nbcuni.com,nbcuniversal.com"
    [mgm]="mgmplus.com,epix.com,epixhd.com"
    [discovery]="geosite-discoveryplus,discoveryplus.com,discoveryplus.co.uk,discoveryplus.in,disco-api.com,dnitv.com,discovery.com"
    [bbc]="geosite-bbc,bbc.co.uk,bbci.co.uk,bbc.com,bbcverticals.com,open.live.bbc.co.uk,bbctvapps.co.uk,bbcfmt.hs.llnwd.net"
    #── 地区规则 ───────────────────────────────────────────────────────────────
    # .jp 覆盖 co.jp / ne.jp / or.jp / go.jp 等全部日本域名；如需连同日本 IP，
    # 在本行追加 geoip-jp（注意可能连带命中托管在日本的非日本业务）
    [jp]="geosite-abema,geosite-niconico,geosite-tver,geosite-nhk,geosite-unext,geosite-dmm,geosite-pixiv,geosite-dlsite,geosite-category-bank-jp,.jp,abema.tv,abema.io,dmm.com,dlsite.com,pixiv.net"
    [cn]="geosite-cn,geoip-cn"
    #── 工具 ───────────────────────────────────────────────────────────────────
    [ipcheck]="checkip.amazonaws.com,icanhazip.com,ifconfig.me,ipapi.co,ipinfo.io,ip.sb,whoami.cloudflare,bgp.he.net,ident.me,ipify.org,ippure.com,ifconfig.co,ip-api.com,ipconfig.io"
    #── 特殊：不出现在菜单，仅供 b) 广告屏蔽与旧规则回显使用 ───────────────────
    [ads]="geosite-category-ads-all"
    [stream]="geosite-netflix,geosite-disney"
)
declare -A ROUTING_PRESET_NAMES=(
    [openai]="OpenAI / ChatGPT"
    [claude]="Anthropic / Claude"
    [netflix]="Netflix"
    [disney]="Disney+"
    [tiktok]="TikTok"
    [google]="YouTube + Gemini + Google"
    [telegram]="Telegram"
    [github]="GitHub"
    [exchange]="OKX + Binance (非 EEA/EU)"
    [bybit]="Bybit"
    [ngwallet]="Gomoney + Paga + Timon (尼日利亚)"
    [hulu]="Hulu"
    [espn]="ESPN Plus"
    [paramount]="Paramount Plus"
    [abcgo]="ABC Go"
    [prime]="Amazon Prime Video"
    [peacock]="Peacock"
    [mgm]="MGM Plus"
    [discovery]="Discovery Plus"
    [bbc]="BBC iPlayer UK"
    [jp]="日本网站"
    [cn]="中国大陆(CN)"
    [ipcheck]="IP 检测站点"
    [ads]="广告屏蔽"
    [stream]="Netflix + Disney+ (旧)"
)

# 菜单里的展示顺序（编号即用户输入的序号）
readonly ROUTING_PRESET_ORDER=(openai claude netflix disney tiktok google telegram github exchange bybit ngwallet hulu espn paramount abcgo prime peacock mgm discovery bbc jp cn ipcheck)

# 菜单分组标题：key 出现时先打印一行分组名
declare -A ROUTING_PRESET_GROUP=(
    [openai]="AI 服务"
    [netflix]="流媒体 / 短视频 / Google"
    [telegram]="社交 / 开发"
    [exchange]="交易所 / 支付"
    [hulu]="美区 / 英区流媒体"
    [jp]="地区规则"
    [ipcheck]="工具"
)

db_routing_rules() { _db_q '.routing_rules // []'; }
db_has_routing_rule() {
    local n; n=$(_db_q --arg t "$1" '[.routing_rules[]? | select(.type == $t)] | length')
    [[ "${n:-0}" -gt 0 ]]
}

# db_add_routing_rule <type> <outbound> <match> <ip_version>
# 优先级: direct 出口规则 > custom > 预设 > all
db_add_routing_rule() {
    local rtype="$1" outbound="$2" match="$3" ip_version="${4:-as_is}"
    local id="$rtype"
    [[ "$rtype" == "custom" ]] && id="custom_$(date +%s)_$RANDOM"
    [[ "$rtype" == "all" ]] && id="all_${ip_version}"
    [[ -z "$match" && "$rtype" != "custom" && "$rtype" != "all" ]] && match="${ROUTING_PRESETS[$rtype]:-}"

    _db_apply --arg id "$id" --arg t "$rtype" --arg o "$outbound" --arg m "$match" --arg iv "$ip_version" '
        ({id:$id,type:$t,outbound:$o,match:$m,ip_version:$iv}) as $new |
        .routing_rules = ((.routing_rules // []) | map(select(.id != $id))) |
        .routing_rules = (
            if $t == "all" then
                ([.routing_rules[] | select(.type != "all" or .ip_version != $iv)] + [$new])
            elif $t == "custom" then
                ([.routing_rules[] | select(.outbound == "direct")] +
                 (if $o == "direct" then [$new] else [] end) +
                 [.routing_rules[] | select(.outbound != "direct" and .type == "custom")] +
                 (if $o != "direct" then [$new] else [] end) +
                 [.routing_rules[] | select(.outbound != "direct" and .type != "custom")])
            else
                ([.routing_rules[] | select(.outbound == "direct")] +
                 (if $o == "direct" then [$new] else [] end) +
                 [.routing_rules[] | select(.outbound != "direct" and .type == "custom")] +
                 [.routing_rules[] | select(.outbound != "direct" and .type != "custom" and .type != "all")] +
                 (if $o != "direct" then [$new] else [] end) +
                 [.routing_rules[] | select(.type == "all" and .outbound != "direct")])
            end)'
}

db_del_routing_rule() {
    if [[ "${2:-}" == "by_type" ]]; then
        _db_apply --arg t "$1" '.routing_rules = ((.routing_rules // []) | map(select(.type != $t)))'
    else
        _db_apply --arg id "$1" '.routing_rules = ((.routing_rules // []) | map(select(.id != $id)))'
    fi
}
db_clear_routing_rules() { _db_apply '.routing_rules = []'; }

#───────────────────────────────────────────────────────────────────────────────
# 多IP 入出站
#───────────────────────────────────────────────────────────────────────────────
db_ip_routing_enabled() { [[ "$(_db_q '.ip_routing.enabled // false')" == "true" ]]; }
db_ip_routing_rules()   { _db_q '.ip_routing.rules // []'; }
db_set_ip_routing_enabled() { _db_apply --argjson e "$1" '.ip_routing.enabled = $e'; }
db_add_ip_routing_rule() {
    _db_apply --arg i "$1" --arg o "$2" '
        .ip_routing.rules = (((.ip_routing.rules // []) | map(select(.inbound_ip != $i))) + [{inbound_ip:$i,outbound_ip:$o}])'
}
db_del_ip_routing_rule() {
    _db_apply --arg i "$1" '.ip_routing.rules = ((.ip_routing.rules // []) | map(select(.inbound_ip != $i)))'
}
db_clear_ip_routing_rules() { _db_apply '.ip_routing.rules = []'; }
db_ip_routing_outbound() {
    _db_q --arg i "$1" '(.ip_routing.rules // [])[] | select(.inbound_ip == $i) | .outbound_ip'
}
get_all_public_ipv4() { ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | sort -u; }
get_all_public_ipv6() { ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | cut -d/ -f1 | grep -v '^fe80' | sort -u; }

#───────────────────────────────────────────────────────────────────────────────
# WARP / 直连出口
#───────────────────────────────────────────────────────────────────────────────
db_get_warp_mode() { local m; m=$(_db_q '.routing.warp_mode // "disabled"'); echo "${m:-disabled}"; }
db_set_warp_mode() { _db_apply --arg m "$1" '.routing.warp_mode = $m'; }
db_get_direct_ip_version() { local v; v=$(_db_q '.routing.direct_ip_version // "as_is"'); echo "${v:-as_is}"; }
db_set_direct_ip_version() { _db_apply --arg v "$1" '.routing.direct_ip_version = $v'; }

#───────────────────────────────────────────────────────────────────────────────
# 旧版数据库迁移 (Xray 时代 -> Sing-box 统一)
#───────────────────────────────────────────────────────────────────────────────
db_migrate_legacy() {
    [[ -f "$DB_FILE" ]] || return 0
    local has_xray; has_xray=$(_db_q 'has("xray")')
    [[ "$has_xray" != "true" ]] && return 0

    _warn "检测到旧版 (Xray) 数据库，开始迁移..."
    cp "$DB_FILE" "${DB_FILE}.legacy.bak" 2>/dev/null

    # 旧键名 -> 新键名。未列出的键在迁移时丢弃（Sing-box 无法承载或已废弃）。
    local namemap='{
      "vless":"vless-reality", "vless-reality":"vless-reality",
      "vless-vision":"vless-vision", "vless-ws":"vless-ws", "vless-ws-notls":"vless-ws-notls",
      "vmess-ws":"vmess-ws", "trojan":"trojan", "trojan-ws":"trojan-ws",
      "hy2":"hy2", "hysteria2":"hy2", "tuic":"tuic", "anytls":"anytls",
      "ss2022":"ss2022", "ss-legacy":"ss-legacy", "ss":"ss-legacy",
      "socks":"socks", "socks5":"socks", "naive":"naive", "naiveproxy":"naive",
      "ss2022-shadowtls":"ss2022-shadowtls",
      "snell":"snell", "snell-v5":"snell-v5", "snell-v6":"snell-v6",
      "snell-shadowtls":"snell-shadowtls", "snell-v5-shadowtls":"snell-v5-shadowtls"
    }'
    local snellset='["snell","snell-v5","snell-v6","snell-shadowtls","snell-v5-shadowtls"]'

    local dropped
    dropped=$(_db_q --argjson m "$namemap" \
        '[((.xray // {}) + (.snell // {}) + (.singbox // {})) | keys[] | select($m[.] == null)] | join(", ")')
    [[ -n "$dropped" ]] && _warn "以下协议未迁移（Sing-box 不支持或已废弃）: $dropped"

    _db_apply --argjson m "$namemap" --argjson sn "$snellset" --arg ver "$VERSION" '
      def norm: if type == "array" then . else [.] end;
      def normuser: {
            name: (.name // "default"),
            secret: (.secret // .uuid // .password // .psk // ""),
            quota: (.quota // 0), used: (.used // 0),
            enabled: (if (.enabled == false) then false else true end),
            created: (.created // ""), expire_date: (.expire_date // .expire // ""),
            routing: (.routing // "")
          };
      def normusers: map(.users = ((.users // []) | map(normuser)));
      # ShadowTLS 变体在旧库里可能没有 backend_port，按端口确定性派生一个内部端口
      def fixbackend: map(
            if (has("stls_password") and ((.backend_port // 0) | tonumber? // 0) == 0)
            then .backend_port = (if (.port // 0) > 30000 then (.port - 20000) else (.port + 20000) end)
            else . end);
      ((.xray // {}) + (.snell // {}) + (.singbox // {})) as $old
      | ($old | to_entries
           | map(select($m[.key] != null))
           | map({key: $m[.key], value: (.value | norm | normusers | fixbackend)})
           | group_by(.key)
           | map({key: .[0].key, value: (map(.value) | add)})) as $mapped
      # 注意: 必须先把 .key 绑到 $k，否则 `$sn | index(.key)` 里的 . 已变成 $sn
      | .singbox = ([$mapped[] | select(.key as $k | ($sn | index($k)) == null)] | from_entries)
      | .snell   = ([$mapped[] | select(.key as $k | ($sn | index($k)) != null)] | from_entries)
      | .routing_rules = ((.routing_rules // []) | map({
            id: (.id // .type), type: .type, outbound: .outbound,
            match: (.match // .domains // ""), ip_version: (.ip_version // "as_is")}))
      | .chain_proxy = ((.chain_proxy // {nodes:[]}) | .nodes = (.nodes // []))
      | .balancer_groups = (.balancer_groups // [])
      | .ip_routing = ((.ip_routing // {}) | {enabled: (.enabled // false), rules: (.rules // [])})
      | .routing = ((.routing // {}) + {
            warp_mode: (.routing.warp_mode // "disabled"),
            direct_ip_version: (.routing.direct_ip_version // "as_is")})
      | del(.xray)
      | .version = $ver' || { _err "数据库迁移失败，已保留备份: ${DB_FILE}.legacy.bak"; return 1; }

    local sbn snn
    sbn=$(_db_q '(.singbox | keys | length)'); snn=$(_db_q '(.snell | keys | length)')
    _ok "数据库迁移完成: Sing-box 协议 ${sbn} 个 / Snell 协议 ${snn} 个 (备份: ${DB_FILE}.legacy.bak)"
    local fixed
    fixed=$(_db_q '[(.singbox, .snell) | .[]? | .[]? | select(.stls_password != null) | .port] | join(", ")')
    [[ -n "$fixed" ]] && _warn "ShadowTLS 实例 (端口 ${fixed}) 的内部端口已自动派生，请在「查看协议配置」中确认无冲突"
    _warn "请在主菜单执行一次「管理协议服务 → 重启所有服务」以重建配置"
}
#═══════════════════════════════════════════════════════════════════════════════
# 内核安装（Sing-box / Snell / ShadowTLS / wgcf）
#═══════════════════════════════════════════════════════════════════════════════
_gh_latest_tag() {
    curl -fsSL --connect-timeout 10 --max-time 30 \
        "https://api.github.com/repos/$1/releases/latest" 2>/dev/null | jq -r '.tag_name // empty'
}

_gh_asset_sha256() {  # repo tag asset_name
    local json digest
    json=$(curl -fsSL --connect-timeout 10 --max-time 30 \
        "https://api.github.com/repos/$1/releases/tags/$2" 2>/dev/null) || return 1
    digest=$(printf '%s' "$json" | jq -r --arg n "$3" \
        '[.assets[]? | select(.name == $n) | .digest // empty][0] // empty' 2>/dev/null)
    [[ "$digest" == sha256:* ]] && { echo "${digest#sha256:}"; return 0; }
    # 回退：尝试 checksum 资产
    local curl_url tmp
    curl_url=$(printf '%s' "$json" | jq -r '[.assets[]? | select(.name|test("sha256|checksums?";"i")) | .browser_download_url][0] // empty')
    [[ -z "$curl_url" ]] && return 1
    tmp=$(mktemp) || return 1
    curl -fsSL --connect-timeout 10 --max-time 30 -o "$tmp" "$curl_url" || { rm -f "$tmp"; return 1; }
    awk -v n="$3" 'index($0,n){for(i=1;i<=NF;i++) if($i ~ /^[0-9a-fA-F]{64}$/){print tolower($i); exit}}' "$tmp"
    rm -f "$tmp"
}

_verify_sha256() {  # file expected
    local a e
    [[ "$2" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
    a=$(_sha256_file "$1" | tr 'A-F' 'a-f'); e=$(echo "$2" | tr 'A-F' 'a-f')
    [[ "$a" == "$e" ]]
}

_singbox_binary_version() {  # _singbox_binary_version <binary>
    local binary="$1"
    [[ -x "$binary" ]] || { echo ""; return; }
    "$binary" version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+([-.a-zA-Z0-9]*)?' | head -1
}

_sb_version() { _singbox_binary_version "$SB_BIN"; }

_version_ge() {  # _version_ge a b -> a >= b
    local i raw_a raw_b
    local -a A=() B=()
    raw_a="${1//[^0-9.]/}"; raw_b="${2//[^0-9.]/}"
    IFS='.' read -r -a A <<<"$raw_a"
    IFS='.' read -r -a B <<<"$raw_b"
    for ((i=0; i<${#A[@]} || i<${#B[@]}; i++)); do
        local x=${A[i]:-0} y=${B[i]:-0}
        ((10#$x > 10#$y)) && return 0
        ((10#$x < 10#$y)) && return 1
    done
    return 0
}

# 校验缺失时的处理：交互式确认 / 环境变量放行
_confirm_unverified() {  # _confirm_unverified <名称>
    local what="$1"
    if [[ "${ALLOW_UNVERIFIED_DOWNLOADS:-0}" == "1" ]]; then
        _warn "${what}: 未取得官方 SHA-256，已按 ALLOW_UNVERIFIED_DOWNLOADS=1 放行"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        _err "${what}: 无法获取官方 SHA-256，非交互环境已拒绝安装"
        echo -e "  ${D}确认来源可信后可设置 ALLOW_UNVERIFIED_DOWNLOADS=1 重试${NC}" >&2
        return 1
    fi
    echo "" >&2
    _warn "${what}: GitHub API 未提供该资产的 SHA-256（旧版本 Release 常见）"
    echo -e "  ${D}文件已通过 HTTPS 从 github.com 下载，但缺少独立哈希校验${NC}" >&2
    local a
    read -rp "  是否仍要继续安装? [y/N]: " a
    [[ "$a" =~ ^[Yy]$ ]] && return 0
    _info "已取消安装"
    return 1
}

_resolve_singbox_version() {  # _resolve_singbox_version [override]
    local ver="${1:-}" tag
    if [[ -z "$ver" ]]; then
        tag=$(_gh_latest_tag "SagerNet/sing-box")
        ver="${tag#v}"
    fi
    ver="${ver#v}"
    [[ -n "$ver" ]] || { _err "获取 Sing-box 版本失败，请检查网络"; return 1; }
    [[ "$ver" =~ ^[0-9A-Za-z._-]+$ ]] || { _err "无效版本号: $ver"; return 1; }
    echo "$ver"
}

_download_singbox_binary() {  # _download_singbox_binary <version> <destination>
    local ver="$1" destination="$2" arch asset url tmp expect found verified actual
    arch=$(_map_arch "amd64:arm64:armv7") || { _err "不支持的架构: $(uname -m)"; return 1; }
    [[ "$DISTRO" == "alpine" ]] && apk add --no-cache gcompat libc6-compat >/dev/null 2>&1

    asset="sing-box-${ver}-linux-${arch}.tar.gz"
    url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/${asset}"
    tmp=$(mktemp -d) || return 1
    if ! curl -fsSL --connect-timeout 30 --retry 2 -o "$tmp/pkg.tar.gz" "$url"; then
        rm -rf "$tmp"; _err "下载失败: $url"; return 1
    fi
    expect=$(_gh_asset_sha256 "SagerNet/sing-box" "v${ver}" "$asset" 2>/dev/null)
    if [[ -n "$expect" ]]; then
        _verify_sha256 "$tmp/pkg.tar.gz" "$expect" || {
            rm -rf "$tmp"; _err "Sing-box SHA-256 校验失败，已拒绝安装"; return 1; }
    else
        _confirm_unverified "Sing-box v${ver}" || { rm -rf "$tmp"; return 1; }
    fi
    _archive_safe "$tmp/pkg.tar.gz" tar.gz || {
        rm -rf "$tmp"; _err "压缩包路径校验失败"; return 1; }
    tar -xzf "$tmp/pkg.tar.gz" -C "$tmp" || {
        rm -rf "$tmp"; _err "解压失败"; return 1; }
    found=$(find "$tmp" -type f -name 'sing-box' -print -quit)
    [[ -n "$found" ]] || { rm -rf "$tmp"; _err "未找到 sing-box 二进制"; return 1; }
    verified="$tmp/sing-box.verified"
    install -m 755 "$found" "$verified" || {
        rm -rf "$tmp"; _err "暂存 Sing-box 失败"; return 1; }

    actual=$(_singbox_binary_version "$verified")
    if [[ "$actual" != "$ver" ]]; then
        rm -rf "$tmp"
        _err "Sing-box 版本校验失败（期望 ${ver}，实际 ${actual:-无法运行}）"
        return 1
    fi
    install -m 755 "$verified" "$destination" || {
        rm -rf "$tmp"; _err "写入 Sing-box 候选核心失败"; return 1; }
    rm -rf "$tmp"
    return 0
}

install_singbox() {
    local cur; cur=$(_sb_version)
    if [[ -n "$cur" ]]; then
        if _version_ge "$cur" "$SB_MIN_VERSION"; then _ok "Sing-box 已安装 (v$cur)"; return 0; fi
        _warn "Sing-box v$cur 版本过低（需 >= $SB_MIN_VERSION），将升级"
    fi

    local ver; ver=$(_resolve_singbox_version) || return 1
    _info "安装 Sing-box v${ver}..."
    _download_singbox_binary "$ver" "$SB_BIN" || return 1

    cur=$(_sb_version)
    [[ -z "$cur" ]] && { _err "Sing-box 安装后无法运行"; return 1; }
    _version_ge "$cur" "$SB_MIN_VERSION" || _warn "当前 Sing-box v$cur 低于建议版本 $SB_MIN_VERSION，部分功能可能不可用"
    _ok "Sing-box v${cur} 安装完成"
}

#───────────────────────────────────────────────────────────────────────────────
# Snell（闭源，独立进程）
#───────────────────────────────────────────────────────────────────────────────
# Snell 版本不做硬编码：先向官方发布说明查询当前实际提供下载的版本，
# 取不到时才回退到下面的保底版本。也可用环境变量强制指定：
#   SNELL_V6_VERSION=6.0.0rc2 vless
readonly SNELL_RELEASE_NOTES="https://kb.nssurge.com/surge-knowledge-base/release-notes/snell.md"
# 保底版本：仅在拿不到官方列表时使用，不是版本上限
readonly SNELL_V4_FALLBACK="4.1.1"
readonly SNELL_V5_FALLBACK="5.0.1"
readonly SNELL_V6_FALLBACK="6.0.0rc2"

declare -A _SNELL_VER_CACHE=()
_SNELL_PAGE_CACHE=""
_SNELL_PAGE_FETCHED=0

# 已知版本的官方压缩包 SHA-256：命中即强校验。
# 官方对 Snell 不公布校验和，新版本（含 beta/rc）默认走 _confirm_unverified 人工确认；
# 自行校验过的可用环境变量补充，例如：
#   SNELL_SHA256_6_0_0rc2_amd64=<64位哈希> vless
_snell_sha256() {  # version arch
    local _k="${1}:${2}" _envk
    _envk="SNELL_SHA256_${_k}"; _envk="${_envk//[.:-]/_}"
    [[ -n "${!_envk:-}" ]] && { echo "${!_envk}"; return 0; }
    case "$_k" in
        4.1.1:amd64)   echo "cc2271b79c7506888b34e651e8741b3aa7fc7d5f60aa65ef8bb096f3313a193b" ;;
        4.1.1:aarch64) echo "38d4cdc03dcdb3608af8594df83e1795265167fafc5d802f815148908902d758" ;;
        4.1.1:armv7l)  echo "d00b98ed803be4039f0f0630b810932cd3d3d87ee3e6ed224106fdc63347d8e6" ;;
        5.0.1:amd64)   echo "9bea1c2b9e35b73b31634856c04d18c393072b9e5dcde6a32781d8b8f908c539" ;;
        5.0.1:aarch64) echo "2f178bf5ac468ce1a130454efa40a0603fbbe4e47ecc4880a989f4abc7f824cf" ;;
        5.0.1:armv7l)  echo "14489f3e857569c8835dd3598b7ea6bca5371d4290ac7cf0f6c8dfb3381c1fb2" ;;
        6.0.0b4:amd64)   echo "d66891cffc9f1b24a7b959ffbd2c4a246013f4f9e612733027b5ad106ce5f87f" ;;
        6.0.0b4:aarch64) echo "2c957ee6bb37ce4b1df2b6a23e652b75546d10bc4f0443a2928e5834ae0429af" ;;
        *) return 1 ;;
    esac
}

# 版本排序键：主.次.补 + 阶段(alpha 0 < beta 1 < rc 2 < 正式 3) + 阶段序号
# 定宽数字串，可直接做字符串比较。例：6.0.0b4 < 6.0.0rc < 6.0.0rc2 < 6.0.0
_snell_ver_key() {  # version
    local v="$1" core suffix stage num a b c
    core="${v%%[!0-9.]*}"; core="${core%.}"
    suffix="${v#"$core"}"
    IFS='.' read -r a b c <<<"$core"
    case "$suffix" in
        "")              stage=3 ;;
        b|b[0-9]*|beta*) stage=1 ;;
        rc|rc[0-9]*)     stage=2 ;;
        *)               stage=0 ;;
    esac
    num=$(printf '%s' "$suffix" | tr -dc '0-9')
    printf '%05d%05d%05d%d%05d' \
        "$((10#${a:-0}))" "$((10#${b:-0}))" "$((10#${c:-0}))" "$stage" "$((10#${num:-0}))"
}

# 抓官方发布说明，整个进程只抓一次。
# 必须在父 shell 里调用：_snell_remote_versions 会被放进进程替换（子 shell），
# 在那里写全局变量是丢的。
_snell_fetch_release_page() {
    [[ "$_SNELL_PAGE_FETCHED" == "1" ]] && return 0
    _SNELL_PAGE_FETCHED=1
    check_cmd curl || return 0
    _SNELL_PAGE_CACHE=$(curl -fsSL --connect-timeout 10 --max-time 30 \
        "$SNELL_RELEASE_NOTES" 2>/dev/null || true)
    return 0
}

# 从已缓存的发布说明里抽取“当前确实提供下载”的版本，并按本机架构过滤（纯解析，不联网）
_snell_remote_versions() {  # major arch
    local major="$1" arch="$2"
    [[ -z "$_SNELL_PAGE_CACHE" ]] && return 1
    printf '%s' "$_SNELL_PAGE_CACHE" \
        | grep -oE "snell-server-v[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z]*-linux-${arch}\.zip" \
        | sed -E "s#^snell-server-v(.+)-linux-${arch}\.zip\$#\1#" \
        | grep -E "^${major}\." | sort -u
}

# 解析某个大版本当前应安装的版本号
_snell_version() {  # major [quiet]
    local major="$1" quiet="${2:-}" arch ovr cached best="" bk="" v vk
    case "$major" in
        4) ovr="${SNELL_V4_VERSION:-}" ;;
        5) ovr="${SNELL_V5_VERSION:-}" ;;
        6) ovr="${SNELL_V6_VERSION:-}" ;;
        *) return 1 ;;
    esac
    [[ -n "$ovr" ]] && { echo "$ovr"; return 0; }

    arch=$(_map_arch "amd64:aarch64:armv7l") || return 1
    cached="${_SNELL_VER_CACHE[${major}:${arch}]:-}"
    [[ -n "$cached" ]] && { echo "$cached"; return 0; }

    _snell_fetch_release_page
    while IFS= read -r v; do
        [[ -z "$v" ]] && continue
        vk=$(_snell_ver_key "$v")
        if [[ -z "$bk" || "$vk" > "$bk" ]]; then best="$v"; bk="$vk"; fi
    done < <(_snell_remote_versions "$major" "$arch" 2>/dev/null)

    if [[ -z "$best" ]]; then
        if [[ -n "$_SNELL_PAGE_CACHE" ]]; then
            # 官方列表拿到了，但没有本机架构的构建 —— 别用保底版本去撞 404
            [[ "$quiet" != "quiet" ]] && {
                _err "官方发布页未提供 Snell v${major} 的 ${arch} 构建"
                [[ "$major" == "6" ]] &&
                    echo -e "  ${D}Snell v6 自 rc 起仅提供 amd64 / i386 / aarch64${NC}" >&2
            }
            return 1
        fi
        case "$major" in
            4) best="$SNELL_V4_FALLBACK" ;;
            5) best="$SNELL_V5_FALLBACK" ;;
            6) best="$SNELL_V6_FALLBACK" ;;
        esac
        [[ "$quiet" != "quiet" ]] &&
            _warn "无法访问官方发布页，Snell v${major} 回退到保底版本 ${best}"
    fi
    _SNELL_VER_CACHE["${major}:${arch}"]="$best"
    echo "$best"
}

_snell_installed_version() {  # binary
    check_cmd "$1" || return 1
    local out
    out=$("$1" --v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z]*' | head -1)
    [[ -n "$out" ]] && echo "$out"
}

ensure_snell_alpine_runtime() {
    [[ "$DISTRO" == "alpine" ]] || return 0
    _info "准备 Alpine Snell 兼容运行环境..."
    apk add --no-cache gcompat libc6-compat libstdc++ libgcc >/dev/null 2>&1 || {
        _err "Alpine glibc 兼容层安装失败"; return 1; }
    apk add --no-cache upx file >/dev/null 2>&1 || true
}

_prepare_snell_binary() {
    local bin="$1"
    chmod 755 "$bin" 2>/dev/null || return 1
    if [[ "$DISTRO" == "alpine" ]]; then
        ensure_snell_alpine_runtime || return 1
        check_cmd upx && upx -d "$bin" >/dev/null 2>&1 || true
    fi
}

_snell_binary_works() {
    local b="$1"
    [[ -x "$b" ]] || return 1
    "$b" --v >/dev/null 2>&1 && return 0
    "$b" --version >/dev/null 2>&1 && return 0
    "$b" -v >/dev/null 2>&1 && return 0
    check_cmd ldd && ! ldd "$b" 2>&1 | grep -qiE 'not found|Error loading' && return 0
    return 1
}

_install_snell_generic() {  # version target_bin
    local ver="$1" target="$2"
    local arch; arch=$(_map_arch "amd64:aarch64:armv7l") || { _err "不支持的架构"; return 1; }
    [[ "$DISTRO" == "alpine" ]] && { ensure_snell_alpine_runtime || return 1; }

    _info "安装 Snell v${ver} ..."
    local url="https://dl.nssurge.com/snell/snell-server-v${ver}-linux-${arch}.zip"
    local expect; expect=$(_snell_sha256 "$ver" "$arch" 2>/dev/null || true)
    local tmp; tmp=$(mktemp -d) || return 1
    if ! curl -fL --connect-timeout 20 --max-time 120 --retry 3 -o "$tmp/s.zip" "$url"; then
        rm -rf "$tmp"
        _err "Snell 下载失败: $url"
        echo -e "  ${D}若为 404，通常是该版本没有 ${arch} 构建；可用 SNELL_V*_VERSION 指定其他版本${NC}" >&2
        return 1
    fi
    if [[ -n "$expect" ]]; then
        _verify_sha256 "$tmp/s.zip" "$expect" || { rm -rf "$tmp"; _err "Snell SHA-256 校验失败"; return 1; }
    else
        local _hint="SNELL_SHA256_${ver}:${arch}"; _hint="${_hint//[.:-]/_}"
        _warn "Snell v${ver} (${arch}): 官方未公布 SHA-256，脚本内置哈希表也无此版本"
        echo -e "  ${D}自行校验后可用 ${_hint}=<64位哈希> 重试以启用强校验${NC}" >&2
        _confirm_unverified "Snell v${ver} (${arch})" || { rm -rf "$tmp"; return 1; }
    fi
    _archive_safe "$tmp/s.zip" zip && unzip -oq "$tmp/s.zip" -d "$tmp" || {
        rm -rf "$tmp"; _err "Snell 压缩包无效"; return 1; }
    _tree_safe "$tmp" || { rm -rf "$tmp"; _err "Snell 压缩包含链接或特殊文件"; return 1; }
    [[ -f "$tmp/snell-server" ]] || { rm -rf "$tmp"; _err "压缩包内未找到 snell-server"; return 1; }
    install -m 755 "$tmp/snell-server" "$tmp/staged" || { rm -rf "$tmp"; return 1; }
    _prepare_snell_binary "$tmp/staged" || { rm -rf "$tmp"; _err "Snell 兼容处理失败"; return 1; }
    _snell_binary_works "$tmp/staged" || { rm -rf "$tmp"; _err "Snell 二进制无法在当前系统运行"; return 1; }
    install -m 755 "$tmp/staged" "$target" || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    _ok "Snell v${ver} 已安装: $target"
}

_snell_install_major() {  # major binary target
    local major="$1" bname="$2" target="$3" ver cur
    if check_cmd "$bname"; then
        cur=$(_snell_installed_version "$bname")
        _ok "Snell v${major} 已安装 (${cur:-版本未知})"
        return 0
    fi
    ver=$(_snell_version "$major") || return 1
    _install_snell_generic "$ver" "$target"
}

install_snell()    { _snell_install_major 4 snell-server    /usr/local/bin/snell-server; }
install_snell_v5() { _snell_install_major 5 snell-server-v5 /usr/local/bin/snell-server-v5; }
install_snell_v6() { _snell_install_major 6 snell-server-v6 /usr/local/bin/snell-server-v6; }

install_shadowtls() {
    check_cmd shadow-tls && { _ok "ShadowTLS 已安装"; return 0; }
    local arch; arch=$(_map_arch "x86_64-unknown-linux-musl:aarch64-unknown-linux-musl:armv7-unknown-linux-musleabihf") \
        || { _err "不支持的架构"; return 1; }
    local tag ver; tag=$(_gh_latest_tag "ihciah/shadow-tls"); ver="${tag#v}"
    [[ -z "$ver" ]] && { _err "获取 ShadowTLS 版本失败"; return 1; }
    local asset="shadow-tls-${arch}"
    local url="https://github.com/ihciah/shadow-tls/releases/download/v${ver}/${asset}"
    _info "安装 ShadowTLS v${ver}..."
    local tmp; tmp=$(mktemp -d) || return 1
    curl -fsSL --connect-timeout 30 -o "$tmp/bin" "$url" || { rm -rf "$tmp"; _err "下载失败"; return 1; }
    local expect; expect=$(_gh_asset_sha256 "ihciah/shadow-tls" "v${ver}" "$asset" 2>/dev/null || true)
    if [[ -n "$expect" ]]; then
        _verify_sha256 "$tmp/bin" "$expect" || { rm -rf "$tmp"; _err "ShadowTLS 校验失败"; return 1; }
    else
        _confirm_unverified "ShadowTLS v${ver}" || { rm -rf "$tmp"; return 1; }
    fi
    install -m 755 "$tmp/bin" /usr/local/bin/shadow-tls || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"; _ok "ShadowTLS v${ver} 已安装"
}

#═══════════════════════════════════════════════════════════════════════════════
# 防火墙端口放行
#═══════════════════════════════════════════════════════════════════════════════
#═══════════════════════════════════════════════════════════════════════════════
# 防火墙托管开关
#═══════════════════════════════════════════════════════════════════════════════
# 本脚本的原则：只做"放行"和"计数"，从不改默认策略、不启用防火墙、不插 DROP/REJECT。
# 但如果你想要一台完全不被脚本碰规则的机器，可以彻底关掉托管。
readonly NO_FIREWALL_FLAG="$CFG/no_firewall"

# 返回 0 表示允许脚本写防火墙规则
firewall_managed() {
    [[ "${VLESS_NO_FIREWALL:-0}" == "1" ]] && return 1
    [[ -f "$NO_FIREWALL_FLAG" ]] && return 1
    return 0
}

# allow_port <端口|起始:结束> [tcp|udp]
# 只增加 ACCEPT，且仅在"你已经有防火墙在跑"时才动手：
#   ufw      -> 仅当 ufw 已 active（绝不执行 ufw enable）
#   firewalld-> 仅当 firewalld 已运行（绝不启动它）
#   iptables -> 仅当 INPUT 默认策略为 DROP/REJECT，或已存在全局 DROP/REJECT 规则
#               （即你本来就是限制型）；同一条件下同时处理 ip6tables
# 全端口开放的机器上，这个函数什么都不做。

# INPUT 是否处于限制型状态
_ipt_restrictive() {  # <iptables|ip6tables>
    local ipt="$1" pol
    pol=$("$ipt" -S INPUT 2>/dev/null | head -1 | awk '{print $3}')
    [[ "$pol" == "DROP" || "$pol" == "REJECT" ]] && return 0
    "$ipt" -L INPUT -n 2>/dev/null | grep -qE '^(DROP|REJECT)[[:space:]]+all' && return 0
    return 1
}

# 只在限制型 INPUT 上插一条 ACCEPT；确实插入返回 0，未改动返回 1
_ipt_allow() {  # <iptables|ip6tables> <proto> <dport>
    local ipt="$1" proto="$2" dport="$3"
    check_cmd "$ipt" || return 1
    "$ipt" -C INPUT -p "$proto" --dport "$dport" -j ACCEPT >/dev/null 2>&1 && return 1
    # 带 comment 的规则 -C 匹配不到，需按注释判重，否则每次运行都会重复插入
    "$ipt" -S INPUT 2>/dev/null | grep -qE -- "--comment \"?vless-${proto}-${dport}\"?( |\$)" && return 1
    _ipt_restrictive "$ipt" || return 1
    "$ipt" -I INPUT -p "$proto" --dport "$dport" \
        -m comment --comment "vless-${proto}-${dport}" -j ACCEPT >/dev/null 2>&1 || return 1
    _ok "${ipt} 已放行 ${dport}/${proto}"
    return 0
}

allow_port() {
    local port="$1" proto="${2:-tcp}" changed=0
    [[ -z "$port" ]] && return 1
    firewall_managed || return 0

    if check_cmd ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
        if ! ufw status 2>/dev/null | grep -q "${port}/${proto}"; then
            ufw allow "${port}/${proto}" >/dev/null 2>&1 && changed=1
        fi
        [[ "$changed" == "1" ]] && _ok "ufw 已放行 ${port}/${proto}"
        return 0
    fi

    if check_cmd firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        local fp="${port/:/-}"
        if ! firewall-cmd --list-ports --permanent 2>/dev/null | grep -qw "${fp}/${proto}"; then
            firewall-cmd --zone=public --add-port="${fp}/${proto}" --permanent >/dev/null 2>&1
            firewall-cmd --reload >/dev/null 2>&1
            _ok "firewalld 已放行 ${fp}/${proto}"
        fi
        return 0
    fi

    # iptables / ip6tables + netfilter-persistent（Debian/Ubuntu 常见）
    if check_cmd iptables; then
        local dport="$port" changed_ipt=0   # iptables 支持 --dport a:b
        _ipt_allow iptables "$proto" "$dport" && changed_ipt=1
        if _has_ipv6 && check_cmd ip6tables; then
            _ipt_allow ip6tables "$proto" "$dport" && changed_ipt=1
        fi
        if [[ "$changed_ipt" == "1" ]] && check_cmd netfilter-persistent; then
            netfilter-persistent save >/dev/null 2>&1
        fi
    fi
    return 0
}

# 展示脚本到底往防火墙里写了什么（审计用）
show_firewall_footprint() {
    _line
    echo -e "  ${W}防火墙足迹审计${NC}" >&2
    _line
    if ! firewall_managed; then
        echo -e "  托管状态: ${Y}已关闭${NC} ${D}(脚本不会新增任何规则)${NC}" >&2
    else
        echo -e "  托管状态: ${G}开启${NC} ${D}(只放行/计数，从不 DROP)${NC}" >&2
    fi
    if ! check_cmd iptables; then
        echo -e "  ${D}本机无 iptables 命令${NC}" >&2; _line; return 0
    fi

    # 现有防火墙形态
    local pol_in ufw_state fw_state
    pol_in=$(iptables -S INPUT 2>/dev/null | head -1 | awk '{print $3}')
    echo -e "  INPUT 默认策略: $( [[ "$pol_in" == "ACCEPT" ]] && echo "${G}ACCEPT (全开)${NC}" || echo "${Y}${pol_in}${NC}" )" >&2
    if check_cmd ip6tables; then
        local pol_in6; pol_in6=$(ip6tables -S INPUT 2>/dev/null | head -1 | awk '{print $3}')
        [[ -n "$pol_in6" ]] && echo -e "  INPUT6 默认策略: $( [[ "$pol_in6" == "ACCEPT" ]] && echo "${G}ACCEPT (全开)${NC}" || echo "${Y}${pol_in6}${NC}" )" >&2
    fi
    if check_cmd ufw; then
        ufw_state=$(ufw status 2>/dev/null | head -1)
        echo -e "  ufw     : ${D}${ufw_state:-未知}${NC}" >&2
    fi
    if check_cmd firewall-cmd; then
        fw_state=$(firewall-cmd --state 2>/dev/null || echo "not running")
        echo -e "  firewalld: ${D}${fw_state}${NC}" >&2
    fi
    if iptables -V 2>/dev/null | grep -qi nf_tables; then
        echo -e "  后端    : ${D}iptables-nft（规则最终落在 nftables 表里，脚本不直接调 nft）${NC}" >&2
    fi
    _line

    local n=0 line
    echo -e "  ${W}本脚本写入的规则${NC}" >&2
    # 1) 放行规则
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        echo -e "    ${C}[放行]${NC} ${D}${line}${NC}" >&2; ((n++))
    done < <(iptables -S INPUT 2>/dev/null | grep -- '--comment "vless-' )
    if check_cmd ip6tables; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            echo -e "    ${C}[放行6]${NC} ${D}${line}${NC}" >&2; ((n++))
        done < <(ip6tables -S INPUT 2>/dev/null | grep -- '--comment "vless-' )
    fi
    # 2) 流量统计链
    if iptables -S "$TRAFFIC_CHAIN" >/dev/null 2>&1; then
        local cnt; cnt=$(iptables -S "$TRAFFIC_CHAIN" 2>/dev/null | grep -c -- '--comment "vt:')
        echo -e "    ${C}[计数]${NC} ${D}自定义链 ${TRAFFIC_CHAIN}（${cnt} 条纯计数规则，无 target，不影响放行）${NC}" >&2
        iptables -S INPUT 2>/dev/null | grep -q -- "-j ${TRAFFIC_CHAIN}" &&             echo -e "    ${C}[计数]${NC} ${D}INPUT 第 1 位跳转到 ${TRAFFIC_CHAIN}${NC}" >&2
        ((n++))
    fi
    # 3) 端口跳跃 NAT
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        echo -e "    ${C}[NAT]${NC}  ${D}${line}${NC}" >&2; ((n++))
    done < <(iptables -t nat -S 2>/dev/null | grep -- '--comment "vless-hop')
    [[ "$n" -eq 0 ]] && echo -e "    ${D}（无）${NC}" >&2
    _line
    echo -e "  ${D}脚本从不执行: 修改默认策略 / ufw enable / 插入 DROP 或 REJECT${NC}" >&2
    _line
}

toggle_firewall_management() {
    show_firewall_footprint
    if firewall_managed; then
        echo -e "  ${D}关闭后：不再自动放行端口，也不再写流量统计链${NC}" >&2
        echo -e "  ${D}端口跳跃的 NAT 规则是 Hysteria2 跳跃功能本身所必需，不受此开关影响${NC}" >&2
        if _ask_yes "关闭防火墙托管?"; then
            touch "$NO_FIREWALL_FLAG"
            _ok "已关闭。脚本不会再新增放行/计数规则"
            if _ask_yes "同时清除脚本已写入的放行与计数规则?"; then
                cleanup_firewall_footprint
            fi
        fi
    else
        if _ask_yes "重新开启防火墙托管?"; then
            rm -f "$NO_FIREWALL_FLAG"
            _ok "已开启"
        fi
    fi
}

# 清掉脚本写过的放行与计数规则（不动 NAT 跳跃，也不动你自己的规则）
cleanup_firewall_footprint() {
    check_cmd iptables || return 0
    local rule removed=0
    while IFS= read -r rule; do
        [[ -z "$rule" ]] && continue
        # shellcheck disable=SC2086
        iptables ${rule/-A /-D } >/dev/null 2>&1 && ((removed++))
    done < <(iptables -S INPUT 2>/dev/null | grep -- '--comment "vless-')
    if check_cmd ip6tables; then
        while IFS= read -r rule; do
            [[ -z "$rule" ]] && continue
            # shellcheck disable=SC2086
            ip6tables ${rule/-A /-D } >/dev/null 2>&1 && ((removed++))
        done < <(ip6tables -S INPUT 2>/dev/null | grep -- '--comment "vless-')
    fi
    if iptables -S INPUT 2>/dev/null | grep -q -- "-j ${TRAFFIC_CHAIN}"; then
        iptables -D INPUT -j "$TRAFFIC_CHAIN" >/dev/null 2>&1 && ((removed++))
    fi
    iptables -F "$TRAFFIC_CHAIN" 2>/dev/null
    iptables -X "$TRAFFIC_CHAIN" 2>/dev/null
    check_cmd netfilter-persistent && netfilter-persistent save >/dev/null 2>&1
    _ok "已清除 ${removed} 条脚本写入的规则"
}

# 一次放行 TCP+UDP
allow_port_both() { allow_port "$1" tcp; allow_port "$1" udp; }

#═══════════════════════════════════════════════════════════════════════════════
# 证书元数据
#═══════════════════════════════════════════════════════════════════════════════
# $CFG/cert_meta 保存: ca / method / acme_domain / wildcard / issued_at
_meta_get() {
    [[ -f "$SSL_META" ]] || return 1
    local v; v=$(grep -m1 "^$1=" "$SSL_META" 2>/dev/null | cut -d= -f2-)
    [[ -n "$v" ]] && { echo "$v"; return 0; }
    return 1
}
_meta_set() {
    local k="$1" v="$2" tmp
    mkdir -p "$CFG"; touch "$SSL_META"; chmod 600 "$SSL_META"
    tmp=$(mktemp) || return 1
    grep -v "^${k}=" "$SSL_META" 2>/dev/null >"$tmp"
    printf '%s=%s\n' "$k" "$v" >>"$tmp"
    mv "$tmp" "$SSL_META"; chmod 600 "$SSL_META"
}

_acme_bin() {
    local p
    for p in "$HOME/.acme.sh/acme.sh" /root/.acme.sh/acme.sh; do
        [[ -f "$p" ]] && { echo "$p"; return 0; }
    done
    return 1
}

# CA 的证书有效期（用于剩余天数提示）
_ca_valid_days() {
    case "$1" in
        buypass) echo 180 ;;
        *)       echo 90 ;;
    esac
}
_ca_display() {
    case "$1" in
        letsencrypt) echo "Let's Encrypt" ;;
        zerossl)     echo "ZeroSSL" ;;
        buypass)     echo "Buypass" ;;
        google)      echo "Google Trust Services" ;;
        imported)    echo "外部导入" ;;
        self-signed) echo "自签" ;;
        unknown|"")  echo "未能识别" ;;
        *)           echo "$1" ;;
    esac
}

#═══════════════════════════════════════════════════════════════════════════════
# 证书判定与校验
#═══════════════════════════════════════════════════════════════════════════════
# 非自签即视为 CA 签发（issuer != subject）
_is_real_cert() {
    local crt="$SSL_DIR/server.crt"
    [[ -s "$crt" ]] || return 1
    local issuer subject
    issuer=$(openssl x509 -in "$crt" -noout -issuer 2>/dev/null | sed 's/^issuer= *//')
    subject=$(openssl x509 -in "$crt" -noout -subject 2>/dev/null | sed 's/^subject= *//')
    [[ -z "$issuer" ]] && return 1
    [[ "$issuer" == "$subject" ]] && return 1
    return 0
}

# 列出证书里的所有域名（SAN，回落 CN）
_cert_names() {
    local crt="${1:-$SSL_DIR/server.crt}"
    [[ -s "$crt" ]] || return 1
    local san
    san=$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null |
        tr ',' '\n' | grep -oE 'DNS:[^ ]+' | cut -d: -f2- | tr -d ' ')
    [[ -z "$san" ]] && san=$(openssl x509 -in "$crt" -noout -subject 2>/dev/null |
        sed -n 's/.*CN *= *\([^,]*\).*/\1/p')
    echo "$san"
}

# 证书是否覆盖某个 SNI（含通配符匹配，通配符只匹配一级标签）
_cert_covers() {
    local sni="$1" crt="${2:-$SSL_DIR/server.crt}" n base
    [[ -z "$sni" ]] && return 1
    while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        [[ "$n" == "$sni" ]] && return 0
        if [[ "$n" == \*.* ]]; then
            base="${n#*.}"
            [[ "$sni" == *".$base" ]] || continue
            # 通配符仅匹配一级：a.example.com 命中 *.example.com，a.b.example.com 不命中
            [[ "${sni%%.*}.$base" == "$sni" ]] && return 0
        fi
    done < <(_cert_names "$crt")
    return 1
}

# 证书剩余天数（输出整数，可能为负）
_cert_days_left() {
    local crt="$SSL_DIR/server.crt" na exp now
    [[ -s "$crt" ]] || return 1
    na=$(openssl x509 -in "$crt" -noout -enddate 2>/dev/null | cut -d= -f2)
    [[ -z "$na" ]] && return 1
    exp=$(date -d "$na" +%s 2>/dev/null) || return 1
    now=$(date +%s)
    echo $(( (exp - now) / 86400 ))
}

# 证书与私钥是否配对
_cert_key_match() {
    local crt="$SSL_DIR/server.crt" key="$SSL_DIR/server.key" a b
    [[ -s "$crt" && -s "$key" ]] || return 1
    a=$(openssl x509 -in "$crt" -noout -pubkey 2>/dev/null | openssl md5 2>/dev/null)
    b=$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl md5 2>/dev/null)
    [[ -n "$a" && "$a" == "$b" ]]
}

# 综合校验：存在 / 配对 / 未过期
verify_cert() {
    local days
    if [[ ! -s "$SSL_DIR/server.crt" || ! -s "$SSL_DIR/server.key" ]]; then
        _err "证书文件缺失: $SSL_DIR/server.crt"; return 1
    fi
    if ! openssl x509 -in "$SSL_DIR/server.crt" -noout >/dev/null 2>&1; then
        _err "server.crt 不是有效的 PEM 证书"; return 1
    fi
    if ! _cert_key_match; then
        _err "证书与私钥不匹配，服务将无法启动"; return 1
    fi
    days=$(_cert_days_left)
    if [[ -n "$days" && "$days" -lt 0 ]]; then
        _err "证书已过期 ${days#-} 天"; return 1
    fi
    _ok "证书校验通过$( [[ -n "$days" ]] && echo "（剩余 ${days} 天）" )"
    return 0
}

#═══════════════════════════════════════════════════════════════════════════════
# 自签证书
#═══════════════════════════════════════════════════════════════════════════════
gen_self_cert() {
    local domain="${1:-localhost}"
    mkdir -p "$SSL_DIR"; chmod 700 "$SSL_DIR"
    _info "生成自签名证书 (CN=$domain)..."
    rm -f "$SSL_DIR/server.crt" "$SSL_DIR/server.key"
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "$SSL_DIR/server.key" -out "$SSL_DIR/server.crt" \
        -subj "/CN=$domain" -days 3650 \
        -addext "subjectAltName=DNS:$domain" \
        -addext "basicConstraints=critical,CA:FALSE" \
        -addext "extendedKeyUsage=serverAuth" >/dev/null 2>&1 || {
        _err "自签证书生成失败"; return 1; }
    chmod 600 "$SSL_DIR/server.key"; chmod 644 "$SSL_DIR/server.crt"
    echo "$domain" >"$CFG/cert_domain"
    _meta_set ca "self-signed"; _meta_set method "self"
    _meta_set acme_domain "$domain"; _meta_set wildcard "false"
    _meta_set issued_at "$(date '+%F %T')"
    _ok "自签证书已生成"
}

#═══════════════════════════════════════════════════════════════════════════════
# 域名 / 端口验证（参考 v2ray-agent 的验证思路）
#═══════════════════════════════════════════════════════════════════════════════
# _resolve_domain <域名> [4|6] -> IP
_resolve_domain() {
    local d="$1" t="${2:-4}" rr=A ip="" ns
    [[ "$t" == "6" ]] && rr=AAAA
    if check_cmd dig; then
        for ns in 1.1.1.1 8.8.8.8 9.9.9.9; do
            ip=$(dig "@${ns}" +short +time=3 +tries=1 "$d" "$rr" 2>/dev/null |
                grep -vE '\.$' | grep -E '[0-9a-fA-F:.]' | head -1)
            [[ -n "$ip" ]] && break
        done
    fi
    if [[ -z "$ip" ]] && check_cmd getent; then
        if [[ "$t" == "6" ]]; then ip=$(getent ahostsv6 "$d" 2>/dev/null | awk '{print $1}' | head -1)
        else ip=$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | head -1); fi
    fi
    echo "$ip"
}

# 检查域名是否托管在 Cloudflare 且开启了橙云代理
_is_cf_proxied() {
    local d="$1" out
    out=$(curl -s --max-time 6 "https://${d}/cdn-cgi/trace" 2>/dev/null)
    echo "$out" | grep -q "^h=${d}" && return 0
    echo "$out" | grep -q "visit_scheme=" && return 0
    return 1
}

# check_domain_dns <域名> [strict]
# strict=true 时解析不一致返回 1；否则仅告警返回 0
check_domain_dns() {
    local d="$1" strict="${2:-false}" v4 v6 my4 my6
    _info "校验域名解析: ${d}"
    v4=$(_resolve_domain "$d" 4)
    v6=$(_resolve_domain "$d" 6)
    if [[ -z "$v4" && -z "$v6" ]]; then
        _err "无法解析 ${d}，请检查 DNS 记录是否已添加并生效"
        [[ "$strict" == "true" ]] && return 1
        return 0
    fi
    my4=$(get_ipv4); my6=$(get_ipv6)
    echo -e "  ${D}解析结果: ${v4:-无} ${v6:-}${NC}" >&2
    echo -e "  ${D}本机地址: ${my4:-无} ${my6:-}${NC}" >&2

    if [[ -n "$v4" && -n "$my4" && "$v4" == "$my4" ]] ||
       [[ -n "$v6" && -n "$my6" && "$v6" == "$my6" ]]; then
        _ok "域名解析指向本机"
        return 0
    fi

    if _is_cf_proxied "$d"; then
        _warn "${d} 已开启 Cloudflare 橙云代理（解析到 CF 边缘 IP）"
        echo -e "  ${D}DNS-01 申请证书不受影响；HTTP-01 与直连协议需要先关掉小云朵${NC}" >&2
        [[ "$strict" == "true" ]] && return 1
        return 0
    fi

    _warn "域名解析与本机 IP 不一致"
    echo -e "  ${D}若客户端用域名连接会连到别的机器；用 DNS-01 申请证书本身不受影响${NC}" >&2
    [[ "$strict" == "true" ]] && return 1
    return 0
}

# 本机端口可达性检查：起临时监听 + 自连读回魔术串
# 说明：仅能验证本机监听与本机防火墙，无法证明云厂商安全组已放行
# 监听端按 socat -> python3 回退。刻意不用 nc：
# OpenBSD/传统/busybox 三种 nc 的 -l -p 参数与连接关闭行为都不一致，容易挂住
_start_probe_listener() {
    local port="$1" magic="$2"
    if check_cmd socat; then
        socat -T6 "TCP-LISTEN:${port},reuseaddr" SYSTEM:"printf %s ${magic}" >/dev/null 2>&1 &
        echo $!; return 0
    fi
    if check_cmd python3; then
        python3 -c '
import socket,sys
p=int(sys.argv[1]); m=sys.argv[2].encode()
s=None
try:
    s=socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", p)); s.listen(1); s.settimeout(8)
    c,_=s.accept(); c.sendall(m); c.close()
except Exception: pass
finally:
    try: s.close()
    except Exception: pass
' "$port" "$magic" >/dev/null 2>&1 &
        echo $!; return 0
    fi
    return 1
}

check_port_listen() {
    local port="$1" magic pid got=""
    magic="vlchk$(gen_password 8)"

    if _port_listening "$port"; then
        _warn "端口 ${port} 当前已被占用，跳过可达性测试"
        (ss -tulnp 2>/dev/null || netstat -tulnp 2>/dev/null) | grep -E ":${port}[^0-9]" | sed 's/^/    /' >&2
        return 2
    fi

    pid=$(_start_probe_listener "$port" "$magic") || {
        _warn "缺少 socat 与 python3，跳过端口可达性测试"
        echo -e "  ${D}装一个即可启用该检测: apt install -y socat${NC}" >&2
        return 2
    }
    sleep 1

    local host; host=$(get_ipv4); [[ -z "$host" ]] && host=$(get_ipv6)
    if [[ -n "$host" ]]; then
        got=$( (exec 3<>"/dev/tcp/${host}/${port}" 2>/dev/null &&
                printf 'probe\n' >&3 2>/dev/null &&
                timeout 4 head -c 32 <&3 2>/dev/null) 2>/dev/null )
    fi
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

    if [[ "$got" == *"$magic"* ]]; then
        _ok "端口 ${port} 本机监听与自连测试通过"
        echo -e "  ${D}注意: 该测试走本机路由，仍需确认云厂商安全组已放行${NC}" >&2
        return 0
    fi
    _warn "端口 ${port} 自连测试未通过"
    echo -e "  ${D}常见原因: 本机防火墙拦截、云安全组未放行、或存在网页防火墙${NC}" >&2
    return 1
}

#═══════════════════════════════════════════════════════════════════════════════
# acme.sh 与 CA / 邮箱 / DNS API
#═══════════════════════════════════════════════════════════════════════════════
# HTTP-01 standalone 模式依赖 socat；acme.sh 已存在时也必须单独检查
_ensure_socat() {
    check_cmd socat && return 0
    _info "安装 socat（HTTP-01 standalone 验证必需）..."
    case "$DISTRO" in
        alpine) apk add --no-cache socat >/dev/null 2>&1 ;;
        centos) yum install -y socat >/dev/null 2>&1 ;;
        *) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq socat >/dev/null 2>&1 ;;
    esac
    check_cmd socat && { _ok "socat 已安装"; return 0; }
    _err "socat 安装失败，HTTP-01 无法进行"
    echo -e "  ${D}可改用 DNS API 方式（不需要 socat 和 80 端口）${NC}" >&2
    return 1
}

# acme.sh 的 DNS 验证依赖 dnsapi/dns_xxx.sh 这些 hook 脚本，
# 只下载主程序会导致 "Cannot find DNS API hook"，必须完整安装
_acme_dnsapi_dir() {
    local b d
    b=$(_acme_bin) || return 1
    d="$(dirname "$b")/dnsapi"
    [[ -d "$d" ]] && { echo "$d"; return 0; }
    return 1
}

# 某个 DNS hook 是否可用
_acme_has_hook() {
    local hook="$1" d
    d=$(_acme_dnsapi_dir) || return 1
    [[ -f "${d}/${hook}.sh" ]]
}

# 完整安装 / 修复 acme.sh（含 dnsapi、deploy、notify）
# install_acme_tool [force]
install_acme_tool() {
    local force="${1:-false}"
    if [[ "$force" != "true" ]] && _acme_bin >/dev/null && _acme_dnsapi_dir >/dev/null; then
        _ok "acme.sh 已安装（含 $(ls "$(_acme_dnsapi_dir)"/*.sh 2>/dev/null | wc -l) 个 DNS hook）"
        return 0
    fi
    if [[ "$force" != "true" ]] && _acme_bin >/dev/null; then
        _warn "检测到 acme.sh 安装不完整（缺少 dnsapi 目录），将重新完整安装"
    fi

    _info "安装 acme.sh（完整版，含 DNS API hook）..."
    check_cmd curl || { _err "缺少 curl"; return 1; }
    check_cmd tar  || { _err "缺少 tar"; return 1; }

    local tag tmp tarball url ok=false
    tag=$(_gh_latest_tag "acmesh-official/acme.sh")
    [[ -n "$tag" && "$tag" =~ ^[0-9A-Za-z._-]+$ ]] || {
        _err "无法取得 acme.sh 的稳定版本号，已拒绝从 master 分支安装"
        return 1
    }
    tmp=$(mktemp -d) || return 1
    tarball="$tmp/acme.tar.gz"
    for url in \
        "https://github.com/acmesh-official/acme.sh/archive/refs/tags/${tag}.tar.gz" \
        "https://codeload.github.com/acmesh-official/acme.sh/tar.gz/refs/tags/${tag}"; do
        _info "拉取: ${url%%\?*}"
        if curl -fsSL --connect-timeout 12 --max-time 120 -o "$tarball" "$url" 2>/dev/null &&
           [[ -s "$tarball" ]] && _archive_safe "$tarball" tar.gz; then
            ok=true; break
        fi
        _warn "该地址不可用，尝试下一个"
    done
    if [[ "$ok" != "true" ]]; then
        rm -rf "$tmp"
        _err "acme.sh v${tag} 下载失败（GitHub 不可达）"
        return 1
    fi

    # GitHub 自动生成的源码包没有独立 SHA-256；执行其安装器前明确征得同意。
    _confirm_unverified "acme.sh v${tag} 源码包" || { rm -rf "$tmp"; return 1; }

    tar -xzf "$tarball" -C "$tmp" || { rm -rf "$tmp"; _err "解包失败"; return 1; }
    _tree_safe "$tmp" || { rm -rf "$tmp"; _err "acme.sh 压缩包含链接或特殊文件"; return 1; }
    local src; src=$(find "$tmp" -maxdepth 1 -type d -name 'acme.sh-*' | head -1)
    if [[ -z "$src" || ! -f "$src/acme.sh" ]]; then
        rm -rf "$tmp"; _err "压缩包结构异常，未找到 acme.sh"; return 1
    fi
    if [[ ! -d "$src/dnsapi" ]]; then
        rm -rf "$tmp"; _err "压缩包中缺少 dnsapi 目录"; return 1
    fi

    _ensure_socat >/dev/null 2>&1 || true
    local email; email=$(_meta_get email) || email="$ACME_DEFAULT_EMAIL"
    local install_args=(--install --home "$HOME/.acme.sh" --noprofile)
    [[ -n "$email" ]] && install_args+=(--accountemail "$email")
    ( cd "$src" && ./acme.sh "${install_args[@]}" >/dev/null 2>&1 )
    rm -rf "$tmp"

    if ! _acme_bin >/dev/null || ! _acme_dnsapi_dir >/dev/null; then
        _err "acme.sh 安装未完成"
        return 1
    fi
    "$(_acme_bin)" --install-cronjob >/dev/null 2>&1
    _ok "acme.sh 安装完成（$(ls "$(_acme_dnsapi_dir)"/*.sh 2>/dev/null | wc -l) 个 DNS hook）"
}

# 选择证书颁发机构，设置 SSL_CA
select_ssl_ca() {
    SSL_CA=""
    local cur; cur=$(_meta_get ca) || cur=""
    echo "" >&2
    _line
    echo -e "  ${W}选择证书颁发机构${NC} ${D}(均为免费)${NC}" >&2
    [[ -n "$cur" && "$cur" != "self-signed" ]] && echo -e "  ${D}上次使用: $(_ca_display "$cur")${NC}" >&2
    _line
    _item "1" "Let's Encrypt ${D}(默认，90 天，兼容性最好)${NC}"
    _item "2" "ZeroSSL ${D}(90 天，需邮箱注册)${NC}"
    _item "3" "Buypass ${D}(180 天，不支持 DNS-01 通配符)${NC}"
    _line
    local c; read -rp "  请选择 [1]: " c
    case "${c:-1}" in
        2) SSL_CA="zerossl" ;;
        3) SSL_CA="buypass" ;;
        *) SSL_CA="letsencrypt" ;;
    esac
    echo -e "  ${C}使用: ${G}$(_ca_display "$SSL_CA")${NC}" >&2
    return 0
}

# 设置 acme 账户邮箱（ZeroSSL 必需，LE 建议）
setup_acme_email() {
    local acme conf cur email
    acme=$(_acme_bin) || return 1
    conf="$(dirname "$acme")/account.conf"
    cur=$(grep -m1 '^ACCOUNT_EMAIL' "$conf" 2>/dev/null | cut -d"'" -f2)
    [[ -z "$cur" ]] && cur=$(_meta_get email)
    if [[ -n "$cur" ]]; then
        echo -e "  ${D}acme 账户邮箱: ${cur}${NC}" >&2
        _ask_yes "是否更换邮箱?" || return 0
    fi
    while true; do
        if [[ -n "$ACME_DEFAULT_EMAIL" ]]; then
            read -rp "  请输入邮箱地址 [${ACME_DEFAULT_EMAIL}]: " email
            [[ -z "$email" ]] && email="$ACME_DEFAULT_EMAIL"
        else
            read -rp "  请输入邮箱地址 (证书到期提醒用，不能为空): " email
        fi
        if [[ "$email" == *@*.* ]]; then break; fi
        _err "邮箱格式无效，示例: you@example.com"
    done
    _meta_set email "$email"
    "$acme" --register-account -m "$email" --server "${SSL_CA:-letsencrypt}" >/dev/null 2>&1
    _ok "邮箱已设置: $email"
}

#── DNS API 凭据（保存复用，续期时也要用到）──────────────────────────────────
_save_dns_creds() {
    mkdir -p "$CFG"
    : >"$DNS_API_CONF"; chmod 600 "$DNS_API_CONF"
    local k
    for k in DNS_PROVIDER CF_Token CF_Account_ID CF_Key CF_Email Ali_Key Ali_Secret; do
        [[ -n "${!k}" ]] && printf '%s=%s\n' "$k" "${!k}" >>"$DNS_API_CONF"
    done
    chmod 600 "$DNS_API_CONF"
}
_load_dns_creds() {
    [[ -f "$DNS_API_CONF" ]] || return 1
    local line k v
    while IFS= read -r line; do
        k="${line%%=*}"; v="${line#*=}"
        case "$k" in
            DNS_PROVIDER|CF_Token|CF_Account_ID|CF_Key|CF_Email|Ali_Key|Ali_Secret)
                export "$k=$v" ;;
        esac
    done <"$DNS_API_CONF"
    [[ -n "${DNS_PROVIDER:-}" ]]
}

# 选择 / 录入 DNS API 凭据，设置 DNS_PROVIDER 与对应环境变量
setup_dns_api() {
    local reuse=false
    if _load_dns_creds; then
        echo "" >&2
        echo -e "  ${D}已保存的 DNS API: ${DNS_PROVIDER}${NC}" >&2
        _ask_yes "复用已保存的 DNS API 凭据?" && reuse=true
    fi
    if [[ "$reuse" == "true" ]]; then
        _ok "复用 ${DNS_PROVIDER} 凭据"
        return 0
    fi

    echo "" >&2
    _line
    echo -e "  ${W}DNS 服务商${NC}" >&2
    _line
    _item "1" "Cloudflare ${D}(推荐，API Token)${NC}"
    _item "2" "Cloudflare ${D}(Global API Key + 邮箱，旧方式)${NC}"
    _item "3" "阿里云 DNS"
    _line
    local c; read -rp "  请选择 [1]: " c
    case "${c:-1}" in
        2)
            DNS_PROVIDER="dns_cf"
            read -rp "  Cloudflare 账户邮箱: " CF_Email
            read -rsp "  Global API Key: " CF_Key; echo "" >&2
            [[ -z "$CF_Email" || -z "$CF_Key" ]] && { _err "不能为空"; return 1; }
            export CF_Email CF_Key; unset CF_Token CF_Account_ID ;;
        3)
            DNS_PROVIDER="dns_ali"
            _read_secret Ali_Key "  Ali Key: "
            _read_secret Ali_Secret "  Ali Secret: "
            [[ -z "$Ali_Key" || -z "$Ali_Secret" ]] && { _err "不能为空"; return 1; }
            export Ali_Key Ali_Secret ;;
        *)
            DNS_PROVIDER="dns_cf"
            echo "" >&2
            echo -e "  ${D}Token 创建位置: Cloudflare 控制台 → My Profile → API Tokens${NC}" >&2
            echo -e "  ${D}所需权限: Zone → DNS → Edit，且 Zone → Zone → Read${NC}" >&2
            echo -e "  ${D}Zone Resources 选 Include → All zones（或指定你的域名）${NC}" >&2
            read -rsp "  API Token: " CF_Token; echo "" >&2
            [[ -z "$CF_Token" ]] && { _err "Token 不能为空"; return 1; }
            read -rp "  Account ID (可留空): " CF_Account_ID
            export CF_Token CF_Account_ID; unset CF_Key CF_Email ;;
    esac
    export DNS_PROVIDER
    _save_dns_creds
    _ok "DNS API 凭据已保存到 ${DNS_API_CONF} (权限 600)"
}

#═══════════════════════════════════════════════════════════════════════════════
# 证书申请
#═══════════════════════════════════════════════════════════════════════════════
# 把签发好的证书安装到 $SSL_DIR，并挂上续期后的重载动作
_install_cert_files() {
    local acme_domain="$1" ecc="${2:-true}" acme eccflag=()
    acme=$(_acme_bin) || return 1
    [[ "$ecc" == "true" ]] && eccflag=(--ecc)
    mkdir -p "$SSL_DIR"; chmod 700 "$SSL_DIR"
    local reload
    reload="chmod 600 ${SSL_DIR}/server.key; chmod 644 ${SSL_DIR}/server.crt; \
if command -v systemctl >/dev/null 2>&1; then systemctl restart ${SB_SVC} 2>/dev/null || true; \
elif command -v rc-service >/dev/null 2>&1; then rc-service ${SB_SVC} restart 2>/dev/null || true; fi; \
if command -v nginx >/dev/null 2>&1; then nginx -s reload 2>/dev/null || true; fi"

    "$acme" --install-cert -d "$acme_domain" "${eccflag[@]}" \
        --key-file "$SSL_DIR/server.key" \
        --fullchain-file "$SSL_DIR/server.crt" \
        --reloadcmd "$reload" >/dev/null 2>&1

    [[ -s "$SSL_DIR/server.crt" && -s "$SSL_DIR/server.key" ]] || {
        _err "证书安装失败（acme.sh --install-cert）"; return 1; }
    chmod 600 "$SSL_DIR/server.key"; chmod 644 "$SSL_DIR/server.crt"
    return 0
}

# acme.sh 是否已存在该域名的证书
_acme_has_cert() {
    local d="$1"
    [[ -s "$HOME/.acme.sh/${d}_ecc/fullchain.cer" || -s "$HOME/.acme.sh/${d}/fullchain.cer" ]]
}

# 解读 acme.sh 失败原因，给出可执行的下一步
_acme_explain_failure() {
    local log="$1" rc="${2:-0}"
    [[ -f "$log" ]] || return 0
    if grep -q "Please install socat" "$log"; then
        _err "缺少 socat（HTTP-01 standalone 依赖它）"
        echo -e "  ${C}已尝试自动安装；若仍失败可手动: ${D}apt install -y socat${NC}" >&2
        echo -e "  ${C}或改用 DNS API 方式，完全不需要 socat 与 80 端口${NC}" >&2
        return 1
    fi
    if grep -qiE "Timeout|timed out|Fetching http.*failed|Invalid response from http" "$log"; then
        _err "HTTP-01 验证超时：CA 无法从公网访问本机 80 端口"
        echo -e "  ${D}检查: 域名解析是否指向本机 / 云安全组是否放行 80 / 是否开了 Cloudflare 橙云${NC}" >&2
        return 1
    fi
    if grep -qiE "rateLimited|too many certificates|Error creating new order" "$log"; then
        _err "触发 CA 频率限制，请等待后再试或换一家 CA"
        return 1
    fi
    if grep -qiE "invalid domain|DNS problem|NXDOMAIN" "$log"; then
        _err "域名解析有问题，CA 查不到有效记录"
        return 1
    fi
    if grep -qi "Cannot find DNS API hook" "$log"; then
        local hook; hook=$(grep -oiE 'Cannot find DNS API hook for: *[a-z0-9_]+' "$log" | awk -F': *' '{print $2}' | head -1)
        _err "acme.sh 缺少 DNS hook 脚本 ${hook:-dns_xxx}，这不是 Token 的问题"
        echo -e "  ${D}原因: acme.sh 安装不完整（只有主程序，没有 dnsapi/ 目录）${NC}" >&2
        echo -e "  ${C}修复: 证书管理 → 修复 acme.sh 安装，然后重新申请${NC}" >&2
        return 1
    fi
    if grep -qiE "Please add the TXT|Add the following TXT" "$log"; then
        _err "acme.sh 退回了手动 DNS 模式，未能自动写入 TXT 记录"
        echo -e "  ${D}多为 DNS hook 缺失或凭据未生效导致${NC}" >&2
        return 1
    fi
    if grep -qiE "Skipping\. Next renewal time" "$log"; then
        _warn "acme.sh 判定尚未到续期时间，本次没有签发新证书"
        echo -e "  ${D}如需立即换证，请使用强制模式或先删除旧记录${NC}" >&2
        return 1
    fi
    if grep -qiE "Cert success|Cert renewed" "$log"; then
        return 0
    fi
    [[ "$rc" != "0" ]] && { _err "acme.sh 返回错误码 ${rc}，完整日志: $HOME/.acme.sh/acme.sh.log"; return 1; }
    return 0
}

# issue_cert_dns_api <acme_domain> [附加域名]
# 用 DNS-01 签发，支持通配符，不需要 80 端口，NAT / 橙云均可
issue_cert_dns_api() {
    local acme_domain="$1" extra="${2:-}" acme args=()
    acme=$(_acme_bin) || return 1
    _load_dns_creds >/dev/null 2>&1

    # 预检：DNS hook 必须存在，否则 acme.sh 会静默退回手动模式
    if ! _acme_has_hook "$DNS_PROVIDER"; then
        _warn "缺少 DNS hook: ${DNS_PROVIDER}.sh"
        _info "自动修复 acme.sh 安装..."
        install_acme_tool true || return 1
        _acme_has_hook "$DNS_PROVIDER" || {
            _err "修复后仍找不到 ${DNS_PROVIDER}.sh，请改用手动 DNS 或 HTTP-01"
            return 1
        }
    fi

    args=(--issue -d "$acme_domain")
    [[ -n "$extra" ]] && args+=(-d "$extra")
    args+=(--dns "$DNS_PROVIDER" -k ec-256 --server "${SSL_CA:-letsencrypt}")
    [[ -n "$(get_ipv4)" ]] || args+=(--listen-v6)
    # 该域名已有 acme 记录时必须 --force，否则 acme.sh 会 "Skipping" 而我们
    # 会误把旧证书（可能已过期或验证方式已变）重新装一遍
    if _acme_has_cert "$acme_domain"; then
        args+=(--force)
        _info "检测到 ${acme_domain} 已有 acme 记录，本次强制重新签发"
    fi

    _info "通过 ${DNS_PROVIDER} 申请证书: ${acme_domain}${extra:+, $extra}"
    echo -e "  ${D}需要等待 DNS TXT 记录生效，通常 20-120 秒${NC}" >&2
    local log; log=$(mktemp)
    "$acme" "${args[@]}" >"$log" 2>&1
    local rc=$?
    grep -viE 'debug|^$' "$log" | tail -20 | sed 's/^/    /' >&2
    _acme_explain_failure "$log" "$rc"
    rm -f "$log"

    if ! _acme_has_cert "$acme_domain"; then
        _err "证书申请失败"
        echo -e "  ${D}排查方向:${NC}" >&2
        echo -e "  ${D}• Token 权限是否包含 Zone:DNS:Edit 与 Zone:Zone:Read${NC}" >&2
        echo -e "  ${D}• 域名是否确实托管在该 DNS 服务商（NS 指向）${NC}" >&2
        echo -e "  ${D}• 同一域名一周内是否已达 CA 签发上限${NC}" >&2
        echo -e "  ${D}• 完整日志: $HOME/.acme.sh/acme.sh.log${NC}" >&2
        return 1
    fi
    _install_cert_files "$acme_domain" || return 1
    local dl; dl=$(_cert_days_left)
    if [[ -n "$dl" && "$dl" -lt 1 ]]; then
        _err "安装后的证书剩余 ${dl} 天，疑似装到了旧证书"
        echo -e "  ${D}可尝试: rm -rf $HOME/.acme.sh/${acme_domain}_ecc 后重新签发${NC}" >&2
        return 1
    fi
    _meta_set ca "${SSL_CA:-letsencrypt}"
    _meta_set method "$DNS_PROVIDER"
    _meta_set acme_domain "$acme_domain"
    _meta_set wildcard "$( [[ "$acme_domain" == \** ]] && echo true || echo false )"
    _meta_set issued_at "$(date '+%F %T')"
    _ok "证书签发并安装完成"
}

# issue_cert_http01 <域名>
issue_cert_http01() {
    local d="$1" acme nginx_was=false
    acme=$(_acme_bin) || return 1

    check_domain_dns "$d" || {
        _ask_yes "域名校验未通过，仍要继续?" || return 1
    }
    if _is_cf_proxied "$d"; then
        _err "${d} 处于 Cloudflare 橙云代理后，HTTP-01 无法完成验证"
        echo -e "  ${D}请关掉小云朵后等 3 分钟重试，或改用 Cloudflare DNS API 方式${NC}" >&2
        return 1
    fi

    _ensure_socat || return 1
    allow_port 80 tcp
    if ss -tuln 2>/dev/null | grep -qE ':80[^0-9]'; then
        svc status nginx >/dev/null 2>&1 && { nginx_was=true; svc stop nginx; }
        sleep 1
        if ss -tuln 2>/dev/null | grep -qE ':80[^0-9]'; then
            _err "80 端口被占用，HTTP-01 无法进行"
            ss -tulnp 2>/dev/null | grep -E ':80[^0-9]' | sed 's/^/    /' >&2
            [[ "$nginx_was" == "true" ]] && svc start nginx
            return 1
        fi
    fi

    _info "申请证书 (HTTP-01): ${d}"
    local log fargs=(); log=$(mktemp)
    _acme_has_cert "$d" && fargs+=(--force)
    "$acme" --issue -d "$d" --standalone --httpport 80 -k ec-256 \
        --server "${SSL_CA:-letsencrypt}" "${fargs[@]}" >"$log" 2>&1
    local rc=$?
    grep -viE 'debug|^$' "$log" | tail -20 | sed 's/^/    /' >&2
    _acme_explain_failure "$log" "$rc"
    rm -f "$log"
    [[ "$nginx_was" == "true" ]] && svc start nginx

    _acme_has_cert "$d" || { _err "证书申请失败，详见 $HOME/.acme.sh/acme.sh.log"; return 1; }
    _install_cert_files "$d" || return 1
    _meta_set ca "${SSL_CA:-letsencrypt}"; _meta_set method "http-01"
    _meta_set acme_domain "$d"; _meta_set wildcard "false"
    _meta_set issued_at "$(date '+%F %T')"
    _ok "证书签发并安装完成"
}

# issue_cert_manual_dns <域名>
issue_cert_manual_dns() {
    local d="$1" acme out txt
    acme=$(_acme_bin) || return 1
    _info "申请证书 (手动 DNS TXT): ${d}"
    out=$("$acme" --issue -d "$d" --dns -k ec-256 --server "${SSL_CA:-letsencrypt}" \
        --yes-I-know-dns-manual-mode-enough-go-ahead-please 2>&1)
    txt=$(printf '%s' "$out" | sed -n "s/.*TXT value: *'\([^']*\)'.*/\1/p" | head -1)
    [[ -z "$txt" ]] && { _err "未能取得 TXT 记录值"; printf '%s\n' "$out" | tail -10 | sed 's/^/    /' >&2; return 1; }
    echo "" >&2
    _dline
    echo -e "  主机记录: ${G}_acme-challenge.${d%%\**}${NC}" >&2
    echo -e "  记录类型: ${G}TXT${NC}" >&2
    echo -e "  记录值  : ${G}${txt}${NC}" >&2
    _dline
    read -rp "  添加并生效后按回车继续..." _
    "$acme" --renew -d "$d" --ecc \
        --yes-I-know-dns-manual-mode-enough-go-ahead-please 2>&1 |
        grep -viE 'debug|^$' | tail -10 | sed 's/^/    /' >&2
    _acme_has_cert "$d" || { _err "证书申请失败"; return 1; }
    _install_cert_files "$d" || return 1
    _meta_set ca "${SSL_CA:-letsencrypt}"; _meta_set method "manual-dns"
    _meta_set acme_domain "$d"; _meta_set wildcard "$( [[ "$d" == \** ]] && echo true || echo false )"
    _meta_set issued_at "$(date '+%F %T')"
    _warn "手动 DNS 模式无法自动续期，到期前需再走一次本流程"
}

# 由域名推导通配符父域（不做公共后缀判断，会让用户确认）
_wildcard_of() {
    local d="$1" labels
    labels=$(echo "$d" | awk -F'.' '{print NF}')
    if [[ "$labels" -le 2 ]]; then echo "*.${d}"; else echo "*.${d#*.}"; fi
}

#═══════════════════════════════════════════════════════════════════════════════
# REALITY / ShadowTLS 伪装目标（握手域名）适配性检查
#═══════════════════════════════════════════════════════════════════════════════
# 与本地证书完全无关：伪装目标是"第三方网站"，服务端会把未通过认证的握手
# 原样转发给它，让探测者看到那个网站的真实证书。因此它必须是别人的站点。
# check_reality_dest <域名> [端口] -> 0 合适 / 1 不合适
check_reality_dest() {
    local d="$1" port="${2:-443}" v4 v6 my4 my6 out proto group vrc

    # 1) 绝对不能是自己 —— 服务端要向该目标发起握手，指向自己会自握手/失败
    v4=$(_resolve_domain "$d" 4); v6=$(_resolve_domain "$d" 6)
    my4=$(get_ipv4); my6=$(get_ipv6)
    if [[ -n "$v4" && -n "$my4" && "$v4" == "$my4" ]] ||
       [[ -n "$v6" && -n "$my6" && "$v6" == "$my6" ]]; then
        _err "${d} 解析到本机，不能作为伪装目标"
        echo -e "  ${D}服务端需要把未认证的握手转发给该目标；指向自己会形成自握手${NC}" >&2
        echo -e "  ${D}伪装目标必须是你不拥有的第三方大站（如 www.microsoft.com）${NC}" >&2
        return 1
    fi

    # 2) 不该用自己名下的域名 —— 会把代理和你的域名绑在一起，丧失抵赖性
    #    候选来源：cert_domain / acme_domain / 各实例的连接地址，并各取其注册域
    local owns=() o root
    [[ -f "$CFG/cert_domain" ]] && owns+=("$(cat "$CFG/cert_domain")")
    o=$(_meta_get acme_domain) && owns+=("$o")
    while IFS= read -r o; do [[ -n "$o" ]] && owns+=("$o"); done < <(
        _db_q '[(.singbox // {}, .snell // {}) | .[]? | .[]? | .address // empty] | unique | .[]' 2>/dev/null)

    local roots=()
    for o in "${owns[@]}"; do
        o="${o#\*.}"; [[ -z "$o" ]] && continue
        roots+=("$o")
        # 三段及以上时把注册域也算进来：ipv4.example.com -> example.com
        if [[ "$(echo "$o" | awk -F'.' '{print NF}')" -ge 3 ]]; then
            roots+=("${o#*.}")
        fi
    done
    for root in "${roots[@]}"; do
        [[ -z "$root" ]] && continue
        if [[ "$d" == "$root" || "$d" == *".$root" ]]; then
            _err "${d} 属于你自己名下的域名 (${root})"
            echo -e "  ${D}用自己的域名做伪装,等于把代理和该域名绑定,审查方可直接封域名${NC}" >&2
            echo -e "  ${D}且服务端向自己的域名发起握手通常拿不到可用的第三方证书${NC}" >&2
            return 1
        fi
    done

    # 3) 目标必须支持 TLS 1.3，且最好走 X25519 密钥交换
    if ! check_cmd openssl; then
        _warn "缺少 openssl，跳过伪装目标探测"
        return 0
    fi
    _info "探测伪装目标 ${d}:${port} ..."
    out=$(timeout 10 openssl s_client -connect "${d}:${port}" -servername "$d" \
            -tls1_3 -brief </dev/null 2>&1)
    if [[ -z "$out" ]] || echo "$out" | grep -qiE 'connect:errno|Connection refused|no route|timed out|unable to get local issuer|handshake failure'; then
        # -brief 在旧版 openssl 不支持，退回普通模式再试一次
        out=$(timeout 10 openssl s_client -connect "${d}:${port}" -servername "$d" \
                -tls1_3 </dev/null 2>&1)
    fi
    if [[ -z "$out" ]] || echo "$out" | grep -qiE 'connect:errno|Connection refused|no route to host|timed out'; then
        _err "无法从本机连到 ${d}:${port}"
        echo -e "  ${D}目标必须能从这台 VPS 直连，否则 REALITY 握手会失败${NC}" >&2
        return 1
    fi
    if echo "$out" | grep -qiE 'wrong version number|unsupported protocol|no protocols available'; then
        _err "${d} 不支持 TLS 1.3，不能用作 REALITY 目标"
        return 1
    fi

    proto=$(echo "$out" | grep -oE 'TLSv1\.[0-9]' | head -1)
    group=$(echo "$out" | grep -oiE 'Negotiated TLS1.3 group: [A-Za-z0-9_]+|Server Temp Key: [A-Za-z0-9_]+' | head -1 | awk -F': ' '{print $2}')
    vrc=$(echo "$out" | grep -oE 'Verify return code: [0-9]+' | head -1 | grep -oE '[0-9]+$')

    if [[ "$proto" != "TLSv1.3" ]]; then
        _err "${d} 协商到的是 ${proto:-未知}，REALITY 要求 TLS 1.3"
        return 1
    fi
    echo -e "  ${G}✓${NC} TLS 1.3 可用   密钥交换: ${C}${group:-未知}${NC}" >&2
    if [[ -n "$group" ]] && ! echo "$group" | grep -qiE 'X25519|x25519'; then
        _warn "密钥交换为 ${group}，非 X25519，部分客户端兼容性可能变差"
    fi
    if [[ -n "$vrc" && "$vrc" != "0" ]]; then
        _warn "目标证书校验返回码 ${vrc}（证书与该域名可能不匹配）"
    fi

    # 4) Cloudflare 橙云后的域名不适合做目标
    if _is_cf_proxied "$d"; then
        _warn "${d} 位于 Cloudflare 代理之后"
        echo -e "  ${D}这类目标的流量会经 CF 中转，可能被他人蹭用，且指纹不稳定${NC}" >&2
        _ask_yes "仍要使用?" || return 1
    fi

    _ok "伪装目标 ${d} 可用"
    return 0
}

#═══════════════════════════════════════════════════════════════════════════════
# 已有证书的识别与接管（重装 / 恢复备份后自愈）
#═══════════════════════════════════════════════════════════════════════════════
# 找到 ~/.acme.sh 下与当前 server.crt 指纹一致的域名目录
_acme_match_dir() {
    local crt="$SSL_DIR/server.crt" fp d f
    [[ -s "$crt" ]] || return 1
    fp=$(openssl x509 -in "$crt" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
    [[ -z "$fp" ]] && return 1
    for d in "$HOME/.acme.sh"/*/; do
        f="${d}fullchain.cer"
        [[ -s "$f" ]] || continue
        if [[ "$(openssl x509 -in "$f" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)" == "$fp" ]]; then
            echo "${d%/}"; return 0
        fi
    done
    return 1
}

# 列出该目录下所有 .conf（正常只有一个，但别假设）
_acme_conf_files() { find "$1" -maxdepth 1 -type f -name '*.conf' 2>/dev/null; }

# 容错读取 acme.sh conf 的键值：
# 兼容 key='v' / key="v" / key=v，容忍 CRLF 与前导空白，并遍历目录下所有 conf
_acme_conf_get() {
    local dir="$1" key="$2" f line v
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        line=$(grep -m1 -E "^[[:space:]]*${key}=" "$f" 2>/dev/null | tr -d '\r')
        [[ -z "$line" ]] && continue
        v="${line#*=}"
        v="${v#[\'\"]}"; v="${v%[\'\"]}"
        [[ -n "$v" ]] && { echo "$v"; return 0; }
    done < <(_acme_conf_files "$dir")
    return 1
}

# 从证书 issuer 判断 CA —— 比读 acme.sh conf 可靠，优先用它
_ca_from_issuer() {
    local crt="$SSL_DIR/server.crt" issuer
    issuer=$(openssl x509 -in "$crt" -noout -issuer 2>/dev/null)
    [[ -z "$issuer" ]] && { echo "unknown"; return 1; }
    case "$issuer" in
        *ZeroSSL*|*zerossl*)                     echo "zerossl" ;;
        *"Let's Encrypt"*|*Letsencrypt*|*ISRG*)  echo "letsencrypt" ;;
        *Buypass*)                               echo "buypass" ;;
        *"E5"*|*"E6"*|*"R10"*|*"R11"*|*"R3"*)    echo "letsencrypt" ;;
        *Google*)                                echo "google" ;;
        *)                                       echo "unknown" ;;
    esac
}

_ca_from_api() {
    case "$1" in
        *letsencrypt*) echo "letsencrypt" ;;
        *zerossl*)     echo "zerossl" ;;
        *buypass*)     echo "buypass" ;;
        *)             echo "unknown" ;;
    esac
}

# acme.sh 的 account.conf 里存有上次用过的 DNS API 凭据（SAVED_ 前缀），
# 恢复备份后 dns_api.conf 可能不存在，从这里回收即可继续自动续期
_import_dns_creds_from_acme() {
    local conf="$HOME/.acme.sh/account.conf" k v found=false
    [[ -f "$conf" ]] || return 1
    for k in CF_Token CF_Account_ID CF_Key CF_Email Ali_Key Ali_Secret; do
        v=$(grep -m1 "^SAVED_${k}=" "$conf" 2>/dev/null | cut -d"'" -f2)
        [[ -n "$v" ]] && { export "$k=$v"; found=true; }
    done
    [[ "$found" == "true" ]] || return 1
    if   [[ -n "${CF_Token:-}" || -n "${CF_Key:-}" ]]; then DNS_PROVIDER="dns_cf"
    elif [[ -n "${Ali_Key:-}" ]]; then DNS_PROVIDER="dns_ali"
    else return 1; fi
    export DNS_PROVIDER
    _save_dns_creds
    return 0
}

# 确保系统有 crontab（部分精简镜像默认不带）
_ensure_crontab() {
    check_cmd crontab && return 0
    _info "安装 cron ..."
    case "$DISTRO" in
        alpine) apk add --no-cache dcron >/dev/null 2>&1; rc-update add dcron default >/dev/null 2>&1; rc-service dcron start >/dev/null 2>&1 ;;
        centos) yum install -y cronie >/dev/null 2>&1; systemctl enable --now crond >/dev/null 2>&1 ;;
        *)      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cron >/dev/null 2>&1; systemctl enable --now cron >/dev/null 2>&1 ;;
    esac
    check_cmd crontab && { _ok "cron 已安装"; return 0; }
    _err "cron 安装失败，无法配置自动续期定时任务"
    return 1
}

# cert_adopt [quiet]
# 识别现有证书来源并补全 cert_meta；恢复备份 / 旧版本升级后自动调用
cert_adopt() {
    local quiet="${1:-false}"
    [[ -s "$SSL_DIR/server.crt" ]] || return 1

    if ! _is_real_cert; then
        _meta_set ca "self-signed"; _meta_set method "self"
        _meta_set acme_domain "$(_cert_names | head -1)"; _meta_set wildcard "false"
        [[ "$quiet" == "true" ]] || _info "检测到自签证书"
        return 0
    fi

    local dir dom web api ca
    if dir=$(_acme_match_dir); then
        # 域名：conf -> 目录名 -> 证书 SAN
        dom=$(_acme_conf_get "$dir" Le_Domain) || dom=""
        if [[ -z "$dom" ]]; then
            dom="${dir##*/}"; dom="${dom%_ecc}"
        fi
        [[ -z "$dom" ]] && dom="$(_cert_names | head -1)"

        # CA：以证书 issuer 为准，conf 里的 Le_API 仅作补充
        ca=$(_ca_from_issuer)
        if [[ "$ca" == "unknown" ]]; then
            api=$(_acme_conf_get "$dir" Le_API) || api=""
            ca=$(_ca_from_api "$api")
        fi

        # 验证方式：读不到就标 unknown，不要猜成 http-01
        web=$(_acme_conf_get "$dir" Le_Webroot) || web=""
        case "$web" in
            dns_*)  _meta_set method "$web" ;;
            dns)    _meta_set method "manual-dns" ;;
            no)     _meta_set method "http-01" ;;
            "")     _meta_set method "unknown" ;;
            *)      _meta_set method "$web" ;;
        esac
        _meta_set ca "$ca"
        _meta_set acme_domain "$dom"
        _meta_set wildcard "$( [[ "$dom" == \** ]] && echo true || echo false )"
        _meta_set acme_dir "$dir"
        _meta_set ecc "$( [[ "$dir" == *_ecc ]] && echo true || echo false )"
        local ct; ct=$(_acme_conf_get "$dir" Le_CertCreateTimeStr) && _meta_set issued_at "$ct"
        [[ "$quiet" == "true" ]] || {
            _ok "已接管 acme.sh 证书: ${dom}"
            echo -e "  ${D}CA: $(_ca_display "$ca")   验证方式: $(_meta_get method)${NC}" >&2
            if [[ -z "$(_acme_conf_files "$dir")" ]]; then
                _warn "该目录下没有 acme.sh 配置文件: ${dir}"
                echo -e "  ${D}证书文件在但配置缺失（多为从别的脚本/机器搬过来），无法沿用原续期设置${NC}" >&2
                echo -e "  ${D}建议在证书管理中重新签发一次，之后即可全自动续期${NC}" >&2
            elif [[ "$(_meta_get method)" == "unknown" ]]; then
                _warn "无法确定原来的验证方式（conf 中缺少 Le_Webroot）"
                echo -e "  ${D}续期时可能失败，建议重新签发一次以固定验证方式${NC}" >&2
            fi
            local dl; dl=$(_cert_days_left)
            if [[ -n "$dl" && "$dl" -lt 0 ]]; then
                _err "该证书已过期 ${dl#-} 天，必须重新签发（续期无法救回长期过期的证书）"
            fi
        }
        # 凭据回收：DNS 验证方式但本机没有 dns_api.conf
        if [[ "$(_meta_get method)" == dns_* ]] && [[ ! -f "$DNS_API_CONF" ]]; then
            if _import_dns_creds_from_acme; then
                [[ "$quiet" == "true" ]] || _ok "已从 acme.sh 回收 DNS API 凭据"
            else
                [[ "$quiet" == "true" ]] || _warn "未找到 DNS API 凭据，续期可能失败（可在证书管理中重新录入 Token）"
            fi
        fi
        return 0
    fi

    # 证书存在但不是 acme.sh 签发/管理的
    _meta_set ca "imported"; _meta_set method "imported"
    _meta_set acme_domain "$(_cert_names | head -1)"
    [[ "$quiet" == "true" ]] || {
        _warn "证书不由本机 acme.sh 管理（外部导入或 acme 数据缺失），无法自动续期"
    }
    return 0
}

# 首次进入菜单 / 恢复备份后的静默自愈
cert_selfheal() {
    [[ -s "$SSL_DIR/server.crt" ]] || return 0
    # meta 缺失或 CA 未知时才重新识别，避免每次进菜单都跑 openssl
    local ca; ca=$(_meta_get ca) || ca=""
    if [[ -z "$ca" || "$ca" == "unknown" ]]; then
        cert_adopt true >/dev/null 2>&1
    fi
    return 0
}

#═══════════════════════════════════════════════════════════════════════════════
# 自动续期：保证 acme.sh cron + reloadcmd + 巡检任务三者齐备
#═══════════════════════════════════════════════════════════════════════════════
# cert_ensure_autorenew [quiet] -> 0 全部就绪 / 1 有修复动作 / 2 无法自动续期
cert_ensure_autorenew() {
    local quiet="${1:-false}" acme dir fixed=0 cron_ok=true
    [[ -s "$SSL_DIR/server.crt" ]] || return 2
    _is_real_cert || return 2

    acme=$(_acme_bin) || {
        [[ "$quiet" == "true" ]] || _warn "未安装 acme.sh，无法自动续期"
        return 2
    }

    # 已过期的证书：装 cron 也救不回来，必须重签
    local dl; dl=$(_cert_days_left)
    if [[ -n "$dl" && "$dl" -lt 0 ]]; then
        [[ "$quiet" == "true" ]] || {
            _err "证书已过期 ${dl#-} 天，配置自动续期无意义"
            echo -e "  ${C}请执行「证书管理 → 申请 / 更换证书」重新签发${NC}" >&2
        }
        return 3
    fi
    dir=$(_meta_get acme_dir) || dir=""
    [[ -d "$dir" ]] || dir=$(_acme_match_dir) || dir=""
    if [[ -z "$dir" ]]; then
        [[ "$quiet" == "true" ]] || _warn "当前证书不由 acme.sh 管理，无法自动续期"
        return 2
    fi

    # 1/2. 定时任务：acme.sh 自身续签 + 本脚本兜底巡检
    if check_cmd crontab || { [[ "$quiet" != "true" ]] && _ensure_crontab; }; then
        if ! crontab -l 2>/dev/null | grep -q 'acme.sh'; then
            "$acme" --install-cronjob >/dev/null 2>&1
            if crontab -l 2>/dev/null | grep -q 'acme.sh'; then
                fixed=1
                [[ "$quiet" == "true" ]] || _ok "已补装 acme.sh 续期定时任务"
            else
                [[ "$quiet" == "true" ]] || _err "acme.sh 定时任务安装失败，请手动执行: $acme --install-cronjob"
                cron_ok=false
            fi
        fi
        if ! crontab -l 2>/dev/null | grep -q 'vless-cert-check'; then
            install_cert_cron >/dev/null 2>&1
            if crontab -l 2>/dev/null | grep -q 'vless-cert-check'; then
                fixed=1
                [[ "$quiet" == "true" ]] || _ok "已补装证书巡检任务 (每天 04:10)"
            else
                cron_ok=false
            fi
        fi
    else
        cron_ok=false
        [[ "$quiet" == "true" ]] || _err "系统缺少 crontab，无法安装自动续期任务"
    fi

    # 3. reloadcmd 与安装路径：续期后必须把新证书写到 $SSL_DIR 并重启服务
    local rc fc dom ecc
    rc=$(_acme_conf_get "$dir" Le_ReloadCmd) || rc=""
    fc=$(_acme_conf_get "$dir" Le_RealFullChainPath) || fc=""
    dom=$(_acme_conf_get "$dir" Le_Domain) || dom=$(_meta_get acme_domain)
    ecc=$( [[ "$dir" == *_ecc ]] && echo true || echo false )
    if [[ -z "$rc" || "$fc" != "$SSL_DIR/server.crt" ]]; then
        [[ "$quiet" == "true" ]] || _info "修复续期后的安装路径与重载动作..."
        if _install_cert_files "$dom" "$ecc"; then
            _meta_set acme_dir "$dir"; _meta_set ecc "$ecc"
            fixed=1
            [[ "$quiet" == "true" ]] || _ok "已挂上续期后自动重启 ${SB_SVC} 的动作"
        else
            [[ "$quiet" == "true" ]] || _err "修复失败，请手动执行一次证书申请"
            return 2
        fi
    fi

    # 4. DNS 验证方式需要凭据在位
    if [[ "$(_meta_get method)" == dns_* ]] && [[ ! -f "$DNS_API_CONF" ]]; then
        _import_dns_creds_from_acme >/dev/null 2>&1 || {
            [[ "$quiet" == "true" ]] || _warn "缺少 DNS API 凭据，续期会失败，请在证书管理中录入"
            return 2
        }
        fixed=1
    fi

    [[ "$cron_ok" != "true" ]] && return 2
    [[ "$fixed" == "1" ]] && return 1
    return 0
}

#═══════════════════════════════════════════════════════════════════════════════
# 申请向导（Cloudflare DNS API 为主路径）
#═══════════════════════════════════════════════════════════════════════════════
# cert_request_wizard [建议域名] -> 成功后 $SSL_DIR 有可用证书
cert_request_wizard() {
    local suggest="${1:-}" d wc use_wc=false acme_domain extra=""
    install_acme_tool || return 1

    echo "" >&2
    _line
    echo -e "  ${W}申请证书${NC}" >&2
    _line
    local cur_domain=""
    [[ -f "$CFG/cert_domain" ]] && cur_domain=$(cat "$CFG/cert_domain")
    [[ -z "$suggest" ]] && suggest="$cur_domain"
    echo -e "  ${D}示例: node.example.com（子域）或 example.com（主域）${NC}" >&2
    while true; do
        read -rp "  域名${suggest:+ [$suggest]}: " d; d="${d:-$suggest}"
        _is_valid_dns_name "$d" && break
        _err "域名格式无效"
    done

    echo "" >&2
    _line
    echo -e "  ${W}验证方式${NC}" >&2
    _line
    _item "1" "DNS API ${D}(推荐；支持通配符 / NAT / 无需 80 端口 / 橙云可开)${NC}"
    _item "2" "HTTP-01 ${D}(需 80 端口空闲且域名直连本机、关闭橙云)${NC}"
    _item "3" "手动 DNS TXT ${D}(不能自动续期)${NC}"
    _item "0" "取消"
    _line
    local m; read -rp "  请选择 [1]: " m; m="${m:-1}"
    [[ "$m" == "0" ]] && return 2

    if [[ "$m" == "1" ]]; then
        wc=$(_wildcard_of "$d")
        echo "" >&2
        echo -e "  ${W}是否申请通配符证书?${NC}" >&2
        echo -e "  ${D}通配符 ${wc} 可以覆盖该域下所有一级子域，${NC}" >&2
        echo -e "  ${D}以后新增 n2/n3 等节点无需重新签发，多机复用同一张证书${NC}" >&2
        _line
        _item "1" "申请通配符 ${G}${wc}${NC}"
        _item "2" "只申请 ${G}${d}${NC}"
        _item "3" "自定义通配符写法"
        _line
        local wcc; read -rp "  请选择 [1]: " wcc
        case "${wcc:-1}" in
            2) acme_domain="$d" ;;
            3)
                read -rp "  通配符域名 [$wc]: " wc2; wc="${wc2:-$wc}"
                [[ "$wc" == \*.* ]] || { _err "必须以 *. 开头"; return 1; }
                acme_domain="$wc"; use_wc=true ;;
            *) acme_domain="$wc"; use_wc=true ;;
        esac
        if [[ "$use_wc" == "true" ]]; then
            # 通配符不覆盖裸域，需要时一并签发
            local bare="${acme_domain#*.}"
            _ask_yes "是否同时把裸域 ${bare} 加入证书?" && extra="$bare"
        fi
        select_ssl_ca
        if [[ "$SSL_CA" == "buypass" && "$use_wc" == "true" ]]; then
            _err "Buypass 不支持通配符证书，请改选 Let's Encrypt 或 ZeroSSL"
            return 1
        fi
        setup_acme_email
        setup_dns_api || return 1
        issue_cert_dns_api "$acme_domain" "$extra" || return 1
    elif [[ "$m" == "2" ]]; then
        select_ssl_ca; setup_acme_email
        issue_cert_http01 "$d" || return 1
    else
        wc=$(_wildcard_of "$d")
        _ask_yes "是否申请通配符 ${wc}?" && d="$wc"
        select_ssl_ca; setup_acme_email
        issue_cert_manual_dns "$d" || return 1
    fi

    verify_cert || return 1
    cert_adopt true >/dev/null 2>&1
    cert_ensure_autorenew
    return 0
}

# 证书续期检查定时任务（acme.sh 自身负责续签，这里做兜底巡检与告警）
install_cert_cron() {
    local acme; acme=$(_acme_bin) || return 0
    "$acme" --install-cronjob >/dev/null 2>&1
    check_cmd crontab || return 0
    local script="$SYSTEM_SCRIPT"
    [[ -x "$script" ]] || script=$(readlink -f "$0")
    local entry="10 4 * * * /bin/bash $script --cert-check >> $CFG/cert.log 2>&1 # vless-cert-check"
    # 先把现有内容读进变量，避免读写同一 spool 造成截断
    local cur; cur=$(crontab -l 2>/dev/null | grep -v "vless-cert-check")
    printf '%s\n%s\n' "$cur" "$entry" | awk 'NF' | crontab -
    _ok "已安装证书巡检任务 (每天 04:10)"
}

# --cert-check 入口：剩余天数不足时尝试续期并重启服务
cert_check_and_renew() {
    local days acme d
    [[ -s "$SSL_DIR/server.crt" ]] || { echo "[$(date '+%F %T')] 无证书，跳过"; return 0; }
    _is_real_cert || { echo "[$(date '+%F %T')] 自签证书，跳过"; return 0; }
    days=$(_cert_days_left)
    echo "[$(date '+%F %T')] 证书剩余 ${days} 天"
    [[ -z "$days" ]] && return 0
    if [[ "$days" -gt 20 ]]; then return 0; fi
    acme=$(_acme_bin) || { echo "acme.sh 缺失，无法续期"; return 1; }
    d=$(_meta_get acme_domain) || d=$(cat "$CFG/cert_domain" 2>/dev/null)
    [[ -z "$d" ]] && { echo "未记录 acme 域名，无法续期"; return 1; }
    _load_dns_creds >/dev/null 2>&1
    echo "尝试续期: $d"
    local ecc; ecc=$(_meta_get ecc) || ecc=true
    if [[ "$ecc" == "true" ]]; then "$acme" --renew -d "$d" --ecc >>"$CFG/cert.log" 2>&1
    else "$acme" --renew -d "$d" >>"$CFG/cert.log" 2>&1; fi
    _install_cert_files "$d" "$ecc" >/dev/null 2>&1
    days=$(_cert_days_left)
    echo "续期后剩余 ${days} 天"
    svc restart "$SB_SVC" >/dev/null 2>&1 || true
}

#═══════════════════════════════════════════════════════════════════════════════
# 统一证书入口：安装向导中被需要证书的协议调用
# setup_cert <协议> [require_real=true|false]
# 成功后设置 CERT_DOMAIN（本协议的 SNI）与 CERT_MODE
#═══════════════════════════════════════════════════════════════════════════════
setup_cert() {
    local proto="$1" require_real="${2:-false}"
    CERT_DOMAIN=""; CERT_MODE=""
    mkdir -p "$SSL_DIR"; chmod 700 "$SSL_DIR" 2>/dev/null

    while true; do
        local have_real=false days="" ca meta_domain
        _is_real_cert && have_real=true
        days=$(_cert_days_left 2>/dev/null)
        ca=$(_meta_get ca) || ca=""
        meta_domain=$(_meta_get acme_domain) || meta_domain=""

        echo "" >&2
        _dline
        echo -e "  ${W}TLS 证书 - $(get_protocol_name "$proto")${NC}" >&2
        _dline
        if [[ -s "$SSL_DIR/server.crt" ]]; then
            if [[ "$have_real" == "true" ]]; then
                echo -e "  当前证书: ${G}$(_cert_names | tr '\n' ' ')${NC}" >&2
                echo -e "  颁发机构: ${G}$(_ca_display "$ca")${NC}   剩余: ${G}${days:-?} 天${NC}" >&2
            else
                echo -e "  当前证书: ${Y}自签${NC} ${D}($(_cert_names | tr '\n' ' '))${NC}" >&2
            fi
        else
            echo -e "  ${D}尚无证书${NC}" >&2
        fi
        _line
        if [[ "$have_real" == "true" ]]; then
            _item "1" "复用现有证书 ${D}(推荐)${NC}"
        else
            _item "1" "复用现有证书文件 ${D}(需已存在)${NC}"
        fi
        _item "2" "申请证书 ${D}(Cloudflare DNS API / HTTP-01 / 手动 TXT)${NC}"
        _item "3" "导入自己的证书文件"
        if [[ "$require_real" == "true" ]]; then
            echo -e "  ${D}(本协议客户端强制校验证书，不提供自签选项)${NC}" >&2
        else
            _item "4" "使用自签证书 ${D}(客户端需勾选跳过证书验证)${NC}"
        fi
        _item "0" "取消安装"
        _line
        local c; read -rp "  请选择 [1]: " c; c="${c:-1}"

        case "$c" in
            1)
                if [[ ! -s "$SSL_DIR/server.crt" || ! -s "$SSL_DIR/server.key" ]]; then
                    _warn "没有可复用的证书，请先申请或导入"; continue
                fi
                if [[ "$require_real" == "true" && "$have_real" != "true" ]]; then
                    _warn "现有证书为自签，本协议要求真实证书"; continue
                fi
                verify_cert || { _ask_yes "证书校验未通过，仍要使用?" || continue; }
                ;;
            2)
                cert_request_wizard "$meta_domain"
                local rc=$?
                [[ "$rc" == "2" ]] && continue
                [[ "$rc" != "0" ]] && { _warn "证书申请未完成"; continue; }
                have_real=true
                ;;
            3)
                _cert_import_files || continue
                _is_real_cert && have_real=true
                if [[ "$require_real" == "true" && "$have_real" != "true" ]]; then
                    _warn "导入的是自签证书，本协议要求真实证书"; continue
                fi
                ;;
            4)
                [[ "$require_real" == "true" ]] && { _err "无效选择"; continue; }
                local sd defsd
                defsd=$(gen_sni)
                read -rp "  自签证书的伪装域名 [${defsd}]: " sd; sd="${sd:-$defsd}"
                _is_valid_dns_name "$sd" || { _err "域名无效"; continue; }
                gen_self_cert "$sd" || continue
                CERT_DOMAIN="$sd"; CERT_MODE="self"
                _warn "客户端必须勾选「跳过证书验证 / insecure / allowInsecure」"
                return 0
                ;;
            0) return 2 ;;
            *) _err "无效选择"; continue ;;
        esac

        #── 选择本协议使用的 SNI（通配符证书下可为每个节点用不同子域）─────────
        local names sni def
        names=$(_cert_names)
        def=""
        [[ -f "$CFG/cert_domain" ]] && def=$(cat "$CFG/cert_domain")
        if [[ -z "$def" ]] || ! _cert_covers "$def"; then
            def=$(echo "$names" | grep -v '^\*' | head -1)
            [[ -z "$def" ]] && def="$(echo "$names" | head -1)"
            [[ "$def" == \*.* ]] && def="n1.${def#*.}"
        fi
        echo "" >&2
        _line
        echo -e "  ${W}本协议使用的连接域名 / SNI${NC}" >&2
        echo -e "  ${D}证书覆盖: ${names//$'\n'/ }${NC}" >&2
        if [[ "$names" == *'*'* ]]; then
            echo -e "  ${D}通配符证书可为每个节点使用不同子域（如 n1/n2），只要指向本机即可${NC}" >&2
        fi
        _line
        while true; do
            read -rp "  SNI [${def}]: " sni; sni="${sni:-$def}"
            _is_valid_dns_name "$sni" || { _err "域名格式无效"; continue; }
            if ! _cert_covers "$sni"; then
                _err "证书未覆盖 ${sni}，客户端会证书校验失败"
                _ask_yes "仍要使用该 SNI?" && break
                continue
            fi
            break
        done

        check_domain_dns "$sni" false
        CERT_DOMAIN="$sni"
        CERT_MODE=$( [[ "$have_real" == "true" ]] && echo "real" || echo "existing" )
        echo "$sni" >"$CFG/cert_domain"
        _ok "证书就绪，SNI: ${sni}"
        return 0
    done
}

# 导入外部证书文件
_cert_import_files() {
    mkdir -p "$SSL_DIR"
    _line
    echo -e "  ${W}导入证书${NC}" >&2
    echo -e "  ${D}把证书链与私钥放到下面两个路径后再选本项:${NC}" >&2
    echo -e "    ${C}${SSL_DIR}/server.crt${NC}  ${D}(fullchain，含中间证书)${NC}" >&2
    echo -e "    ${C}${SSL_DIR}/server.key${NC}" >&2
    _line
    if [[ ! -s "$SSL_DIR/server.crt" || ! -s "$SSL_DIR/server.key" ]]; then
        _err "文件不存在或为空"; return 1
    fi
    openssl x509 -in "$SSL_DIR/server.crt" -noout >/dev/null 2>&1 || {
        _err "server.crt 不是有效的 PEM 证书"; return 1; }
    _cert_key_match || { _err "证书与私钥不匹配"; return 1; }
    chmod 600 "$SSL_DIR/server.key"; chmod 644 "$SSL_DIR/server.crt"
    local d; d=$(_cert_names | head -1)
    _meta_set ca "imported"; _meta_set method "imported"
    _meta_set acme_domain "$d"; _meta_set issued_at "$(date '+%F %T')"
    _ok "证书已导入: $(_cert_names | tr '\n' ' ')"
    _warn "手动导入的证书不会自动续期，请自行维护"
}
#═══════════════════════════════════════════════════════════════════════════════
# 本机 HTTPS 伪装站点（供 REALITY 用自己的域名做握手目标）
#═══════════════════════════════════════════════════════════════════════════════
# 原理：REALITY 会把未通过认证的握手原样转发给 handshake 目标。
# 想用自己的域名，就必须在本机另开一个端口跑真正的 HTTPS 站点（用自己的证书），
# REALITY 监听在别的端口，转发到它 —— 这样探测者看到的是你自己的真实网站，
# 而不会因为指向 REALITY 自己的端口形成死循环。
readonly SITE_PORT_FILE="$CFG/decoy_site_port"
readonly SITE_ROOT="${SONGBOX_SITE_ROOT:-/var/www/decoy}"
readonly SITE_CONF_NAME="vless-decoy.conf"

_nginx_conf_dir() {
    if [[ -d /etc/nginx/http.d ]]; then echo "/etc/nginx/http.d"
    else echo "/etc/nginx/conf.d"; fi
}

decoy_site_port() { [[ -f "$SITE_PORT_FILE" ]] && cat "$SITE_PORT_FILE"; }

# 伪装站是否已在跑（端口有监听 + 能握手）
decoy_site_running() {
    local port; port=$(decoy_site_port) || return 1
    [[ -z "$port" ]] && return 1
    _port_listening "$port"
}

# v2ray-agent 当前提供 9 套静态站。固定到已审计提交并逐包校验 SHA-256，
# 避免跟随 master 变动；仓库内的 3 套原创轻量页继续作为备用。
readonly V2RAY_AGENT_DECOY_COMMIT="89388ca675af39c70e72f9174c1f112b04613703"
readonly V2RAY_AGENT_DECOY_BASE="${SONGBOX_V2RAY_AGENT_ASSET_BASE:-https://raw.githubusercontent.com/mack-a/v2ray-agent/${V2RAY_AGENT_DECOY_COMMIT}/fodder/blog/unable}"
declare -rA DECOY_TPL_NAME=(
    [1]="新手引导" [2]="游戏网站" [3]="个人博客 01" [4]="企业站 01"
    [5]="音乐解锁工具" [6]="mikutap 互动页" [7]="企业站 02"
    [8]="个人博客 02" [9]="404 跳转页"
)
declare -rA DECOY_TPL_SHA256=(
    [1]="a226ca42b854e3cd3585d57bfb9f8c6f09d4d195dbe5fbf41c5358cd7540631b"
    [2]="42e9f76fdf8df0af7a07dc1408a1e3caac7db6691f3ff49aabe38913eb0bbb75"
    [3]="3e8e4835c54e9c3ca4d771db4c2256d5af9dde3d2d19bd2f41364afc9079d75e"
    [4]="6e17ee5a6d8db1e266139694dfacb11ea379dbbfbf2342f3024fd8cd709f0156"
    [5]="faf987332c287e347e67a47f48390966b8377c2f9c66bdcf24a435e99690bb4f"
    [6]="d06c145330f46587a6f8c91c0ba7acdf3a3224bf028d87726f31e88162ee725a"
    [7]="bf0d0e7cc1ecbf9663d326603e9262c7f30c9fcc939c1ace8522b05c92cb376a"
    [8]="01b510bd8efe94ecc9b6c585c87261f849a8ed91f1323e8e1764b6c596de8e68"
    [9]="eb7eb42a7c07c3bfd71c97d6b309fadf22924195e2b84b2ce420766a5c7162ff"
)

readonly SONGBOX_DECOY_TPL_BASE="${SONGBOX_ASSET_RAW_BASE:-https://raw.githubusercontent.com/NeverF1ower/songbox/main/assets/decoy-sites}"
readonly LEGACY_SONGBOX_DECOY_TPL_BASE="https://raw.githubusercontent.com/NeverF1ower/SingsongBox/main/assets/decoy-sites"
declare -rA SONGBOX_DECOY_TPL_NAME=(
    [1]="服务状态页" [2]="产品文档页" [3]="个人作品页"
)
declare -rA SONGBOX_DECOY_TPL_FILE=(
    [1]="status.html" [2]="docs.html" [3]="portfolio.html"
)

# 从 songbox 仓库下载并铺设原创单文件静态模板。
_install_songbox_decoy_template() {
    local n="$1" url base tmp html filename size ok=false
    [[ "$n" == "random" ]] && n=$(( ($(od -An -tu4 -N4 /dev/urandom 2>/dev/null | tr -d ' ') % 3) + 1 ))
    [[ "$n" =~ ^[1-3]$ ]] || { _err "模板编号无效"; return 1; }
    filename="${SONGBOX_DECOY_TPL_FILE[$n]}"
    tmp=$(mktemp -d) || return 1
    html="$tmp/index.html"
    for base in "$SONGBOX_DECOY_TPL_BASE" "$LEGACY_SONGBOX_DECOY_TPL_BASE"; do
        while IFS= read -r url; do
            [[ -z "$url" ]] && continue
            _info "下载 songbox 轻量模板 ${n} (${SONGBOX_DECOY_TPL_NAME[$n]}) ..."
            if curl -fsSL --proto '=https' --connect-timeout 12 --max-time 60 \
               -o "$html" "$url" 2>/dev/null; then
                size=$(stat -c%s "$html" 2>/dev/null || echo 0)
                if (( size >= 256 && size <= 524288 )) &&
                   grep -qiE '<!doctype html|<html([[:space:]>])' "$html"; then
                    ok=true; break 2
                fi
            fi
            : >"$html"
        done < <(_raw_mirrors "${base}/${filename}")
        [[ "$base" == "$SONGBOX_DECOY_TPL_BASE" ]] && {
            _warn "新仓库资源地址不可用，尝试旧仓库兼容地址"
        }
    done
    if [[ "$ok" != "true" ]]; then
        rm -rf "$tmp"
        _err "模板下载或内容校验失败"
        return 1
    fi

    mkdir -p "$SITE_ROOT"
    find "$SITE_ROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
    install -m 644 "$html" "$SITE_ROOT/index.html" || {
        rm -rf "$tmp"; _err "模板写入失败"; return 1
    }
    printf 'songbox:%s\n' "$n" >"$SITE_ROOT/.tpl"
    chmod 644 "$SITE_ROOT/.tpl"
    rm -rf "$tmp"
    _ok "songbox 轻量模板已铺设: ${n} (${SONGBOX_DECOY_TPL_NAME[$n]})"
}

# 下载并安全铺设 v2ray-agent 1-9 模板。压缩包不进入本仓库，避免约 36 MiB
# 的 Git 历史膨胀；来源提交与哈希记录在 assets/decoy-sites/v2ray-agent.sha256。
_install_v2ray_agent_decoy_template() {
    local n="$1" url tmp zip extract size ok=false
    [[ "$n" == "random" ]] && n=$(( ($(od -An -tu4 -N4 /dev/urandom 2>/dev/null | tr -d ' ') % 9) + 1 ))
    [[ "$n" =~ ^[1-9]$ ]] || { _err "v2ray-agent 模板编号无效"; return 1; }
    check_cmd unzip || { _err "缺少 unzip，无法安装完整静态站模板"; return 1; }
    tmp=$(mktemp -d) || return 1
    zip="$tmp/html${n}.zip"; extract="$tmp/extract"
    mkdir -p "$extract"
    while IFS= read -r url; do
        [[ -z "$url" ]] && continue
        _info "下载 v2ray-agent 模板 ${n} (${DECOY_TPL_NAME[$n]}) ..."
        if curl -fsSL --proto '=https' --connect-timeout 15 --max-time 180 \
           -o "$zip" "$url" 2>/dev/null; then
            size=$(stat -c%s "$zip" 2>/dev/null || echo 0)
            if (( size >= 10240 && size <= 33554432 )) &&
               _verify_sha256 "$zip" "${DECOY_TPL_SHA256[$n]}" &&
               _archive_safe "$zip" zip; then
                ok=true; break
            fi
            _warn "模板 ${n} 的大小、SHA-256 或归档结构校验失败"
        fi
        : >"$zip"
    done < <(_raw_mirrors "${V2RAY_AGENT_DECOY_BASE}/html${n}.zip")
    [[ "$ok" == "true" ]] || {
        rm -rf "$tmp"; _err "v2ray-agent 模板 ${n} 下载或校验失败"; return 1; }
    unzip -oq "$zip" -d "$extract" || {
        rm -rf "$tmp"; _err "v2ray-agent 模板解包失败"; return 1; }
    _tree_safe "$extract" || {
        rm -rf "$tmp"; _err "v2ray-agent 模板包含链接或特殊文件"; return 1; }
    [[ -s "$extract/index.html" ]] || {
        rm -rf "$tmp"; _err "v2ray-agent 模板缺少根目录 index.html"; return 1; }
    rm -rf "$extract/__MACOSX" 2>/dev/null
    find "$extract" -name '.DS_Store' -type f -delete 2>/dev/null

    mkdir -p "$SITE_ROOT"
    find "$SITE_ROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
    cp -a "$extract/." "$SITE_ROOT/" || {
        rm -rf "$tmp"; _err "v2ray-agent 模板写入失败"; return 1; }
    printf 'v2ray-agent:%s\n' "$n" >"$SITE_ROOT/.tpl"
    find "$SITE_ROOT" -type d -exec chmod 755 {} + 2>/dev/null
    find "$SITE_ROOT" -type f -exec chmod 644 {} + 2>/dev/null
    rm -rf "$tmp"
    _ok "v2ray-agent 模板已铺设: ${n} (${DECOY_TPL_NAME[$n]})"
}

_decoy_tpl_description() {
    local tpl="$1" n i
    case "$tpl" in
        v2ray-agent:[1-9]) n="${tpl#*:}"; echo "v2ray-agent 模板 ${n} (${DECOY_TPL_NAME[$n]})" ;;
        songbox:[1-3]) n="${tpl#*:}"; echo "songbox 轻量模板 ${n} (${SONGBOX_DECOY_TPL_NAME[$n]})" ;;
        [1-9]) echo "v2ray-agent 旧版模板 ${tpl} (${DECOY_TPL_NAME[$tpl]})" ;;
        *.html)
            for i in 1 2 3; do
                [[ "${SONGBOX_DECOY_TPL_FILE[$i]}" == "$tpl" ]] && {
                    echo "songbox 轻量模板 ${i} (${SONGBOX_DECOY_TPL_NAME[$i]})"; return; }
            done
            echo "未知模板 (${tpl})" ;;
        "") echo "内置极简页" ;;
        *) echo "自定义内容 (${tpl})" ;;
    esac
}

# 选择伪装站内容
_choose_decoy_content() {
    echo "" >&2
    _line
    echo -e "  ${W}伪装站页面${NC}" >&2
    echo -e "  ${D}探测者直连该端口时看到的就是这个网站，越像正常站点越好${NC}" >&2
    _line
    _item "1" "v2ray-agent 完整模板 ${D}(9 套，随机)${NC}"
    _item "2" "v2ray-agent 完整模板 ${D}(手动指定 1-9)${NC}"
    _item "3" "songbox 轻量模板 ${D}(3 套原创单页，随机)${NC}"
    _item "4" "songbox 轻量模板 ${D}(手动指定 1-3)${NC}"
    _item "5" "内置极简页 ${D}(Service Status，体积最小)${NC}"
    _item "6" "保留现有内容 ${D}(${SITE_ROOT})${NC}"
    _line
    local c; read -rp "  请选择 [1]: " c
    case "${c:-1}" in
        2)
            local i
            for i in 1 2 3 4 5 6 7 8 9; do _item "$i" "${DECOY_TPL_NAME[$i]}"; done
            local n; read -rp "  模板编号 [3]: " n
            _install_v2ray_agent_decoy_template "${n:-3}" || _write_decoy_page ;;
        3) _install_songbox_decoy_template random || _write_decoy_page ;;
        4)
            local i
            for i in 1 2 3; do _item "$i" "${SONGBOX_DECOY_TPL_NAME[$i]}"; done
            local n; read -rp "  模板编号 [1]: " n
            _install_songbox_decoy_template "${n:-1}" || _write_decoy_page ;;
        5) rm -f "$SITE_ROOT/.tpl"; find "$SITE_ROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
           _write_decoy_page ;;
        6) [[ -f "$SITE_ROOT/index.html" ]] || { _warn "现有内容为空，改用内置页"; _write_decoy_page; } ;;
        *) _install_v2ray_agent_decoy_template random || _write_decoy_page ;;
    esac
}

# 静态页面：普通的"建设中"页面，避免默认 nginx 欢迎页那种特征
_write_decoy_page() {
    mkdir -p "$SITE_ROOT"
    [[ -f "$SITE_ROOT/index.html" ]] && return 0
    cat >"$SITE_ROOT/index.html" <<'EOFH'
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Service Status</title>
<style>
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
margin:0;display:flex;min-height:100vh;align-items:center;justify-content:center;background:#f6f7f9;color:#24292f}
.card{max-width:520px;padding:40px;background:#fff;border:1px solid #d0d7de;border-radius:8px}
h1{font-size:20px;margin:0 0 12px}p{margin:8px 0;line-height:1.6;color:#57606a;font-size:14px}
</style></head>
<body><div class="card">
<h1>Service Status</h1>
<p>All systems are operational.</p>
<p>This endpoint serves static content only. If you reached this page unexpectedly,
no action is required.</p>
</div></body></html>
EOFH
    chmod 644 "$SITE_ROOT/index.html"
}

# 伪装站端口选择：给出推荐值并做占用校验
# 这个端口就是 REALITY 的 handshake 目标，不能和 REALITY 自身端口相同
_ask_decoy_port() {
    local cur def i port
    cur=$(decoy_site_port)
    def="$cur"
    if [[ -z "$def" ]]; then
        for i in 8443 2096 2087 9443 8080; do
            _port_listening "$i" && continue
            is_internal_port_occupied "$i" >/dev/null && continue
            def="$i"; break
        done
        [[ -z "$def" ]] && def=$(gen_port)
    fi
    echo "" >&2
    _line
    echo -e "  ${W}伪装站端口（= REALITY 握手目标端口）${NC}" >&2
    echo -e "  ${D}REALITY 会把未认证的握手转发到 127.0.0.1:<该端口>${NC}" >&2
    echo -e "  ${D}它必须与 REALITY 监听端口不同，否则自握手死循环${NC}" >&2
    echo -e "  ${D}想让别人直连域名也能看到网站，就选 443；只做握手目标则任意高位端口即可${NC}" >&2
    _line
    echo -e "  ${C}建议: ${G}${def}${NC}${cur:+  ${D}(当前已在用)${NC}}" >&2
    local owner
    while true; do
        read -rp "  端口 [回车用 ${def}]: " port; port="${port:-$def}"
        [[ "$port" == "0" ]] && return 1
        _is_valid_port "$port" || { _err "端口必须为 1-65535"; continue; }
        if [[ -n "$cur" && "$port" == "$cur" ]]; then echo "$port"; return 0; fi
        owner=$(is_internal_port_occupied "$port") && {
            _err "端口 ${port} 已被本脚本的 [${owner}] 占用"; continue; }
        if _port_listening "$port"; then
            _warn "端口 ${port} 已有进程监听"
            _ask_yes "仍要使用（若那是别的网站会被 nginx 抢占）?" || continue
        fi
        echo "$port"; return 0
    done
}

# setup_decoy_site [端口] -> 输出实际使用的端口
# 用 $SSL_DIR 里的真实证书跑一个 HTTPS 站点
# setup_decoy_site [端口] [keep|ask]
#   keep = 保留现有页面内容，只重建 nginx 配置（换端口时用）
setup_decoy_site() {
    local want="${1:-}" content="${2:-ask}" port conf_dir conf
    if [[ ! -s "$SSL_DIR/server.crt" || ! -s "$SSL_DIR/server.key" ]]; then
        _err "还没有可用证书，无法搭建本机 HTTPS 伪装站"
        echo -e "  ${D}请先在「证书管理」里申请证书${NC}" >&2
        return 1
    fi
    if ! _is_real_cert; then
        _warn "当前是自签证书：探测者会看到自签证书，反而更可疑"
        _ask_yes "仍要继续?" || return 1
    fi
    install_nginx || return 1

    port="$want"
    [[ -z "$port" ]] && port=$(_ask_decoy_port)
    [[ -z "$port" ]] && return 1
    _is_valid_port "$port" || { _err "端口无效: $port"; return 1; }

    if [[ "$content" == "ask" ]]; then
        _choose_decoy_content
    else
        [[ -f "$SITE_ROOT/index.html" ]] || _write_decoy_page
    fi
    conf_dir=$(_nginx_conf_dir); mkdir -p "$conf_dir"
    conf="${conf_dir}/${SITE_CONF_NAME}"

    local v6=""
    _has_ipv6 && v6="    listen [::]:${port} ssl;"
    cat >"$conf" <<EOF
# REALITY 握手目标用的本机 HTTPS 站点（由 songbox 生成）
server {
    listen 127.0.0.1:${port} ssl;
    listen ${port} ssl;
${v6}
    http2 on;
    server_name _;

    ssl_certificate     ${SSL_DIR}/server.crt;
    ssl_certificate_key ${SSL_DIR}/server.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache   shared:DECOY:10m;

    root ${SITE_ROOT};
    index index.html;
    server_tokens off;
    location / { try_files \$uri \$uri/ =404; }
}
EOF
    if ! nginx -t >/dev/null 2>&1; then
        # 老版本 nginx 不认独立的 http2 指令，退回旧写法
        sed -i 's/^    http2 on;$//' "$conf"
        sed -i "s/listen ${port} ssl;/listen ${port} ssl http2;/" "$conf"
        if ! nginx -t >/dev/null 2>&1; then
            _err "Nginx 配置校验失败"
            nginx -t 2>&1 | sed 's/^/    /' >&2
            rm -f "$conf"
            return 1
        fi
    fi
    svc enable nginx >/dev/null 2>&1
    svc restart nginx >/dev/null 2>&1 || nginx -s reload >/dev/null 2>&1
    allow_port "$port" tcp >/dev/null 2>&1
    echo "$port" >"$SITE_PORT_FILE"
    _ok "本机 HTTPS 伪装站已就绪: 端口 ${port}"
    echo "$port"
}

remove_decoy_site() {
    local conf_dir; conf_dir=$(_nginx_conf_dir)
    rm -f "${conf_dir}/${SITE_CONF_NAME}" /etc/nginx/conf.d/${SITE_CONF_NAME} \
          /etc/nginx/http.d/${SITE_CONF_NAME} 2>/dev/null
    rm -f "$SITE_PORT_FILE"
    nginx -t >/dev/null 2>&1 && { nginx -s reload >/dev/null 2>&1 || svc restart nginx >/dev/null 2>&1; }
    _ok "已移除本机 HTTPS 伪装站"
}

# check_local_tls_site <域名> <端口>
# 校验：本机该端口确实在跑 TLS 1.3 站点，且证书覆盖该域名、未过期
check_local_tls_site() {
    local d="$1" port="$2" out proto vrc
    check_cmd openssl || { _warn "缺少 openssl，跳过本机站点探测"; return 0; }
    if ! _port_listening "$port"; then
        _err "本机 ${port} 端口没有监听，握手目标不可用"
        return 1
    fi
    _info "探测本机 HTTPS 站点 127.0.0.1:${port} (SNI=${d}) ..."
    out=$(timeout 10 openssl s_client -connect "127.0.0.1:${port}" -servername "$d" \
            -tls1_3 </dev/null 2>&1)
    if [[ -z "$out" ]] || echo "$out" | grep -qiE 'connect:errno|Connection refused'; then
        _err "无法连接 127.0.0.1:${port}"
        return 1
    fi
    if echo "$out" | grep -qiE 'wrong version number|unsupported protocol|no protocols available'; then
        _err "本机站点不支持 TLS 1.3，REALITY 需要 TLS 1.3"
        return 1
    fi
    proto=$(echo "$out" | grep -oE 'TLSv1\.[0-9]' | head -1)
    if [[ "$proto" != "TLSv1.3" ]]; then
        _err "本机站点协商到 ${proto:-未知}，需要 TLS 1.3"
        return 1
    fi
    if ! _cert_covers "$d"; then
        _err "本机证书未覆盖 ${d}"
        echo -e "  ${D}证书包含: $(_cert_names | tr '\n' ' ')${NC}" >&2
        return 1
    fi
    local dl; dl=$(_cert_days_left)
    if [[ -n "$dl" && "$dl" -lt 0 ]]; then
        _err "本机证书已过期 ${dl#-} 天，探测者会看到过期证书，反而暴露"
        return 1
    fi
    _ok "本机 HTTPS 站点可用 (TLS 1.3, 证书覆盖 ${d}, 剩余 ${dl:-?} 天)"
    return 0
}

#═══════════════════════════════════════════════════════════════════════════════
# 伪装目标选择（借用第三方 / 用自己的域名）
# 成功后设置：HS_SNI / HS_HOST / HS_PORT
#═══════════════════════════════════════════════════════════════════════════════
select_handshake_target() {
    HS_SNI=""; HS_HOST=""; HS_PORT=443
    local def cert_d="" cert_ok=false
    def=$(gen_sni)
    [[ -f "$CFG/cert_domain" ]] && cert_d=$(cat "$CFG/cert_domain")
    if [[ -n "$cert_d" ]] && _is_real_cert && _cert_covers "$cert_d"; then
        local dl; dl=$(_cert_days_left)
        [[ -n "$dl" && "$dl" -ge 0 ]] && cert_ok=true
    fi

    echo "" >&2
    _line
    echo -e "  ${W}伪装域名 / 握手目标${NC}" >&2
    echo -e "  ${D}未通过认证的握手会被原样转发给该目标，探测者看到的是它的证书与页面${NC}" >&2
    _line
    _item "1" "借用第三方大站 (${G}${def}${NC}) ${D}- 抵赖性最好${NC}"
    _item "2" "自定义第三方站点"
    if [[ "$cert_ok" == "true" ]]; then
        _item "3" "用自己的域名 ${G}${cert_d}${NC} + 本机证书 ${D}(需本机 HTTPS 站点)${NC}"
    else
        echo -e "  ${D}3) 用自己的域名 —— 需要先有覆盖该域名且未过期的真实证书${NC}" >&2
    fi
    _item "0" "取消"
    _line
    local ch; read -rp "  请选择 [1]: " ch; ch="${ch:-1}"

    case "$ch" in
        1) HS_SNI="$def"; HS_HOST="$def"; HS_PORT=443; return 0 ;;
        2)
            local s
            while true; do
                read -rp "  第三方站点域名 [回车用 ${def}]: " s; s="${s:-$def}"
                _is_valid_dns_name "$s" || { _err "域名格式无效"; continue; }
                if check_reality_dest "$s" 443; then
                    HS_SNI="$s"; HS_HOST="$s"; HS_PORT=443; return 0
                fi
                echo "" >&2
                _item "1" "换一个"; _item "2" "用推荐值 ${def}"; _item "3" "强行使用 ${s}"
                local rc; read -rp "  请选择 [1]: " rc
                case "${rc:-1}" in
                    2) HS_SNI="$def"; HS_HOST="$def"; HS_PORT=443; return 0 ;;
                    3) _warn "已强行使用 ${s}"; HS_SNI="$s"; HS_HOST="$s"; HS_PORT=443; return 0 ;;
                esac
            done ;;
        3)
            [[ "$cert_ok" != "true" ]] && { _err "无效选择"; return 1; }
            echo "" >&2
            _line
            echo -e "  ${Y}用自己的域名做伪装目标 —— 取舍要清楚${NC}" >&2
            echo -e "  ${D}好处: 完全自己可控，不依赖第三方站点的可达性与指纹${NC}" >&2
            echo -e "  ${D}      探测者看到的是有效证书 + 正常网页，本身并不异常${NC}" >&2
            echo -e "  ${D}代价: 该域名与你的代理绑定，封域名即全灭；抵赖性弱于借用大站${NC}" >&2
            echo -e "  ${D}要求: 本机另开一个端口跑真实 HTTPS 站点（脚本可自动搭建）${NC}" >&2
            _line
            local sni
            while true; do
                read -rp "  伪装域名 (须在证书覆盖内) [${cert_d}]: " sni; sni="${sni:-$cert_d}"
                _is_valid_dns_name "$sni" || { _err "域名格式无效"; continue; }
                _cert_covers "$sni" && break
                _err "证书未覆盖 ${sni}"
                echo -e "  ${D}证书包含: $(_cert_names | tr '\n' ' ')${NC}" >&2
            done

            local port reuse_ok=false
            port=$(decoy_site_port)
            if [[ -n "$port" ]] && decoy_site_running && \
               check_local_tls_site "$sni" "$port" >/dev/null 2>&1; then
                reuse_ok=true
            fi

            if [[ "$reuse_ok" == "true" ]]; then
                # 已有伪装站也要给出改端口/换页面的入口，不能默默复用
                local tpl tpl_desc
                tpl=$(cat "$SITE_ROOT/.tpl" 2>/dev/null)
                tpl_desc=$(_decoy_tpl_description "$tpl")
                echo "" >&2
                _line
                echo -e "  ${W}检测到已有本机 HTTPS 伪装站${NC}" >&2
                echo -e "  端口: ${G}${port}${NC}   页面: ${G}${tpl_desc}${NC}" >&2
                echo -e "  ${D}目录: ${SITE_ROOT}${NC}" >&2
                _line
                _item "1" "直接复用 ${D}(端口与页面都不变)${NC}"
                _item "2" "更换伪装站端口"
                _item "3" "更换伪装站页面"
                _item "4" "端口和页面都换"
                _line
                local dc; read -rp "  请选择 [1]: " dc
                case "${dc:-1}" in
                    2)
                        local np; np=$(_ask_decoy_port) || return 1
                        port=$(setup_decoy_site "$np" keep | tail -1)
                        [[ -z "$port" ]] && { _err "伪装站重建失败"; return 1; } ;;
                    3)
                        _choose_decoy_content
                        _ok "页面已更换（端口 ${port} 不变）" ;;
                    4)
                        local np; np=$(_ask_decoy_port) || return 1
                        port=$(setup_decoy_site "$np" ask | tail -1)
                        [[ -z "$port" ]] && { _err "伪装站重建失败"; return 1; } ;;
                    *) _ok "复用已有伪装站 (端口 ${port})" ;;
                esac
                check_local_tls_site "$sni" "$port" || return 1
            else
                echo "" >&2
                echo -e "  ${D}需要在本机搭建一个 HTTPS 站点作为握手目标${NC}" >&2
                port=$(setup_decoy_site "" ask | tail -1)
                [[ -z "$port" ]] && { _err "伪装站搭建失败"; return 1; }
                check_local_tls_site "$sni" "$port" || return 1
            fi
            # 握手目标走回环，避免绕一圈公网、也不受入站防火墙影响
            HS_SNI="$sni"; HS_HOST="127.0.0.1"; HS_PORT="$port"
            echo "" >&2
            echo -e "  伪装域名: ${G}${sni}${NC}" >&2
            echo -e "  握手目标: ${G}127.0.0.1:${port}${NC} ${D}(本机 HTTPS 站点)${NC}" >&2
            _warn "证书到期会让探测者看到过期证书，请确保自动续期正常"
            return 0 ;;
        0) return 1 ;;
        *) _err "无效选择"; return 1 ;;
    esac
}
#═══════════════════════════════════════════════════════════════════════════════
# 网络调优（识别现状优先，默认不覆盖已有配置）
#═══════════════════════════════════════════════════════════════════════════════
# 文件名用 99-zz- 前缀：同一 sysctl.d 目录内按字典序加载，保证晚于常见的
# 99-kejilion-*.conf；Alpine 默认 sysctl 可能不支持 --system，必须直接 -p 应用
# 与 SONGBOX_CFG_DIR 一样，以下覆盖仅用于隔离回归测试。
readonly SYSCTL_CONF="${SONGBOX_TEST_SYSCTL_CONF:-/etc/sysctl.d/99-zz-vless-tuning.conf}"
readonly SYSCTL_LEGACY="${SONGBOX_TEST_SYSCTL_LEGACY:-/etc/sysctl.d/99-bbr-proxy.conf}"
readonly BBR_MODULE_CONF="${SONGBOX_TEST_BBR_MODULE_CONF:-/etc/modules-load.d/99-vless-bbr.conf}"

# 让 Alpine/OpenRC 在重启后继续加载 /etc/sysctl.d/*.conf。
_ensure_sysctl_boot_load() {
    [[ "$DISTRO" == "alpine" ]] || return 0
    if ! rc-update add sysctl boot >/dev/null 2>&1; then
        _warn "无法把 sysctl 服务加入 OpenRC boot，配置已立即应用但重启后可能失效"
        return 1
    fi
}

# 直接把刚生成的文件最后应用。BusyBox sysctl 支持 -p，但不支持 procps-ng 的
# --system；直接 -p 也能确保当前生效值不会再被较早的 kejilion 文件抢回去。
_apply_sysctl_file() {
    local file="$1"
    [[ -r "$file" ]] || { _warn "sysctl 配置不存在或不可读: ${file}"; return 1; }
    _ensure_sysctl_boot_load || true
    if ! sysctl -p "$file" >/dev/null; then
        _warn "sysctl -p ${file} 返回失败，将逐项回读定位未生效参数"
        return 1
    fi
}

# 删除配置后要重新加载系统剩余配置。Alpine 使用其 OpenRC sysctl 服务维护
# /lib、/usr/lib、/etc 与 /run 下的加载顺序；其它发行版继续使用 --system。
_reload_system_sysctl() {
    if [[ "$DISTRO" == "alpine" ]]; then
        _ensure_sysctl_boot_load || true
        if [[ ! -x /etc/init.d/sysctl ]]; then
            _warn "未找到 Alpine OpenRC sysctl 服务，无法自动恢复其余 sysctl 配置"
            return 1
        fi
        rc-service sysctl restart >/dev/null
    else
        sysctl --system >/dev/null
    fi
}

# 列出所有声明过某个 key 的配置文件（不含本脚本自己的）
_sysctl_sources() {
    local key="$1" f esc
    esc=$(echo "$key" | sed 's/\./\\./g')
    for f in /etc/sysctl.conf /etc/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf /run/sysctl.d/*.conf; do
        [[ -f "$f" ]] || continue
        [[ "$f" == "$SYSCTL_CONF" ]] && continue
        grep -qE "^[[:space:]]*${esc}[[:space:]]*=" "$f" 2>/dev/null && echo "$f"
    done
}

# 判断本脚本的配置文件在加载顺序上是否处于最后
_sysctl_loads_last() {
    local last
    last=$(ls /etc/sysctl.d/*.conf 2>/dev/null | sort | tail -1)
    [[ "$last" == "$SYSCTL_CONF" ]]
}

#── BBR 版本识别 ────────────────────────────────────────────────────────────────
# 说明：内核并未导出 BBR 的版本号，v1/v3 在 sysctl 里都叫 "bbr"。
# 这里只能根据内核发行标识与模块信息做推断，并如实标注是推断而非确证。
detect_bbr_flavor() {
    BBR_AVAILABLE=false; BBR_LOADABLE=false; BBR_FLAVOR="未检测到"; BBR_EVIDENCE=""; BBR_ALGORITHM=""
    local avail kr modinfo_out
    avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
    local algorithm
    for algorithm in bbr3 bbr2 bbr; do
        if echo "$avail" | grep -qw "$algorithm"; then
            BBR_AVAILABLE=true; BBR_ALGORITHM="$algorithm"; break
        fi
    done
    if [[ "$BBR_AVAILABLE" != "true" ]]; then
        if command -v modinfo >/dev/null 2>&1 && modinfo tcp_bbr >/dev/null 2>&1; then
            BBR_LOADABLE=true
            BBR_FLAVOR="BBR 模块可加载（当前未启用）"
            BBR_EVIDENCE="modinfo tcp_bbr 成功，但 available_congestion_control 尚无 bbr"
        fi
        return 1
    fi

    kr=$(uname -r)
    modinfo_out=$(modinfo tcp_bbr 2>/dev/null)

    if [[ "$BBR_ALGORITHM" == bbr3 ]]; then
        BBR_FLAVOR="BBRv3 (算法名 bbr3)"; BBR_EVIDENCE="内核提供 bbr3"
    elif [[ "$BBR_ALGORITHM" == bbr2 ]]; then
        BBR_FLAVOR="BBRv2 (算法名 bbr2)"; BBR_EVIDENCE="内核提供 bbr2"
    elif echo "$kr" | grep -qi 'xanmod'; then
        BBR_FLAVOR="BBRv3 (推断: XanMod 内核)"
        BBR_EVIDENCE="内核 ${kr} 为 XanMod，其 6.x 分支自带 BBRv3"
    elif echo "$modinfo_out" | grep -qi 'version'; then
        BBR_FLAVOR="BBR ($(echo "$modinfo_out" | awk '/^version:/{print $2; exit}'))"
        BBR_EVIDENCE="modinfo tcp_bbr 提供了 version 字段"
    elif [[ -z "$modinfo_out" ]]; then
        BBR_FLAVOR="BBR (内核内置，无法判定版本)"
        BBR_EVIDENCE="tcp_bbr 已编入内核，非模块，无 modinfo 可读"
    else
        BBR_FLAVOR="BBR (版本无法判定)"
        BBR_EVIDENCE="内核 ${kr} 仅导出算法名 bbr，无法仅凭版本号判定 BBR 版本"
    fi
    return 0
}

# 只在真正应用配置时加载 BBR 模块；查看状态不会改变系统
_ensure_bbr_ready() {
    detect_bbr_flavor >/dev/null 2>&1 && return 0
    if command -v modprobe >/dev/null 2>&1 && modprobe tcp_bbr >/dev/null 2>&1; then
        mkdir -p "${BBR_MODULE_CONF%/*}"
        printf '%s\n' tcp_bbr >"$BBR_MODULE_CONF"
        detect_bbr_flavor >/dev/null 2>&1 && return 0
    fi
    _err "当前内核没有可用的 BBR：请先安装含 BBR/BBRv3 的内核并重启"
    return 1
}

#── VPS 能力探测 ────────────────────────────────────────────────────────────────
# 找到当前进程所在 cgroup 及其可见父级；兼容 v1/v2、容器命名空间与非标准挂载点。
_tuning_cgroup_dirs() {
    local controller="$1" proc_root="${SONGBOX_TUNING_PROC_ROOT:-/proc}"
    local id controllers cgpath line left right root mount fs opts dir
    while IFS=: read -r id controllers cgpath; do
        [[ "$id" == 0 && -z "$controllers" ]] || [[ ",$controllers," == *",${controller},"* ]] || continue
        while IFS= read -r line; do
            left=${line%% - *}; right=${line#* - }
            read -r fs _ opts <<<"$right"
            [[ "$fs" == cgroup2 && "$id" == 0 ]] ||
                [[ "$fs" == cgroup && ",$opts," == *",${controller},"* ]] || continue
            read -r _ _ _ root mount _ <<<"$left"
            if [[ "$root" != / && ( "$cgpath" == "$root" || "$cgpath" == "$root/"* ) ]]; then
                dir="${mount}${cgpath#"$root"}"
            else
                # cgroup namespace 中的 / 相对于 namespace 根，不一定等于 mountinfo 的宿主 root。
                dir="${mount}${cgpath}"
            fi
            # 有些容器只暴露 namespace 根目录；不跟随含 .. 的宿主路径。
            [[ "/$dir/" == *"/../"* || ! -d "$dir" ]] && dir="$mount"
            dir=${dir%/}
            while [[ "$dir" == "$mount" || "$dir" == "$mount/"* ]]; do
                printf '%s\n' "$dir"
                [[ "$dir" == "$mount" ]] && break
                dir=${dir%/*}
            done
        done <"$proc_root/self/mountinfo"
    done <"$proc_root/self/cgroup"
}

_tuning_cpuset_count() {
    awk -F, '{for(i=1;i<=NF;i++){split($i,r,"-"); n+=(r[2]=="" ? 1 : r[2]-r[1]+1)} print n}' <<<"$1"
}

# Swap 不计入网络内存预算；以宿主 MemTotal、cgroup 硬/软上限的最小值为准。
_detect_tuning_resources() {
    local proc_root="${SONGBOX_TUNING_PROC_ROOT:-/proc}" dir file limit quota period cpus count
    VPS_HOST_MEM_KB=$(awk '/^MemTotal:/{print $2}' "$proc_root/meminfo" 2>/dev/null)
    VPS_MEM_KNOWN=true
    if [[ ! "$VPS_HOST_MEM_KB" =~ ^[0-9]+$ || "$VPS_HOST_MEM_KB" -le 0 ]]; then
        VPS_HOST_MEM_KB=65536; VPS_MEM_KNOWN=false
    fi
    VPS_MEM_KB="$VPS_HOST_MEM_KB"; VPS_RESOURCE_LIMITED=false
    VPS_HOST_CPU_THREADS="$VPS_CPU_THREADS"
    if [[ -r "$proc_root/self/cgroup" && -r "$proc_root/self/mountinfo" ]]; then
        while IFS= read -r dir; do
            for file in memory.max memory.high memory.limit_in_bytes memory.soft_limit_in_bytes; do
                limit=$(cat "$dir/$file" 2>/dev/null)
                # v1 的 19 位 unlimited 哨兵值忽略，不作为宿主内存参与乘法。
                if [[ "$file" == memory.max || "$file" == memory.high ]] && [[ "$limit" == 0 ]]; then
                    VPS_MEM_KB=1024; VPS_RESOURCE_LIMITED=true
                fi
                if [[ "$limit" =~ ^[0-9]+$ && ${#limit} -le 18 ]] && (( limit >= 1024 && limit / 1024 < VPS_MEM_KB )); then
                    VPS_MEM_KB=$(( limit / 1024 )); VPS_RESOURCE_LIMITED=true
                fi
            done
        done < <(_tuning_cgroup_dirs memory)
        while IFS= read -r dir; do
            quota=""; period=""
            if [[ -r "$dir/cpu.max" ]]; then read -r quota period <"$dir/cpu.max"
            else
                quota=$(cat "$dir/cpu.cfs_quota_us" 2>/dev/null)
                period=$(cat "$dir/cpu.cfs_period_us" 2>/dev/null)
            fi
            if [[ "$quota" =~ ^[0-9]+$ && "$period" =~ ^[0-9]+$ ]] && (( quota > 0 && period > 0 )); then
                count=$(( (quota + period - 1) / period ))
                if (( count < VPS_CPU_THREADS )); then VPS_CPU_THREADS="$count"; VPS_RESOURCE_LIMITED=true; fi
            fi
        done < <(_tuning_cgroup_dirs cpu)
        while IFS= read -r dir; do
            cpus=$(cat "$dir/cpuset.cpus.effective" 2>/dev/null || cat "$dir/cpuset.cpus" 2>/dev/null)
            [[ "$cpus" =~ ^[0-9,-]+$ ]] || continue
            count=$(_tuning_cpuset_count "$cpus")
            if (( count > 0 && count < VPS_CPU_THREADS )); then VPS_CPU_THREADS="$count"; VPS_RESOURCE_LIMITED=true; fi
        done < <(_tuning_cgroup_dirs cpuset)
    fi
    VPS_MEM_MB=$(( VPS_MEM_KB / 1024 )); VPS_HOST_MEM_MB=$(( VPS_HOST_MEM_KB / 1024 ))
    (( VPS_MEM_MB > 0 )) || VPS_MEM_MB=1
    VPS_SWAP_MB=$(awk '/^SwapTotal:/{printf "%d",$2/1024}' "$proc_root/meminfo" 2>/dev/null)
    [[ "$VPS_SWAP_MB" =~ ^[0-9]+$ ]] || VPS_SWAP_MB=0
    VPS_PAGE_SIZE=$(getconf PAGESIZE 2>/dev/null)
    [[ "$VPS_PAGE_SIZE" =~ ^[0-9]+$ && "$VPS_PAGE_SIZE" -gt 0 ]] || VPS_PAGE_SIZE=4096
}

_tuning_has_key() {
    [[ -f "${SONGBOX_TUNING_PROC_ROOT:-/proc}/sys/${1//.//}" ]]
}

# 新内核限制 netdev_budget_usecs >= 2 * USEC_PER_SEC / CONFIG_HZ。
# getconf CLK_TCK 是用户态 USER_HZ，不能当成内核 CONFIG_HZ。
# 查看推荐值只读配置；配置不可读时保留当前有效值，避免建议内核拒绝的较小值。
_recommend_netdev_budget_usecs() {
    local wanted="$1" proc_root="${SONGBOX_TUNING_PROC_ROOT:-/proc}"
    local boot_root="${SONGBOX_TUNING_BOOT_ROOT:-/boot}" modules_root="${SONGBOX_TUNING_MODULES_ROOT:-/lib/modules}"
    local release config hz current floor
    release=$(uname -r)
    VPS_KERNEL_HZ=0
    for config in "$proc_root/config.gz" "$boot_root/config-$release" "$modules_root/$release/build/.config"; do
        [[ -r "$config" ]] || continue
        if [[ "$config" == *.gz ]]; then
            hz=$(gzip -cd "$config" 2>/dev/null | awk -F= '/^CONFIG_HZ=[0-9]+$/{print $2}')
        else
            hz=$(awk -F= '/^CONFIG_HZ=[0-9]+$/{print $2}' "$config" 2>/dev/null)
        fi
        if [[ "$hz" =~ ^[0-9]+$ ]] && (( hz > 0 && hz <= 1000000 )); then VPS_KERNEL_HZ="$hz"; break; fi
    done
    if (( VPS_KERNEL_HZ > 0 )); then
        floor=$(( 2000000 / VPS_KERNEL_HZ ))
        RECO_NETDEV_REASON="CONFIG_HZ=${VPS_KERNEL_HZ}，内核时间下限 ${floor}us"
    else
        current=$(sysctl -n net.core.netdev_budget_usecs 2>/dev/null)
        floor=20000
        [[ "$current" =~ ^[0-9]+$ && "$current" -gt 0 ]] && floor="$current"
        RECO_NETDEV_REASON="CONFIG_HZ 未知，保留当前有效时间预算（读取失败则保守使用 20000us）"
    fi
    RECO_NETDEV_USECS="$wanted"
    (( RECO_NETDEV_USECS < floor )) && RECO_NETDEV_USECS="$floor"
    return 0
}

# 只使用本机信息，不依赖外部 IP 查询；global IPv6 必须是网卡上真实存在的地址
detect_vps_capabilities() {
    local cpu_flags max_khz ip4_lines ip6_lines iface speed
    local sys_root="${SONGBOX_TUNING_SYS_ROOT:-/sys}"

    VPS_CPU_MODEL=""
    VPS_CPU_THREADS=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
    [[ "$VPS_CPU_THREADS" =~ ^[0-9]+$ && "$VPS_CPU_THREADS" -gt 0 ]] || VPS_CPU_THREADS=1
    VPS_CPU_CORES=""
    if command -v lscpu >/dev/null 2>&1; then
        VPS_CPU_CORES=$(LC_ALL=C lscpu -p=CORE,SOCKET 2>/dev/null | sed '/^#/d;/^$/d' | sort -u | wc -l | tr -d ' ')
        VPS_CPU_MODEL=$(LC_ALL=C lscpu 2>/dev/null | awk -F: '/^Model name:/{sub(/^[ \t]+/,"",$2); print $2; exit}')
    fi
    [[ "$VPS_CPU_CORES" =~ ^[0-9]+$ && "$VPS_CPU_CORES" -gt 0 ]] || VPS_CPU_CORES="$VPS_CPU_THREADS"
    [[ -n "$VPS_CPU_MODEL" ]] || VPS_CPU_MODEL=$(awk -F: '/^(model name|Hardware|Processor)[[:space:]]*:/{sub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null)
    [[ -n "$VPS_CPU_MODEL" ]] || VPS_CPU_MODEL="未知型号"

    max_khz=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)
    if [[ "$max_khz" =~ ^[0-9]+$ && "$max_khz" -gt 0 ]]; then
        VPS_CPU_MHZ=$(( max_khz / 1000 ))
    else
        VPS_CPU_MHZ=$(awk -F: '/cpu MHz[[:space:]]*:/{gsub(/^[ \t]+/,"",$2); printf "%.0f",$2; exit}' /proc/cpuinfo 2>/dev/null)
    fi
    [[ "$VPS_CPU_MHZ" =~ ^[0-9]+$ ]] || VPS_CPU_MHZ=0
    cpu_flags=$(awk -F: '/^(flags|Features)[[:space:]]*:/{print tolower($2); exit}' /proc/cpuinfo 2>/dev/null)
    VPS_CPU_CRYPTO="无 AES 指令标识"
    echo " $cpu_flags " | grep -qwE 'aes|aesni' && VPS_CPU_CRYPTO="支持 AES 指令"

    _detect_tuning_resources
    VPS_ARCH=$(uname -m 2>/dev/null || echo unknown)
    VPS_VIRT=$(systemd-detect-virt 2>/dev/null || true)
    [[ -n "$VPS_VIRT" && "$VPS_VIRT" != "none" ]] || VPS_VIRT=$(LC_ALL=C lscpu 2>/dev/null | awk -F: '/^Hypervisor vendor:/{sub(/^[ \t]+/,"",$2); print $2; exit}')
    [[ -n "$VPS_VIRT" ]] || VPS_VIRT="未识别/裸机"

    VPS_IPV4_ADDRS=""; VPS_IPV6_ADDRS=""; VPS_IPV6_IFACES=""
    VPS_IPV4_DEFAULT_IF=""; VPS_IPV6_DEFAULT_IF=""; VPS_HAS_IPV4=false; VPS_HAS_IPV6=false
    VPS_IPV4_DEFAULT=false; VPS_IPV6_DEFAULT=false
    if command -v ip >/dev/null 2>&1; then
        ip4_lines=$(ip -4 -o addr show scope global 2>/dev/null | awk '$4 !~ /^127\./ {sub(/@.*/,"",$2); print $2, $4}')
        ip6_lines=$(ip -6 -o addr show scope global 2>/dev/null | awk '$4 !~ /^fe80:/ && $0 !~ / tentative| dadfailed/ {sub(/@.*/,"",$2); print $2, $4}')
        VPS_IPV4_ADDRS=$(echo "$ip4_lines" | awk 'NF{print $2}' | paste -sd, -)
        VPS_IPV6_ADDRS=$(echo "$ip6_lines" | awk 'NF{print $2}' | paste -sd, -)
        VPS_IPV6_IFACES=$(echo "$ip6_lines" | awk 'NF{print $1}' | sort -u | paste -sd' ' -)
        VPS_IPV4_DEFAULT_IF=$(ip -4 route show default 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
        VPS_IPV6_DEFAULT_IF=$(ip -6 route show default 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    elif [[ -r /proc/net/if_inet6 ]]; then
        VPS_IPV6_IFACES=$(awk '$4=="00"{print $6}' /proc/net/if_inet6 2>/dev/null | sort -u | paste -sd' ' -)
        [[ -n "$VPS_IPV6_IFACES" ]] && VPS_IPV6_ADDRS="已检测（ip 命令不可用）"
    fi
    [[ -n "$VPS_IPV4_ADDRS" ]] && VPS_HAS_IPV4=true
    [[ -n "$VPS_IPV6_ADDRS" ]] && VPS_HAS_IPV6=true
    [[ -n "$VPS_IPV4_DEFAULT_IF" ]] && VPS_IPV4_DEFAULT=true
    [[ -n "$VPS_IPV6_DEFAULT_IF" ]] && VPS_IPV6_DEFAULT=true

    VPS_PRIMARY_IF="$VPS_IPV6_DEFAULT_IF"
    [[ -n "$VPS_PRIMARY_IF" ]] || VPS_PRIMARY_IF="$VPS_IPV4_DEFAULT_IF"
    VPS_MTU="未知"; VPS_LINK_SPEED="未知"; VPS_LINK_MBPS=0
    if [[ -n "$VPS_PRIMARY_IF" && "$VPS_PRIMARY_IF" =~ ^[[:alnum:]_.-]+$ ]]; then
        [[ -r "${sys_root}/class/net/${VPS_PRIMARY_IF}/mtu" ]] && VPS_MTU=$(cat "${sys_root}/class/net/${VPS_PRIMARY_IF}/mtu" 2>/dev/null)
    fi
    # 双栈可能使用不同出口；取可读取的最快出口速率，不把虚拟网卡速率当作套餐带宽。
    for iface in $(printf '%s\n' "$VPS_IPV4_DEFAULT_IF" "$VPS_IPV6_DEFAULT_IF" | sort -u); do
        [[ "$iface" =~ ^[[:alnum:]_.-]+$ ]] || continue
        speed=$(cat "${sys_root}/class/net/${iface}/speed" 2>/dev/null)
        [[ "$speed" =~ ^[0-9]+$ && "$speed" -gt "$VPS_LINK_MBPS" ]] && VPS_LINK_MBPS="$speed"
    done
    (( VPS_LINK_MBPS > 0 )) && VPS_LINK_SPEED="${VPS_LINK_MBPS}Mbps（链路标称）"

    return 0
}

#── 推荐参数表（按 CPU + 内存 + 双栈/NAT 能力分档）──────────────────────────────
# 不修改防火墙/NAT 拓扑；只优化 BBR、socket、转发和已有 conntrack 的容量
_build_recommended_sysctl() {
    declare -gA REC_SYSCTL=()
    local mem cores rmem somax backlog filemax ctmax budget budget_usecs iface
    local ceiling link_target pages tcp_low tcp_pressure tcp_high udp_low udp_pressure udp_high current
    detect_vps_capabilities
    mem="$VPS_MEM_MB"; cores="$VPS_CPU_THREADS"

    # 上限不是预分配：维持较小初始值，由 TCP 按路径 BDP 自动增长。
    if (( mem < 128 )); then
        TIER="微型保护"; rmem=$(( mem * 1048576 / 16 ))
        (( rmem < 262144 )) && rmem=262144
    elif (( mem < 512 )); then TIER="轻量代理"; rmem=33554432
    elif (( mem < 2048 )); then TIER="均衡代理"; rmem=67108864
    elif (( mem < 8192 )); then TIER="高性能代理"; rmem=134217728
    else TIER="大内存代理"; rmem=268435456
    fi
    # 给 200ms 路径、约 2 倍 BDP 留出空间（不是 RTT 实测）。高速出口可上调，
    # 但不超过有效内存 1/4 与 512MiB；速率未知时保留内存档位。
    if (( mem >= 128 )); then
        ceiling=$(( mem * 1048576 / 4 ))
        (( ceiling > 536870912 )) && ceiling=536870912
        link_target=$(( ${VPS_LINK_MBPS:-0} * 50000 ))
        while (( rmem < link_target && rmem < ceiling )); do rmem=$(( rmem * 2 )); done
        (( rmem > ceiling )) && rmem="$ceiling"
        # 保留机器已有的更高缓冲上限，前提是仍在有效内存预算内。
        local key
        for key in net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem; do
            current=$(sysctl -n "$key" 2>/dev/null | awk '{print $NF}')
            [[ "$current" =~ ^[0-9]+$ ]] && (( current > rmem && current <= ceiling )) && rmem="$current"
        done
    fi
    # CPU 决定单次软中断工作量，内存限制突发队列和连接元数据的容量。
    somax=$(( mem * 16 )); backlog=$(( cores * 4096 ))
    (( somax < 1024 )) && somax=1024
    (( somax > 65536 )) && somax=65536
    (( backlog > somax )) && backlog="$somax"
    budget=$(( 300 + (cores - 1) * 100 )); (( budget > 1200 )) && budget=1200
    budget_usecs=$(( 2000 + (cores - 1) * 500 )); (( budget_usecs > 8000 )) && budget_usecs=8000
    _recommend_netdev_budget_usecs "$budget_usecs"
    budget_usecs="$RECO_NETDEV_USECS"
    filemax=$(( mem * 1024 )); (( filemax < 65536 )) && filemax=65536
    (( filemax > 4194304 )) && filemax=4194304
    current=$(sysctl -n fs.file-max 2>/dev/null)
    [[ "$current" =~ ^[0-9]+$ ]] && (( current > filemax )) && filemax="$current"
    # 按每连接约 1KiB 的预算预留 1/16 内存，CPU 不再强行抬高小内存 NAT 容量。
    ctmax=$(( mem * 64 ))
    [[ $ctmax -lt 1024 ]] && ctmax=1024
    [[ $ctmax -gt 1048576 ]] && ctmax=1048576
    current=$(sysctl -n net.netfilter.nf_conntrack_count 2>/dev/null)
    if [[ "$current" =~ ^[0-9]+$ ]]; then
        current=$(( current + current / 4 + 1024 ))
        (( current > ctmax )) && ctmax="$current"
    fi
    pages=$(( VPS_MEM_KB * 1024 / VPS_PAGE_SIZE ))
    tcp_low=$(( pages / 8 )); tcp_pressure=$(( pages / 4 )); tcp_high=$(( pages / 2 ))
    udp_low=$(( pages / 32 )); udp_pressure=$(( pages / 16 )); udp_high=$(( pages / 8 ))

    REC_SYSCTL[net.core.default_qdisc]="fq"
    detect_bbr_flavor >/dev/null 2>&1 && REC_SYSCTL[net.ipv4.tcp_congestion_control]="$BBR_ALGORITHM"
    REC_SYSCTL[net.core.rmem_max]="$rmem"
    REC_SYSCTL[net.core.wmem_max]="$rmem"
    REC_SYSCTL[net.core.rmem_default]="131072"
    REC_SYSCTL[net.core.wmem_default]="65536"
    REC_SYSCTL[net.ipv4.tcp_rmem]="4096 131072 $rmem"
    REC_SYSCTL[net.ipv4.tcp_wmem]="4096 65536 $rmem"
    REC_SYSCTL[net.ipv4.tcp_moderate_rcvbuf]="1"
    REC_SYSCTL[net.ipv4.tcp_window_scaling]="1"
    REC_SYSCTL[net.ipv4.tcp_sack]="1"
    REC_SYSCTL[net.ipv4.tcp_mem]="$tcp_low $tcp_pressure $tcp_high"
    REC_SYSCTL[net.ipv4.udp_mem]="$udp_low $udp_pressure $udp_high"
    REC_SYSCTL[net.core.somaxconn]="$somax"
    REC_SYSCTL[net.core.netdev_max_backlog]="$backlog"
    REC_SYSCTL[net.ipv4.tcp_max_syn_backlog]="$somax"
    REC_SYSCTL[net.ipv4.tcp_slow_start_after_idle]="0"
    REC_SYSCTL[net.ipv4.tcp_fin_timeout]="15"
    REC_SYSCTL[net.ipv4.tcp_mtu_probing]="1"
    REC_SYSCTL[net.ipv4.ip_local_port_range]="1024 65535"
    REC_SYSCTL[net.ipv4.tcp_tw_reuse]="1"
    REC_SYSCTL[net.ipv4.tcp_keepalive_time]="600"
    REC_SYSCTL[net.ipv4.tcp_keepalive_intvl]="30"
    REC_SYSCTL[net.ipv4.tcp_keepalive_probes]="3"
    REC_SYSCTL[fs.file-max]="$filemax"
    _tuning_has_key net.core.netdev_budget && REC_SYSCTL[net.core.netdev_budget]="$budget"
    _tuning_has_key net.core.netdev_budget_usecs && REC_SYSCTL[net.core.netdev_budget_usecs]="$budget_usecs"
    # 固定 128KiB 会限制未发送队列，增加高速代理唤醒；恢复由 socket/内核控制。
    _tuning_has_key net.ipv4.tcp_notsent_lowat && REC_SYSCTL[net.ipv4.tcp_notsent_lowat]="4294967295"
    _tuning_has_key net.ipv4.tcp_syncookies && REC_SYSCTL[net.ipv4.tcp_syncookies]="1"
    # QUIC(hy2/TUIC) 吞吐取决于 UDP socket 缓冲，与 BBR 无关
    REC_SYSCTL[net.ipv4.udp_rmem_min]="8192"
    REC_SYSCTL[net.ipv4.udp_wmem_min]="8192"
    REC_SYSCTL[net.core.optmem_max]="65536"
    _tuning_has_key net.ipv4.tcp_fastopen && REC_SYSCTL[net.ipv4.tcp_fastopen]="3"

    # IPv4 NAT/转发：不创建 MASQUERADE/DNAT 规则，只准备内核转发与安全边界
    if [[ "$VPS_HAS_IPV4" == "true" ]]; then
        REC_SYSCTL[net.ipv4.ip_forward]="1"
        REC_SYSCTL[net.ipv4.conf.all.forwarding]="1"
        REC_SYSCTL[net.ipv4.conf.default.forwarding]="1"
        REC_SYSCTL[net.ipv4.conf.all.accept_redirects]="0"
        REC_SYSCTL[net.ipv4.conf.default.accept_redirects]="0"
        REC_SYSCTL[net.ipv4.conf.all.send_redirects]="0"
        REC_SYSCTL[net.ipv4.conf.default.send_redirects]="0"
    fi

    # 开启 IPv6 forwarding 后内核默认不再接受 RA；accept_ra=2 保住 SLAAC 默认路由
    if [[ "$VPS_HAS_IPV6" == "true" ]]; then
        REC_SYSCTL[net.ipv6.conf.all.forwarding]="1"
        REC_SYSCTL[net.ipv6.conf.default.forwarding]="1"
        REC_SYSCTL[net.ipv6.conf.all.accept_ra]="2"
        REC_SYSCTL[net.ipv6.conf.default.accept_ra]="2"
        REC_SYSCTL[net.ipv6.conf.all.accept_redirects]="0"
        REC_SYSCTL[net.ipv6.conf.default.accept_redirects]="0"
        for iface in $VPS_IPV6_IFACES $VPS_IPV6_DEFAULT_IF; do
            [[ "$iface" =~ ^[[:alnum:]_.-]+$ ]] || continue
            # 点式 sysctl key 中，网卡名内的点必须编码成 /（例如 eth0/100）。
            [[ -f "${SONGBOX_TUNING_PROC_ROOT:-/proc}/sys/net/ipv6/conf/${iface}/accept_ra" ]] &&
                REC_SYSCTL["net.ipv6.conf.${iface//./\/}.accept_ra"]="2"
        done
    fi

    if _tuning_has_key net.netfilter.nf_conntrack_max; then
        REC_SYSCTL[net.netfilter.nf_conntrack_max]="$ctmax"
        _tuning_has_key net.netfilter.nf_conntrack_udp_timeout && REC_SYSCTL[net.netfilter.nf_conntrack_udp_timeout]="30"
        _tuning_has_key net.netfilter.nf_conntrack_udp_timeout_stream && REC_SYSCTL[net.netfilter.nf_conntrack_udp_timeout_stream]="120"
    fi
    RECO_MEM="$mem"; RECO_CTMAX="$ctmax"; RECO_BUFFER_MB=$(( rmem / 1048576 ))
}

# net.ipv4.ip_forward 从 0 切到 1 时内核会重置一批 IPv4 参数，必须最先应用
_recommended_keys_apply_order() {
    [[ -n "${REC_SYSCTL[net.ipv4.ip_forward]+x}" ]] && echo net.ipv4.ip_forward
    printf '%s\n' "${!REC_SYSCTL[@]}" | grep -v '^net\.ipv4\.ip_forward$' | sort
}

# 展示当前生效值 / 推荐值 / 来源文件
show_tuning_status() {
    _build_recommended_sysctl
    detect_bbr_flavor
    _line
    echo -e "  ${W}VPS 能力与策略${NC}" >&2
    echo -e "  内核: ${C}$(uname -r)${NC}   架构/虚拟化: ${C}${VPS_ARCH} / ${VPS_VIRT}${NC}" >&2
    echo -e "  CPU : ${C}${VPS_CPU_MODEL}${NC}" >&2
    echo -e "        ${C}${VPS_CPU_CORES} 核 / ${VPS_HOST_CPU_THREADS} 检测线程 / ${VPS_CPU_THREADS} 可用线程 / ${VPS_CPU_MHZ:-0}MHz / ${VPS_CPU_CRYPTO}${NC}" >&2
    echo -e "  内存: ${C}${RECO_MEM}MiB（有效） / ${VPS_HOST_MEM_MB}MiB（MemTotal）${NC}   Swap: ${C}${VPS_SWAP_MB}MiB${NC}   策略档位: ${C}${TIER}${NC}" >&2
    [[ "$VPS_RESOURCE_LIMITED" == "true" ]] && echo -e "  ${D}已按 cgroup 内存/CPU 限制收缩资源预算${NC}" >&2
    [[ "$VPS_MEM_KNOWN" == "false" ]] && _warn "无法读取 MemTotal，暂按 64MiB 保护策略处理"
    echo -e "  缓冲: ${C}TCP/UDP 单 socket 上限 ${RECO_BUFFER_MB}MiB${NC}（按需增长，不预分配）；CPU 决定队列预算" >&2
    echo -e "  ${D}TCP 总预算最多有效内存 1/2、UDP 1/8；tcp_mem/udp_mem 单位为 ${VPS_PAGE_SIZE} 字节的页${NC}" >&2
    _tuning_has_key net.core.netdev_budget_usecs && echo -e "  NAPI: ${C}${RECO_NETDEV_USECS}us${NC}（${RECO_NETDEV_REASON}）" >&2
    echo -e "  网卡: ${C}${VPS_PRIMARY_IF:-未检测}${NC}   MTU: ${C}${VPS_MTU}${NC}   链路: ${C}${VPS_LINK_SPEED}${NC}" >&2
    if [[ "$VPS_HAS_IPV4" == "true" ]]; then
        echo -e "  IPv4: ${G}${VPS_IPV4_ADDRS}${NC}   默认路由: $([[ "$VPS_IPV4_DEFAULT" == "true" ]] && echo -e "${G}有${NC}" || echo -e "${Y}无${NC}")" >&2
    else
        echo -e "  IPv4: ${Y}未检测到 global 地址${NC}" >&2
    fi
    if [[ "$VPS_HAS_IPV6" == "true" ]]; then
        echo -e "  IPv6: ${G}${VPS_IPV6_ADDRS}${NC}   默认路由: $([[ "$VPS_IPV6_DEFAULT" == "true" ]] && echo -e "${G}有${NC}" || echo -e "${Y}无${NC}")" >&2
        echo -e "  双栈: ${G}启用 IPv6 forwarding + accept_ra=2（防止 SLAAC 路由丢失）${NC}" >&2
    else
        echo -e "  IPv6: ${D}未检测到 global 地址，不写入 IPv6 转发参数${NC}" >&2
    fi
    if [[ -f /proc/sys/net/netfilter/nf_conntrack_max ]]; then
        echo -e "  NAT : ${C}conntrack $(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0) / $(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)${NC}，推荐上限 ${C}${RECO_CTMAX}${NC}" >&2
    else
        echo -e "  NAT : ${D}nf_conntrack 未加载，仅准备 IP 转发，不创建 NAT 规则${NC}" >&2
    fi
    if [[ "$BBR_AVAILABLE" == "true" ]]; then
        echo -e "  BBR : ${G}${BBR_FLAVOR}${NC}" >&2
        [[ -n "$BBR_EVIDENCE" ]] && echo -e "        ${D}依据: ${BBR_EVIDENCE}${NC}" >&2
        [[ "$BBR_ALGORITHM" == bbr ]] && echo -e "        ${D}注意: 算法名 bbr 不导出版本号，发行标识仅供推断${NC}" >&2
    elif [[ "$BBR_LOADABLE" == "true" ]]; then
        echo -e "  BBR : ${Y}${BBR_FLAVOR}${NC}（应用时自动加载并持久化）" >&2
    else
        echo -e "  BBR : ${R}内核不支持${NC}" >&2
    fi
    echo -e "  拥塞控制: ${G}$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)${NC}   队列: ${G}$(sysctl -n net.core.default_qdisc 2>/dev/null)${NC}" >&2
    echo -e "  ${D}default_qdisc 影响新建队列；已有网卡队列需重启后采用新默认值${NC}" >&2
    echo -e "  ${D}BBR 只作用于 TCP：REALITY/Vision/Trojan/Snell 受益；${NC}" >&2
    echo -e "  ${D}Hysteria2/TUIC 走用户态 QUIC 拥塞控制，不经内核 BBR${NC}" >&2
    _line

    local key cur want src same=0 diff=0 miss=0
    printf "  ${W}%-42s %-22s %s${NC}\n" "参数" "当前生效值" "状态" >&2
    for key in $(printf '%s\n' "${!REC_SYSCTL[@]}" | sort); do
        want="${REC_SYSCTL[$key]}"
        cur=$(sysctl -n "$key" 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/ $//')
        src=$(_sysctl_sources "$key" | head -1)
        if [[ -z "$cur" ]]; then
            printf "  %-42s %-22s ${D}%s${NC}\n" "$key" "(不可用)" "内核无此项" >&2
        elif [[ "$cur" == "$want" ]]; then
            printf "  %-42s %-22s ${G}%s${NC}\n" "$key" "$cur" "已达推荐值" >&2; ((same++))
        elif [[ -n "$src" ]]; then
            printf "  %-42s %-22s ${Y}%s${NC}\n" "$key" "$cur" "由 ${src##*/} 设定" >&2; ((diff++))
        else
            printf "  %-42s %-22s ${C}%s${NC}\n" "$key" "$cur" "推荐 ${want}" >&2; ((miss++))
        fi
    done
    _line
    echo -e "  ${G}${same}${NC} 项已达标   ${Y}${diff}${NC} 项被其它配置文件接管   ${C}${miss}${NC} 项未显式设置" >&2

    # 冲突与加载顺序提示
    local conflicts=() f
    for key in "${!REC_SYSCTL[@]}"; do
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            printf '%s\n' "${conflicts[@]}" | grep -qxF "$f" || conflicts+=("$f")
        done < <(_sysctl_sources "$key")
    done
    if [[ ${#conflicts[@]} -gt 0 ]]; then
        _line
        echo -e "  ${W}其它配置文件也在设置这些参数:${NC}" >&2
        for f in "${conflicts[@]}"; do echo -e "    ${D}${f}${NC}" >&2; done
        if [[ -f "$SYSCTL_CONF" ]] && ! _sysctl_loads_last; then
            _warn "本脚本的 ${SYSCTL_CONF##*/} 不是最后加载，重启后可能被覆盖"
        fi
    fi
    if [[ -f "$SYSCTL_LEGACY" ]]; then
        _warn "检测到旧版遗留 ${SYSCTL_LEGACY##*/}（会被 99-sysctl.conf 覆盖，建议清理）"
    fi
    _line
}

# 只补齐"没被任何文件显式设置"的项，不动已有配置
apply_tuning_missing_only() {
    _ensure_bbr_ready || _warn "保留当前拥塞控制，继续应用缓冲/双栈/NAT 调优"
    _build_recommended_sysctl
    local key want src added=0 skipped=0 lines=""
    for key in $(_recommended_keys_apply_order); do
        want="${REC_SYSCTL[$key]}"
        [[ -z "$(sysctl -n "$key" 2>/dev/null)" ]] && continue   # 内核无此项
        src=$(_sysctl_sources "$key" | head -1)
        if [[ -n "$src" ]]; then
            ((skipped++))
            echo -e "  ${D}跳过 ${key}（已由 ${src##*/} 设定）${NC}" >&2
        else
            lines+="${key} = ${want}"$'\n'
            ((added++))
        fi
    done
    if [[ "$added" -eq 0 ]]; then
        if [[ -f "$SYSCTL_CONF" ]]; then
            rm -f "$SYSCTL_CONF"
            _reload_system_sysctl || _warn "重新加载系统 sysctl 配置失败"
            _ok "其它配置已覆盖全部推荐参数，已清除本脚本的重复配置"
        else
            _ok "没有需要补齐的项，现有配置已覆盖全部推荐参数"
        fi
        return 0
    fi
    {
        echo "# 由 ${SCRIPT_NAME} 生成 - $(date '+%F %T')"
        echo "# VPS: ${VPS_CPU_CORES}C/${VPS_CPU_THREADS}T ${VPS_MEM_MB}MB, 档位: ${TIER}, IPv6: ${VPS_HAS_IPV6}"
        echo "# 仅补齐未被其它配置文件设置的项；文件名 99-zz- 保证最后加载"
        echo "$lines"
    } >"$SYSCTL_CONF"
    if _apply_sysctl_file "$SYSCTL_CONF"; then
        _ok "已补齐 ${added} 项（跳过 ${skipped} 项已有配置）"
    else
        _warn "配置文件已写入，但有参数未能立即应用"
    fi
    _verify_tuning_applied
}

# 完整套用推荐值（会覆盖，先备份）
apply_tuning_full() {
    _build_recommended_sysctl
    _warn "本操作会把全部推荐值写入 ${SYSCTL_CONF}"
    echo -e "  ${D}文件名保证最后加载，因此会覆盖其它文件里的同名项${NC}" >&2
    _ask_yes "确认覆盖?" || return 0
    _ensure_bbr_ready || _warn "保留当前拥塞控制，继续应用缓冲/双栈/NAT 调优"
    _build_recommended_sysctl
    local bk
    bk="/root/sysctl-backup-$(date '+%Y%m%d-%H%M%S').tar.gz"
    local backup_sources=("${SYSCTL_CONF%/*}")
    [[ -f /etc/sysctl.conf ]] && backup_sources+=(/etc/sysctl.conf)
    if ! tar -czf "$bk" "${backup_sources[@]}" 2>/dev/null; then
        _err "原有 sysctl 配置备份失败，未覆盖调优文件"; return 1
    fi
    _ok "原有 sysctl 配置已备份: ${bk}"
    {
        echo "# 由 ${SCRIPT_NAME} 生成 - $(date '+%F %T')   档位: ${TIER}"
        local key
        echo "# VPS: ${VPS_CPU_CORES}C/${VPS_CPU_THREADS}T ${VPS_MEM_MB}MB, IPv6: ${VPS_HAS_IPV6}"
        echo "# ip_forward 必须最先应用，避免内核重置后覆盖后续 IPv4 参数"
        for key in $(_recommended_keys_apply_order); do
            [[ -z "$(sysctl -n "$key" 2>/dev/null)" ]] && continue
            echo "${key} = ${REC_SYSCTL[$key]}"
        done
    } >"$SYSCTL_CONF"
    if _apply_sysctl_file "$SYSCTL_CONF"; then
        _ok "推荐配置已套用（档位: ${TIER}）"
    else
        _warn "推荐配置已写入，但有参数未能立即应用（档位: ${TIER}）"
    fi
    _verify_tuning_applied
}

# 应用后回读实际值，逐项确认是否真的生效（防止被别的文件覆盖而不自知）
_verify_tuning_applied() {
    local key want cur bad=0
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        want=$(grep -F -m1 "${key} = " "$SYSCTL_CONF" | cut -d= -f2- | sed 's/^ *//;s/ *$//')
        cur=$(sysctl -n "$key" 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/ $//')
        if [[ "$cur" != "$want" ]]; then
            [[ "$bad" == "0" ]] && _warn "以下参数写入后实际值仍不符（被其它配置或内核限制覆盖）:"
            echo -e "    ${Y}${key}${NC}: 期望 ${want} / 实际 ${cur}" >&2
            ((bad++))
        fi
    done < <(grep -oE '^[a-zA-Z0-9_./:-]+ = ' "$SYSCTL_CONF" 2>/dev/null | sed 's/ = //')
    [[ "$bad" == "0" ]] && _ok "已回读确认：写入的参数全部生效"
}

remove_tuning() {
    local removed=0
    [[ -f "$SYSCTL_CONF" ]] && { rm -f "$SYSCTL_CONF"; ((removed++)); }
    [[ -f "$BBR_MODULE_CONF" ]] && { rm -f "$BBR_MODULE_CONF"; ((removed++)); }
    if [[ -f "$SYSCTL_LEGACY" ]]; then
        _ask_yes "同时删除旧版遗留的 ${SYSCTL_LEGACY##*/}?" && { rm -f "$SYSCTL_LEGACY"; ((removed++)); }
    fi
    _reload_system_sysctl || _warn "重新加载系统 sysctl 配置失败"
    [[ "$removed" -gt 0 ]] && _ok "已移除 ${removed} 个本脚本写入的配置（BBR 模块和转发状态需重启才完全回到默认）" \
        || _info "没有本脚本写入的配置"
}

network_tuning_menu() {
    while true; do
        _header
        echo -e "  ${W}网络调优${NC}" >&2
        show_tuning_status
        _item "1" "刷新状态"
        _item "2" "按 VPS 能力补齐 BBR/双栈/NAT 参数 ${D}(保留已有值，可能仍低于推荐)${NC}"
        _item "3" "完整套用 VPS 自适应策略 ${D}(推荐；覆盖同名项，先备份)${NC}"
        _item "4" "移除本脚本写入的配置"
        _item "5" "清理旧版遗留文件 ${D}(99-bbr-proxy.conf)${NC}"
        _item "0" "返回"
        _line
        local ch; read -rp "  请选择: " ch
        case "$ch" in
            1) continue ;;
            2) apply_tuning_missing_only; _pause ;;
            3) apply_tuning_full; _pause ;;
            4) remove_tuning; _pause ;;
            5)
                if [[ -f "$SYSCTL_LEGACY" ]]; then
                    rm -f "$SYSCTL_LEGACY"; _reload_system_sysctl || _warn "重新加载系统 sysctl 配置失败"
                    _ok "已删除 ${SYSCTL_LEGACY}"
                else
                    _info "没有遗留文件"
                fi
                _pause ;;
            0) return ;;
            *) _err "无效选择"; sleep 1 ;;
        esac
    done
}

#═══════════════════════════════════════════════════════════════════════════════
# TCP Fast Open（默认关闭的可选项）
#═══════════════════════════════════════════════════════════════════════════════
# 仅对 TCP 类入站有意义；QUIC 协议(hy2/tuic)与 Snell(独立进程)不适用
readonly TFO_PROTOCOLS="vless-reality vless-vision vless-ws vless-ws-notls vmess-ws trojan trojan-ws anytls ss2022 ss-legacy socks naive ss2022-shadowtls"

_tfo_kernel_ready() {
    local v; v=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null)
    [[ -z "$v" ]] && return 2
    (( (v & 2) != 0 ))
}

_tfo_enable_kernel() {
    local v; v=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null) || return 1
    local nv=$(( v | 3 ))
    sysctl -w net.ipv4.tcp_fastopen="$nv" >/dev/null 2>&1 || return 1
    # 单独一个文件只放这一项，不碰用户其它调优
    echo "# TCP Fast Open (服务端+客户端) - 由 ${SCRIPT_NAME} 写入" >/etc/sysctl.d/99-zz-vless-tfo.conf
    echo "net.ipv4.tcp_fastopen = $nv" >>/etc/sysctl.d/99-zz-vless-tfo.conf
    _apply_sysctl_file /etc/sysctl.d/99-zz-vless-tfo.conf || return 1
    _ok "内核 TCP Fast Open 已开启 (tcp_fastopen=$nv)"
}

manage_tfo() {
    local list=() p q core
    for p in $(db_all_protocols); do
        for q in $TFO_PROTOCOLS; do [[ "$p" == "$q" ]] && { list+=("$p"); break; }; done
    done
    _header
    echo -e "  ${W}TCP Fast Open${NC}" >&2
    _line
    echo -e "  ${D}TFO 在握手包里带上数据，省掉一次 RTT；对高延迟链路首字节有改善${NC}" >&2
    echo -e "  ${Y}代价${NC}${D}: TFO cookie 是可指纹的特征，部分中间盒会丢弃带 TFO 的 SYN，${NC}" >&2
    echo -e "  ${D}      表现为间歇性连不上。因此默认关闭，建议先在一个协议上试。${NC}" >&2
    _line
    local kv; kv=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null)
    if [[ -z "$kv" ]]; then
        echo -e "  内核支持: ${R}无 net.ipv4.tcp_fastopen${NC}" >&2
    elif _tfo_kernel_ready; then
        echo -e "  内核支持: ${G}已开启服务端 TFO (tcp_fastopen=${kv})${NC}" >&2
    else
        echo -e "  内核支持: ${Y}未开启服务端位 (tcp_fastopen=${kv}，需含 2)${NC}" >&2
    fi
    _line
    if [[ ${#list[@]} -eq 0 ]]; then
        echo -e "  ${D}没有安装适用 TFO 的 TCP 类协议${NC}" >&2
        _line; _pause; return
    fi
    echo -e "  ${W}各协议当前状态${NC}" >&2
    local i=1 cur
    for p in "${list[@]}"; do
        core=$(proto_core "$p")
        cur=$(_db_q --arg c "$core" --arg p "$p" '[(.[$c][$p] // [])[] | (.tcp_fast_open // "0")] | join(",")')
        local mark="${D}关${NC}"
        [[ "$cur" == *1* ]] && mark="${G}开${NC}"
        _item "$i" "$(get_protocol_name "$p")  ${mark}"
        ((i++))
    done
    _line
    _item "a" "全部开启"
    _item "n" "全部关闭"
    _item "0" "返回"
    _line
    local ch; read -rp "  选择要切换的协议（或 a/n）: " ch
    [[ "$ch" == "0" || -z "$ch" ]] && return

    local targets=() want
    case "$ch" in
        a|A) targets=("${list[@]}"); want=1 ;;
        n|N) targets=("${list[@]}"); want=0 ;;
        *)
            [[ "$ch" =~ ^[0-9]+$ ]] && (( ch >= 1 && ch <= ${#list[@]} )) || { _err "无效选择"; _pause; return; }
            targets=("${list[$((ch-1))]}")
            core=$(proto_core "${targets[0]}")
            cur=$(db_field "$core" "${targets[0]}" tcp_fast_open)
            [[ "$cur" == "1" ]] && want=0 || want=1 ;;
    esac

    if [[ "$want" == "1" ]]; then
        if ! _tfo_kernel_ready; then
            _warn "内核未开启服务端 TFO，开了协议也不会生效"
            _ask_yes "现在开启内核 TFO?" && _tfo_enable_kernel || { _info "已取消"; _pause; return; }
        fi
    fi

    for p in "${targets[@]}"; do
        core=$(proto_core "$p")
        db_set_inst_field "$core" "$p" all tcp_fast_open "$want"
    done
    reload_config
    _refresh_subscription_files
    _ok "$([[ "$want" == "1" ]] && echo "已开启" || echo "已关闭") TFO: ${targets[*]}"
    [[ "$want" == "1" ]] && _warn "若出现间歇性连接失败，回来这里关掉即可"
    _pause
}
#═══════════════════════════════════════════════════════════════════════════════
# 规则集 (rule-set) 管理
#═══════════════════════════════════════════════════════════════════════════════
_ruleset_urls() {  # tag -> 多个候选 URL
    local tag="$1" repo name
    case "$tag" in
        geosite-*) repo="SagerNet/sing-geosite"; name="$tag" ;;
        geoip-*)   repo="SagerNet/sing-geoip";   name="$tag" ;;
        *) return 1 ;;
    esac
    echo "https://raw.githubusercontent.com/${repo}/rule-set/${name}.srs"
    echo "https://cdn.jsdelivr.net/gh/${repo}@rule-set/${name}.srs"
    echo "https://gh-proxy.com/https://raw.githubusercontent.com/${repo}/rule-set/${name}.srs"
}

_ensure_ruleset() {  # 下载并缓存 .srs，成功返回 0
    local tag="$1" url magic f
    f="$RULESET_DIR/${tag}.srs"
    mkdir -p "$RULESET_DIR"
    if [[ -s "$f" ]] && [[ "$(head -c 3 "$f" 2>/dev/null)" == "SRS" ]]; then return 0; fi
    while IFS= read -r url; do
        [[ -z "$url" ]] && continue
        if curl -fsSL --connect-timeout 8 --max-time 40 -o "${f}.tmp" "$url" 2>/dev/null; then
            magic=$(head -c 3 "${f}.tmp" 2>/dev/null)
            if [[ "$magic" == "SRS" ]]; then
                mv "${f}.tmp" "$f"; chmod 644 "$f"; return 0
            fi
        fi
        rm -f "${f}.tmp"
    done < <(_ruleset_urls "$tag")
    return 1
}

sync_all_rulesets() {
    local tags tag ok=0 fail=0
    tags=$(db_routing_rules | jq -r '.[].match' | tr ',' '\n' |
           sed -n 's/^geosite:/geosite-/p;s/^geoip:/geoip-/p;/^geosite-/p;/^geoip-/p' | sort -u)
    tags="$tags
geosite-cn
geoip-cn"
    tags=$(printf '%s\n' "$tags" | sed '/^$/d' | sort -u)
    [[ -z "$tags" ]] && { _info "无需下载规则集"; return 0; }
    _info "同步规则集（首次可能耗时 30-120 秒）..."
    while IFS= read -r tag; do
        [[ -z "$tag" ]] && continue
        rm -f "$RULESET_DIR/${tag}.srs"
        if _ensure_ruleset "$tag"; then echo -e "    ${G}✓${NC} $tag" >&2; ((ok++))
        else echo -e "    ${R}✗${NC} $tag" >&2; ((fail++)); fi
    done <<<"$tags"
    _ok "规则集同步完成 (成功 $ok / 失败 $fail)"
}

#═══════════════════════════════════════════════════════════════════════════════
# Sing-box 用户数组生成
#═══════════════════════════════════════════════════════════════════════════════
# _sb_users <proto> <instance_json>
_sb_users() {
    local proto="$1" cfg="$2"
    local raw
    raw=$(echo "$cfg" | jq -c '[(.users // [])[] | select((.enabled // true) == true)]')
    if [[ "$raw" == "[]" || -z "$raw" ]]; then
        # 无用户列表 -> 使用实例自身凭证构造回落用户
        # socks / naive 的用户名必须取实例里的 username，否则会变成 "default" 而与客户端不符
        local secret fbname
        secret=$(echo "$cfg" | jq -r '.uuid // .password // .psk // empty')
        [[ -z "$secret" ]] && { echo "[]"; return; }
        fbname=$(echo "$cfg" | jq -r '.username // empty')
        [[ -z "$fbname" ]] && fbname="default"
        raw=$(jq -nc --arg s "$secret" --arg n "$fbname" '[{name:$n,secret:$s}]')
    fi
    local inst_pw; inst_pw=$(echo "$cfg" | jq -r '.password // empty')

    case "$proto" in
        vless-reality|vless-vision)
            echo "$raw" | jq -c --arg p "$proto" '[.[] | {name:($p+"-"+.name), uuid:.secret, flow:"xtls-rprx-vision"}]' ;;
        vless-ws|vless-ws-notls)
            echo "$raw" | jq -c --arg p "$proto" '[.[] | {name:($p+"-"+.name), uuid:.secret}]' ;;
        vmess-ws)
            echo "$raw" | jq -c --arg p "$proto" '[.[] | {name:($p+"-"+.name), uuid:.secret, alterId:0}]' ;;
        trojan|trojan-ws)
            echo "$raw" | jq -c --arg p "$proto" '[.[] | {name:($p+"-"+.name), password:.secret}]' ;;
        hy2|anytls|ss2022|ss2022-shadowtls)
            echo "$raw" | jq -c --arg p "$proto" '[.[] | {name:($p+"-"+.name), password:.secret}]' ;;
        tuic)
            echo "$raw" | jq -c --arg p "$proto" --arg pw "$inst_pw" \
                '[.[] | {name:($p+"-"+.name), uuid:.secret, password:$pw}]' ;;
        socks|naive)
            echo "$raw" | jq -c '[.[] | {username:.name, password:.secret}]' ;;
        *) echo "[]" ;;
    esac
}

# _sb_tls <sni> [alpn_json] [insecure_ignored]
_sb_tls() {
    local sni="$1" alpn="${2:-}"
    if [[ -n "$alpn" ]]; then
        jq -nc --arg s "$sni" --arg c "$SSL_DIR/server.crt" --arg k "$SSL_DIR/server.key" --argjson a "$alpn" \
            '{enabled:true, server_name:$s, alpn:$a, certificate_path:$c, key_path:$k}'
    else
        jq -nc --arg s "$sni" --arg c "$SSL_DIR/server.crt" --arg k "$SSL_DIR/server.key" \
            '{enabled:true, server_name:$s, certificate_path:$c, key_path:$k}'
    fi
}

# _sb_tls_reality <sni> <private_key> <short_id> [handshake_host] [handshake_port]
# handshake 目标可以是第三方大站（借用门面），也可以是本机自己的 HTTPS 站点
# （此时 host 通常填 127.0.0.1、port 填 nginx 的伪装站端口，避免自握手死循环）
_sb_tls_reality() {
    local sni="$1" pk="$2" sid="$3" hhost="${4:-}" hport="${5:-443}"
    [[ -z "$hhost" ]] && hhost="$sni"
    [[ -z "$hport" || "$hport" == "null" ]] && hport=443
    jq -nc --arg s "$sni" --arg pk "$pk" --arg sid "$sid" \
           --arg hh "$hhost" --argjson hp "$hport" \
        '{enabled:true, server_name:$s,
          reality:{enabled:true, handshake:{server:$hh, server_port:$hp},
                   private_key:$pk, short_id:[$sid]}}'
}

#═══════════════════════════════════════════════════════════════════════════════
# Sing-box inbound 生成
#═══════════════════════════════════════════════════════════════════════════════
# _sb_inbound <proto> <cfg> <tag> <listen>
# ShadowTLS 类协议会输出两个 inbound（JSON 数组）
# 对外入口：在原始入站 JSON 上按需合并 TCP Fast Open
# TFO 只对 TCP 监听有意义，QUIC(hy2/tuic) 跳过；ShadowTLS 合并到对外那个入站
_sb_inbound() {
    local raw
    raw=$(_sb_inbound_raw "$@") || return 1
    if [[ "$(echo "$2" | jq -r '.tcp_fast_open // "0"')" == "1" ]]; then
        case "$1" in
            hy2|tuic) ;;
            *) raw=$(echo "$raw" | jq -c 'if length > 0 then (.[0] += {tcp_fast_open:true}) else . end') ;;
        esac
    fi
    echo "$raw"
}

_sb_inbound_raw() {
    local proto="$1" cfg="$2" tag="$3" listen="$4"
    local port sni path users
    port=$(echo "$cfg" | jq -r '.port')
    sni=$(echo "$cfg" | jq -r '.sni // empty')
    path=$(echo "$cfg" | jq -r '.path // empty')
    users=$(_sb_users "$proto" "$cfg")

    case "$proto" in
        vless-reality)
            local pk sid tls
            pk=$(echo "$cfg" | jq -r '.private_key')
            sid=$(echo "$cfg" | jq -r '.short_id')
            local hhost hport
            hhost=$(echo "$cfg" | jq -r '.handshake_host // empty')
            hport=$(echo "$cfg" | jq -r '.handshake_port // 443')
            tls=$(_sb_tls_reality "$sni" "$pk" "$sid" "$hhost" "$hport")
            jq -nc --arg t "$tag" --arg l "$listen" --argjson p "$port" --argjson u "$users" --argjson tls "$tls" \
                '[{type:"vless", tag:$t, listen:$l, listen_port:$p, users:$u, tls:$tls}]' ;;
        vless-vision)
            local tls; tls=$(_sb_tls "$sni" '["h2","http/1.1"]')
            jq -nc --arg t "$tag" --arg l "$listen" --argjson p "$port" --argjson u "$users" --argjson tls "$tls" \
                '[{type:"vless", tag:$t, listen:$l, listen_port:$p, users:$u, tls:$tls}]' ;;
        vless-ws)
            local tls; tls=$(_sb_tls "$sni" '["http/1.1"]')
            jq -nc --arg t "$tag" --arg l "$listen" --argjson p "$port" --argjson u "$users" \
                --argjson tls "$tls" --arg path "$path" \
                '[{type:"vless", tag:$t, listen:$l, listen_port:$p, users:$u, tls:$tls,
                   transport:{type:"ws", path:$path, early_data_header_name:"Sec-WebSocket-Protocol"}}]' ;;
        vless-ws-notls)
            local host; host=$(echo "$cfg" | jq -r '.host // empty')
            jq -nc --arg t "$tag" --arg l "$listen" --argjson p "$port" --argjson u "$users" --arg path "$path" \
                '[{type:"vless", tag:$t, listen:$l, listen_port:$p, users:$u,
                   transport:{type:"ws", path:$path, early_data_header_name:"Sec-WebSocket-Protocol"}}]' ;;
        vmess-ws)
            local tls; tls=$(_sb_tls "$sni" '["http/1.1"]')
            jq -nc --arg t "$tag" --arg l "$listen" --argjson p "$port" --argjson u "$users" \
                --argjson tls "$tls" --arg path "$path" \
                '[{type:"vmess", tag:$t, listen:$l, listen_port:$p, users:$u, tls:$tls,
                   transport:{type:"ws", path:$path, early_data_header_name:"Sec-WebSocket-Protocol"}}]' ;;
        trojan)
            local tls; tls=$(_sb_tls "$sni" '["h2","http/1.1"]')
            jq -nc --arg t "$tag" --arg l "$listen" --argjson p "$port" --argjson u "$users" --argjson tls "$tls" \
                '[{type:"trojan", tag:$t, listen:$l, listen_port:$p, users:$u, tls:$tls}]' ;;
        trojan-ws)
            local tls; tls=$(_sb_tls "$sni" '["http/1.1"]')
            jq -nc --arg t "$tag" --arg l "$listen" --argjson p "$port" --argjson u "$users" \
                --argjson tls "$tls" --arg path "$path" \
                '[{type:"trojan", tag:$t, listen:$l, listen_port:$p, users:$u, tls:$tls,
                   transport:{type:"ws", path:$path}}]' ;;
        hy2)
            local tls up down; tls=$(_sb_tls "$sni" '["h3"]')
            up=$(echo "$cfg" | jq -r '.up_mbps // 0')
            down=$(echo "$cfg" | jq -r '.down_mbps // 0')
            if [[ "$up" -gt 0 && "$down" -gt 0 ]]; then
                # Brutal: 固定速率拥塞控制。与 ignore_client_bandwidth 互斥，不能同时给
                jq -nc --arg t "$tag" --arg l "$listen" --argjson p "$port" --argjson u "$users" \
                    --argjson up "$up" --argjson down "$down" --argjson tls "$tls" \
                    '[{type:"hysteria2", tag:$t, listen:$l, listen_port:$p, users:$u,
                       up_mbps:$up, down_mbps:$down,
                       tls:$tls, masquerade:"https://www.bing.com"}]'
            else
                jq -nc --arg t "$tag" --arg l "$listen" --argjson p "$port" --argjson u "$users" --argjson tls "$tls" \
                    '[{type:"hysteria2", tag:$t, listen:$l, listen_port:$p, users:$u,
                       ignore_client_bandwidth:true, tls:$tls, masquerade:"https://www.bing.com"}]'
            fi ;;
        tuic)
            local tls; tls=$(_sb_tls "$sni" '["h3"]')
            jq -nc --arg t "$tag" --arg l "$listen" --argjson p "$port" --argjson u "$users" --argjson tls "$tls" \
                '[{type:"tuic", tag:$t, listen:$l, listen_port:$p, users:$u,
                   congestion_control:"bbr", auth_timeout:"3s", zero_rtt_handshake:false, tls:$tls}]' ;;
        anytls)
            local tls; tls=$(_sb_tls "$sni")
            jq -nc --arg t "$tag" --arg l "$listen" --argjson p "$port" --argjson u "$users" --argjson tls "$tls" \
                '[{type:"anytls", tag:$t, listen:$l, listen_port:$p, users:$u, tls:$tls}]' ;;
        ss2022)
            local method server_psk
            method=$(echo "$cfg" | jq -r '.method')
            server_psk=$(echo "$cfg" | jq -r '.password')
            jq -nc --arg t "$tag" --arg l "$listen" --argjson p "$port" --arg m "$method" \
                --arg pw "$server_psk" --argjson u "$users" \
                '[{type:"shadowsocks", tag:$t, listen:$l, listen_port:$p, method:$m, password:$pw, users:$u}]' ;;
        ss-legacy)
            local method pw
            method=$(echo "$cfg" | jq -r '.method')
            pw=$(echo "$cfg" | jq -r '.password')
            jq -nc --arg t "$tag" --arg l "$listen" --argjson p "$port" --arg m "$method" --arg pw "$pw" \
                '[{type:"shadowsocks", tag:$t, listen:$l, listen_port:$p, method:$m, password:$pw}]' ;;
        socks)
            local auth_mode bind
            auth_mode=$(echo "$cfg" | jq -r '.auth_mode // "password"')
            bind=$(echo "$cfg" | jq -r '.listen_addr // empty'); [[ -z "$bind" ]] && bind="$listen"
            if [[ "$auth_mode" == "noauth" ]]; then
                jq -nc --arg t "$tag" --arg l "$bind" --argjson p "$port" \
                    '[{type:"socks", tag:$t, listen:$l, listen_port:$p}]'
            else
                jq -nc --arg t "$tag" --arg l "$bind" --argjson p "$port" --argjson u "$users" \
                    '[{type:"socks", tag:$t, listen:$l, listen_port:$p, users:$u}]'
            fi ;;
        naive)
            local domain tls
            domain=$(echo "$cfg" | jq -r '.domain // .sni')
            tls=$(_sb_tls "$domain" '["h2","http/1.1"]')
            jq -nc --arg t "$tag" --arg l "$listen" --argjson p "$port" --argjson u "$users" --argjson tls "$tls" \
                '[{type:"naive", tag:$t, listen:$l, listen_port:$p, users:$u, tls:$tls}]' ;;
        ss2022-shadowtls)
            # ShadowTLS(v3) 前置 + Shadowsocks 后端（Sing-box 原生 detour）
            local method server_psk stls_pw handshake bport btag
            method=$(echo "$cfg" | jq -r '.method')
            server_psk=$(echo "$cfg" | jq -r '.password')
            stls_pw=$(echo "$cfg" | jq -r '.stls_password')
            handshake=$(echo "$cfg" | jq -r '.sni')
            bport=$(echo "$cfg" | jq -r '.backend_port')
            btag="sbk-${tag}"
            jq -nc --arg t "$tag" --arg bt "$btag" --arg l "$listen" --argjson p "$port" \
                --argjson bp "$bport" --arg spw "$stls_pw" --arg hs "$handshake" \
                --arg m "$method" --arg pw "$server_psk" --argjson u "$users" \
                '[{type:"shadowtls", tag:$t, listen:$l, listen_port:$p, version:3,
                   users:[{name:"stls", password:$spw}],
                   handshake:{server:$hs, server_port:443},
                   strict_mode:true, detour:$bt},
                  {type:"shadowsocks", tag:$bt, listen:"127.0.0.1", listen_port:$bp,
                   method:$m, password:$pw, users:$u}]' ;;
        *) echo "[]" ;;
    esac
}

#═══════════════════════════════════════════════════════════════════════════════
# 出站生成
#═══════════════════════════════════════════════════════════════════════════════
# sing-box 1.12 起 outbound.domain_strategy 被废弃，1.14 已移除。
# 新写法是 outbound.domain_resolver = {server, strategy}，需要 dns.servers 里有对应 tag。
# 这里按实际内核版本选择写法，老内核继续用 legacy 字段。
readonly SB_DNS_TAG="dns-local"
_sb_uses_legacy_domain_strategy() {
    local v="${SONGBOX_SB_VERSION_OVERRIDE:-}"
    [[ -n "$v" ]] || v=$(_sb_version 2>/dev/null)
    [[ -z "$v" ]] && return 1
    _version_ge "$v" "1.12" && return 1
    return 0
}

# _sb_apply_domain_strategy <出站JSON> <策略>
# 策略为空则原样返回
_sb_apply_domain_strategy() {
    local ob="$1" ds="$2"
    [[ -z "$ds" ]] && { echo "$ob"; return 0; }
    if _sb_uses_legacy_domain_strategy; then
        echo "$ob" | jq -c --arg d "$ds" '.domain_strategy = $d'
    else
        echo "$ob" | jq -c --arg d "$ds" --arg srv "$SB_DNS_TAG" \
            '.domain_resolver = {server:$srv, strategy:$d}'
    fi
}

_sb_direct_outbound() {  # tag ip_version
    local tag="$1" iv="$2" ds=""
    case "$iv" in
        ipv4_only)   ds="ipv4_only" ;;
        ipv6_only)   ds="ipv6_only" ;;
        prefer_ipv4) ds="prefer_ipv4" ;;
        prefer_ipv6) ds="prefer_ipv6" ;;
    esac
    _sb_apply_domain_strategy "$(jq -nc --arg t "$tag" '{type:"direct", tag:$t}')" "$ds"
}

# 绑定本机某个 IP 出站的 tag
# 同一个 IP 可能同时存在"严格"和"允许回落"两种规则，回落模式必须单独成 tag，
# 否则后写入的那条会因 tag 重复被丢弃，用户以为设了却没生效
_bind_tag_for() {
    local ip="$1" iv="${2:-}"
    case "$iv" in
        prefer_ipv4|prefer_ipv6) echo "bind-${ip//[.:]/-}-fallback" ;;
        *)                       echo "bind-${ip//[.:]/-}" ;;
    esac
}

# _sb_bind_outbound <tag> <本机IP> [ip_version]
# 关键：绑了 IPv6 源地址却让 sing-box 自由解析，目标若是 v4-only 站点会走
# 默认路由回落到 IPv4，直接暴露本机 v4。所以默认强制 *_only，杜绝回落。
_sb_bind_outbound() {
    local tag="$1" ip="$2" iv="${3:-}" field ds
    if [[ "$ip" == *:* ]]; then
        field="inet6_bind_address"; ds="ipv6_only"
    else
        field="inet4_bind_address"; ds="ipv4_only"
    fi
    # 只有显式选了 prefer_* 才允许回落（会泄露另一族地址，UI 里已警告）
    case "$iv" in
        prefer_ipv4|prefer_ipv6) ds="$iv" ;;
    esac
    _sb_apply_domain_strategy \
        "$(jq -nc --arg t "$tag" --arg f "$field" --arg ip "$ip" '{type:"direct", tag:$t} | .[$f] = $ip')" \
        "$ds"
}

_direct_tag_for() {  # ip_version -> outbound tag
    case "$1" in
        ipv4_only)   echo "direct-ipv4" ;;
        ipv6_only)   echo "direct-ipv6" ;;
        prefer_ipv4) echo "direct-prefer-ipv4" ;;
        prefer_ipv6) echo "direct-prefer-ipv6" ;;
        *)           echo "direct" ;;
    esac
}

# gen_sb_chain_outbound <node_name|node_json> <tag>
gen_sb_chain_outbound() {
    local ref="$1" tag="$2" node
    if [[ "$ref" == \{* ]]; then node="$ref"; else node=$(db_chain_node "$ref"); fi
    [[ -z "$node" || "$node" == "null" ]] && return 1

    local type server port out
    type=$(echo "$node" | jq -r '.type')
    server=$(echo "$node" | jq -r '.server')
    port=$(echo "$node" | jq -r '.port')
    [[ "$port" =~ ^[0-9]+$ ]] || return 1

    local sni insecure
    sni=$(echo "$node" | jq -r '.sni // empty')
    insecure=$(echo "$node" | jq -r '.insecure // "false"')
    [[ -z "$sni" ]] && sni="$server"

    case "$type" in
        socks)
            out=$(jq -nc --arg t "$tag" --arg s "$server" --argjson p "$port" \
                --arg u "$(echo "$node" | jq -r '.username // empty')" \
                --arg w "$(echo "$node" | jq -r '.password // empty')" \
                '{type:"socks", tag:$t, server:$s, server_port:$p, version:"5"}
                 + (if $u != "" then {username:$u, password:$w} else {} end)') ;;
        http)
            out=$(jq -nc --arg t "$tag" --arg s "$server" --argjson p "$port" \
                --arg u "$(echo "$node" | jq -r '.username // empty')" \
                --arg w "$(echo "$node" | jq -r '.password // empty')" \
                --arg sni "$sni" --argjson tls "$([[ "$(echo "$node" | jq -r '.tls // "false"')" == "true" ]] && echo true || echo false)" \
                '{type:"http", tag:$t, server:$s, server_port:$p}
                 + (if $u != "" then {username:$u, password:$w} else {} end)
                 + (if $tls then {tls:{enabled:true, server_name:$sni, insecure:true}} else {} end)') ;;
        shadowsocks)
            out=$(jq -nc --arg t "$tag" --arg s "$server" --argjson p "$port" \
                --arg m "$(echo "$node" | jq -r '.method')" \
                --arg w "$(echo "$node" | jq -r '.password')" \
                '{type:"shadowsocks", tag:$t, server:$s, server_port:$p, method:$m, password:$w}') ;;
        vmess)
            out=$(jq -nc --arg t "$tag" --arg s "$server" --argjson p "$port" \
                --arg id "$(echo "$node" | jq -r '.uuid')" \
                --arg net "$(echo "$node" | jq -r '.network // "tcp"')" \
                --arg path "$(echo "$node" | jq -r '.path // "/"')" \
                --arg host "$(echo "$node" | jq -r '.host // empty')" \
                --arg sni "$sni" --argjson tls "$([[ "$(echo "$node" | jq -r '.tls // "false"')" == "true" ]] && echo true || echo false)" \
                --argjson insec "$([[ "$insecure" == "true" ]] && echo true || echo false)" \
                '{type:"vmess", tag:$t, server:$s, server_port:$p, uuid:$id, security:"auto", alter_id:0}
                 + (if $tls then {tls:{enabled:true, server_name:$sni, insecure:$insec}} else {} end)
                 + (if $net == "ws" then {transport:{type:"ws", path:$path} +
                      (if $host != "" then {headers:{Host:$host}} else {} end)} else {} end)') ;;
        vless)
            local security flow
            security=$(echo "$node" | jq -r '.security // "none"')
            flow=$(echo "$node" | jq -r '.flow // empty')
            local base
            base=$(jq -nc --arg t "$tag" --arg s "$server" --argjson p "$port" \
                --arg id "$(echo "$node" | jq -r '.uuid')" --arg f "$flow" \
                '{type:"vless", tag:$t, server:$s, server_port:$p, uuid:$id}
                 + (if $f != "" then {flow:$f} else {} end)')
            if [[ "$security" == "reality" ]]; then
                base=$(echo "$base" | jq -c --arg sni "$sni" \
                    --arg pbk "$(echo "$node" | jq -r '.public_key // empty')" \
                    --arg sid "$(echo "$node" | jq -r '.short_id // empty')" \
                    --arg fp "$(echo "$node" | jq -r '.fingerprint // "chrome"')" \
                    '.tls = {enabled:true, server_name:$sni, utls:{enabled:true, fingerprint:$fp},
                             reality:{enabled:true, public_key:$pbk, short_id:$sid}}')
            elif [[ "$security" == "tls" ]]; then
                base=$(echo "$base" | jq -c --arg sni "$sni" \
                    --argjson insec "$([[ "$insecure" == "true" ]] && echo true || echo false)" \
                    '.tls = {enabled:true, server_name:$sni, insecure:$insec}')
            fi
            local net; net=$(echo "$node" | jq -r '.network // "tcp"')
            if [[ "$net" == "ws" ]]; then
                base=$(echo "$base" | jq -c --arg path "$(echo "$node" | jq -r '.path // "/"')" \
                    --arg host "$(echo "$node" | jq -r '.host // empty')" \
                    '.transport = ({type:"ws", path:$path} + (if $host != "" then {headers:{Host:$host}} else {} end))')
            fi
            out="$base" ;;
        trojan)
            out=$(jq -nc --arg t "$tag" --arg s "$server" --argjson p "$port" \
                --arg w "$(echo "$node" | jq -r '.password')" --arg sni "$sni" \
                --argjson insec "$([[ "$insecure" == "true" ]] && echo true || echo false)" \
                --arg net "$(echo "$node" | jq -r '.network // "tcp"')" \
                --arg path "$(echo "$node" | jq -r '.path // "/"')" \
                '{type:"trojan", tag:$t, server:$s, server_port:$p, password:$w,
                  tls:{enabled:true, server_name:$sni, insecure:$insec}}
                 + (if $net == "ws" then {transport:{type:"ws", path:$path}} else {} end)') ;;
        hysteria2)
            out=$(jq -nc --arg t "$tag" --arg s "$server" --argjson p "$port" \
                --arg w "$(echo "$node" | jq -r '.password')" --arg sni "$sni" \
                --argjson insec "$([[ "$insecure" == "true" ]] && echo true || echo false)" \
                '{type:"hysteria2", tag:$t, server:$s, server_port:$p, password:$w,
                  tls:{enabled:true, server_name:$sni, insecure:$insec, alpn:["h3"]}}') ;;
        tuic)
            out=$(jq -nc --arg t "$tag" --arg s "$server" --argjson p "$port" \
                --arg id "$(echo "$node" | jq -r '.uuid')" \
                --arg w "$(echo "$node" | jq -r '.password')" --arg sni "$sni" \
                --argjson insec "$([[ "$insecure" == "true" ]] && echo true || echo false)" \
                '{type:"tuic", tag:$t, server:$s, server_port:$p, uuid:$id, password:$w,
                  congestion_control:"bbr", udp_relay_mode:"native",
                  tls:{enabled:true, server_name:$sni, insecure:$insec, alpn:["h3"]}}') ;;
        anytls)
            out=$(jq -nc --arg t "$tag" --arg s "$server" --argjson p "$port" \
                --arg w "$(echo "$node" | jq -r '.password')" --arg sni "$sni" \
                --argjson insec "$([[ "$insecure" == "true" ]] && echo true || echo false)" \
                '{type:"anytls", tag:$t, server:$s, server_port:$p, password:$w,
                  tls:{enabled:true, server_name:$sni, insecure:$insec}}') ;;
        *) return 1 ;;
    esac

    # 经 WARP 出站（双层链式）
    if [[ "$(echo "$node" | jq -r '.via_warp // false')" == "true" ]]; then
        local wm; wm=$(db_get_warp_mode)
        [[ -n "$wm" && "$wm" != "disabled" ]] && out=$(echo "$out" | jq -c '.detour = "warp"')
    fi
    echo "$out"
}

# WARP：输出 {kind:"endpoint"|"outbound", data:{...}}
gen_sb_warp() {
    local mode; mode=$(db_get_warp_mode)
    [[ -z "$mode" || "$mode" == "disabled" ]] && return 1
    if [[ "$mode" == "official" ]]; then
        check_cmd warp-cli || return 1
        jq -nc --argjson p "$WARP_OFFICIAL_PORT" \
            '{kind:"outbound", data:{type:"socks", tag:"warp", server:"127.0.0.1", server_port:$p, version:"5"}}'
        return 0
    fi
    [[ -s "$WARP_CONF_FILE" ]] || return 1
    jq -e . "$WARP_CONF_FILE" >/dev/null 2>&1 || {
        _warn "WARP 配置文件损坏: $WARP_CONF_FILE，已跳过 WARP 出站"; return 1; }
    local pk pub v4 v6 ep ehost eport
    # 一律用 // empty，缺键时得到空串而不是字面量 "null"
    pk=$(jq -r '.private_key // empty' "$WARP_CONF_FILE")
    pub=$(jq -r '.public_key // empty' "$WARP_CONF_FILE")
    v4=$(jq -r '.address_v4 // empty' "$WARP_CONF_FILE")
    v6=$(jq -r '.address_v6 // empty' "$WARP_CONF_FILE")
    ep=$(jq -r '.endpoint // empty' "$WARP_CONF_FILE")
    if [[ -z "$pk" || -z "$pub" || -z "$ep" ]]; then
        _warn "WARP 配置缺少 private_key / public_key / endpoint，已跳过 WARP 出站"
        echo -e "  ${D}可在「分流管理 → WARP 管理」中重新注册${NC}" >&2
        return 1
    fi
    if [[ -z "$v4" && -z "$v6" ]]; then
        _warn "WARP 配置缺少内网地址 (address_v4/address_v6)，已跳过 WARP 出站"
        return 1
    fi
    if [[ "$ep" == \[*\]:* ]]; then
        ehost=$(echo "$ep" | sed 's/^\[\(.*\)\]:.*/\1/'); eport=$(echo "$ep" | sed 's/.*\]://')
    else
        ehost="${ep%%:*}"; eport="${ep##*:}"
    fi
    [[ "$eport" =~ ^[0-9]+$ ]] || eport=2408
    local addrs; addrs=$(jq -nc --arg v4 "$v4" --arg v6 "$v6" '[$v4, $v6] | map(select(. != "" and . != null))')
    jq -nc --arg pk "$pk" --arg pub "$pub" --argjson addr "$addrs" \
        --arg h "$ehost" --argjson p "$eport" \
        '{kind:"endpoint", data:{type:"wireguard", tag:"warp", system:false, mtu:1280,
           address:$addr, private_key:$pk,
           peers:[{address:$h, port:$p, public_key:$pub, allowed_ips:["0.0.0.0/0","::/0"]}]}}'
}

#═══════════════════════════════════════════════════════════════════════════════
# 路由规则生成
#═══════════════════════════════════════════════════════════════════════════════
_rule_outbound_tag() {  # outbound ip_version
    local ob="$1" iv="$2"
    case "$ob" in
        direct)     _direct_tag_for "$iv" ;;
        warp)       echo "warp" ;;
        block)      echo "__reject__" ;;
        bind:*)     _bind_tag_for "${ob#bind:}" "$iv" ;;
        chain:*)    echo "chain-${ob#chain:}" ;;
        balancer:*) echo "balancer-${ob#balancer:}" ;;
        *)          echo "$ob" ;;
    esac
}

# 收集规则/用户所引用的出站，输出去重后的 outbound 标识（direct/warp/chain:x/balancer:x）
_collect_needed_outbounds() {
    db_routing_rules | jq -r '.[].outbound'
    local core proto
    for core in singbox snell; do
        for proto in $(db_list_protocols "$core"); do
            _db_q --arg c "$core" --arg p "$proto" \
                '[(.[$c][$p] // [])[].users[]? | .routing // ""] | .[]' | sed '/^$/d'
        done
    done
    # 负载均衡组成员需要链式出站
    db_balancer_groups | jq -r '.[] | .nodes[]? | "chain:" + .'
}

# _match_conditions <match> <ip_version> -> jq 片段(JSON对象，含 rule_set/domain_suffix/ip_cidr)
_match_conditions() {
    local match="$1" tok
    local rulesets=() domains=() ips=() _toks=()
    IFS=',' read -r -a _toks <<<"$match"
    for tok in "${_toks[@]}"; do
        tok=$(echo "$tok" | tr -d '[:space:]')
        [[ -z "$tok" ]] && continue
        case "$tok" in
            geosite:*) rulesets+=("geosite-${tok#geosite:}") ;;
            geoip:*)   rulesets+=("geoip-${tok#geoip:}") ;;
            geosite-*|geoip-*) rulesets+=("$tok") ;;
            *)
                if [[ "$tok" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]] || \
                   [[ "$tok" =~ ^[0-9a-fA-F:]+(/[0-9]+)?$ && "$tok" == *:* ]]; then
                    [[ "$tok" != */* ]] && { [[ "$tok" == *:* ]] && tok="$tok/128" || tok="$tok/32"; }
                    ips+=("$tok")
                else
                    domains+=("$tok")
                fi ;;
        esac
    done

    # 校验 rule_set 可用性
    local avail=() rs
    for rs in "${rulesets[@]}"; do
        if _ensure_ruleset "$rs"; then avail+=("$rs")
        else _warn "规则集 $rs 下载失败，已从该规则中忽略"; fi
    done

    local j="{}"
    if [[ ${#avail[@]} -gt 0 ]]; then
        j=$(echo "$j" | jq -c --argjson v "$(printf '%s\n' "${avail[@]}" | jq -R . | jq -s .)" '.rule_set = $v')
    fi
    if [[ ${#domains[@]} -gt 0 ]]; then
        j=$(echo "$j" | jq -c --argjson v "$(printf '%s\n' "${domains[@]}" | jq -R . | jq -s .)" '.domain_suffix = $v')
    fi
    if [[ ${#ips[@]} -gt 0 ]]; then
        j=$(echo "$j" | jq -c --argjson v "$(printf '%s\n' "${ips[@]}" | jq -R . | jq -s .)" '.ip_cidr = $v')
    fi
    echo "$j"
}

#═══════════════════════════════════════════════════════════════════════════════
# 主配置生成
#═══════════════════════════════════════════════════════════════════════════════
generate_singbox_config() {  # generate_singbox_config [output_path]
    local output="${1:-$SB_CONFIG}"
    local protos; protos=$(get_singbox_protocols)
    if [[ -z "$protos" ]]; then
        [[ "$output" == "$SB_CONFIG" ]] && rm -f "$output" 2>/dev/null
        return 1
    fi
    mkdir -p "$CFG" "$RULESET_DIR" "$(dirname "$output")"
    local listen; listen=$(_listen_addr)

    local inbounds="[]" outbounds="[]" endpoints="[]" rules="[]" rs_defs="[]"
    local public_tags=()

    #── inbounds ────────────────────────────────────────────────────────────────
    local proto cfg port tag arr
    for proto in $protos; do
        while IFS= read -r cfg; do
            [[ -z "$cfg" ]] && continue
            port=$(echo "$cfg" | jq -r '.port')
            tag="${proto}-${port}"
            arr=$(_sb_inbound "$proto" "$cfg" "$tag" "$listen")
            if [[ -z "$arr" || "$arr" == "[]" ]]; then
                _warn "协议 $proto (端口 $port) 配置生成失败，已跳过"; continue
            fi
            inbounds=$(jq -nc --argjson a "$inbounds" --argjson b "$arr" '$a + $b')
            public_tags+=("$tag")
        done < <(db_instances singbox "$proto")
    done
    [[ "$(echo "$inbounds" | jq 'length')" == "0" ]] && { _err "没有有效的 inbound"; return 1; }

    #── 多IP 入站副本 ────────────────────────────────────────────────────────────
    local ip_rules_json="" ipin_rules="[]"
    if db_ip_routing_enabled; then
        ip_rules_json=$(db_ip_routing_rules)
        local rule in_ip out_ip mangled dup_tags
        while IFS= read -r rule; do
            [[ -z "$rule" ]] && continue
            in_ip=$(echo "$rule" | jq -r '.inbound_ip')
            out_ip=$(echo "$rule" | jq -r '.outbound_ip')
            [[ -z "$in_ip" || -z "$out_ip" ]] && continue
            mangled="${in_ip//[.:]/-}"
            dup_tags="[]"
            local t
            for t in "${public_tags[@]}"; do
                local src new_tag dup
                src=$(echo "$inbounds" | jq -c --arg t "$t" '.[] | select(.tag == $t)')
                [[ -z "$src" ]] && continue
                # 仅复制普通 TCP/UDP 监听协议
                new_tag="ipin-${mangled}-${t}"
                dup=$(echo "$src" | jq -c --arg l "$in_ip" --arg nt "$new_tag" '.listen = $l | .tag = $nt')
                inbounds=$(jq -nc --argjson a "$inbounds" --argjson b "$dup" '$a + [$b]')
                dup_tags=$(echo "$dup_tags" | jq -c --arg nt "$new_tag" '. + [$nt]')
            done
            if [[ "$(echo "$dup_tags" | jq 'length')" != "0" ]]; then
                ipin_rules=$(jq -nc --argjson a "$ipin_rules" --argjson tags "$dup_tags" \
                    --arg ot "direct-ip-${mangled}" '$a + [{inbound:$tags, outbound:$ot}]')
                local bind_field="inet4_bind_address"
                [[ "$out_ip" == *:* ]] && bind_field="inet6_bind_address"
                outbounds=$(jq -nc --argjson a "$outbounds" --arg t "direct-ip-${mangled}" \
                    --arg f "$bind_field" --arg ip "$out_ip" \
                    '$a + [({type:"direct", tag:$t} | .[$f] = $ip)]')
            fi
        done < <(echo "$ip_rules_json" | jq -c '.[]')
    fi

    #── 出站 ─────────────────────────────────────────────────────────────────────
    outbounds=$(jq -nc --argjson a "$outbounds" --argjson d "$(_sb_direct_outbound direct as_is)" '[$d] + $a')

    local needed ob
    needed=$(_collect_needed_outbounds | sed '/^$/d' | sort -u)

    # 直连派生出站（按 IP 版本）
    local iv dt
    while IFS= read -r iv; do
        [[ -z "$iv" ]] && continue
        dt=$(_direct_tag_for "$iv")
        [[ "$dt" == "direct" ]] && continue
        if ! echo "$outbounds" | jq -e --arg t "$dt" 'any(.[]; .tag == $t)' >/dev/null; then
            outbounds=$(jq -nc --argjson a "$outbounds" --argjson o "$(_sb_direct_outbound "$dt" "$iv")" '$a + [$o]')
        fi
    done < <(db_routing_rules | jq -r '.[] | select(.outbound == "direct") | .ip_version // "as_is"' | sort -u)

    # 绑定本机指定 IP 的出站（bind:<ip>）
    local bip bt biv
    while IFS='|' read -r bip biv; do
        [[ -z "$bip" ]] && continue
        bt=$(_bind_tag_for "$bip" "$biv")
        echo "$outbounds" | jq -e --arg t "$bt" 'any(.[]; .tag == $t)' >/dev/null && continue
        # 本机确实还持有这个地址才生成，否则 sing-box 会因 bind 失败而整体起不来
        if ! { get_all_public_ipv4; get_all_public_ipv6; } 2>/dev/null | grep -qxF "$bip"; then
            _warn "出口绑定 IP ${bip} 已不在本机，相关规则将被跳过"
            continue
        fi
        outbounds=$(jq -nc --argjson a "$outbounds" \
            --argjson o "$(_sb_bind_outbound "$bt" "$bip" "$biv")" '$a + [$o]')
    done < <(db_routing_rules | jq -r '.[] | select(.outbound | startswith("bind:")) | "\(.outbound | ltrimstr("bind:"))|\(.ip_version // "")"' | sort -u)

    # 全局直连出口 IP 版本（作用于默认 direct）
    local gdiv; gdiv=$(db_get_direct_ip_version)
    if [[ "$gdiv" != "as_is" ]]; then
        local gds base patched
        case "$gdiv" in
            ipv4_only)   gds=ipv4_only ;;
            ipv6_only)   gds=ipv6_only ;;
            prefer_ipv6) gds=prefer_ipv6 ;;
            *)           gds=prefer_ipv4 ;;
        esac
        base=$(echo "$outbounds" | jq -c '.[] | select(.tag == "direct")')
        if [[ -n "$base" ]]; then
            patched=$(_sb_apply_domain_strategy "$base" "$gds")
            outbounds=$(jq -nc --argjson a "$outbounds" --argjson p "$patched" \
                '$a | map(if .tag == "direct" then $p else . end)')
        fi
    fi

    # WARP
    local need_warp=false
    grep -q '^warp$' <<<"$needed" && need_warp=true
    [[ "$(db_get_warp_mode)" != "disabled" ]] && need_warp=true
    if [[ "$need_warp" == "true" ]]; then
        local w; w=$(gen_sb_warp) || w=""
        if [[ -n "$w" ]]; then
            if [[ "$(echo "$w" | jq -r '.kind')" == "endpoint" ]]; then
                endpoints=$(jq -nc --argjson a "$endpoints" --argjson d "$(echo "$w" | jq -c '.data')" '$a + [$d]')
            else
                outbounds=$(jq -nc --argjson a "$outbounds" --argjson d "$(echo "$w" | jq -c '.data')" '$a + [$d]')
            fi
        else
            _warn "WARP 已启用但配置不完整，已跳过 WARP 出站"
        fi
    fi

    # 链式代理出站
    local node_name ctag cout
    while IFS= read -r ob; do
        [[ "$ob" == chain:* ]] || continue
        node_name="${ob#chain:}"
        ctag="chain-${node_name}"
        echo "$outbounds" | jq -e --arg t "$ctag" 'any(.[]; .tag == $t)' >/dev/null && continue
        if cout=$(gen_sb_chain_outbound "$node_name" "$ctag"); then
            outbounds=$(jq -nc --argjson a "$outbounds" --argjson o "$cout" '$a + [$o]')
        else
            _warn "链式节点 $node_name 无法生成出站配置，已跳过"
        fi
    done <<<"$needed"

    # 负载均衡组 (urltest)
    local grp gname gstrategy members
    while IFS= read -r ob; do
        [[ "$ob" == balancer:* ]] || continue
        gname="${ob#balancer:}"
        grp=$(db_balancer_group "$gname"); [[ -z "$grp" ]] && continue
        echo "$outbounds" | jq -e --arg t "balancer-$gname" 'any(.[]; .tag == $t)' >/dev/null && continue
        members="[]"
        while IFS= read -r node_name; do
            [[ -z "$node_name" ]] && continue
            ctag="chain-${node_name}"
            if ! echo "$outbounds" | jq -e --arg t "$ctag" 'any(.[]; .tag == $t)' >/dev/null; then
                cout=$(gen_sb_chain_outbound "$node_name" "$ctag") || continue
                outbounds=$(jq -nc --argjson a "$outbounds" --argjson o "$cout" '$a + [$o]')
            fi
            members=$(echo "$members" | jq -c --arg t "$ctag" '. + [$t]')
        done < <(echo "$grp" | jq -r '.nodes[]?')
        [[ "$(echo "$members" | jq 'length')" == "0" ]] && { _warn "负载均衡组 $gname 无有效成员"; continue; }
        gstrategy=$(echo "$grp" | jq -r '.strategy // "urltest"')
        if [[ "$gstrategy" == "selector" ]]; then
            outbounds=$(jq -nc --argjson a "$outbounds" --arg t "balancer-$gname" --argjson m "$members" \
                '$a + [{type:"selector", tag:$t, outbounds:$m, default:$m[0]}]')
        else
            outbounds=$(jq -nc --argjson a "$outbounds" --arg t "balancer-$gname" --argjson m "$members" \
                '$a + [{type:"urltest", tag:$t, outbounds:$m, url:"https://www.gstatic.com/generate_204",
                        interval:"5m", tolerance:50, idle_timeout:"30m"}]')
        fi
    done <<<"$needed"

    #── 路由规则 ────────────────────────────────────────────────────────────────
    rules=$(jq -nc '[{action:"sniff"}]')

    # 多IP 入站定向
    [[ "$(echo "$ipin_rules" | jq 'length')" != "0" ]] && \
        rules=$(jq -nc --argjson a "$rules" --argjson b "$ipin_rules" '$a + $b')

    # 用户级路由（auth_user）
    # 注意: socks / naive 入站在 sing-box 中的用户标识就是 username 本身，
    # 其余协议由 _sb_users 统一加上 "<proto>-" 前缀以避免跨协议同名冲突。
    local user_rules="[]" u_name u_routing u_tag u_key
    for proto in $protos; do
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            u_name="${line%%|*}"; u_routing="${line#*|}"
            [[ -z "$u_routing" || "$u_routing" == "null" ]] && continue
            case "$proto" in
                socks|naive) u_key="$u_name" ;;
                *)           u_key="${proto}-${u_name}" ;;
            esac
            u_tag=$(_rule_outbound_tag "$u_routing" "as_is")
            if [[ "$u_tag" == "__reject__" ]]; then
                user_rules=$(jq -nc --argjson a "$user_rules" --arg u "$u_key" \
                    '$a + [{auth_user:[$u], action:"reject"}]')
            elif echo "$outbounds" | jq -e --arg t "$u_tag" 'any(.[]; .tag == $t)' >/dev/null || \
                 echo "$endpoints" | jq -e --arg t "$u_tag" 'any(.[]; .tag == $t)' >/dev/null; then
                user_rules=$(jq -nc --argjson a "$user_rules" --arg u "$u_key" --arg t "$u_tag" \
                    '$a + [{auth_user:[$u], outbound:$t}]')
            fi
        done < <(_db_q --arg c singbox --arg p "$proto" \
            '[(.[$c][$p] // [])[].users[]?] | unique_by(.name) | .[] | select((.routing // "") != "") | "\(.name)|\(.routing)"')
    done
    [[ "$(echo "$user_rules" | jq 'length')" != "0" ]] && \
        rules=$(jq -nc --argjson a "$rules" --argjson b "$user_rules" '$a + $b')

    # 全局分流规则
    local rline rtype rob rmatch riv rtag conds rule_json
    while IFS= read -r rline; do
        [[ -z "$rline" ]] && continue
        rtype=$(echo "$rline" | jq -r '.type')
        rob=$(echo "$rline" | jq -r '.outbound')
        rmatch=$(echo "$rline" | jq -r '.match // ""')
        riv=$(echo "$rline" | jq -r '.ip_version // "as_is"')
        rtag=$(_rule_outbound_tag "$rob" "$riv")

        if [[ "$rtag" != "__reject__" ]] && \
           ! echo "$outbounds" | jq -e --arg t "$rtag" 'any(.[]; .tag == $t)' >/dev/null && \
           ! echo "$endpoints" | jq -e --arg t "$rtag" 'any(.[]; .tag == $t)' >/dev/null; then
            _warn "规则 ${rtype} 的出站 ${rob} 不可用，已跳过"; continue
        fi

        case "$rtype" in
            restrict-bt)
                rule_json=$(jq -nc '{protocol:["bittorrent"], action:"reject"}') ;;
            all)
                rule_json=$(jq -nc '{network:["tcp","udp"]}') ;;
            *)
                conds=$(_match_conditions "$rmatch" "$riv")
                if [[ "$conds" == "{}" ]]; then
                    _warn "规则 ${rtype} 无有效匹配条件，已跳过"; continue
                fi
                rule_json="$conds" ;;
        esac

        case "$riv" in
            ipv4_only) rule_json=$(echo "$rule_json" | jq -c '.ip_version = 4') ;;
            ipv6_only) rule_json=$(echo "$rule_json" | jq -c '.ip_version = 6') ;;
        esac

        if [[ "$rtype" == "restrict-bt" ]]; then
            :
        elif [[ "$rtag" == "__reject__" ]]; then
            rule_json=$(echo "$rule_json" | jq -c '.action = "reject"')
        else
            rule_json=$(echo "$rule_json" | jq -c --arg t "$rtag" '.outbound = $t')
        fi
        rules=$(jq -nc --argjson a "$rules" --argjson r "$rule_json" '$a + [$r]')
    done < <(db_routing_rules | jq -c '.[]')

    # rule_set 定义
    local tags tg
    tags=$(echo "$rules" | jq -r '[.[] | .rule_set // [] | .[]] | unique | .[]')
    while IFS= read -r tg; do
        [[ -z "$tg" ]] && continue
        rs_defs=$(jq -nc --argjson a "$rs_defs" --arg t "$tg" --arg p "$RULESET_DIR/${tg}.srs" \
            '$a + [{type:"local", tag:$t, format:"binary", path:$p}]')
    done <<<"$tags"

    #── 组装 ─────────────────────────────────────────────────────────────────────
    local conf route_json
    # auto_detect_interface 仅用于 TUN 等需要防路由环路的客户端场景。songbox 不生成
    # TUN 入站，多 IP 出口走显式 inet4_bind_address/inet6_bind_address，因此这里必须
    # 保持 false：置 true 会拉起 sing-tun 的 networkUpdateMonitor，在 netlink 事件频繁
    # 的宿主机（如运行 Podman/LXC 的 NAT 母鸡）上可能陷入 select 空转并占满一个 CPU 核。
    route_json=$(jq -nc --argjson rl "$rules" --argjson rs "$rs_defs" \
        '{rules:$rl, final:"direct", auto_detect_interface:false}
         + (if ($rs|length) > 0 then {rule_set:$rs} else {} end)')
    # 纯服务端不使用 FakeIP / RDRC / Clash 选择记录，rule_set 也全部是本地文件，
    # cache_file 存不下任何有用状态，却会在每次启动时打开一个可能被异常重启截断的 bbolt 库。
    conf=$(jq -nc --argjson inb "$inbounds" --argjson oub "$outbounds" \
        --argjson route "$route_json" '
        {log:{level:"warn", timestamp:true},
         inbounds:$inb,
         outbounds:$oub,
         route:$route}')
    # 新版 domain_resolver 引用的 DNS 服务器必须存在
    if ! _sb_uses_legacy_domain_strategy; then
        conf=$(echo "$conf" | jq -c --arg t "$SB_DNS_TAG" \
            '.dns = {servers:[{type:"local", tag:$t}]}
             | .route.default_domain_resolver = $t')
    fi
    [[ "$(echo "$endpoints" | jq 'length')" != "0" ]] && \
        conf=$(echo "$conf" | jq -c --argjson e "$endpoints" '.endpoints = $e')

    printf '%s\n' "$conf" | jq . >"${output}.tmp" 2>/dev/null || {
        _err "Sing-box 配置 JSON 生成失败"; rm -f "${output}.tmp"; return 1; }
    chmod 600 "${output}.tmp"

    local check_bin="${SONGBOX_SB_CHECK_BIN:-$SB_BIN}"
    if [[ -x "$check_bin" ]]; then
        local check_out
        if ! check_out=$("$check_bin" check -c "${output}.tmp" 2>&1); then
            _err "Sing-box 配置校验失败:"
            echo "$check_out" | head -8 | sed 's/^/    /' >&2
            rm -f "${output}.tmp"
            return 1
        fi
    fi
    mv "${output}.tmp" "$output"
    _ok "Sing-box 配置已生成 ($(echo "$protos" | wc -w) 个协议 / $(echo "$inbounds" | jq 'length') 个入站)"
    return 0
}
#═══════════════════════════════════════════════════════════════════════════════
# 服务单元与启动管理
#═══════════════════════════════════════════════════════════════════════════════
readonly WARP_CONF_FILE="$CFG/warp.json"
readonly WARP_OFFICIAL_PORT=40000

declare -A SNELL_BIN=(
    [snell]="/usr/local/bin/snell-server"
    [snell-v5]="/usr/local/bin/snell-server-v5"
    [snell-v6]="/usr/local/bin/snell-server-v6"
    [snell-shadowtls]="/usr/local/bin/snell-server"
    [snell-v5-shadowtls]="/usr/local/bin/snell-server-v5"
)
declare -A SNELL_CONF=(
    [snell]="$CFG/snell.conf"
    [snell-v5]="$CFG/snell-v5.conf"
    [snell-v6]="$CFG/snell-v6.conf"
    [snell-shadowtls]="$CFG/snell-shadowtls.conf"
    [snell-v5-shadowtls]="$CFG/snell-v5-shadowtls.conf"
)

_write_openrc() {  # name desc cmd args [env] [retry] [start_pre_cmd]
    local name="$1" desc="$2" cmd="$3" service_args="$4" env="$5" retry="${6:-0}" pre="${7:-}"
    cat >"/etc/init.d/${name}" <<EOF
#!/sbin/openrc-run
name="${desc}"
command="${cmd}"
command_args="${service_args}"
command_background="yes"
pidfile="/run/${name}.pid"
${env:+export ${env}}

depend() {
    need net localmount
    after firewall
}
EOF
    if [[ -n "$pre" && "$retry" != "1" ]]; then
        cat >>"/etc/init.d/${name}" <<EOF

start_pre() {
    ${pre}
}
EOF
    fi
    if [[ "$retry" == "1" ]]; then
        cat >>"/etc/init.d/${name}" <<EOF

start_pre() {
    sleep 1
    [ -x "${cmd}" ] || { eerror "可执行文件不存在: ${cmd}"; return 1; }
    ${pre}
}

start_post() {
    (
        for d in 3 6 10; do
            sleep "\$d"
            if [ -s "/run/${name}.pid" ]; then
                _pid=\$(cat "/run/${name}.pid" 2>/dev/null)
                [ -n "\$_pid" ] && kill -0 "\$_pid" 2>/dev/null && exit 0
            fi
            rc-service "${name}" restart >/dev/null 2>&1 || true
        done
    ) >/dev/null 2>&1 &
}
EOF
    fi
    chmod +x "/etc/init.d/${name}"
}

_write_systemd() {  # name desc exec [env] [pre]
    local name="$1" desc="$2" exec="$3" env="${4:-}" pre="${5:-}"
    cat >"/etc/systemd/system/${name}.service" <<EOF
[Unit]
Description=${desc}
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
${env:+Environment=${env}}
${pre:+ExecStartPre=${pre}}
ExecStart=${exec}
Restart=always
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_DAC_OVERRIDE

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1 || true
}

create_singbox_service() {
    local env=""
    local pre=""
    [[ -f "$CFG/hop-nat.sh" ]] && pre="-/bin/bash $CFG/hop-nat.sh"
    if [[ "$DISTRO" == "alpine" ]]; then
        # OpenRC: 端口跳跃在 start_pre 中执行
        local orc_pre=""
        [[ -f "$CFG/hop-nat.sh" ]] && orc_pre="[ -x \"$CFG/hop-nat.sh\" ] && \"$CFG/hop-nat.sh\" >/dev/null 2>&1; return 0"
        _write_openrc "$SB_SVC" "Sing-box Proxy Server" "$SB_BIN" "run -c $SB_CONFIG" "$env" "0" "$orc_pre"
    else
        _write_systemd "$SB_SVC" "Sing-box Proxy Server" "$SB_BIN run -c $SB_CONFIG" "$env" "$pre"
    fi
}

create_snell_service() {
    local proto="$1" svc bin conf
    svc="vless-${proto}"; bin="${SNELL_BIN[$proto]}"; conf="${SNELL_CONF[$proto]}"
    if [[ "$DISTRO" == "alpine" ]]; then
        _write_openrc "$svc" "Snell Server ($proto)" "$bin" "-c $conf" "" "1"
    else
        _write_systemd "$svc" "Snell Server ($proto)" "$bin -c $conf"
    fi
}

create_shadowtls_service() {  # snell-shadowtls / snell-v5-shadowtls
    local proto="$1" svc
    svc="vless-${proto}"
    local port sni stls_pw bport listen
    port=$(db_field snell "$proto" port)
    sni=$(db_field snell "$proto" sni)
    stls_pw=$(db_field snell "$proto" stls_password)
    bport=$(db_field snell "$proto" backend_port)
    listen=$(_listen_addr)
    local shadow_exec
    shadow_exec="/usr/local/bin/shadow-tls --v3 server --listen $(_fmt_hostport "$listen" "$port") \
--server 127.0.0.1:${bport} --tls ${sni}:443 --password ${stls_pw}"
    # ShadowTLS 在高版本内核上需回退旧 IO 驱动，避免 CPU 100%
    if [[ "$DISTRO" == "alpine" ]]; then
        _write_openrc "$svc" "ShadowTLS ($proto)" "/usr/local/bin/shadow-tls" \
            "--v3 server --listen $(_fmt_hostport "$listen" "$port") --server 127.0.0.1:${bport} --tls ${sni}:443 --password ${stls_pw}" \
            "MONOIO_FORCE_LEGACY_DRIVER=1"
    else
        _write_systemd "$svc" "ShadowTLS ($proto)" "$shadow_exec" "MONOIO_FORCE_LEGACY_DRIVER=1"
    fi
    # 后端 Snell
    local bsvc="${svc}-backend" bbin="${SNELL_BIN[$proto]}" bconf="${SNELL_CONF[$proto]}"
    if [[ "$DISTRO" == "alpine" ]]; then
        _write_openrc "$bsvc" "Snell Backend ($proto)" "$bbin" "-c $bconf" "" "1"
    else
        _write_systemd "$bsvc" "Snell Backend ($proto)" "$bbin -c $bconf"
    fi
}

create_watchdog_service() {
    cat >"$CFG/watchdog.sh" <<'EOFW'
#!/bin/bash
umask 077
CFG="/etc/vless-reality"
LOG="/var/log/vless-watchdog.log"
declare -A CNT FIRST
MAX=5; COOL=300
log() {
    echo "[$(date '+%F %T')] $1" >>"$LOG"
    local s; s=$(stat -c%s "$LOG" 2>/dev/null || echo 0)
    [[ "$s" -gt 2097152 ]] && { tail -n 500 "$LOG" >"${LOG}.t" && mv "${LOG}.t" "$LOG"; }
}
restart_svc() {
    local s="$1" now; now=$(date +%s)
    if [[ $((now - ${FIRST[$s]:-0})) -gt $COOL ]]; then CNT[$s]=1; FIRST[$s]=$now
    else CNT[$s]=$(( ${CNT[$s]:-0} + 1 ))
         [[ ${CNT[$s]} -gt $MAX ]] && { log "ERROR: $s 冷却期内重启超限，暂停监控"; return 1; }
    fi
    log "INFO: 重启 $s (第 ${CNT[$s]} 次)"
    if command -v systemctl >/dev/null 2>&1; then systemctl restart "$s"
    elif command -v rc-service >/dev/null 2>&1; then rc-service "$s" restart; fi
}
svc_list() {
    local db="$CFG/db.json" p
    [[ -f "$db" ]] || return
    [[ -n "$(jq -r '.singbox | keys[]?' "$db" 2>/dev/null)" ]] && echo "vless-singbox:sing-box"
    for p in $(jq -r '.snell | keys[]?' "$db" 2>/dev/null); do
        case "$p" in
            snell)              echo "vless-snell:snell-server" ;;
            snell-v5)           echo "vless-snell-v5:snell-server-v5" ;;
            snell-v6)           echo "vless-snell-v6:snell-server-v6" ;;
            snell-shadowtls)    echo "vless-snell-shadowtls:shadow-tls" ;;
            snell-v5-shadowtls) echo "vless-snell-v5-shadowtls:shadow-tls" ;;
        esac
    done
}
log "INFO: Watchdog 启动"
while true; do
    for e in $(svc_list); do
        s="${e%%:*}"; proc="${e##*:}"
        pgrep -x "$proc" >/dev/null 2>&1 || pgrep -f "$proc" >/dev/null 2>&1 || {
            log "CRITICAL: $proc 未运行，尝试重启 $s"
            restart_svc "$s"; sleep 5
        }
    done
    sleep 60
done
EOFW
    chmod +x "$CFG/watchdog.sh"
    if [[ "$DISTRO" == "alpine" ]]; then
        _write_openrc "vless-watchdog" "VLESS Watchdog" "/bin/bash" "$CFG/watchdog.sh"
    else
        _write_systemd "vless-watchdog" "VLESS Watchdog" "/bin/bash $CFG/watchdog.sh"
    fi
}

#───────────────────────────────────────────────────────────────────────────────
# Snell 配置文件
#───────────────────────────────────────────────────────────────────────────────
gen_snell_conf() {  # proto
    local proto="$1" cfg conf
    conf="${SNELL_CONF[$proto]}"
    cfg=$(db_instances snell "$proto" | head -1)
    [[ -z "$cfg" ]] && return 1
    # Snell 是独立进程 + 单配置文件，多端口实例只有第一个会真正监听
    local _ninst; _ninst=$(db_count_instances snell "$proto" 2>/dev/null)
    if [[ "${_ninst:-1}" -gt 1 ]]; then
        _warn "$(get_protocol_name "$proto") 有 ${_ninst} 个端口实例，但 Snell 为单配置文件独立进程"
        echo -e "  ${D}只有端口 $(echo "$cfg" | jq -r '.port') 会监听，其余实例的节点必然连接超时${NC}" >&2
    fi
    local psk port version listen bind
    psk=$(echo "$cfg" | jq -r '.psk')
    port=$(echo "$cfg" | jq -r '.port')
    version=$(echo "$cfg" | jq -r '.version // "4"')
    listen=$(_listen_addr)
    bind="$listen"

    case "$proto" in
        snell-shadowtls|snell-v5-shadowtls)
            # ShadowTLS 后端只监听本地
            bind="127.0.0.1"
            port=$(echo "$cfg" | jq -r '.backend_port') ;;
    esac

    {
        printf '[snell-server]\n'
        printf 'listen = %s\n' "$(_fmt_hostport "$bind" "$port")"
        printf 'psk = %s\n' "$psk"
        if [[ "$version" == "6" ]]; then
            printf 'mode = %s\n' "$(echo "$cfg" | jq -r '.mode // "default"')"
            local dns; dns=$(echo "$cfg" | jq -r '.dns // empty')
            [[ -n "$dns" ]] && printf 'dns = %s\n' "$dns"
            printf 'dns-ip-preference = %s\n' "$(echo "$cfg" | jq -r '.dns_ip_preference // "default"')"
        else
            [[ "$version" != "4" ]] && printf 'version = %s\n' "$version"
            if _has_ipv6; then printf 'ipv6 = true\n'; else printf 'ipv6 = false\n'; fi
            printf 'obfs = off\n'
        fi
    } >"$conf"
    chmod 600 "$conf"
}

#───────────────────────────────────────────────────────────────────────────────
# 端口跳跃 (Hysteria2 / TUIC)
#───────────────────────────────────────────────────────────────────────────────
gen_hop_nat_script() {
    local any=false proto cfg
    local body=""
    for proto in hy2 tuic; do
        db_exists singbox "$proto" || continue
        while IFS= read -r cfg; do
            [[ -z "$cfg" ]] && continue
            local en port hs he
            en=$(echo "$cfg" | jq -r '.hop_enable // 0')
            [[ "$en" != "1" ]] && continue
            port=$(echo "$cfg" | jq -r '.port')
            hs=$(echo "$cfg" | jq -r '.hop_start // 20000')
            he=$(echo "$cfg" | jq -r '.hop_end // 50000')
            _is_valid_port "$port" && _is_valid_port "$hs" && _is_valid_port "$he" || continue
            [[ "$hs" -ge "$he" ]] && continue
            any=true
            body+="apply_hop ${proto} ${port} ${hs} ${he}"$'\n'
        done < <(db_instances singbox "$proto")
    done

    if [[ "$any" != "true" ]]; then
        [[ -f "$CFG/hop-nat.sh" ]] && { bash "$CFG/hop-nat.sh" --flush 2>/dev/null || true; rm -f "$CFG/hop-nat.sh"; }
        return 0
    fi

    cat >"$CFG/hop-nat.sh" <<'EOFH'
#!/bin/bash
# 由脚本自动生成：UDP 端口跳跃 NAT 规则
command -v iptables >/dev/null 2>&1 || { echo "[hop-nat] iptables 未安装" >&2; exit 1; }
FLUSH=0; [[ "${1:-}" == "--flush" ]] && FLUSH=1

apply_hop() {
    local tag="$1" port="$2" hs="$3" he="$4" cmt="vless-${1}-hop"
    local ipt
    for ipt in iptables ip6tables; do
        command -v "$ipt" >/dev/null 2>&1 || continue
        $ipt -t nat -D PREROUTING -p udp --dport ${hs}:${he} -m comment --comment "$cmt" -j REDIRECT --to-ports $port 2>/dev/null
        $ipt -t nat -D OUTPUT     -p udp --dport ${hs}:${he} -m comment --comment "$cmt" -j REDIRECT --to-ports $port 2>/dev/null
        [[ "$FLUSH" == "1" ]] && continue
        # 只在 PREROUTING 做端口跳跃：这条只影响"从外面进来"的包。
        # 曾经这里还加过 nat OUTPUT 的同款规则，那会连本机主动发出的 UDP 一起劫持——
        # 只要目的端口落在跳跃范围内（默认 20000-50000），到上游 hy2/tuic 节点、
        # WireGuard、DoQ 等的出站流量都会被重定向到本地端口，属于严重副作用。
        $ipt -t nat -A PREROUTING -p udp --dport ${hs}:${he} -m comment --comment "$cmt" -j REDIRECT --to-ports $port 2>/dev/null
    done
}

EOFH
    printf '%s' "$body" >>"$CFG/hop-nat.sh"
    chmod +x "$CFG/hop-nat.sh"
}

cleanup_hop_nat() {
    [[ -x "$CFG/hop-nat.sh" ]] && bash "$CFG/hop-nat.sh" --flush 2>/dev/null || true
}

#───────────────────────────────────────────────────────────────────────────────
# 启停
#───────────────────────────────────────────────────────────────────────────────
start_services() {
    local failed=()
    rm -f "$CFG/paused"
    init_db

    local sb_protos; sb_protos=$(get_singbox_protocols)
    if [[ -n "$sb_protos" ]]; then
        [[ -x "$SB_BIN" ]] || install_singbox || failed+=("$SB_SVC")
        gen_hop_nat_script
        if generate_singbox_config; then
            create_singbox_service
            svc enable "$SB_SVC" 2>/dev/null
            if svc status "$SB_SVC" >/dev/null 2>&1; then svc restart "$SB_SVC" || failed+=("$SB_SVC")
            else svc start "$SB_SVC" || failed+=("$SB_SVC"); fi
            sleep 1
            if svc status "$SB_SVC" >/dev/null 2>&1; then
                _ok "Sing-box 服务运行中 (协议: $(echo "$sb_protos" | tr '\n' ' '))"
            else
                _err "Sing-box 服务未运行"; failed+=("$SB_SVC")
            fi
        else
            _err "Sing-box 配置生成失败"; failed+=("$SB_SVC")
        fi
    fi

    local proto svc snell_protos
    snell_protos=$(get_snell_protocols)
    # 重装系统 / 恢复备份后二进制可能不存在，这里按需补装
    if [[ -n "$snell_protos" ]]; then
        for proto in $snell_protos; do
            case "$proto" in
                snell|snell-shadowtls)    check_cmd snell-server    || install_snell    || failed+=("snell-server") ;;
                snell-v5|snell-v5-shadowtls) check_cmd snell-server-v5 || install_snell_v5 || failed+=("snell-server-v5") ;;
                snell-v6)                 check_cmd snell-server-v6 || install_snell_v6 || failed+=("snell-server-v6") ;;
            esac
            case "$proto" in
                *-shadowtls) check_cmd shadow-tls || install_shadowtls || failed+=("shadow-tls") ;;
            esac
        done
    fi
    for proto in $snell_protos; do
        svc="vless-${proto}"
        gen_snell_conf "$proto"
        case "$proto" in
            snell-shadowtls|snell-v5-shadowtls)
                create_shadowtls_service "$proto"
                svc enable "${svc}-backend" 2>/dev/null
                if svc status "${svc}-backend" >/dev/null 2>&1; then svc restart "${svc}-backend" || true
                else svc start "${svc}-backend" || failed+=("${svc}-backend"); fi
                sleep 1 ;;
            *) create_snell_service "$proto" ;;
        esac
        svc enable "$svc" 2>/dev/null
        if svc status "$svc" >/dev/null 2>&1; then svc restart "$svc" || failed+=("$svc")
        else svc start "$svc" || failed+=("$svc"); fi
        sleep 1
        svc status "$svc" >/dev/null 2>&1 && _ok "$(get_protocol_name "$proto") 服务运行中" || {
            _err "$(get_protocol_name "$proto") 服务未运行"; failed+=("$svc"); }
    done

    create_watchdog_service
    svc enable vless-watchdog 2>/dev/null
    svc status vless-watchdog >/dev/null 2>&1 || svc start vless-watchdog 2>/dev/null || true

    if [[ ${#failed[@]} -gt 0 ]]; then
        _warn "以下服务启动失败: ${failed[*]}"
        return 1
    fi
    return 0
}

stop_services() {
    local stopped=() s
    for s in vless-watchdog "$SB_SVC"; do
        svc status "$s" >/dev/null 2>&1 && { svc stop "$s"; stopped+=("$s"); }
    done
    local proto
    for proto in $SNELL_PROTOCOLS; do
        for s in "vless-${proto}" "vless-${proto}-backend"; do
            svc status "$s" >/dev/null 2>&1 && { svc stop "$s"; stopped+=("$s"); }
        done
    done
    cleanup_hop_nat
    if [[ ${#stopped[@]} -gt 0 ]]; then _info "已停止: ${stopped[*]}"; else _info "没有运行中的服务"; fi
}

restart_all_services() { stop_services; sleep 1; start_services; }

# 配置变更后热重建（用户/分流/节点变更时调用）
reload_config() {
    local sb_protos; sb_protos=$(get_singbox_protocols)
    [[ -z "$sb_protos" ]] && return 0
    gen_hop_nat_script
    if generate_singbox_config; then
        create_singbox_service
        if svc status "$SB_SVC" >/dev/null 2>&1; then
            svc restart "$SB_SVC" >/dev/null 2>&1 && _ok "Sing-box 已重载" || _err "Sing-box 重启失败"
        fi
        return 0
    fi
    _err "配置重建失败，已保留原配置"
    return 1
}

#───────────────────────────────────────────────────────────────────────────────
# 快捷命令
#───────────────────────────────────────────────────────────────────────────────
_install_script_links() {  # _install_script_links <canonical-script>
    local target="$1" legacy_backup="${LEGACY_SYSTEM_SCRIPT}.pre-songbox.bak"
    [[ -f "$target" ]] || return 1
    if [[ -e "$LEGACY_SYSTEM_SCRIPT" && ! -L "$LEGACY_SYSTEM_SCRIPT" && \
          "$LEGACY_SYSTEM_SCRIPT" != "$target" && ! -e "$legacy_backup" ]]; then
        cp -a "$LEGACY_SYSTEM_SCRIPT" "$legacy_backup" 2>/dev/null || true
    fi
    ln -sfn "$target" "$LEGACY_SYSTEM_SCRIPT" 2>/dev/null || return 1
    ln -sfn "$target" /usr/local/bin/vless 2>/dev/null || return 1
    ln -sfn "$target" /usr/bin/vless 2>/dev/null || true
    hash -r 2>/dev/null
}

create_shortcut() {
    local sys="$SYSTEM_SCRIPT" src
    src=$(readlink -f "$0" 2>/dev/null || echo "$0")
    if [[ -f "$src" && "$src" != "$sys" ]]; then
        install -m 755 "$src" "$sys" 2>/dev/null || { _warn "无法写入 $sys"; return 1; }
    fi
    [[ -f "$sys" ]] || { _warn "未找到脚本文件，跳过快捷命令创建"; return 1; }
    chmod 755 "$sys"
    _install_script_links "$sys" || { _warn "快捷命令链接创建失败"; return 1; }
    _ok "脚本已安装: $sys（快捷命令: vless；旧路径保持兼容）"
}

_auto_sync_system_script() {
    local sys="$SYSTEM_SCRIPT" src cur sys_md5
    src=$(readlink -f "$0" 2>/dev/null || echo "$0")
    [[ -f "$src" ]] || return 0
    if [[ "$src" != "$sys" ]]; then
        cur=$(_sha256_file "$src" 2>/dev/null)
        sys_md5=$(_sha256_file "$sys" 2>/dev/null)
        if [[ ! -f "$sys" || -z "$cur" || "$cur" != "$sys_md5" ]]; then
            install -m 755 "$src" "$sys" 2>/dev/null || return 1
            _ok "系统脚本已同步到 $sys (v$VERSION)"
        fi
    fi
    _install_script_links "$sys" >/dev/null 2>&1 || true
}

#═══════════════════════════════════════════════════════════════════════════════
# WARP
#═══════════════════════════════════════════════════════════════════════════════
warp_status() {
    local mode; mode=$(db_get_warp_mode)
    if [[ "$mode" == "official" ]]; then
        check_cmd warp-cli || { echo "not_configured"; return; }
        local st; st=$(warp-cli status 2>/dev/null)
        echo "$st" | grep -qiE "Connected" && { echo "connected"; return; }
        echo "$st" | grep -qiE "Registration|Status:" && { echo "registered"; return; }
        echo "not_configured"; return
    fi
    if [[ -f "$WARP_CONF_FILE" ]] && [[ -n "$(jq -r '.private_key // empty' "$WARP_CONF_FILE" 2>/dev/null)" ]]; then
        echo "configured"; return
    fi
    echo "not_configured"
}

download_wgcf() {
    [[ -x /usr/local/bin/wgcf ]] && return 0
    local arch; arch=$(_map_arch "amd64:arm64:armv7") || { _err "不支持的架构"; return 1; }
    local ver; ver=$(_gh_latest_tag "ViRb3/wgcf"); ver="${ver#v}"
    [[ -z "$ver" ]] && ver="2.2.29"
    _info "下载 wgcf v${ver}..."
    local asset="wgcf_${ver}_linux_${arch}" expect
    expect=$(_gh_asset_sha256 "ViRb3/wgcf" "v${ver}" "$asset" 2>/dev/null)
    local urls=("https://github.com/ViRb3/wgcf/releases/download/v${ver}/${asset}")
    if [[ -n "$expect" || "${ALLOW_THIRD_PARTY_MIRRORS:-0}" == "1" ]]; then
        urls+=("https://gh-proxy.com/https://github.com/ViRb3/wgcf/releases/download/v${ver}/${asset}")
    fi
    local u tmp; tmp=$(mktemp) || return 1
    for u in "${urls[@]}"; do
        if curl -fsSL -A "Mozilla/5.0" --connect-timeout 15 --max-time 90 -o "$tmp" "$u"; then
            local size; size=$(stat -c%s "$tmp" 2>/dev/null || echo 0)
            if [[ "$size" -gt 100000 ]]; then
                if [[ -n "$expect" ]]; then
                    _verify_sha256 "$tmp" "$expect" || { _warn "wgcf SHA-256 不匹配，拒绝该下载源"; : >"$tmp"; continue; }
                else
                    _confirm_unverified "wgcf v${ver}" || { rm -f "$tmp"; return 1; }
                fi
                install -m 755 "$tmp" /usr/local/bin/wgcf && rm -f "$tmp" && { _ok "wgcf 已安装"; return 0; }
            fi
        fi
        : >"$tmp"
    done
    rm -f "$tmp"; _err "wgcf 下载失败"; return 1
}

_normalize_b64() {
    local s="$1" m=$(( ${#1} % 4 ))
    case "$m" in 2) echo "${s}==" ;; 3) echo "${s}=" ;; *) echo "$s" ;; esac
}

_select_best_warp_ipv6_endpoint() {
    local port="${1:-2408}" best="2606:4700:d0::a29f:c001" bl=9999 ep lat
    for ep in "2606:4700:d0::a29f:c001" "2606:4700:d0::a29f:c002" "2606:4700:d1::a29f:c001"; do
        lat=$(ping6 -c 2 -W 1 "$ep" 2>/dev/null | sed -n 's/.*time=\([0-9.]*\).*/\1/p' |
              awk '{s+=$1;n++} END{if(n>0) printf "%.0f", s/n; else print 9999}')
        [[ -z "$lat" ]] && lat=9999
        [[ "$lat" -lt "$bl" ]] && { bl="$lat"; best="$ep"; }
    done
    echo "[${best}]:${port}"
}

register_warp_wgcf() {
    download_wgcf || return 1
    local tmp; tmp=$(mktemp -d) || return 1
    _info "注册 WARP 账户..."
    if ! ( cd "$tmp" &&
           /usr/local/bin/wgcf register --accept-tos >/dev/null 2>&1 &&
           [[ -f wgcf-account.toml ]] &&
           /usr/local/bin/wgcf generate >/dev/null 2>&1 &&
           [[ -f wgcf-profile.conf ]] ); then
        rm -rf "$tmp"; _err "WARP 注册或配置生成失败"; return 1
    fi
    _info "WireGuard 配置已生成"

    local pk pub ep addrs v4="" v6="" a
    pk=$(_normalize_b64 "$(grep PrivateKey "$tmp/wgcf-profile.conf" | cut -d= -f2- | xargs)")
    pub=$(_normalize_b64 "$(grep PublicKey "$tmp/wgcf-profile.conf" | cut -d= -f2- | xargs)")
    ep=$(grep Endpoint "$tmp/wgcf-profile.conf" | cut -d= -f2- | xargs)
    addrs=$(grep Address "$tmp/wgcf-profile.conf" | cut -d= -f2- | tr -d ' ' | tr '\n' ',')
    IFS=',' read -r -a _a <<<"$addrs"
    for a in "${_a[@]}"; do
        [[ -z "$a" ]] && continue
        if [[ "$a" == *:* ]]; then v6="$a"; else v4="$a"; fi
    done
    rm -rf "$tmp"

    [[ -n "$pk" && -n "$pub" && -n "$ep" ]] || {
        _err "wgcf 输出缺少私钥、公钥或端点"; return 1; }

    if [[ -z "$(get_ipv4)" ]]; then
        local p="${ep##*:}"; [[ "$p" =~ ^[0-9]+$ ]] || p=2408
        ep=$(_select_best_warp_ipv6_endpoint "$p")
    fi

    jq -n --arg pk "$pk" --arg pub "$pub" --arg v4 "$v4" --arg v6 "$v6" --arg ep "$ep" \
        '{private_key:$pk, public_key:$pub, address_v4:$v4, address_v6:$v6, endpoint:$ep}' >"$WARP_CONF_FILE"
    chmod 600 "$WARP_CONF_FILE"
    db_set_warp_mode "wgcf"
    _ok "WARP (WGCF) 配置完成"
    echo -e "  端点: ${C}${ep}${NC}  内网: ${G}${v4}${NC} / ${D}${v6}${NC}" >&2
}

install_warp_official() {
    [[ "$DISTRO" == "alpine" ]] && { _err "Alpine 不支持 WARP 官方客户端（依赖 glibc），请使用 WGCF 模式"; return 1; }
    check_cmd warp-cli && { _ok "WARP 官方客户端已安装"; return 0; }
    local arch; arch=$(uname -m)
    [[ "$arch" != "x86_64" && "$arch" != "aarch64" ]] && { _err "官方客户端仅支持 x86_64/arm64"; return 1; }

    _info "添加 Cloudflare 软件源..."
    if [[ "$DISTRO" == "debian" || "$DISTRO" == "ubuntu" ]]; then
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq curl gnupg lsb-release >/dev/null 2>&1
        local key; key=$(mktemp)
        curl -fsSL --connect-timeout 10 -o "$key" https://pkg.cloudflareclient.com/pubkey.gpg || { rm -f "$key"; _err "密钥下载失败"; return 1; }
        gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg "$key" 2>/dev/null
        rm -f "$key"
        local cn; cn=$(lsb_release -cs 2>/dev/null || grep VERSION_CODENAME /etc/os-release | cut -d= -f2)
        case "$cn" in bookworm|trixie|sid) cn="bookworm" ;; noble|oracular|plucky) cn="jammy" ;; esac
        [[ -z "$cn" ]] && cn="jammy"
        echo "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $cn main" \
            >/etc/apt/sources.list.d/cloudflare-client.list
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y cloudflare-warp >/dev/null 2>&1 || { _err "安装失败"; return 1; }
    else
        curl -fsSL -o /etc/yum.repos.d/cloudflare-warp.repo https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo || return 1
        yum install -y cloudflare-warp >/dev/null 2>&1 || { _err "安装失败"; return 1; }
    fi
    check_cmd warp-cli || { _err "warp-cli 未就绪"; return 1; }
    systemctl enable --now warp-svc >/dev/null 2>&1
    sleep 2
    _ok "WARP 官方客户端安装完成"
}

configure_warp_official() {
    check_cmd warp-cli || { _err "warp-cli 未安装"; return 1; }
    systemctl is-active warp-svc >/dev/null 2>&1 || { systemctl start warp-svc 2>/dev/null; sleep 3; }

    local st; st=$(warp-cli status 2>/dev/null)
    if echo "$st" | grep -qi "Registration Missing" || [[ -z "$st" ]]; then
        _info "注册 WARP 账户..."
        warp-cli --accept-tos registration new >/dev/null 2>&1 || yes | warp-cli registration new >/dev/null 2>&1
        sleep 3
    fi
    _info "设置代理模式 (SOCKS5 127.0.0.1:${WARP_OFFICIAL_PORT})..."
    warp-cli mode proxy >/dev/null 2>&1 || warp-cli set-mode proxy >/dev/null 2>&1
    warp-cli proxy port "$WARP_OFFICIAL_PORT" >/dev/null 2>&1 || warp-cli set-proxy-port "$WARP_OFFICIAL_PORT" >/dev/null 2>&1
    warp-cli connect >/dev/null 2>&1

    local i=0
    while [[ $i -lt 20 ]]; do
        sleep 2
        warp-cli status 2>/dev/null | grep -qiE "Connected" && break
        ((i++))
    done
    warp-cli status 2>/dev/null | grep -qiE "Connected" || { _err "WARP 连接超时"; warp-cli status 2>/dev/null | sed 's/^/  /'; return 1; }
    db_set_warp_mode "official"
    _ok "WARP 官方客户端已连接"
    local ip
    ip=$(curl -s --connect-timeout 8 --socks5 "127.0.0.1:$WARP_OFFICIAL_PORT" https://api.ipify.org 2>/dev/null)
    [[ -n "$ip" ]] && echo -e "  WARP 出口 IP: ${G}${ip}${NC}" >&2
}

uninstall_warp() {
    local mode; mode=$(db_get_warp_mode)
    _info "卸载 WARP..."
    if [[ "$mode" == "official" ]]; then
        warp-cli disconnect >/dev/null 2>&1
        systemctl disable --now warp-svc >/dev/null 2>&1
        if [[ "$DISTRO" == "debian" || "$DISTRO" == "ubuntu" ]]; then
            apt-get remove -y cloudflare-warp >/dev/null 2>&1
            rm -f /etc/apt/sources.list.d/cloudflare-client.list /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
        elif [[ "$DISTRO" == "centos" ]]; then
            yum remove -y cloudflare-warp >/dev/null 2>&1
            rm -f /etc/yum.repos.d/cloudflare-warp.repo
        fi
    fi
    rm -f "$WARP_CONF_FILE" /usr/local/bin/wgcf ~/.wgcf-account.toml 2>/dev/null
    db_set_warp_mode "disabled"
    # 移除引用 WARP 的分流规则
    _db_apply '.routing_rules = ((.routing_rules // []) | map(select(.outbound != "warp")))'
    reload_config
    _ok "WARP 已卸载"
}

test_warp_connection() {
    local mode st; mode=$(db_get_warp_mode); st=$(warp_status)
    echo "" >&2; _line
    case "$mode" in
        official)
            echo -e "  模式: ${G}官方客户端 (TCP/SOCKS5:${WARP_OFFICIAL_PORT})${NC}" >&2
            [[ "$st" == "connected" ]] && echo -e "  状态: ${G}已连接${NC}" >&2 || echo -e "  状态: ${R}未连接${NC}" >&2
            local ip; ip=$(curl -s --connect-timeout 8 --socks5 "127.0.0.1:$WARP_OFFICIAL_PORT" https://api.ipify.org 2>/dev/null)
            echo -e "  WARP 出口: ${G}${ip:-获取失败}${NC}" >&2 ;;
        wgcf)
            echo -e "  模式: ${C}WGCF (UDP/WireGuard, Sing-box 内置)${NC}" >&2
            if [[ -f "$WARP_CONF_FILE" ]]; then
                echo -e "  端点: ${G}$(jq -r '.endpoint' "$WARP_CONF_FILE")${NC}" >&2
                echo -e "  内网: ${D}$(jq -r '.address_v4' "$WARP_CONF_FILE")${NC}" >&2
            fi
            echo -e "  状态: ${G}配置就绪${NC}（实际连通性由 Sing-box 出站决定）" >&2 ;;
        *) echo -e "  ${D}WARP 未配置${NC}" >&2 ;;
    esac
    echo -e "  直连出口: ${C}$(get_ipv4)${NC}" >&2
    _line
}
#═══════════════════════════════════════════════════════════════════════════════
# 分享链接生成
#═══════════════════════════════════════════════════════════════════════════════
# sni -> 0 表示"真实证书且覆盖该 SNI"，用于决定链接里要不要带 insecure
# 用 _cert_covers 而不是与 cert_domain 字符串相等：
# 通配符证书下 cert_domain 可能是 *.example.com 而实际 SNI 是 node.example.com
_cert_real_for() {
    local sni="$1"
    [[ -z "$sni" ]] && return 1
    _is_real_cert || return 1
    _cert_covers "$sni"
}

_fmt_addr() { local ip="$1"; if [[ "$ip" == *:* && "$ip" != \[* ]]; then echo "[$ip]"; else echo "$ip"; fi; }

# SS 客户端密码：SS2022 多用户模式需 "服务端PSK:用户PSK"；单用户 / 传统 SS 直接用密码
_ss_client_password() {
    local cfg="$1" secret="$2" spsk
    spsk=$(echo "$cfg" | jq -r '.password // empty')
    if [[ -n "$spsk" && -n "$secret" && "$spsk" != "$secret" ]]; then
        echo "${spsk}:${secret}"
    else
        echo "${secret:-$spsk}"
    fi
}

# 实例级连接地址覆盖：db 里的 address 字段优先，否则用探测到的公网 IP
# 用途：让客户端用域名连接（ipv6.example.com 走 IPv6 / ipv4.example.com 走 IPv4），
# 而 SNI 单独指向证书里的名字，两者互不影响
_instance_addr() {
    local cfg="$1" fallback="$2" ov
    ov=$(echo "$cfg" | jq -r '.address // empty' 2>/dev/null)
    [[ -n "$ov" && "$ov" != "null" ]] && { echo "$ov"; return 0; }
    echo "$fallback"
}

# build_share_link <proto> <cfg> <addr> <label> [secret] [username]
build_share_link() {
    local proto="$1" cfg="$2" addr="$3" label="$4" secret="${5:-}" uname="${6:-}"
    addr=$(_instance_addr "$cfg" "$addr")
    addr=$(_fmt_addr "$addr")
    [[ -z "$uname" ]] && uname=$(echo "$cfg" | jq -r '.username // empty')
    local port sni path insec="1"
    port=$(echo "$cfg" | jq -r '.port')
    sni=$(echo "$cfg" | jq -r '.sni // empty')
    path=$(echo "$cfg" | jq -r '.path // empty')
    _cert_real_for "$sni" && insec="0"
    local name; name=$(urlencode "$label")

    case "$proto" in
        vless-reality)
            local pbk sid
            pbk=$(echo "$cfg" | jq -r '.public_key')
            sid=$(echo "$cfg" | jq -r '.short_id')
            echo "vless://${secret}@${addr}:${port}?encryption=none&security=reality&type=tcp&sni=${sni}&fp=chrome&pbk=${pbk}&sid=${sid}&flow=xtls-rprx-vision#${name}" ;;
        vless-vision)
            echo "vless://${secret}@${addr}:${port}?encryption=none&security=tls&sni=${sni}&type=tcp&fp=chrome&flow=xtls-rprx-vision&allowInsecure=${insec}#${name}" ;;
        vless-ws)
            echo "vless://${secret}@${addr}:${port}?encryption=none&security=tls&sni=${sni}&type=ws&host=${sni}&path=$(urlencode "$path")&allowInsecure=${insec}#${name}" ;;
        vless-ws-notls)
            local host; host=$(echo "$cfg" | jq -r '.host // empty')
            local l
            l="vless://${secret}@${addr}:${port}?encryption=none&security=none&type=ws&path=$(urlencode "$path")"
            [[ -n "$host" ]] && l="${l}&host=${host}"
            echo "${l}#${name}" ;;
        vmess-ws)
            local json
            json="{\"v\":\"2\",\"ps\":\"${label}\",\"add\":\"${addr//[\[\]]/}\",\"port\":\"${port}\",\"id\":\"${secret}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${sni}\",\"path\":\"${path}\",\"tls\":\"tls\",\"sni\":\"${sni}\",\"allowInsecure\":\"${insec}\"}"
            printf 'vmess://%s\n' "$(printf '%s' "$json" | base64 -w 0 2>/dev/null || printf '%s' "$json" | base64 | tr -d '\n')" ;;
        trojan)
            echo "trojan://${secret}@${addr}:${port}?security=tls&sni=${sni}&type=tcp&allowInsecure=${insec}#${name}" ;;
        trojan-ws)
            echo "trojan://${secret}@${addr}:${port}?security=tls&sni=${sni}&type=ws&host=${sni}&path=$(urlencode "$path")&allowInsecure=${insec}#${name}" ;;
        hy2)
            local hup hdown extra=""
            hup=$(echo "$cfg" | jq -r '.up_mbps // 0'); hdown=$(echo "$cfg" | jq -r '.down_mbps // 0')
            # Brutal 模式下客户端必须申报带宽，否则服务端退回 BBR
            [[ "$hup" -gt 0 && "$hdown" -gt 0 ]] && extra="&upmbps=${hdown}&downmbps=${hup}"
            local hs he
            hs=$(echo "$cfg" | jq -r '.hop_start // 0'); he=$(echo "$cfg" | jq -r '.hop_end // 0')
            [[ "$(echo "$cfg" | jq -r '.hop_enable // 0')" == "1" ]] && extra="${extra}&mport=${hs}-${he}"
            echo "hysteria2://${secret}@${addr}:${port}?sni=${sni}&insecure=${insec}${extra}#${name}" ;;
        tuic)
            local pw; pw=$(echo "$cfg" | jq -r '.password')
            echo "tuic://${secret}:${pw}@${addr}:${port}?congestion_control=bbr&alpn=h3&sni=${sni}&udp_relay_mode=native&allow_insecure=${insec}#${name}" ;;
        anytls)
            echo "anytls://${secret}@${addr}:${port}?sni=${sni}&insecure=${insec}#${name}" ;;
        ss2022|ss-legacy)
            local method pw ui
            method=$(echo "$cfg" | jq -r '.method')
            pw=$(_ss_client_password "$cfg" "$secret")
            ui=$(printf '%s:%s' "$method" "$pw" | base64 -w 0 2>/dev/null || printf '%s:%s' "$method" "$pw" | base64 | tr -d '\n')
            echo "ss://${ui}@${addr}:${port}#${name}" ;;
        socks)
            local am; am=$(echo "$cfg" | jq -r '.auth_mode // "password"')
            if [[ "$am" == "noauth" ]]; then
                echo "socks5://${addr}:${port}#${name}"
            else
                echo "socks5://$(urlencode "$uname"):$(urlencode "$secret")@${addr}:${port}#${name}"
            fi ;;
        naive)
            local domain; domain=$(echo "$cfg" | jq -r '.domain // .sni')
            echo "naive+https://$(urlencode "$uname"):$(urlencode "$secret")@${domain}:${port}#${name}" ;;
        ss2022-shadowtls)
            local method spw pw
            method=$(echo "$cfg" | jq -r '.method')
            spw=$(echo "$cfg" | jq -r '.stls_password')
            pw=$(_ss_client_password "$cfg" "$secret")
            local ui; ui=$(printf '%s:%s' "$method" "$pw" | base64 -w 0 2>/dev/null || printf '%s:%s' "$method" "$pw" | base64 | tr -d '\n')
            echo "ss://${ui}@${addr}:${port}?plugin=shadow-tls%3Bhost%3D${sni}%3Bpassword%3D${spw}%3Bversion%3D3#${name}" ;;
        snell|snell-v5|snell-v6|snell-shadowtls|snell-v5-shadowtls)
            echo "" ;;   # Snell 无标准 URI，使用 Surge 配置行
        *) echo "" ;;
    esac
}

# 打印 Surge / Clash 片段（针对无标准 URI 或需要特殊格式的协议）
print_client_snippet() {
    local proto="$1" cfg="$2" addr="$3" label="$4" secret="${5:-}" uname="${6:-}"
    addr=$(_instance_addr "$cfg" "$addr")
    local port psk version sni stls method
    port=$(echo "$cfg" | jq -r '.port')
    sni=$(echo "$cfg" | jq -r '.sni // empty')
    [[ -z "$uname" ]] && uname=$(echo "$cfg" | jq -r '.username // empty')
    case "$proto" in
        snell|snell-v5|snell-v6)
            psk=$(echo "$cfg" | jq -r '.psk')
            version=$(echo "$cfg" | jq -r '.version // "4"')
            local tfo mode_p=""; tfo=$(echo "$cfg" | jq -r '.tfo // "true"')
            # v6 的 mode 必须与服务端一致；低于 v6 传 mode 是 Surge 配置错误
            [[ "$version" == "6" ]] && mode_p=", mode=$(echo "$cfg" | jq -r '.mode // "default"')"
            echo -e "  ${Y}Surge:${NC}" >&2
            echo -e "  ${C}${label} = snell, ${addr}, ${port}, psk=${psk}, version=${version}, reuse=true, tfo=${tfo}${mode_p}${NC}" >&2 ;;
        snell-shadowtls|snell-v5-shadowtls)
            psk=$(echo "$cfg" | jq -r '.psk')
            version=$(echo "$cfg" | jq -r '.version // "4"')
            stls=$(echo "$cfg" | jq -r '.stls_password')
            echo -e "  ${Y}Surge:${NC}" >&2
            echo -e "  ${C}${label} = snell, ${addr}, ${port}, psk=${psk}, version=${version}, reuse=true, tfo=true, shadow-tls-password=${stls}, shadow-tls-sni=${sni}, shadow-tls-version=3${NC}" >&2 ;;
        ss2022|ss2022-shadowtls)
            method=$(echo "$cfg" | jq -r '.method')
            local pw; pw=$(_ss_client_password "$cfg" "$secret")
            stls=$(echo "$cfg" | jq -r '.stls_password // empty')
            echo -e "  ${Y}Surge:${NC}" >&2
            if [[ -n "$stls" ]]; then
                echo -e "  ${C}${label} = ss, ${addr}, ${port}, encrypt-method=${method}, password=${pw}, shadow-tls-password=${stls}, shadow-tls-sni=${sni}, shadow-tls-version=3${NC}" >&2
                echo -e "  ${Y}Loon:${NC}" >&2
                echo -e "  ${C}${label} = shadowsocks, ${addr}, ${port}, ${method}, \"${pw}\", shadow-tls-password=${stls}, shadow-tls-sni=${sni}, shadow-tls-version=3${NC}" >&2
            else
                echo -e "  ${C}${label} = ss, ${addr}, ${port}, encrypt-method=${method}, password=${pw}, udp-relay=true${NC}" >&2
            fi ;;
        naive)
            local domain; domain=$(echo "$cfg" | jq -r '.domain // .sni')
            echo -e "  ${Y}Shadowrocket (HTTP2):${NC}" >&2
            echo -e "  ${C}http2://${uname}:${secret}@${domain}:${port}${NC}" >&2 ;;
        socks)
            local am; am=$(echo "$cfg" | jq -r '.auth_mode // "password"')
            if [[ "$am" != "noauth" ]]; then
                echo -e "  ${Y}Surge:${NC}" >&2
                echo -e "  ${C}${label} = socks5, ${addr}, ${port}, ${uname}, ${secret}${NC}" >&2
            fi ;;
    esac
}

# 取协议实例的“主凭证” + 展示名（default 用户或实例自身）
_primary_secret() {    local proto="$1" cfg="$2" s
    s=$(echo "$cfg" | jq -r '[(.users // [])[] | select((.enabled // true) == true)][0].secret // empty')
    [[ -z "$s" ]] && s=$(echo "$cfg" | jq -r '.uuid // .password // .psk // empty')
    echo "$s"
}
_primary_user_name() {
    local n; n=$(echo "$2" | jq -r '[(.users // [])[] | select((.enabled // true) == true)][0].name // empty')
    echo "${n:-default}"
}

# _instance_user_pairs <proto> <instance_json> -> 逐行 "用户名|凭证"
# 无 users[] 的实例（如传统 SS、Snell、旧库迁移数据）回落到实例自身凭证，
# 保证订阅/链接生成不会静默漏掉这些节点。
_instance_user_pairs() {
    local proto="$1" cfg="$2" pairs
    pairs=$(echo "$cfg" | jq -r '[(.users // [])[] | select((.enabled // true) == true)] | .[] | "\(.name)|\(.secret)"')
    if [[ -n "$pairs" ]]; then
        echo "$pairs"
        return 0
    fi
    local sec label
    sec=$(_primary_secret "$proto" "$cfg")
    [[ -z "$sec" ]] && return 1
    label=$(echo "$cfg" | jq -r '.username // empty')
    [[ -z "$label" ]] && label=$(echo "$cfg" | jq -r '.port')
    printf '%s|%s\n' "$label" "$sec"
}

#═══════════════════════════════════════════════════════════════════════════════
# 协议信息展示
#═══════════════════════════════════════════════════════════════════════════════
show_single_protocol_info() {
    local proto="$1" clear_screen="${2:-true}" want_port="${3:-}"
    local core; core=$(proto_core "$proto")
    db_exists "$core" "$proto" || { _err "协议 $proto 不存在"; return 1; }

    local cfg
    if [[ -n "$want_port" ]]; then
        cfg=$(db_inst "$core" "$proto" "$want_port")
    else
        local ports; ports=$(db_list_ports "$core" "$proto")
        local cnt; cnt=$(echo "$ports" | sed '/^$/d' | wc -l)
        if [[ "$cnt" -gt 1 ]]; then
            echo "" >&2
            echo -e "  ${C}协议 ${Y}$(get_protocol_name "$proto")${C} 有 ${cnt} 个端口实例:${NC}" >&2
            local i=1 arr=()
            while IFS= read -r p; do [[ -z "$p" ]] && continue; _item "$i" "端口 ${G}${p}${NC}"; arr+=("$p"); ((i++)); done <<<"$ports"
            _item "0" "返回"
            local ch; read -rp "  请选择: " ch
            [[ "$ch" == "0" || -z "$ch" ]] && return 0
            [[ "$ch" =~ ^[0-9]+$ ]] && (( ch >= 1 && ch <= ${#arr[@]} )) || { _err "无效选择"; return 1; }
            cfg=$(db_inst "$core" "$proto" "${arr[$((ch-1))]}")
        else
            cfg=$(db_instances "$core" "$proto" | head -1)
        fi
    fi
    [[ -z "$cfg" ]] && { _err "未找到配置"; return 1; }

    local ipv4 ipv6 cc port
    ipv4=$(get_ipv4); ipv6=$(get_ipv6)
    cc=$(get_ip_country "$ipv4"); [[ -z "$cc" || "$cc" == "XX" ]] && cc=$(get_ip_country "$ipv6")
    port=$(echo "$cfg" | jq -r '.port')

    [[ "$clear_screen" == "true" ]] && _header
    _line
    echo -e "  ${W}$(get_protocol_name "$proto") 配置详情${NC}" >&2
    _line
    [[ -n "$ipv4" ]] && echo -e "  IPv4: ${G}${ipv4}${NC}" >&2
    [[ -n "$ipv6" ]] && echo -e "  IPv6: ${G}${ipv6}${NC}" >&2
    echo -e "  端口: ${G}${port}${NC}" >&2

    # 关键参数
    local k
    for k in sni path domain method version mode dns dns_ip_preference; do
        local v; v=$(echo "$cfg" | jq -r --arg k "$k" '.[$k] // empty')
        [[ -n "$v" ]] && echo -e "  $(printf '%-14s' "$k"): ${G}${v}${NC}" >&2
    done
    local pbk sid stls bport am la
    pbk=$(echo "$cfg" | jq -r '.public_key // empty'); [[ -n "$pbk" ]] && echo -e "  公钥          : ${G}${pbk}${NC}" >&2
    sid=$(echo "$cfg" | jq -r '.short_id // empty');   [[ -n "$sid" ]] && echo -e "  ShortID       : ${G}${sid}${NC}" >&2
    stls=$(echo "$cfg" | jq -r '.stls_password // empty'); [[ -n "$stls" ]] && echo -e "  ShadowTLS 密码: ${G}${stls}${NC}" >&2
    bport=$(echo "$cfg" | jq -r '.backend_port // empty'); [[ -n "$bport" ]] && echo -e "  后端端口      : ${D}${bport}${NC}" >&2
    am=$(echo "$cfg" | jq -r '.auth_mode // empty');   [[ -n "$am" ]] && echo -e "  认证模式      : ${G}${am}${NC}" >&2
    la=$(echo "$cfg" | jq -r '.listen_addr // empty'); [[ -n "$la" ]] && echo -e "  监听地址      : ${G}${la}${NC}" >&2
    local hop; hop=$(echo "$cfg" | jq -r '.hop_enable // 0')
    [[ "$hop" == "1" ]] && echo -e "  端口跳跃      : ${G}$(echo "$cfg" | jq -r '.hop_start')-$(echo "$cfg" | jq -r '.hop_end')${NC}" >&2

    # 用户与链接
    local users_json cnt_users
    users_json=$(echo "$cfg" | jq -c '[(.users // [])[] | select((.enabled // true) == true)]')
    cnt_users=$(echo "$users_json" | jq 'length')
    _line

    local addr="$ipv4"; [[ -z "$addr" ]] && addr="$ipv6"
    local uname secret label link
    if [[ "$cnt_users" -gt 0 ]]; then
        while IFS='|' read -r uname secret; do
            [[ -z "$uname" ]] && continue
            label=$(_node_label "$proto" "$cc" "$uname")
            echo -e "  ${Y}用户: ${uname}${NC}" >&2
            link=$(build_share_link "$proto" "$cfg" "$addr" "$label" "$secret" "$uname")
            if [[ -n "$link" ]]; then
                echo -e "  ${G}${link}${NC}" >&2
                [[ "$cnt_users" -eq 1 ]] && { echo "" >&2; gen_qr "$link" >&2; }
            fi
            print_client_snippet "$proto" "$cfg" "$addr" "$label" "$secret" "$uname"
            echo "" >&2
        done < <(echo "$users_json" | jq -r '.[] | "\(.name)|\(.secret)"')
    else
        secret=$(_primary_secret "$proto" "$cfg")
        label=$(_node_label "$proto" "$cc" "")
        link=$(build_share_link "$proto" "$cfg" "$addr" "$label" "$secret")
        [[ -n "$link" ]] && { echo -e "  ${C}分享链接:${NC}" >&2; echo -e "  ${G}${link}${NC}" >&2; echo "" >&2; gen_qr "$link" >&2; }
        print_client_snippet "$proto" "$cfg" "$addr" "$label" "$secret"
    fi

    _line
    local sni; sni=$(echo "$cfg" | jq -r '.sni // empty')
    if [[ -n "$sni" ]] && ! _cert_real_for "$sni" && [[ "$proto" != "vless-reality" ]]; then
        echo -e "  ${Y}⚠ 当前使用自签证书，客户端需开启「跳过证书验证 / allowInsecure」${NC}" >&2
    fi
    [[ "$hop" == "1" ]] && echo -e "  ${Y}⚠ 端口跳跃已启用，客户端端口可填 $(echo "$cfg" | jq -r '.hop_start')-$(echo "$cfg" | jq -r '.hop_end')${NC}" >&2
    [[ "$clear_screen" == "true" ]] && _pause
    return 0
}

show_all_share_links() {
    _header
    echo -e "  ${W}全部协议分享链接${NC}" >&2
    _line
    local ipv4 ipv6 cc addr proto cfg core secret uname label link found=false
    ipv4=$(get_ipv4); ipv6=$(get_ipv6)
    cc=$(get_ip_country "$ipv4"); [[ -z "$cc" || "$cc" == "XX" ]] && cc=$(get_ip_country "$ipv6")
    addr="$ipv4"; [[ -z "$addr" ]] && addr="$ipv6"

    for proto in $(db_all_protocols); do
        core=$(proto_core "$proto")
        while IFS= read -r cfg; do
            [[ -z "$cfg" ]] && continue
            found=true
            echo -e "  ${Y}$(get_protocol_name "$proto") (端口 $(echo "$cfg" | jq -r '.port'))${NC}" >&2
            while IFS='|' read -r uname secret; do
                [[ -z "$uname" ]] && continue
                label=$(_node_label "$proto" "$cc" "$uname")
                link=$(build_share_link "$proto" "$cfg" "$addr" "$label" "$secret" "$uname")
                [[ -n "$link" ]] && echo -e "  ${G}${link}${NC}" >&2
                print_client_snippet "$proto" "$cfg" "$addr" "$label" "$secret" "$uname"
            done < <(_instance_user_pairs "$proto" "$cfg")
            echo "" >&2
        done < <(db_instances "$core" "$proto")
    done
    [[ "$found" == "false" ]] && echo -e "  ${D}暂无已安装协议${NC}" >&2
    _line
}

show_all_protocols_info() {
    while true; do
        _header
        echo -e "  ${W}已安装协议配置${NC}" >&2
        _line
        local idx=1 arr=() proto core ports
        local sb; sb=$(get_singbox_protocols)
        if [[ -n "$sb" ]]; then
            echo -e "  ${Y}Sing-box 协议 (服务: ${SB_SVC}):${NC}" >&2
            for proto in $sb; do
                ports=$(db_list_ports singbox "$proto" | tr '\n' ',' | sed 's/,$//')
                _item "$idx" "$(get_protocol_name "$proto") ${D}- 端口: ${ports}${NC}"
                arr+=("$proto"); ((idx++))
            done
            echo "" >&2
        fi
        local sn; sn=$(get_snell_protocols)
        if [[ -n "$sn" ]]; then
            echo -e "  ${Y}Snell 独立进程:${NC}" >&2
            for proto in $sn; do
                ports=$(db_list_ports snell "$proto" | tr '\n' ',' | sed 's/,$//')
                _item "$idx" "$(get_protocol_name "$proto") ${D}- 端口: ${ports}${NC}"
                arr+=("$proto"); ((idx++))
            done
            echo "" >&2
        fi
        [[ ${#arr[@]} -eq 0 ]] && { echo -e "  ${D}未安装任何协议${NC}" >&2; _pause; return; }

        _line
        echo -e "  ${D}输入序号查看详细配置/链接/二维码${NC}" >&2
        _item "a" "一键展示所有分享链接"
        _item "0" "返回"
        _line
        local ch; read -rp "  请选择: " ch
        case "$ch" in
            0|"") return ;;
            a|A) show_all_share_links; _pause ;;
            *)
                if [[ "$ch" =~ ^[0-9]+$ ]] && (( ch >= 1 && ch <= ${#arr[@]} )); then
                    show_single_protocol_info "${arr[$((ch-1))]}"
                else
                    _err "无效选择"; sleep 1
                fi ;;
        esac
    done
}

show_services_status() {
    _line
    echo -e "  ${C}服务状态${NC}" >&2
    _line
    local sb; sb=$(get_singbox_protocols)
    if [[ -n "$sb" ]]; then
        if svc status "$SB_SVC" >/dev/null 2>&1; then
            echo -e "  ${G}●${NC} Sing-box - ${G}运行中${NC} ${D}(v$(_sb_version))${NC}" >&2
            local p; for p in $sb; do echo -e "      ${D}└ $(get_protocol_name "$p")${NC}" >&2; done
        else
            echo -e "  ${R}●${NC} Sing-box - ${R}已停止${NC}" >&2
        fi
    fi
    local proto
    for proto in $(get_snell_protocols); do
        if svc status "vless-${proto}" >/dev/null 2>&1; then
            echo -e "  ${G}●${NC} $(get_protocol_name "$proto") - ${G}运行中${NC}" >&2
        else
            echo -e "  ${R}●${NC} $(get_protocol_name "$proto") - ${R}已停止${NC}" >&2
        fi
    done
    _line
}

# 端口级流量统计（iptables 计数器）
readonly TRAFFIC_CHAIN="VLESS_TRAFFIC"
# 端口级流量统计：在自定义链里放"无 target"的匹配规则，只累加计数器，
# 数完自然返回 INPUT 继续走后面的规则。
# 之前用 -j ACCEPT 会短路 INPUT，等于替用户放行了这些端口——那是错的。
sync_traffic_counters() {
    check_cmd iptables || return 1
    firewall_managed || { return 0; }
    iptables -N "$TRAFFIC_CHAIN" 2>/dev/null || true
    iptables -C INPUT -j "$TRAFFIC_CHAIN" 2>/dev/null || iptables -I INPUT 1 -j "$TRAFFIC_CHAIN" 2>/dev/null || true
    iptables -F "$TRAFFIC_CHAIN" 2>/dev/null || true
    local core proto port
    for core in singbox snell; do
        for proto in $(db_list_protocols "$core"); do
            while IFS= read -r port; do
                [[ -z "$port" ]] && continue
                iptables -A "$TRAFFIC_CHAIN" -p tcp --dport "$port" -m comment --comment "vt:${proto}:${port}:tcp" 2>/dev/null || true
                iptables -A "$TRAFFIC_CHAIN" -p udp --dport "$port" -m comment --comment "vt:${proto}:${port}:udp" 2>/dev/null || true
            done < <(db_list_ports "$core" "$proto")
        done
    done
}

show_port_traffic() {
    _header
    echo -e "  ${W}协议流量统计 (入站字节 / iptables 计数)${NC}" >&2
    _line
    check_cmd iptables || { _warn "iptables 不可用"; return; }
    iptables -nL "$TRAFFIC_CHAIN" >/dev/null 2>&1 || {
        _warn "计数器未初始化，正在初始化..."; sync_traffic_counters; }
    printf "  ${W}%-22s %-8s %-14s %-14s${NC}\n" "协议" "端口" "TCP" "UDP" >&2
    _line
    local core proto port tcp udp
    for core in singbox snell; do
        for proto in $(db_list_protocols "$core"); do
            while IFS= read -r port; do
                [[ -z "$port" ]] && continue
                tcp=$(iptables -nvx -L "$TRAFFIC_CHAIN" 2>/dev/null | awk -v c="vt:${proto}:${port}:tcp" '$0~c{print $2; exit}')
                udp=$(iptables -nvx -L "$TRAFFIC_CHAIN" 2>/dev/null | awk -v c="vt:${proto}:${port}:udp" '$0~c{print $2; exit}')
                printf "  %-22s %-8s %-14s %-14s\n" "$(get_protocol_name "$proto")" "$port" \
                    "$(format_bytes "${tcp:-0}")" "$(format_bytes "${udp:-0}")" >&2
            done < <(db_list_ports "$core" "$proto")
        done
    done
    _line
    echo -e "  ${D}说明: 计数在服务重启/规则重建后归零；仅统计入站方向。${NC}" >&2
    echo -e "  ${D}Sing-box 官方版本未提供 CLI 统计客户端，暂不支持按用户精确计费。${NC}" >&2
}
#═══════════════════════════════════════════════════════════════════════════════
# 链式代理：节点录入（手动 / 分享链接 / 订阅）
#═══════════════════════════════════════════════════════════════════════════════
_ask() {  # _ask <提示> <变量名> [默认值] [必填=1]
    local prompt="$1" __var="$2" def="${3:-}" req="${4:-1}" val
    while true; do
        if [[ -n "$def" ]]; then read -rp "  ${prompt} [${def}]: " val; val="${val:-$def}"
        else read -rp "  ${prompt}: " val; fi
        if [[ -z "$val" && "$req" == "1" ]]; then _err "该项不能为空"; continue; fi
        printf -v "$__var" '%s' "$val"; return 0
    done
}

_ask_secret() {  # _ask_secret <提示> <变量名> [必填=1]
    local prompt="$1" __var="$2" req="${3:-1}" val=""
    while true; do
        _read_secret val "  ${prompt}: "
        if [[ -z "$val" && "$req" == "1" ]]; then _err "该项不能为空"; continue; fi
        printf -v "$__var" '%s' "$val"; return 0
    done
}

_ask_host_port() {  # 设置 NODE_SERVER / NODE_PORT
    NODE_SERVER=""; NODE_PORT=""
    echo -e "  ${D}地址可填 IPv4 / IPv6 / 域名；IPv6 不需要方括号${NC}" >&2
    while true; do
        _ask "服务器地址" NODE_SERVER
        NODE_SERVER="${NODE_SERVER#[}"; NODE_SERVER="${NODE_SERVER%]}"
        _is_valid_host "$NODE_SERVER" && break
        _err "地址格式无效"
    done
    while true; do
        _ask "端口" NODE_PORT
        _is_valid_port "$NODE_PORT" && break
        _err "端口必须是 1-65535 的整数"
    done
}

_ask_node_name() {  # 设置 NODE_NAME（去重）
    local def="$1"
    while true; do
        _ask "节点名称（用于分流出口标识）" NODE_NAME "$def"
        if [[ ! "$NODE_NAME" =~ ^[A-Za-z0-9._@-]+$ ]]; then
            _err "名称只能包含字母、数字及 . _ - @ （避免生成配置时出错）"; continue
        fi
        if db_chain_exists "$NODE_NAME"; then
            _warn "节点 $NODE_NAME 已存在"
            read -rp "  是否覆盖? [y/N]: " ov
            [[ "$ov" =~ ^[yY]$ ]] && { db_del_chain_node "$NODE_NAME"; break; }
            continue
        fi
        break
    done
}

_ask_yes() { local a; read -rp "  $1 [y/N]: " a; [[ "$a" =~ ^[yY]$ ]]; }

# 手动录入节点（纯文字交互，无需分享链接）
chain_add_manual() {
    _header
    echo -e "  ${W}手动添加代理节点${NC}" >&2
    _line
    echo -e "  ${D}直接按提示逐项输入服务器信息，无需分享链接${NC}" >&2
    _line
    _item "1" "SOCKS5"
    _item "2" "HTTP / HTTPS"
    _item "3" "Shadowsocks (含 SS2022)"
    _item "4" "VMess"
    _item "5" "VLESS (TLS / REALITY)"
    _item "6" "Trojan"
    _item "7" "Hysteria2"
    _item "8" "TUIC v5"
    _item "9" "AnyTLS"
    _item "0" "返回"
    _line
    local t; read -rp "  请选择协议类型: " t
    [[ "$t" == "0" || -z "$t" ]] && return 0

    local node="" NODE_SERVER NODE_PORT NODE_NAME
    case "$t" in
        1)
            _ask_host_port
            local user pass
            _ask "用户名（无认证直接回车）" user "" 0
            if [[ -n "$user" ]]; then _ask_secret "密码" pass; else pass=""; fi
            _ask_node_name "socks-${NODE_SERVER##*.}-${NODE_PORT}"
            node=$(jq -nc --arg n "$NODE_NAME" --arg s "$NODE_SERVER" --argjson p "$NODE_PORT" \
                --arg u "$user" --arg w "$pass" \
                '{name:$n, type:"socks", server:$s, port:$p} + (if $u != "" then {username:$u, password:$w} else {} end)') ;;
        2)
            _ask_host_port
            local user pass tls="false" sni
            _ask "用户名（无认证直接回车）" user "" 0
            if [[ -n "$user" ]]; then _ask_secret "密码" pass; else pass=""; fi
            _ask_yes "是否为 HTTPS (TLS) 代理?" && tls="true"
            sni=""
            [[ "$tls" == "true" ]] && _ask "SNI（回车使用服务器地址）" sni "$NODE_SERVER" 0
            _ask_node_name "http-${NODE_SERVER##*.}-${NODE_PORT}"
            node=$(jq -nc --arg n "$NODE_NAME" --arg s "$NODE_SERVER" --argjson p "$NODE_PORT" \
                --arg u "$user" --arg w "$pass" --arg tls "$tls" --arg sni "$sni" \
                '{name:$n, type:"http", server:$s, port:$p, tls:$tls, sni:$sni}
                 + (if $u != "" then {username:$u, password:$w} else {} end)') ;;
        3)
            _ask_host_port
            echo -e "  ${D}常见加密: aes-256-gcm / aes-128-gcm / chacha20-ietf-poly1305${NC}" >&2
            echo -e "  ${D}SS2022: 2022-blake3-aes-128-gcm / 2022-blake3-aes-256-gcm${NC}" >&2
            local method pass
            _ask "加密方式" method "aes-256-gcm"
            _ask_secret "密码 / PSK" pass
            _ask_node_name "ss-${NODE_SERVER##*.}-${NODE_PORT}"
            node=$(jq -nc --arg n "$NODE_NAME" --arg s "$NODE_SERVER" --argjson p "$NODE_PORT" \
                --arg m "$method" --arg w "$pass" \
                '{name:$n, type:"shadowsocks", server:$s, port:$p, method:$m, password:$w}') ;;
        4)
            _ask_host_port
            local uuid net="tcp" tls="false" sni path host insec="false"
            _ask_secret "UUID" uuid
            _ask_yes "是否使用 WebSocket 传输?" && net="ws"
            _ask_yes "是否启用 TLS?" && tls="true"
            sni=""; path="/"; host=""
            [[ "$tls" == "true" ]] && { _ask "SNI" sni "$NODE_SERVER"; _ask_yes "跳过证书校验?" && insec="true"; }
            [[ "$net" == "ws" ]] && { _ask "WS Path" path "/"; _ask "WS Host（回车留空）" host "" 0; }
            _ask_node_name "vmess-${NODE_SERVER##*.}-${NODE_PORT}"
            node=$(jq -nc --arg n "$NODE_NAME" --arg s "$NODE_SERVER" --argjson p "$NODE_PORT" \
                --arg id "$uuid" --arg net "$net" --arg tls "$tls" --arg sni "$sni" \
                --arg path "$path" --arg host "$host" --arg ins "$insec" \
                '{name:$n, type:"vmess", server:$s, port:$p, uuid:$id, network:$net,
                  tls:$tls, sni:$sni, path:$path, host:$host, insecure:$ins}') ;;
        5)
            _ask_host_port
            local uuid sec="none" sni pbk sid flow net="tcp" path host insec="false"
            _ask_secret "UUID" uuid
            echo -e "  ${D}安全层: 1) REALITY  2) TLS  3) 无${NC}" >&2
            local sc; read -rp "  请选择 [1]: " sc; sc="${sc:-1}"
            case "$sc" in 1) sec="reality" ;; 2) sec="tls" ;; *) sec="none" ;; esac
            sni=""; pbk=""; sid=""; flow=""; path="/"; host=""
            if [[ "$sec" == "reality" ]]; then
                _ask "SNI (服务器 serverName)" sni
                _ask "Public Key (pbk)" pbk
                _ask "Short ID (sid)" sid "" 0
                _ask_yes "是否使用 xtls-rprx-vision (flow)?" && flow="xtls-rprx-vision"
            elif [[ "$sec" == "tls" ]]; then
                _ask "SNI" sni "$NODE_SERVER"
                _ask_yes "跳过证书校验?" && insec="true"
                _ask_yes "是否使用 xtls-rprx-vision (flow)?" && flow="xtls-rprx-vision"
            fi
            _ask_yes "是否使用 WebSocket 传输?" && { net="ws"; _ask "WS Path" path "/"; _ask "WS Host（回车留空）" host "" 0; flow=""; }
            _ask_node_name "vless-${NODE_SERVER##*.}-${NODE_PORT}"
            node=$(jq -nc --arg n "$NODE_NAME" --arg s "$NODE_SERVER" --argjson p "$NODE_PORT" \
                --arg id "$uuid" --arg sec "$sec" --arg sni "$sni" --arg pbk "$pbk" --arg sid "$sid" \
                --arg flow "$flow" --arg net "$net" --arg path "$path" --arg host "$host" --arg ins "$insec" \
                '{name:$n, type:"vless", server:$s, port:$p, uuid:$id, security:$sec, sni:$sni,
                  public_key:$pbk, short_id:$sid, flow:$flow, network:$net, path:$path,
                  host:$host, insecure:$ins, fingerprint:"chrome"}') ;;
        6)
            _ask_host_port
            local pass sni net="tcp" path insec="false"
            _ask_secret "密码" pass
            _ask "SNI" sni "$NODE_SERVER"
            _ask_yes "跳过证书校验?" && insec="true"
            path="/"
            _ask_yes "是否使用 WebSocket 传输?" && { net="ws"; _ask "WS Path" path "/"; }
            _ask_node_name "trojan-${NODE_SERVER##*.}-${NODE_PORT}"
            node=$(jq -nc --arg n "$NODE_NAME" --arg s "$NODE_SERVER" --argjson p "$NODE_PORT" \
                --arg w "$pass" --arg sni "$sni" --arg net "$net" --arg path "$path" --arg ins "$insec" \
                '{name:$n, type:"trojan", server:$s, port:$p, password:$w, sni:$sni,
                  network:$net, path:$path, insecure:$ins}') ;;
        7|8|9)
            _ask_host_port
            local pass sni insec="false" uuid
            case "$t" in
                7|9) _ask_secret "密码" pass ;;
                8) _ask_secret "UUID" uuid; _ask_secret "密码" pass ;;
            esac
            _ask "SNI" sni "$NODE_SERVER"
            _ask_yes "跳过证书校验?" && insec="true"
            local ty tn
            case "$t" in 7) ty="hysteria2"; tn="hy2" ;; 8) ty="tuic"; tn="tuic" ;; 9) ty="anytls"; tn="anytls" ;; esac
            _ask_node_name "${tn}-${NODE_SERVER##*.}-${NODE_PORT}"
            node=$(jq -nc --arg n "$NODE_NAME" --arg ty "$ty" --arg s "$NODE_SERVER" --argjson p "$NODE_PORT" \
                --arg w "$pass" --arg id "${uuid:-}" --arg sni "$sni" --arg ins "$insec" \
                '{name:$n, type:$ty, server:$s, port:$p, password:$w, sni:$sni, insecure:$ins}
                 + (if $id != "" then {uuid:$id} else {} end)') ;;
        *) _err "无效选择"; return 1 ;;
    esac

    [[ -z "$node" ]] && return 1

    # 双层链式：经 WARP 连接落地
    local wm; wm=$(db_get_warp_mode)
    if [[ "$wm" != "disabled" ]]; then
        if _ask_yes "该节点是否通过 WARP 出站（双层链式）?"; then
            node=$(echo "$node" | jq -c '.via_warp = true')
        fi
    fi

    echo "" >&2; _line
    echo "$node" | jq . >&2
    _line
    _ask_yes "确认添加该节点?" || { _info "已取消"; return 0; }

    if db_add_chain_node "$node"; then
        _ok "节点 $NODE_NAME 已添加"
        if _ask_yes "是否立即为该节点配置分流规则?"; then routing_add_rule; fi
    else
        _err "节点保存失败"
    fi
}

#───────────────────────────────────────────────────────────────────────────────
# 分享链接解析
#───────────────────────────────────────────────────────────────────────────────
_parse_hostport() {  # -> host|port
    local hp="$1" host port
    if [[ "$hp" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then host="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"
    else host="${hp%%:*}"; port="${hp##*:}"; [[ "$host" == "$port" ]] && port=""; fi
    echo "${host}|${port}"
}
_qparam() {
    local params="$1" key="$2" pair; local IFS='&'
    for pair in $params; do
        [[ "$pair" == "$key="* ]] && { urldecode "${pair#*=}"; return; }
    done
}

parse_share_link() {
    local link="$1" out=""
    case "$link" in
        socks://*|socks5://*)
            local c="${link#socks://}"; c="${c#socks5://}"
            local name=""; [[ "$c" == *"#"* ]] && { name=$(urldecode "${c##*#}"); c="${c%%#*}"; }
            c="${c%%\?*}"
            local user="" pass="" hp="$c"
            [[ "$c" == *"@"* ]] && { local ui="${c%%@*}"; hp="${c#*@}"; user=$(urldecode "${ui%%:*}"); pass=$(urldecode "${ui#*:}"); }
            local r; r=$(_parse_hostport "$hp")
            local h="${r%%|*}" p="${r##*|}"
            _is_valid_port "$p" || return 1
            [[ -z "$name" ]] && name="socks-${h##*.}-${p}"
            out=$(jq -nc --arg n "$name" --arg s "$h" --argjson p "$p" --arg u "$user" --arg w "$pass" \
                '{name:$n,type:"socks",server:$s,port:$p} + (if $u != "" then {username:$u,password:$w} else {} end)') ;;
        ss://*)
            local c="${link#ss://}" name="" method="" pass="" h="" p=""
            [[ "$c" == *"#"* ]] && { name=$(urldecode "${c##*#}"); c="${c%%#*}"; }
            c="${c%%\?*}"
            if [[ "$c" == *"@"* ]]; then
                local ui="${c%%@*}" hp="${c#*@}" dec
                dec=$(echo "$ui" | base64 -d 2>/dev/null)
                if [[ "$dec" == *":"* ]]; then method="${dec%%:*}"; pass="${dec#*:}"
                else method=$(urldecode "${ui%%:*}"); pass=$(urldecode "${ui#*:}"); fi
                local r; r=$(_parse_hostport "$hp"); h="${r%%|*}"; p="${r##*|}"
            else
                local dec; dec=$(echo "$c" | base64 -d 2>/dev/null)
                [[ "$dec" == *"@"* ]] || return 1
                local mp="${dec%%@*}" hp="${dec#*@}"
                method="${mp%%:*}"; pass="${mp#*:}"
                local r; r=$(_parse_hostport "$hp"); h="${r%%|*}"; p="${r##*|}"
            fi
            _is_valid_port "$p" || return 1
            [[ -z "$name" ]] && name="ss-${h##*.}-${p}"
            out=$(jq -nc --arg n "$name" --arg s "$h" --argjson p "$p" --arg m "$method" --arg w "$pass" \
                '{name:$n,type:"shadowsocks",server:$s,port:$p,method:$m,password:$w}') ;;
        vmess://*)
            local dec; dec=$(echo "${link#vmess://}" | base64 -d 2>/dev/null)
            [[ -z "$dec" ]] && return 1
            out=$(echo "$dec" | jq -c '{name:(.ps // .name // "vmess"), type:"vmess",
                server:(.add // .server), port:((.port|tostring|tonumber)),
                uuid:(.id // .uuid), network:(.net // "tcp"),
                tls:(if (.tls // "") == "tls" then "true" else "false" end),
                sni:(.sni // .host // ""), path:(.path // "/"), host:(.host // ""), insecure:"true"}' 2>/dev/null) || return 1 ;;
        vless://*)
            local c="${link#vless://}" name=""
            [[ "$c" == *"#"* ]] && { name=$(urldecode "${c##*#}"); c="${c%%#*}"; }
            local uuid="${c%%@*}"; c="${c#*@}"
            local hp="${c%%\?*}" params=""
            [[ "$c" == *"?"* ]] && params="${c#*\?}"
            local r; r=$(_parse_hostport "$hp"); local h="${r%%|*}" p="${r##*|}"
            _is_valid_port "$p" || return 1
            local sec sni pbk sid flow net path host
            sec=$(_qparam "$params" security); [[ -z "$sec" ]] && sec="none"
            sni=$(_qparam "$params" sni); pbk=$(_qparam "$params" pbk); sid=$(_qparam "$params" sid)
            flow=$(_qparam "$params" flow); net=$(_qparam "$params" type); [[ -z "$net" ]] && net="tcp"
            path=$(_qparam "$params" path); [[ -z "$path" ]] && path="/"
            host=$(_qparam "$params" host)
            [[ -z "$name" ]] && name="vless-${h##*.}-${p}"
            out=$(jq -nc --arg n "$name" --arg s "$h" --argjson p "$p" --arg id "$uuid" --arg sec "$sec" \
                --arg sni "$sni" --arg pbk "$pbk" --arg sid "$sid" --arg flow "$flow" --arg net "$net" \
                --arg path "$path" --arg host "$host" \
                '{name:$n,type:"vless",server:$s,port:$p,uuid:$id,security:$sec,sni:$sni,
                  public_key:$pbk,short_id:$sid,flow:$flow,network:$net,path:$path,host:$host,
                  insecure:"true",fingerprint:"chrome"}') ;;
        trojan://*)
            local c="${link#trojan://}" name=""
            [[ "$c" == *"#"* ]] && { name=$(urldecode "${c##*#}"); c="${c%%#*}"; }
            local pass="${c%%@*}"; c="${c#*@}"
            local hp="${c%%\?*}" params=""; [[ "$c" == *"?"* ]] && params="${c#*\?}"
            local r; r=$(_parse_hostport "$hp"); local h="${r%%|*}" p="${r##*|}"
            _is_valid_port "$p" || return 1
            local sni net path
            sni=$(_qparam "$params" sni); [[ -z "$sni" ]] && sni="$h"
            net=$(_qparam "$params" type); [[ -z "$net" ]] && net="tcp"
            path=$(_qparam "$params" path); [[ -z "$path" ]] && path="/"
            [[ -z "$name" ]] && name="trojan-${h##*.}-${p}"
            out=$(jq -nc --arg n "$name" --arg s "$h" --argjson p "$p" --arg w "$(urldecode "$pass")" \
                --arg sni "$sni" --arg net "$net" --arg path "$path" \
                '{name:$n,type:"trojan",server:$s,port:$p,password:$w,sni:$sni,network:$net,path:$path,insecure:"true"}') ;;
        hysteria2://*|hy2://*)
            local c="${link#hysteria2://}"; c="${c#hy2://}"
            local name=""; [[ "$c" == *"#"* ]] && { name=$(urldecode "${c##*#}"); c="${c%%#*}"; }
            local pass="${c%%@*}"; c="${c#*@}"
            local hp="${c%%\?*}" params=""; [[ "$c" == *"?"* ]] && params="${c#*\?}"
            local r; r=$(_parse_hostport "$hp"); local h="${r%%|*}" p="${r##*|}"
            _is_valid_port "$p" || return 1
            local sni; sni=$(_qparam "$params" sni); [[ -z "$sni" ]] && sni="$h"
            [[ -z "$name" ]] && name="hy2-${h##*.}-${p}"
            out=$(jq -nc --arg n "$name" --arg s "$h" --argjson p "$p" --arg w "$(urldecode "$pass")" --arg sni "$sni" \
                '{name:$n,type:"hysteria2",server:$s,port:$p,password:$w,sni:$sni,insecure:"true"}') ;;
        tuic://*)
            local c="${link#tuic://}" name=""
            [[ "$c" == *"#"* ]] && { name=$(urldecode "${c##*#}"); c="${c%%#*}"; }
            local ui="${c%%@*}"; c="${c#*@}"
            local uuid="${ui%%:*}" pass="${ui#*:}"
            local hp="${c%%\?*}" params=""; [[ "$c" == *"?"* ]] && params="${c#*\?}"
            local r; r=$(_parse_hostport "$hp"); local h="${r%%|*}" p="${r##*|}"
            _is_valid_port "$p" || return 1
            local sni; sni=$(_qparam "$params" sni); [[ -z "$sni" ]] && sni="$h"
            [[ -z "$name" ]] && name="tuic-${h##*.}-${p}"
            out=$(jq -nc --arg n "$name" --arg s "$h" --argjson p "$p" --arg id "$uuid" \
                --arg w "$(urldecode "$pass")" --arg sni "$sni" \
                '{name:$n,type:"tuic",server:$s,port:$p,uuid:$id,password:$w,sni:$sni,insecure:"true"}') ;;
        anytls://*)
            local c="${link#anytls://}" name=""
            [[ "$c" == *"#"* ]] && { name=$(urldecode "${c##*#}"); c="${c%%#*}"; }
            local pass="${c%%@*}"; c="${c#*@}"
            local hp="${c%%\?*}" params=""; [[ "$c" == *"?"* ]] && params="${c#*\?}"
            local r; r=$(_parse_hostport "$hp"); local h="${r%%|*}" p="${r##*|}"
            _is_valid_port "$p" || return 1
            local sni; sni=$(_qparam "$params" sni); [[ -z "$sni" ]] && sni="$h"
            [[ -z "$name" ]] && name="anytls-${h##*.}-${p}"
            out=$(jq -nc --arg n "$name" --arg s "$h" --argjson p "$p" --arg w "$(urldecode "$pass")" --arg sni "$sni" \
                '{name:$n,type:"anytls",server:$s,port:$p,password:$w,sni:$sni,insecure:"true"}') ;;
        *) return 1 ;;
    esac
    [[ -n "$out" ]] && echo "$out" || return 1
}

_sanitize_node_name() { echo "$1" | tr -c 'A-Za-z0-9._@-' '-' | sed 's/-\+/-/g; s/^-//; s/-$//' | cut -c1-40; }

chain_add_link() {
    _header
    echo -e "  ${W}通过分享链接添加节点${NC}" >&2
    _line
    echo -e "  ${D}支持: ss:// vmess:// vless:// trojan:// hysteria2:// tuic:// anytls:// socks5://${NC}" >&2
    echo "" >&2
    local link; _read_secret link "  分享链接: "
    [[ -z "$link" ]] && return 0
    local node; node=$(parse_share_link "$link") || { _err "链接解析失败，请检查格式"; return 1; }
    local orig; orig=$(echo "$node" | jq -r '.name')
    local safe; safe=$(_sanitize_node_name "$orig")
    echo "" >&2; _line
    echo "$node" | jq . >&2
    _line
    local NODE_NAME; _ask_node_name "$safe"
    node=$(echo "$node" | jq -c --arg n "$NODE_NAME" '.name = $n')
    local wm; wm=$(db_get_warp_mode)
    [[ "$wm" != "disabled" ]] && _ask_yes "该节点是否通过 WARP 出站（双层链式）?" && node=$(echo "$node" | jq -c '.via_warp = true')
    db_add_chain_node "$node" && _ok "节点 $NODE_NAME 已添加" || _err "添加失败"
}

chain_import_subscription() {
    _header
    echo -e "  ${W}导入订阅${NC}" >&2
    _line
    local url; _read_secret url "  订阅链接 (HTTPS): "
    [[ -z "$url" ]] && return 0
    _is_valid_subscription_url "$url" || { _err "仅允许 HTTPS 订阅（如确需 HTTP 请设置 ALLOW_INSECURE_HTTP_SUBSCRIPTIONS=1）"; return 1; }
    _info "获取订阅内容..."
    local content
    content=$(curl -sL --connect-timeout 10 --max-time 30 --max-filesize "$SUBSCRIPTION_MAX_BYTES" \
        --proto '=https' -- "$url" 2>/dev/null) || { _err "订阅获取失败"; return 1; }
    [[ -z "$content" ]] && { _err "订阅内容为空"; return 1; }
    local dec; dec=$(echo "$content" | base64 -d 2>/dev/null)
    [[ -n "$dec" && "$dec" == *"://"* ]] && content="$dec"
    [[ "$content" != *"://"* ]] && { _err "订阅格式不支持（仅支持 Base64/明文链接列表）"; return 1; }

    local tmp; tmp=$(mktemp)
    local line node cnt=0
    while IFS= read -r line; do
        line=$(echo "$line" | tr -d '\r')
        [[ -z "$line" || "$line" == \#* || "$line" != *"://"* ]] && continue
        node=$(parse_share_link "$line" 2>/dev/null) || continue
        echo "$node" >>"$tmp"; ((cnt++))
    done <<<"$content"

    [[ "$cnt" -eq 0 ]] && { rm -f "$tmp"; _err "未解析到有效节点"; return 1; }
    echo "" >&2
    _ok "解析到 $cnt 个节点"
    echo -e "  ${D}节点列表:${NC}" >&2
    jq -r '"    • " + .name + "  (" + .type + " " + .server + ":" + (.port|tostring) + ")"' "$tmp" | head -30 >&2
    echo "" >&2
    local prefix; _ask "节点名前缀（便于识别，回车留空）" prefix "" 0
    _ask_yes "确认导入这 $cnt 个节点?" || { rm -f "$tmp"; _info "已取消"; return 0; }

    local added=0 skipped=0 name
    while IFS= read -r node; do
        [[ -z "$node" ]] && continue
        name=$(_sanitize_node_name "${prefix}$(echo "$node" | jq -r '.name')")
        [[ -z "$name" ]] && name="node-$RANDOM"
        if db_chain_exists "$name"; then ((skipped++)); continue; fi
        node=$(echo "$node" | jq -c --arg n "$name" '.name = $n')
        db_add_chain_node "$node" && ((added++)) || ((skipped++))
    done <"$tmp"
    rm -f "$tmp"
    _ok "导入完成: 新增 $added，跳过 $skipped"
}

#───────────────────────────────────────────────────────────────────────────────
# 节点延迟测试（基于 Sing-box 临时实例）
#───────────────────────────────────────────────────────────────────────────────
check_node_latency() {  # node_name -> "延迟ms|解析IP" 或 "超时|IP"
    local name="$1" node
    node=$(db_chain_node "$name") || { echo "超时|-"; return; }
    [[ -z "$node" ]] && { echo "超时|-"; return; }
    [[ -x "$SB_BIN" ]] || { echo "N/A|-"; return; }

    local server ip
    server=$(echo "$node" | jq -r '.server')
    if _is_valid_ipv4 "$server" || _is_valid_ipv6 "$server"; then ip="$server"
    elif check_cmd dig; then
        ip=$(dig +short "$server" A 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
        [[ -z "$ip" ]] && ip=$(dig +short "$server" AAAA 2>/dev/null | grep ':' | head -1)
    fi
    [[ -z "$ip" ]] && ip="-"

    local out tmp port cfgfile pid lat=""
    out=$(gen_sb_chain_outbound "$node" "proxy") || { echo "超时|$ip"; return; }
    tmp=$(mktemp -d) || { echo "超时|$ip"; return; }
    port=$(gen_port); cfgfile="$tmp/t.json"
    jq -nc --argjson p "$port" --argjson o "$out" \
        '{log:{level:"error"},
          inbounds:[{type:"mixed",tag:"in",listen:"127.0.0.1",listen_port:$p}],
          outbounds:[$o],
          route:{final:"proxy"}}' >"$cfgfile"
    "$SB_BIN" run -c "$cfgfile" >/dev/null 2>&1 &
    pid=$!
    local i=0
    while [[ $i -lt 25 ]]; do
        sleep 0.2
        if check_cmd nc; then nc -z 127.0.0.1 "$port" &>/dev/null && break
        else timeout 1 bash -c "echo >/dev/tcp/127.0.0.1/$port" &>/dev/null && break; fi
        ((i++))
    done
    local t
    t=$(curl -s -o /dev/null -w '%{time_total}' --connect-timeout "$CURL_TIMEOUT_FAST" \
        --max-time "$CURL_TIMEOUT_NORMAL" --socks5-hostname "127.0.0.1:${port}" "$LATENCY_TEST_URL" 2>/dev/null)
    [[ -n "$t" ]] && lat=$(awk -v x="$t" 'BEGIN{if (x ~ /^[0-9.]+$/ && x+0 > 0) printf "%.0f", x*1000}')
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    rm -rf "$tmp"
    [[ -n "$lat" ]] && echo "${lat}|${ip}" || echo "超时|${ip}"
}

_latency_badge() {
    local l="$1" col="$G"
    [[ "$l" == "超时" ]] && { printf "%b" "[${R}超时${NC}]"; return; }
    [[ "$l" == "N/A" ]] && { printf "%b" "[${D}N/A${NC}]"; return; }
    [[ "$l" =~ ^[0-9]+$ ]] || { printf ""; return; }
    [[ "$l" -gt 1000 ]] && col="$R"
    [[ "$l" -gt 300 && "$l" -le 1000 ]] && col="$Y"
    printf "%b" "[${col}${l}ms${NC}]"
}

chain_list_nodes() {
    local test_latency="${1:-false}"
    _header
    echo -e "  ${W}链式代理节点${NC}" >&2
    _line
    local cnt; cnt=$(db_chain_count)
    [[ "${cnt:-0}" -eq 0 ]] && { echo -e "  ${D}暂无节点${NC}" >&2; _line; return; }

    local rules_map=""
    rules_map=$(db_routing_rules | jq -r '.[] | select(.outbound | startswith("chain:")) | (.outbound | sub("^chain:";"")) + "|" + .type')

    if [[ "$test_latency" == "true" ]]; then
        _info "并发测试 $cnt 个节点延迟（每个节点会启动临时 Sing-box 实例）..."
        local tmpres; tmpres=$(mktemp)
        local names=() n running=0
        while IFS= read -r n; do [[ -n "$n" ]] && names+=("$n"); done < <(db_chain_node_names)
        # 分批并发（不使用 wait -n，兼容 bash 4.1/4.2）
        for n in "${names[@]}"; do
            (
                r=$(check_node_latency "$n")
                lat="${r%%|*}"; ip="${r##*|}"
                num=99999; [[ "$lat" =~ ^[0-9]+$ ]] && num="$lat"
                printf '%s|%s|%s|%s\n' "$num" "$lat" "$n" "$ip" >>"$tmpres"
            ) &
            ((running++))
            if [[ "$running" -ge "$LATENCY_PARALLEL" ]]; then wait; running=0; fi
        done
        wait
        echo "" >&2
        local num lat name ip node used
        while IFS='|' read -r num lat name ip; do
            node=$(db_chain_node "$name")
            used=$(echo "$rules_map" | awk -F'|' -v n="$name" '$1==n{printf "%s ", $2}')
            printf "  %b %-24s ${D}%-10s %-24s${NC} %s\n" "$(_latency_badge "$lat")" "$name" \
                "$(echo "$node" | jq -r '.type')" "$(echo "$node" | jq -r '.server'):$(echo "$node" | jq -r '.port')" \
                "${used:+${Y}← ${used}${NC}}" >&2
        done < <(sort -t'|' -k1 -n "$tmpres")
        rm -f "$tmpres"
    else
        local name node used warp
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            node=$(db_chain_node "$name")
            used=$(echo "$rules_map" | awk -F'|' -v n="$name" '$1==n{printf "%s ", $2}')
            warp=""
            [[ "$(echo "$node" | jq -r '.via_warp // false')" == "true" ]] && warp=" ${M}[经WARP]${NC}"
            printf "  ${G}•${NC} %-24s ${D}%-10s %-28s${NC}%b %s\n" "$name" \
                "$(echo "$node" | jq -r '.type')" "$(echo "$node" | jq -r '.server'):$(echo "$node" | jq -r '.port')" \
                "$warp" "${used:+${Y}← ${used}${NC}}" >&2
        done < <(db_chain_node_names)
    fi
    _line
}

chain_rename_node() {
    local cnt; cnt=$(db_chain_count)
    [[ "${cnt:-0}" -eq 0 ]] && { _warn "暂无节点"; return; }
    chain_list_nodes false
    local old new
    _ask "要重命名的节点名（回车取消）" old "" 0
    [[ -z "$old" ]] && return
    db_chain_exists "$old" || { _err "节点不存在"; return; }
    local NODE_NAME; _ask_node_name "$old"
    new="$NODE_NAME"
    [[ "$new" == "$old" ]] && { _info "名称未变更"; return; }
    if db_rename_chain_node "$old" "$new"; then
        _ok "已重命名: $old → $new"; reload_config
    else
        _err "重命名失败（目标名可能已存在）"
    fi
}

chain_delete_node() {
    local cnt; cnt=$(db_chain_count)
    [[ "${cnt:-0}" -eq 0 ]] && { _warn "暂无节点"; return; }
    _header
    echo -e "  ${W}删除节点${NC}" >&2
    _line
    local i=1 arr=() n
    while IFS= read -r n; do [[ -z "$n" ]] && continue; _item "$i" "$n"; arr+=("$n"); ((i++)); done < <(db_chain_node_names)
    echo -e "  ${D}输入 all 删除全部${NC}" >&2
    _item "0" "返回"
    _line
    local ch; read -rp "  请选择: " ch
    [[ "$ch" == "0" || -z "$ch" ]] && return
    if [[ "$ch" == "all" ]]; then
        _ask_yes "确认删除所有节点及其相关分流规则?" || return
        for n in "${arr[@]}"; do db_del_chain_node "$n"; done
        _ok "已删除全部节点"; reload_config; return
    fi
    [[ "$ch" =~ ^[0-9]+$ ]] && (( ch >= 1 && ch <= ${#arr[@]} )) || { _err "无效选择"; return; }
    n="${arr[$((ch-1))]}"
    _ask_yes "确认删除节点 $n（同时删除引用它的分流规则）?" || return
    db_del_chain_node "$n" && { _ok "已删除 $n"; reload_config; } || _err "删除失败"
}

manage_balancer_groups() {
    while true; do
        _header
        echo -e "  ${W}负载均衡组${NC}" >&2
        _line
        local groups; groups=$(db_balancer_groups)
        if [[ "$(echo "$groups" | jq 'length')" == "0" ]]; then
            echo -e "  ${D}暂无负载均衡组${NC}" >&2
        else
            echo "$groups" | jq -r '.[] | "  • \(.name)  [\(.strategy)]  \(.nodes|length) 个节点: \(.nodes|join(", "))"' >&2
        fi
        _line
        _item "1" "创建 / 覆盖负载均衡组"
        _item "2" "删除负载均衡组"
        _item "0" "返回"
        _line
        local ch; read -rp "  请选择: " ch
        case "$ch" in
            1)
                local cnt; cnt=$(db_chain_count)
                [[ "${cnt:-0}" -eq 0 ]] && { _warn "请先添加链式代理节点"; _pause; continue; }
                local gname; _ask "组名称" gname
                gname=$(_sanitize_node_name "$gname")
                echo "" >&2
                _item "1" "urltest ${D}(自动选择最低延迟，推荐)${NC}"
                _item "2" "selector ${D}(固定使用首个可用节点)${NC}"
                local sc; read -rp "  策略 [1]: " sc; sc="${sc:-1}"
                local strategy="urltest"; [[ "$sc" == "2" ]] && strategy="selector"
                echo "" >&2
                echo -e "  ${D}可用节点:${NC}" >&2
                local i=1 arr=() n
                while IFS= read -r n; do [[ -z "$n" ]] && continue; echo -e "    ${G}$i${NC}) $n" >&2; arr+=("$n"); ((i++)); done < <(db_chain_node_names)
                echo "" >&2
                echo -e "  ${D}输入序号（空格分隔），或输入 all 选择全部${NC}" >&2
                local sel; read -rp "  成员: " sel
                local members=()
                if [[ "$sel" == "all" ]]; then members=("${arr[@]}")
                else
                    local x
                    for x in $sel; do
                        [[ "$x" =~ ^[0-9]+$ ]] && (( x >= 1 && x <= ${#arr[@]} )) && members+=("${arr[$((x-1))]}")
                    done
                fi
                [[ ${#members[@]} -eq 0 ]] && { _err "未选择有效节点"; _pause; continue; }
                db_add_balancer_group "$gname" "$strategy" "${members[@]}" && {
                    _ok "负载均衡组 $gname 已创建 (${#members[@]} 个节点 / $strategy)"
                    echo -e "  ${D}下一步: 在「配置分流规则」中选择出口 → 负载均衡:${gname}${NC}" >&2
                    reload_config
                }
                _pause ;;
            2)
                local gn; _ask "要删除的组名（回车取消）" gn "" 0
                [[ -z "$gn" ]] && continue
                db_del_balancer_group "$gn" && { _ok "已删除 $gn"; reload_config; }
                _pause ;;
            0) return ;;
            *) _err "无效选择"; sleep 1 ;;
        esac
    done
}

manage_chain_proxy() {
    while true; do
        _header
        echo -e "  ${W}配置链式代理${NC}" >&2
        _line
        echo -e "  节点总数: ${C}$(db_chain_count)${NC}   负载均衡组: ${C}$(db_balancer_groups | jq 'length')${NC}" >&2
        _line
        _item "1" "手动添加节点 ${D}(逐项输入 SOCKS5 / SS / VMess / VLESS ...)${NC}"
        _item "2" "分享链接添加节点"
        _item "3" "导入订阅"
        echo -e "  ${D}───────────────────────────────────────────${NC}" >&2
        _item "4" "查看节点列表"
        _item "5" "测试节点延迟"
        _item "6" "重命名节点"
        _item "7" "删除节点"
        _item "8" "负载均衡组管理"
        _item "0" "返回"
        _line
        local ch; read -rp "  请选择: " ch
        case "$ch" in
            1) chain_add_manual; _pause ;;
            2) chain_add_link; _pause ;;
            3) chain_import_subscription; _pause ;;
            4) chain_list_nodes false; _pause ;;
            5) chain_list_nodes true; _pause ;;
            6) chain_rename_node; _pause ;;
            7) chain_delete_node; _pause ;;
            8) manage_balancer_groups ;;
            0) return ;;
            *) _err "无效选择"; sleep 1 ;;
        esac
    done
}

#═══════════════════════════════════════════════════════════════════════════════
# 出口选择器
#═══════════════════════════════════════════════════════════════════════════════
_outbound_display() {
    case "$1" in
        direct) echo "直连" ;;
        warp) echo "WARP" ;;
        block) echo "拦截" ;;
        bind:*) echo "出口IP→${1#bind:}" ;;
        chain:*) echo "节点→${1#chain:}" ;;
        balancer:*) echo "负载→${1#balancer:}" ;;
        *) echo "$1" ;;
    esac
}

# _select_outbound [提示] [allow_block]  -> 通过 stdout 返回 outbound 标识
_select_outbound() {
    local prompt="${1:-选择出口}" allow_block="${2:-false}"
    local opts=() i=1 n
    echo "" >&2
    _line
    echo -e "  ${W}选择出口${NC}" >&2
    _line
    echo -e "  ${G}$i${NC}) 直连 ${D}(本机 IP 出口)${NC}" >&2; opts+=("direct"); ((i++))
    local ws; ws=$(warp_status)
    if [[ "$ws" == "configured" || "$ws" == "connected" ]]; then
        echo -e "  ${G}$i${NC}) WARP" >&2; opts+=("warp"); ((i++))
    fi
    while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        local node; node=$(db_chain_node "$n")
        echo -e "  ${G}$i${NC}) $n ${D}($(echo "$node" | jq -r '.type') $(echo "$node" | jq -r '.server'):$(echo "$node" | jq -r '.port'))${NC}" >&2
        opts+=("chain:$n"); ((i++))
    done < <(db_chain_node_names)
    while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        local g; g=$(db_balancer_group "$n")
        echo -e "  ${G}$i${NC}) 负载均衡: $n ${D}($(echo "$g" | jq -r '.strategy'), $(echo "$g" | jq -r '.nodes|length') 节点)${NC}" >&2
        opts+=("balancer:$n"); ((i++))
    done < <(db_balancer_groups | jq -r '.[].name')
    # 本机多 IP 时提供绑定出口选项
    local lip
    while IFS= read -r lip; do
        [[ -z "$lip" ]] && continue
        echo -e "  ${G}$i${NC}) 绑定本机 IP ${C}${lip}${NC} ${D}(严格同族，不回落)${NC}" >&2
        opts+=("bind:$lip"); ((i++))
    done < <( { get_all_public_ipv4; get_all_public_ipv6; } 2>/dev/null | sed '/^$/d' )
    if [[ "$allow_block" == "true" ]]; then
        echo -e "  ${G}$i${NC}) 拦截 (block)" >&2; opts+=("block"); ((i++))
    fi
    echo -e "  ${G}0${NC}) 返回" >&2
    _line
    local ch; read -rp "  ${prompt} [1]: " ch; ch="${ch:-1}"
    [[ "$ch" == "0" ]] && return 1
    [[ "$ch" =~ ^[0-9]+$ ]] && (( ch >= 1 && ch <= ${#opts[@]} )) || return 1
    echo "${opts[$((ch-1))]}"
}

_select_ip_version() {
    echo "" >&2
    echo -e "  ${Y}匹配的 IP 版本:${NC}" >&2
    _item "1" "ALL ${D}(不限制，推荐)${NC}"
    _item "2" "仅 IPv4"
    _item "3" "仅 IPv6"
    local ch; read -rp "  请选择 [1]: " ch; ch="${ch:-1}"
    case "$ch" in 2) echo "ipv4_only" ;; 3) echo "ipv6_only" ;; *) echo "as_is" ;; esac
}

_rule_display_name() {
    local rtype="$1" match="$2"
    case "$rtype" in
        all) echo "所有流量" ;;
        custom) local d="$match"; [[ ${#d} -gt 26 ]] && d="${d:0:23}..."; echo "自定义 (${d})" ;;
        restrict-cn) echo "禁止回国 (CN)" ;;
        restrict-bt) echo "禁止 BT/PT" ;;
        *) echo "${ROUTING_PRESET_NAMES[$rtype]:-$rtype}" ;;
    esac
}

show_routing_status() {
    echo "" >&2
    echo -e "  ${C}出口状态${NC}" >&2
    _line
    local div; div=$(db_get_direct_ip_version)
    local dtxt
    case "$div" in
        ipv4_only) dtxt="仅 IPv4" ;; ipv6_only) dtxt="仅 IPv6" ;;
        prefer_ipv4) dtxt="优先 IPv4" ;; prefer_ipv6) dtxt="优先 IPv6" ;;
        *) dtxt="AsIs (默认)" ;;
    esac
    echo -e "  直连出口: ${G}${dtxt}${NC}" >&2
    case "$(warp_status)" in
        connected)  echo -e "  WARP    : ${G}● 已连接${NC} ${D}(官方客户端/TCP)${NC}" >&2 ;;
        registered) echo -e "  WARP    : ${Y}● 已注册未连接${NC}" >&2 ;;
        configured) echo -e "  WARP    : ${G}● 已配置${NC} ${D}(WGCF/WireGuard)${NC}" >&2 ;;
        *)          echo -e "  WARP    : ${D}○ 未配置${NC}" >&2 ;;
    esac
    local cnt; cnt=$(db_chain_count)
    [[ "${cnt:-0}" -gt 0 ]] && echo -e "  代理节点: ${G}● ${cnt} 个${NC}" >&2 || echo -e "  代理节点: ${D}○ 无${NC}" >&2
    if db_ip_routing_enabled; then
        echo -e "  多IP路由: ${G}● 已启用${NC} ${D}($(db_ip_routing_rules | jq 'length') 条映射)${NC}" >&2
    else
        echo -e "  多IP路由: ${D}○ 未启用${NC}" >&2
    fi

    _line
    echo -e "  ${C}分流规则${NC} ${D}(自上而下匹配)${NC}" >&2
    _line
    local rules; rules=$(db_routing_rules)
    if [[ "$(echo "$rules" | jq 'length')" == "0" ]]; then
        echo -e "  ${D}未配置分流规则（全部流量走 final: 直连）${NC}" >&2
    else
        local rtype rob rmatch riv mark
        while IFS='|' read -r rtype rob rmatch riv; do
            [[ -z "$rtype" ]] && continue
            case "$riv" in ipv4_only) mark=" ${C}[仅IPv4]${NC}" ;; ipv6_only) mark=" ${C}[仅IPv6]${NC}" ;; *) mark="" ;; esac
            if [[ "$rob" == "block" ]]; then
                echo -e "  ${R}●${NC} $(_rule_display_name "$rtype" "$rmatch") → ${R}拦截${NC}${mark}" >&2
            elif [[ "$rtype" == "all" ]]; then
                echo -e "  ${Y}●${NC} $(_rule_display_name "$rtype" "$rmatch") → ${C}$(_outbound_display "$rob")${NC}${mark}" >&2
            else
                echo -e "  ${G}●${NC} $(_rule_display_name "$rtype" "$rmatch") → ${C}$(_outbound_display "$rob")${NC}${mark}" >&2
            fi
        done < <(echo "$rules" | jq -r '.[] | "\(.type)|\(.outbound)|\(.match // "")|\(.ip_version // "as_is")"')
    fi
    _line
}

#═══════════════════════════════════════════════════════════════════════════════
# 配置分流规则
#═══════════════════════════════════════════════════════════════════════════════
routing_add_rule() {
    _header
    echo -e "  ${W}添加分流规则${NC}" >&2
    _line
    echo -e "  ${D}优先级: 直连规则 > 自定义规则 > 预设规则 > 所有流量${NC}" >&2
    _line
    local i=1 key
    declare -A menu_map=()
    for key in "${ROUTING_PRESET_ORDER[@]}"; do
        # 分组标题，仅用于视觉分隔，不占用编号
        [[ -n "${ROUTING_PRESET_GROUP[$key]:-}" ]] &&
            echo -e "  ${D}── ${ROUTING_PRESET_GROUP[$key]} ──${NC}" >&2
        local extra=""
        # 括号里标注该预设用到的规则集与补充条目数量，便于判断覆盖面
        local rs_cnt dm_cnt
        rs_cnt=$(echo "${ROUTING_PRESETS[$key]}" | tr ',' '\n' | grep -cE '^geosite-|^geoip-')
        dm_cnt=$(echo "${ROUTING_PRESETS[$key]}" | tr ',' '\n' | grep -vcE '^geosite-|^geoip-|^$')
        if [[ "$rs_cnt" -gt 0 && "$dm_cnt" -gt 0 ]]; then
            extra=" ${D}(${rs_cnt} 个规则集 + ${dm_cnt} 条补充)${NC}"
        elif [[ "$rs_cnt" -gt 0 ]]; then
            extra=" ${D}(${rs_cnt} 个规则集)${NC}"
        else
            extra=" ${D}(${dm_cnt} 条自定义，无规则集)${NC}"
        fi
        [[ "$key" == "exchange" ]] && extra=" ${D}(${rs_cnt} 个规则集 + ${dm_cnt} 条补充，不含 .eu)${NC}"
        [[ "$key" == "ngwallet" ]] && extra=" ${D}(${rs_cnt} 个规则集 + ${dm_cnt} 条补充，含 NG 全域 IP)${NC}"
        _item "$i" "${ROUTING_PRESET_NAMES[$key]}${extra}"
        menu_map[$i]="$key"
        ((i++))
    done
    _line
    _item "c" "自定义域名 / IP / geosite / geoip"
    _item "b" "广告屏蔽 (geosite-category-ads-all)"
    _item "a" "所有流量"
    _item "0" "返回"
    _line
    echo -e "  ${D}支持多选：用空格或英文逗号分隔，例如 1 2 4 或 1,2,4${NC}" >&2
    _line

    local input; read -rp "  请选择: " input
    [[ -z "$input" ]] && return 0
    # 统一分隔符后逐项解析
    input=$(echo "$input" | tr ',' ' ' | tr -s ' ')
    local tok rtypes=() want_ads=false want_all=false want_custom=false
    for tok in $input; do
        case "$tok" in
            0) return 0 ;;
            b|B) want_ads=true ;;
            a|A) want_all=true ;;
            c|C) want_custom=true ;;
            *)
                if [[ "$tok" =~ ^[0-9]+$ ]] && [[ -n "${menu_map[$tok]:-}" ]]; then
                    rtypes+=("${menu_map[$tok]}")
                else
                    _err "无效选项: ${tok}"; return 1
                fi ;;
        esac
    done

    # 自定义规则单独收一次输入
    local custom_match=""
    if [[ "$want_custom" == "true" ]]; then
        echo "" >&2
        echo -e "  ${Y}输入自定义匹配规则（英文逗号分隔）:${NC}" >&2
        echo -e "  ${D}• 域名后缀: google.com,youtube.com${NC}" >&2
        echo -e "  ${D}• IP/CIDR : 1.2.3.4,192.168.0.0/16,2001:db8::/32${NC}" >&2
        echo -e "  ${D}• 规则集  : geosite:openai,geoip:cn${NC}" >&2
        read -rp "  匹配规则: " custom_match
        custom_match=$(echo "$custom_match" | tr -d '[:space:]')
        [[ -z "$custom_match" ]] && { _err "不能为空"; return 1; }
    fi

    # 广告屏蔽固定拦截，不问出口
    if [[ "$want_ads" == "true" ]]; then
        db_add_routing_rule "ads" "block" "" "as_is"
        _ok "已添加: 广告屏蔽 → 拦截"
    fi

    local total=$(( ${#rtypes[@]} + $([[ "$want_custom" == "true" ]] && echo 1 || echo 0) + $([[ "$want_all" == "true" ]] && echo 1 || echo 0) ))
    if [[ "$total" -eq 0 ]]; then
        [[ "$want_ads" == "true" ]] && { _info "重建配置..."; reload_config; }
        return 0
    fi

    # 多选时共用同一个出口与 IP 版本
    echo "" >&2
    if [[ "$total" -gt 1 ]]; then
        local selected_names="" k
        for k in "${rtypes[@]}"; do selected_names+="${ROUTING_PRESET_NAMES[$k]}, "; done
        [[ "$want_custom" == "true" ]] && selected_names+="自定义, "
        [[ "$want_all" == "true" ]] && selected_names+="所有流量, "
        echo -e "  ${W}已选 ${total} 条规则:${NC} ${C}${selected_names%, }${NC}" >&2
        echo -e "  ${D}它们将共用同一个出口与 IP 版本设置${NC}" >&2
    fi
    local ob; ob=$(_select_outbound "选择这些规则的出口" "true") || { _info "已取消"; return 0; }
    local iv; iv=$(_select_ip_version)

    # 已存在的预设规则先确认是否覆盖
    local dup=() k
    for k in "${rtypes[@]}"; do db_has_routing_rule "$k" && dup+=("$k"); done
    if [[ ${#dup[@]} -gt 0 ]]; then
        local dn="" d
        for d in "${dup[@]}"; do dn+="${ROUTING_PRESET_NAMES[$d]}, "; done
        _warn "以下规则已存在: ${dn%, }"
        _ask_yes "覆盖它们?" || {
            local keep=()
            for k in "${rtypes[@]}"; do db_has_routing_rule "$k" || keep+=("$k"); done
            rtypes=("${keep[@]}")
        }
    fi

    local added=0
    for k in "${rtypes[@]}"; do
        db_add_routing_rule "$k" "$ob" "" "$iv" &&
            { _ok "已添加: ${ROUTING_PRESET_NAMES[$k]} → $(_outbound_display "$ob")"; ((added++)); }
    done
    if [[ "$want_custom" == "true" ]]; then
        db_add_routing_rule "custom" "$ob" "$custom_match" "$iv" &&
            { _ok "已添加: 自定义[${custom_match}] → $(_outbound_display "$ob")"; ((added++)); }
    fi
    if [[ "$want_all" == "true" ]]; then
        db_add_routing_rule "all" "$ob" "" "$iv" &&
            { _ok "已添加: 所有流量 → $(_outbound_display "$ob")"; ((added++)); }
    fi

    if [[ "$added" -gt 0 || "$want_ads" == "true" ]]; then
        _info "重建配置..."
        reload_config
    fi
}

routing_del_rule() {
    _header
    echo -e "  ${W}删除分流规则${NC}" >&2
    _line
    local rules; rules=$(db_routing_rules)
    [[ "$(echo "$rules" | jq 'length')" == "0" ]] && { _warn "没有分流规则"; return; }
    local i=1 ids=() id rtype rob rmatch
    while IFS='|' read -r id rtype rob rmatch; do
        [[ -z "$id" ]] && continue
        _item "$i" "$(_rule_display_name "$rtype" "$rmatch") → $(_outbound_display "$rob")"
        ids+=("$id"); ((i++))
    done < <(echo "$rules" | jq -r '.[] | "\(.id)|\(.type)|\(.outbound)|\(.match // "")"')
    _item "0" "返回"
    _line
    local ch; read -rp "  请选择: " ch
    [[ "$ch" == "0" || -z "$ch" ]] && return
    [[ "$ch" =~ ^[0-9]+$ ]] && (( ch >= 1 && ch <= ${#ids[@]} )) || { _err "无效选择"; return; }
    db_del_routing_rule "${ids[$((ch-1))]}"
    _ok "已删除规则"
    reload_config
}

configure_routing_rules() {
    while true; do
        _header
        echo -e "  ${W}配置分流规则${NC}" >&2
        show_routing_status
        _item "1" "添加分流规则"
        _item "2" "删除分流规则"
        _item "3" "清空所有规则"
        _item "4" "同步 / 更新规则集 (geosite / geoip)"
        _item "0" "返回"
        _line
        local ch; read -rp "  请选择: " ch
        case "$ch" in
            1) routing_add_rule; _pause ;;
            2) routing_del_rule; _pause ;;
            3)
                _ask_yes "确认清空所有分流规则?" && { db_clear_routing_rules; reload_config; _ok "已清空"; }
                _pause ;;
            4) sync_all_rulesets; reload_config; _pause ;;
            0) return ;;
            *) _err "无效选择"; sleep 1 ;;
        esac
    done
}

#═══════════════════════════════════════════════════════════════════════════════
# 多IP 入出站配置
#═══════════════════════════════════════════════════════════════════════════════
manage_ip_routing() {
    while true; do
        _header
        echo -e "  ${W}多IP 入出站配置${NC}" >&2
        _line
        local ips=() ip
        while IFS= read -r ip; do [[ -n "$ip" ]] && ips+=("$ip"); done < <(get_all_public_ipv4)
        while IFS= read -r ip; do [[ -n "$ip" ]] && ips+=("$ip"); done < <(get_all_public_ipv6)
        local cnt=${#ips[@]}
        db_ip_routing_enabled && echo -e "  状态: ${G}● 已启用${NC}" >&2 || echo -e "  状态: ${R}○ 未启用${NC}" >&2
        echo -e "  本机公网 IP: ${C}${cnt}${NC} 个   映射规则: ${C}$(db_ip_routing_rules | jq 'length')${NC}" >&2
        _line
        if [[ $cnt -gt 0 ]]; then
            echo -e "  ${W}IP 列表:${NC}" >&2
            local i=1 out
            for ip in "${ips[@]}"; do
                out=$(db_ip_routing_outbound "$ip")
                if [[ -n "$out" ]]; then echo -e "    ${C}[$i]${NC} $ip ${G}→${NC} $out" >&2
                else echo -e "    ${C}[$i]${NC} $ip ${D}(未配置)${NC}" >&2; fi
                ((i++))
            done
            _line
        fi
        echo -e "  ${D}原理: 为每个「入站 IP」生成独立监听副本，并绑定指定「出站 IP」${NC}" >&2
        _line
        _item "1" "添加 / 修改映射 (入站IP → 出站IP)"
        _item "2" "删除映射"
        _item "3" "清空所有映射"
        db_ip_routing_enabled && _item "4" "禁用多IP路由" || _item "4" "启用多IP路由"
        _item "5" "应用配置"
        _item "0" "返回"
        _line
        local ch; read -rp "  请选择: " ch
        case "$ch" in
            1)
                [[ $cnt -lt 1 ]] && { _err "未检测到公网 IP"; _pause; continue; }
                local a b
                read -rp "  入站 IP 序号: " a
                read -rp "  出站 IP 序号: " b
                [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] && (( a >= 1 && a <= cnt && b >= 1 && b <= cnt )) || {
                    _err "无效序号"; _pause; continue; }
                local in_ip="${ips[$((a-1))]}" out_ip="${ips[$((b-1))]}"
                echo -e "  ${Y}$in_ip ${G}→${NC} $out_ip${NC}" >&2
                _ask_yes "确认添加?" && { db_add_ip_routing_rule "$in_ip" "$out_ip"; _ok "已添加"; }
                _pause ;;
            2)
                local rules; rules=$(db_ip_routing_rules)
                [[ "$(echo "$rules" | jq 'length')" == "0" ]] && { _err "无映射规则"; _pause; continue; }
                local i=1 arr=() line
                while IFS= read -r line; do
                    echo -e "    ${C}[$i]${NC} $(echo "$line" | jq -r '.inbound_ip') → $(echo "$line" | jq -r '.outbound_ip')" >&2
                    arr+=("$(echo "$line" | jq -r '.inbound_ip')"); ((i++))
                done < <(echo "$rules" | jq -c '.[]')
                local d; read -rp "  要删除的序号: " d
                [[ "$d" =~ ^[0-9]+$ ]] && (( d >= 1 && d <= ${#arr[@]} )) || { _err "无效序号"; _pause; continue; }
                db_del_ip_routing_rule "${arr[$((d-1))]}"; _ok "已删除"; _pause ;;
            3) _ask_yes "确认清空?" && { db_clear_ip_routing_rules; _ok "已清空"; }; _pause ;;
            4)
                if db_ip_routing_enabled; then db_set_ip_routing_enabled false; _info "已禁用"
                else db_set_ip_routing_enabled true; _info "已启用"; fi
                reload_config; _pause ;;
            5) reload_config; _pause ;;
            0) return ;;
            *) _err "无效选择"; sleep 1 ;;
        esac
    done
}

#═══════════════════════════════════════════════════════════════════════════════
# 直连出口设置
#═══════════════════════════════════════════════════════════════════════════════
#═══════════════════════════════════════════════════════════════════════════════
# 本机 IP 分析与出口绑定
#═══════════════════════════════════════════════════════════════════════════════
# 逐个 IP 查地域（同一台机器的多个 IPv6 很可能落在不同段/不同归属）
# 结果缓存到 $CFG/ip_geo.cache，避免每次进菜单都打 API
_ip_geo_cached() {
    local ip="$1" cache="$CFG/ip_geo.cache" line geo
    if [[ -f "$cache" ]]; then
        line=$(grep -m1 "^${ip}|" "$cache" 2>/dev/null) && { echo "${line#*|}"; return 0; }
    fi
    geo=$(curl -sf --connect-timeout 5 --max-time 8 "https://ipinfo.io/${ip}/json" 2>/dev/null |
          jq -r '[(.country // "XX"), (.city // ""), (.org // "")] | join("/")' 2>/dev/null)
    [[ -z "$geo" || "$geo" == "null" ]] && geo="XX//"
    mkdir -p "$CFG"
    printf '%s|%s\n' "$ip" "$geo" >>"$cache"
    echo "$geo"
}

# 本机默认出口 IP（不指定源地址时实际会用哪个）
_default_egress_ip() {
    local fam="${1:-4}" ip
    if [[ "$fam" == "6" ]]; then
        ip=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | grep -oE 'src [0-9a-f:]+' | awk '{print $2}')
    else
        ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}')
    fi
    echo "$ip"
}

# 收集本机所有公网 IP 到 LOCAL_IPS 数组
_collect_local_ips() {
    LOCAL_IPS=()
    local ip
    while IFS= read -r ip; do [[ -n "$ip" ]] && LOCAL_IPS+=("$ip"); done < <(get_all_public_ipv4)
    while IFS= read -r ip; do [[ -n "$ip" ]] && LOCAL_IPS+=("$ip"); done < <(get_all_public_ipv6)
    [[ ${#LOCAL_IPS[@]} -gt 0 ]]
}

analyze_local_ips() {
    _line
    echo -e "  ${W}本机 IP 与地域分析${NC}" >&2
    _line
    if ! _collect_local_ips; then
        _err "未检测到公网 IP（需要 iproute2）"; _line; return 1
    fi
    local d4 d6; d4=$(_default_egress_ip 4); d6=$(_default_egress_ip 6)
    _info "查询各 IP 归属（首次较慢，结果会缓存）..."
    printf "  ${W}%-3s %-40s %-10s %-24s %s${NC}\n" "#" "地址" "族" "归属" "默认出口" >&2
    local i=1 ip geo cc org mark fam
    for ip in "${LOCAL_IPS[@]}"; do
        geo=$(_ip_geo_cached "$ip")
        cc="${geo%%/*}"; org=$(echo "$geo" | cut -d/ -f3 | cut -c1-22)
        [[ "$ip" == *:* ]] && fam="IPv6" || fam="IPv4"
        mark=""
        [[ "$ip" == "$d4" || "$ip" == "$d6" ]] && mark="${G}← 默认${NC}"
        printf "  %-3s %-40s %-10s %-24s %b\n" "$i" "$ip" "$fam" "${cc} $(_flag_emoji "$cc")" "$mark" >&2
        [[ -n "$org" ]] && echo -e "      ${D}${org}${NC}" >&2
        ((i++))
    done
    _line
    echo -e "  ${D}默认出口: IPv4=${d4:-无}  IPv6=${d6:-无}${NC}" >&2
    echo -e "  ${D}不绑定源地址时，出站就走上面这两个；绑定后才会用指定地址${NC}" >&2
    _line
}

# 选一个本机 IP，回显到 stdout
_pick_local_ip() {
    local want="${1:-any}"   # any | v4 | v6
    _collect_local_ips || { _err "未检测到公网 IP"; return 1; }
    local list=() ip
    for ip in "${LOCAL_IPS[@]}"; do
        case "$want" in
            v4) [[ "$ip" == *:* ]] && continue ;;
            v6) [[ "$ip" != *:* ]] && continue ;;
        esac
        list+=("$ip")
    done
    [[ ${#list[@]} -eq 0 ]] && { _err "没有符合条件的地址"; return 1; }
    local i=1 geo
    for ip in "${list[@]}"; do
        geo=$(_ip_geo_cached "$ip")
        _item "$i" "${ip} ${D}(${geo%%/*})${NC}"
        ((i++))
    done
    _item "0" "取消"
    _line
    local ch; read -rp "  选择 IP: " ch
    [[ "$ch" == "0" || -z "$ch" ]] && return 1
    [[ "$ch" =~ ^[0-9]+$ ]] && (( ch >= 1 && ch <= ${#list[@]} )) || { _err "无效选择"; return 1; }
    echo "${list[$((ch-1))]}"
}

# 按规则集把出口绑到某个本机 IP
bind_egress_by_ruleset() {
    _header
    echo -e "  ${W}按规则集绑定出口 IP${NC}" >&2
    analyze_local_ips || { _pause; return; }
    echo "" >&2
    echo -e "  ${D}下面选中的流量将以指定本机 IP 作为源地址出站${NC}" >&2

    local ip; ip=$(_pick_local_ip any) || return
    local fam="IPv4"; [[ "$ip" == *:* ]] && fam="IPv6"

    # 防泄露策略
    echo "" >&2
    _line
    echo -e "  ${W}回落策略（防泄露）${NC}" >&2
    echo -e "  ${D}绑定 ${fam} 出口后，若目标站点只有另一族地址会发生什么：${NC}" >&2
    _line
    if [[ "$ip" == *:* ]]; then
        _item "1" "严格 IPv6 ${D}(推荐；v4-only 站点直接失败，绝不泄露 IPv4)${NC}"
        _item "2" "优先 IPv6，允许回落 ${R}(v4-only 站点会暴露本机 IPv4)${NC}"
    else
        _item "1" "严格 IPv4 ${D}(推荐)${NC}"
        _item "2" "优先 IPv4，允许回落 ${R}(会暴露本机 IPv6)${NC}"
    fi
    _line
    local pc iv=""; read -rp "  请选择 [1]: " pc
    if [[ "${pc:-1}" == "2" ]]; then
        [[ "$ip" == *:* ]] && iv="prefer_ipv6" || iv="prefer_ipv4"
        _warn "已选择允许回落：目标只有另一族地址时会暴露另一个本机 IP"
    fi

    # 选规则集
    echo "" >&2
    _line
    echo -e "  ${W}选择要走这个出口的流量${NC}" >&2
    _line
    local i=1 key
    declare -A m=()
    for key in "${ROUTING_PRESET_ORDER[@]}"; do
        _item "$i" "${ROUTING_PRESET_NAMES[$key]}"; m[$i]="$key"; ((i++))
    done
    _item "c" "自定义域名 / IP / geosite / geoip"
    _item "0" "返回"
    _line
    echo -e "  ${D}支持多选：空格或逗号分隔${NC}" >&2
    local input; read -rp "  请选择: " input
    [[ -z "$input" || "$input" == "0" ]] && return
    input=$(echo "$input" | tr ',' ' ' | tr -s ' ')

    local tok types=() custom=""
    for tok in $input; do
        case "$tok" in
            0) return ;;
            c|C)
                echo -e "  ${D}示例: openai.com,geosite:netflix,1.2.3.0/24${NC}" >&2
                read -rp "  匹配规则: " custom
                custom=$(echo "$custom" | tr -d '[:space:]')
                [[ -z "$custom" ]] && { _err "不能为空"; return; } ;;
            *)
                if [[ "$tok" =~ ^[0-9]+$ ]] && [[ -n "${m[$tok]:-}" ]]; then types+=("${m[$tok]}")
                else _err "无效选项: ${tok}"; return; fi ;;
        esac
    done

    local added=0 t
    for t in "${types[@]}"; do
        db_add_routing_rule "$t" "bind:${ip}" "" "$iv" && {
            _ok "${ROUTING_PRESET_NAMES[$t]} → 出口 ${ip}"; ((added++)); }
    done
    if [[ -n "$custom" ]]; then
        db_add_routing_rule "custom" "bind:${ip}" "$custom" "$iv" && {
            _ok "自定义[${custom}] → 出口 ${ip}"; ((added++)); }
    fi
    [[ "$added" -eq 0 ]] && { _warn "没有添加任何规则"; return; }
    reload_config
    echo "" >&2
    _ok "已生效。可用「出口绑定自检」验证实际出口 IP"
}

# 逐条验证绑定是否真的生效、有没有泄露风险
verify_egress_binding() {
    _line
    echo -e "  ${W}出口绑定自检${NC}" >&2
    _line
    local rules; rules=$(db_routing_rules | jq -c '.[] | select(.outbound | startswith("bind:"))')
    if [[ -z "$rules" ]]; then
        echo -e "  ${D}没有出口绑定规则${NC}" >&2; _line; return
    fi
    _collect_local_ips
    local r ip iv rtype ok
    while IFS= read -r r; do
        [[ -z "$r" ]] && continue
        rtype=$(echo "$r" | jq -r '.type')
        ip=$(echo "$r" | jq -r '.outbound | ltrimstr("bind:")')
        iv=$(echo "$r" | jq -r '.ip_version // ""')
        echo -e "  ${C}${rtype}${NC} → ${G}${ip}${NC}" >&2
        # 地址是否还在本机
        if printf '%s\n' "${LOCAL_IPS[@]}" | grep -qxF "$ip"; then
            echo -e "    ${G}✓${NC} 地址仍在本机" >&2
        else
            echo -e "    ${R}✗${NC} 地址已不在本机，该规则会被跳过" >&2
        fi
        # 防泄露策略
        case "$iv" in
            prefer_ipv4|prefer_ipv6)
                echo -e "    ${Y}!${NC} 允许回落：目标只有另一族地址时会泄露另一个本机 IP" >&2 ;;
            *)
                if [[ "$ip" == *:* ]]; then
                    echo -e "    ${G}✓${NC} 严格 ipv6_only，不会回落到 IPv4" >&2
                else
                    echo -e "    ${G}✓${NC} 严格 ipv4_only" >&2
                fi ;;
        esac
        # 实测该源地址出去看到的是什么
        local seen
        if [[ "$ip" == *:* ]]; then
            seen=$(curl -s -6 --interface "$ip" --connect-timeout 6 --max-time 10 https://ipinfo.io/ip 2>/dev/null)
        else
            seen=$(curl -s -4 --interface "$ip" --connect-timeout 6 --max-time 10 https://ipinfo.io/ip 2>/dev/null)
        fi
        seen=$(echo "$seen" | tr -d '[:space:]')
        if [[ -n "$seen" ]]; then
            if [[ "$seen" == "$ip" ]]; then
                echo -e "    ${G}✓${NC} 实测出口: ${seen}" >&2
            else
                echo -e "    ${Y}!${NC} 实测出口 ${seen} 与绑定地址不同（可能存在 NAT）" >&2
            fi
        else
            echo -e "    ${D}·${NC} 实测跳过（该地址无法访问检测服务）" >&2
        fi
    done <<<"$rules"
    _line
    local d4; d4=$(_default_egress_ip 4)
    [[ -n "$d4" ]] && echo -e "  ${D}未被规则命中的流量仍走默认出口 ${d4}${NC}" >&2
    _line
}

configure_direct_outbound() {
    while true; do
        _header
        echo -e "  ${W}直连出口设置${NC}" >&2
        _line
        echo -e "  当前全局直连 IP 版本: ${G}$(db_get_direct_ip_version)${NC}" >&2
        local nb; nb=$(db_routing_rules | jq '[.[] | select(.outbound | startswith("bind:"))] | length')
        echo -e "  出口 IP 绑定规则: ${G}${nb:-0}${NC} 条" >&2
        _line
        _item "1" "本机 IP 与地域分析"
        _item "2" "按规则集绑定出口 IP ${D}(多 IPv6 分流)${NC}"
        _item "3" "出口绑定自检 ${D}(验证是否泄露)${NC}"
        _item "4" "删除出口绑定规则"
        echo -e "  ${D}───────────────────────────────────────────${NC}" >&2
        _item "5" "全局直连 IP 版本 ${D}(未命中规则的流量)${NC}"
        _item "0" "返回"
        _line
        local ch; read -rp "  请选择: " ch
        case "$ch" in
            1) analyze_local_ips; _pause ;;
            2) bind_egress_by_ruleset; _pause ;;
            3) verify_egress_binding; _pause ;;
            4)
                local rules ids=() r i=1
                rules=$(db_routing_rules | jq -c '.[] | select(.outbound | startswith("bind:"))')
                if [[ -z "$rules" ]]; then _warn "没有出口绑定规则"; _pause; continue; fi
                _line
                while IFS= read -r r; do
                    [[ -z "$r" ]] && continue
                    _item "$i" "$(_rule_display_name "$(echo "$r" | jq -r '.type')" "$(echo "$r" | jq -r '.match // ""')") → $(echo "$r" | jq -r '.outbound | ltrimstr("bind:")')"
                    ids+=("$(echo "$r" | jq -r '.id')"); ((i++))
                done <<<"$rules"
                _item "0" "取消"
                _line
                local dc; read -rp "  要删除的编号: " dc
                [[ "$dc" == "0" || -z "$dc" ]] && continue
                [[ "$dc" =~ ^[0-9]+$ ]] && (( dc >= 1 && dc <= ${#ids[@]} )) || { _err "无效选择"; _pause; continue; }
                db_del_routing_rule "${ids[$((dc-1))]}"
                reload_config
                _ok "已删除"; _pause ;;
            5)
                _line
                _item "1" "AsIs ${D}(默认，不做处理)${NC}"
                _item "2" "优先 IPv4"
                _item "3" "优先 IPv6"
                _item "4" "仅 IPv4"
                _item "5" "仅 IPv6"
                _item "0" "返回"
                _line
                local vc v=""; read -rp "  请选择: " vc
                case "$vc" in
                    1) v="as_is" ;; 2) v="prefer_ipv4" ;; 3) v="prefer_ipv6" ;;
                    4) v="ipv4_only" ;; 5) v="ipv6_only" ;;
                    *) continue ;;
                esac
                db_set_direct_ip_version "$v"
                _ok "全局直连出口已设为: $v"
                reload_config; _pause ;;
            0) return ;;
            *) _err "无效选择"; sleep 1 ;;
        esac
    done
}

#═══════════════════════════════════════════════════════════════════════════════
# 测试分流效果
#═══════════════════════════════════════════════════════════════════════════════
test_routing() {
    _header
    echo -e "  ${W}测试分流效果${NC}" >&2
    _line
    local direct_ip; direct_ip=$(curl -s --connect-timeout 6 https://api.ipify.org 2>/dev/null)
    [[ -z "$direct_ip" ]] && direct_ip=$(curl -s --connect-timeout 6 https://ifconfig.me 2>/dev/null)
    echo -e "  直连出口 IP: ${C}${direct_ip:-获取失败}${NC}" >&2

    local ws; ws=$(warp_status)
    if [[ "$ws" == "connected" ]]; then
        local wip; wip=$(curl -s --connect-timeout 8 --socks5 "127.0.0.1:$WARP_OFFICIAL_PORT" https://api.ipify.org 2>/dev/null)
        echo -e "  WARP 出口 IP: ${G}${wip:-获取超时}${NC}" >&2
    elif [[ "$ws" == "configured" ]]; then
        echo -e "  WARP: ${G}WGCF 已配置${NC} ${D}(由 Sing-box 内置 WireGuard 出站)${NC}" >&2
    fi

    _line
    local cnt; cnt=$(db_chain_count)
    if [[ "${cnt:-0}" -gt 0 ]]; then
        echo -e "  ${W}节点连通性${NC} ${D}(通过临时 Sing-box 实例实测)${NC}" >&2
        local n r
        while IFS= read -r n; do
            [[ -z "$n" ]] && continue
            r=$(check_node_latency "$n")
            printf "  %b %s\n" "$(_latency_badge "${r%%|*}")" "$n" >&2
        done < <(db_chain_node_names)
        _line
    fi

    local rules; rules=$(db_routing_rules)
    if [[ "$(echo "$rules" | jq 'length')" == "0" ]]; then
        _warn "未配置分流规则，所有流量走直连"
    else
        echo -e "  ${W}生效的分流规则${NC}" >&2
        local rtype rob rmatch
        while IFS='|' read -r rtype rob rmatch; do
            [[ -z "$rtype" ]] && continue
            echo -e "  ${G}●${NC} $(_rule_display_name "$rtype" "$rmatch") → $(_outbound_display "$rob")" >&2
        done < <(echo "$rules" | jq -r '.[] | "\(.type)|\(.outbound)|\(.match // "")"')
    fi

    _line
    echo -e "  ${Y}客户端验证:${NC} 连接代理后访问 ${C}https://ip.sb${NC} 查看出口 IP" >&2
    echo -e "  ${D}若显示的 IP 不是 ${direct_ip:-本机IP}，说明分流已生效${NC}" >&2
    echo "" >&2
    echo -e "  ${Y}调试命令:${NC}" >&2
    echo -e "  ${C}sing-box check -c ${SB_CONFIG}${NC}   ${D}# 校验配置${NC}" >&2
    if [[ "$DISTRO" == "alpine" ]]; then
        echo -e "  ${C}rc-service ${SB_SVC} restart${NC}     ${D}# 重启服务${NC}" >&2
        echo -e "  ${C}tail -f /var/log/messages | grep sing-box${NC}" >&2
    else
        echo -e "  ${C}journalctl -u ${SB_SVC} -f${NC}      ${D}# 实时日志${NC}" >&2
    fi
    echo -e "  ${C}sed -i 's/\"level\":\"warn\"/\"level\":\"debug\"/' ${SB_CONFIG} \&\& svc restart${NC} ${D}# 开启调试日志${NC}" >&2
    _line
}

#═══════════════════════════════════════════════════════════════════════════════
# WARP 管理
#═══════════════════════════════════════════════════════════════════════════════
manage_warp() {
    while true; do
        _header
        echo -e "  ${W}WARP 管理${NC}" >&2
        _line
        local st mode; st=$(warp_status); mode=$(db_get_warp_mode)
        case "$st" in
            connected)  echo -e "  状态: ${G}● 已连接${NC}   模式: ${C}官方客户端 (TCP/SOCKS5)${NC}" >&2
                        echo -e "  ${D}抗 UDP 封锁，Sing-box 通过本地 SOCKS5 出站${NC}" >&2 ;;
            registered) echo -e "  状态: ${Y}● 已注册未连接${NC}   模式: ${C}官方客户端${NC}" >&2 ;;
            configured) echo -e "  状态: ${G}● 已配置${NC}   模式: ${C}WGCF (Sing-box 内置 WireGuard)${NC}" >&2
                        [[ -f "$WARP_CONF_FILE" ]] && echo -e "  端点: ${D}$(jq -r '.endpoint' "$WARP_CONF_FILE")${NC}" >&2 ;;
            *)          echo -e "  状态: ${D}○ 未配置${NC}" >&2
                        echo -e "  ${D}WARP 提供 Cloudflare 干净 IP 出口，可用于解锁 ChatGPT / Netflix${NC}" >&2 ;;
        esac
        _line
        if [[ "$st" == "not_configured" ]]; then
            _item "1" "配置 WGCF 模式 ${D}(WireGuard，性能好)${NC}"
            _item "2" "配置官方客户端 ${D}(TCP/SOCKS5，绕过 UDP 封锁)${NC}"
        else
            if [[ "$mode" == "official" ]]; then
                _item "1" "切换到 WGCF 模式"
                _item "2" "重新连接官方客户端"
            else
                _item "1" "切换到官方客户端模式"
                _item "2" "重新获取 WGCF 配置"
            fi
            _item "3" "测试 WARP"
            _item "4" "卸载 WARP"
        fi
        _item "0" "返回"
        _line
        local ch; read -rp "  请选择: " ch
        case "$ch" in
            1)
                if [[ "$st" == "not_configured" || "$mode" == "official" ]]; then
                    [[ "$mode" == "official" ]] && { warp-cli disconnect >/dev/null 2>&1; systemctl disable --now warp-svc >/dev/null 2>&1; }
                    register_warp_wgcf && reload_config
                else
                    install_warp_official && configure_warp_official && reload_config
                fi
                _pause ;;
            2)
                if [[ "$st" == "not_configured" ]]; then
                    install_warp_official && configure_warp_official && reload_config
                elif [[ "$mode" == "official" ]]; then
                    warp-cli disconnect >/dev/null 2>&1; sleep 1; configure_warp_official
                else
                    rm -f "$WARP_CONF_FILE"; register_warp_wgcf && reload_config
                fi
                _pause ;;
            3) test_warp_connection; _pause ;;
            4) _ask_yes "确认卸载 WARP?" && uninstall_warp; _pause ;;
            0) return ;;
            *) _err "无效选择"; sleep 1 ;;
        esac
    done
}

#═══════════════════════════════════════════════════════════════════════════════
# 访问限制
#═══════════════════════════════════════════════════════════════════════════════
access_restriction_enabled() {
    db_has_routing_rule "restrict-cn" || db_has_routing_rule "restrict-bt"
}

manage_access_restrictions() {
    while true; do
        _header
        echo -e "  ${W}访问限制${NC}" >&2
        _line
        local cn="否" bt="否"
        db_has_routing_rule "restrict-cn" && cn="是"
        db_has_routing_rule "restrict-bt" && bt="是"
        echo -e "  禁止回国 (geosite-cn / geoip-cn): ${G}${cn}${NC}" >&2
        echo -e "  禁止 BT/PT (bittorrent 协议嗅探): ${G}${bt}${NC}" >&2
        _line
        _item "1" "$( [[ "$cn" == "是" ]] && echo "关闭禁止回国" || echo "启用禁止回国" )"
        _item "2" "$( [[ "$bt" == "是" ]] && echo "关闭禁止 BT/PT" || echo "启用禁止 BT/PT" )"
        _item "0" "返回"
        _line
        local ch; read -rp "  请选择: " ch
        case "$ch" in
            1)
                if [[ "$cn" == "是" ]]; then
                    db_del_routing_rule "restrict-cn" by_type; _ok "已关闭禁止回国"
                else
                    # 「CN 直连」排序在 direct 组，优先级高于本 block 规则，两者同时存在时后者永不命中
                    if [[ "$(db_routing_rules | jq -r '[.[] | select(.type == "cn" and .outbound == "direct")] | length')" != "0" ]]; then
                        _warn "已存在「中国大陆(CN) → 直连」规则，它的匹配顺序在前，禁止回国将不会生效"
                        _ask_yes "是否先删除该直连规则再启用禁止回国?" && db_del_routing_rule "cn" by_type
                    fi
                    _info "下载 CN 规则集..."
                    db_add_routing_rule "restrict-cn" "block" "geosite-cn,geoip-cn" "as_is"
                    _ok "已启用禁止回国"
                fi
                reload_config; _pause ;;
            2)
                if [[ "$bt" == "是" ]]; then
                    db_del_routing_rule "restrict-bt" by_type; _ok "已关闭禁止 BT/PT"
                else
                    db_add_routing_rule "restrict-bt" "block" "" "as_is"
                    _ok "已启用禁止 BT/PT（通过协议嗅探拦截）"
                fi
                reload_config; _pause ;;
            0) return ;;
            *) _err "无效选择"; sleep 1 ;;
        esac
    done
}

#═══════════════════════════════════════════════════════════════════════════════
# 分流管理主菜单
#═══════════════════════════════════════════════════════════════════════════════
manage_routing() {
    while true; do
        _header
        echo -e "  ${W}分流管理${NC}" >&2
        show_routing_status
        _item "1" "配置链式代理 ${D}(添加/管理代理节点)${NC}"
        _item "2" "配置分流规则"
        _item "3" "多IP入出站配置"
        _item "4" "直连出口设置"
        _item "5" "测试分流效果"
        echo -e "  ${D}───────────────────────────────────────────${NC}" >&2
        _item "6" "WARP 管理"
        _item "7" "访问限制"
        _item "8" "查看当前配置"
        _item "0" "返回"
        _line
        local ch; read -rp "  请选择: " ch
        case "$ch" in
            1) manage_chain_proxy ;;
            2) configure_routing_rules ;;
            3) manage_ip_routing ;;
            4) configure_direct_outbound; _pause ;;
            5) test_routing; _pause ;;
            6) manage_warp ;;
            7) manage_access_restrictions ;;
            8)
                _header
                echo -e "  ${W}当前分流配置${NC}" >&2
                _line
                echo -e "  ${C}[数据库 routing_rules]${NC}" >&2
                db_routing_rules | jq . >&2
                echo "" >&2
                echo -e "  ${C}[Sing-box route 段]${NC}" >&2
                if [[ -f "$SB_CONFIG" ]]; then
                    jq '{route: .route, outbounds: [.outbounds[].tag], endpoints: [.endpoints[]?.tag]}' "$SB_CONFIG" >&2
                else
                    echo -e "  ${D}配置文件不存在${NC}" >&2
                fi
                _line
                _pause ;;
            0) return ;;
            *) _err "无效选择"; sleep 1 ;;
        esac
    done
}
#═══════════════════════════════════════════════════════════════════════════════
# 证书管理（独立入口）
#═══════════════════════════════════════════════════════════════════════════════
# 需要真实/自签 TLS 证书文件的协议（REALITY 用的是伪装 SNI，不需要本地证书）
readonly CERT_TLS_PROTOCOLS="vless-vision vless-ws vmess-ws trojan trojan-ws hy2 tuic anytls naive"

_cert_protocols_installed() {
    local p q out=()
    for p in $(db_all_protocols); do
        for q in $CERT_TLS_PROTOCOLS; do
            [[ "$p" == "$q" ]] && { out+=("$p"); break; }
        done
    done
    printf '%s\n' "${out[@]}"
}


show_cert_status() {
    local crt="$SSL_DIR/server.crt" key="$SSL_DIR/server.key"
    _line
    echo -e "  ${W}证书状态${NC}" >&2
    _line
    if [[ ! -s "$crt" || ! -s "$key" ]]; then
        echo -e "  ${D}未找到证书文件 (${crt})${NC}" >&2
        _line
        return 1
    fi
    local domain issuer nb na days sans
    domain=$([[ -f "$CFG/cert_domain" ]] && cat "$CFG/cert_domain")
    issuer=$(openssl x509 -in "$crt" -noout -issuer 2>/dev/null | sed -n 's/.*CN *= *\([^,/]*\).*/\1/p')
    nb=$(openssl x509 -in "$crt" -noout -startdate 2>/dev/null | cut -d= -f2)
    na=$(openssl x509 -in "$crt" -noout -enddate 2>/dev/null | cut -d= -f2)
    sans=$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null | grep -oE 'DNS:[^, ]+' | cut -d: -f2- | tr '\n' ' ')

    if _is_real_cert; then
        echo -e "  类型  : ${G}真实证书${NC} ${D}(签发者: ${issuer:-未知})${NC}" >&2
        local m_ca m_method
        m_ca=$(_meta_get ca) || m_ca=""
        m_method=$(_meta_get method) || m_method=""
        [[ -n "$m_ca" ]] && echo -e "  来源  : ${C}$(_ca_display "$m_ca")${NC}   验证: ${C}${m_method:-未知}${NC}" >&2
    else
        echo -e "  类型  : ${Y}自签证书${NC} ${D}(客户端需勾选跳过证书验证)${NC}" >&2
    fi
    echo -e "  域名  : ${G}${domain:-未记录}${NC}" >&2
    [[ -n "$sans" ]] && echo -e "  SAN   : ${C}${sans}${NC}" >&2
    echo -e "  有效期: ${C}${nb}${NC}  →  ${C}${na}${NC}" >&2

    days=$(_cert_days_left)
    if [[ -n "$days" ]]; then
        if   [[ "$days" -lt 0 ]];  then
            echo -e "  剩余  : ${R}已过期 ${days#-} 天${NC}" >&2
            echo -e "  ${R}后果  : 校验证书的客户端会直接握手失败（勾了 insecure 的暂时无感）${NC}" >&2
            echo -e "  ${C}处理  : 本菜单选 2 重新签发；续期无法救回长期过期的证书${NC}" >&2
        elif [[ "$days" -le 15 ]]; then echo -e "  剩余  : ${R}${days} 天（请尽快续期）${NC}" >&2
        elif [[ "$days" -le 30 ]]; then echo -e "  剩余  : ${Y}${days} 天${NC}" >&2
        else echo -e "  剩余  : ${G}${days} 天${NC}" >&2; fi
    fi

    # 证书与私钥是否配对
    local cm km
    cm=$(openssl x509 -in "$crt" -noout -pubkey 2>/dev/null | openssl md5 2>/dev/null)
    km=$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl md5 2>/dev/null)
    if [[ -n "$cm" && "$cm" == "$km" ]]; then echo -e "  配对  : ${G}证书与私钥匹配${NC}" >&2
    else echo -e "  配对  : ${R}证书与私钥不匹配！服务将无法启动${NC}" >&2; fi

    # 使用该证书的协议
    local users=() p
    while IFS= read -r p; do [[ -n "$p" ]] && users+=("$p"); done < <(_cert_protocols_installed)
    if [[ ${#users[@]} -gt 0 ]]; then
        _line
        echo -e "  ${W}使用本证书的协议${NC}" >&2
        for p in "${users[@]}"; do
            local sni_list addr_list
            sni_list=$(_db_q --arg c "$(proto_core "$p")" --arg p "$p" \
                '[(.[$c][$p] // [])[] | "\(.port)=\(.sni // .domain // "")"] | join("  ")')
            addr_list=$(_db_q --arg c "$(proto_core "$p")" --arg p "$p" \
                '[(.[$c][$p] // [])[] | select((.address // "") != "") | "\(.port)→\(.address)"] | join("  ")')
            echo -e "    ${G}•${NC} $(get_protocol_name "$p") ${D}SNI ${sni_list}${NC}" >&2
            [[ -n "$addr_list" ]] && echo -e "        ${D}连接地址 ${addr_list}${NC}" >&2
            local pp_port pp_sni bad=0
            while IFS= read -r pp_port; do
                [[ -z "$pp_port" ]] && continue
                pp_sni="${pp_port#*=}"
                [[ -z "$pp_sni" || "$pp_sni" == "null" ]] && continue
                _cert_covers "$pp_sni" || bad=1
            done < <(echo "$sni_list" | tr ' ' '\n' | grep '=')
            if [[ "$bad" == "1" ]]; then
                echo -e "      ${Y}↑ 该 SNI 不在证书覆盖范围内，客户端会证书校验失败${NC}" >&2
                echo -e "        ${D}证书绑定域名而非 IP：即使两个域名指向同一台机器也不互通${NC}" >&2
                echo -e "        ${D}出路一: 把 SNI 改成证书里的名字（本菜单 8），连接地址仍可另填域名${NC}" >&2
                echo -e "        ${D}出路二: 重新签发通配符证书一次覆盖所有子域（本菜单 2）${NC}" >&2
            fi
        done
    else
        _line
        echo -e "  ${D}当前没有需要本地证书的协议（REALITY / SS / Snell 不使用）${NC}" >&2
    fi
    _line
    return 0
}

# 换域名后把所有 TLS 协议的 SNI 同步过去
_sync_protocols_sni() {
    local new_domain="$1" changed=0 p core
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        core=$(proto_core "$p")
        db_set_inst_field "$core" "$p" all sni "$new_domain"
        [[ "$p" == "naive" ]] && db_set_inst_field "$core" "$p" all domain "$new_domain"
        ((changed++))
    done < <(_cert_protocols_installed)
    echo "$changed"
}

cert_issue_new() {
    local cur=""
    cur=$(_meta_get acme_domain) || { [[ -f "$CFG/cert_domain" ]] && cur=$(cat "$CFG/cert_domain"); }
    cert_request_wizard "$cur" || return 1

    local n; n=$(_cert_protocols_installed | grep -c .)
    if [[ "${n:-0}" -gt 0 ]]; then
        echo "" >&2
        echo -e "  ${W}有 ${n} 个协议使用本地证书${NC}" >&2
        local names; names=$(_cert_names)
        echo -e "  ${D}证书覆盖: ${names//$'\n'/ }${NC}" >&2
        local d def
        def=$(echo "$names" | grep -v '^\*' | head -1)
        [[ -z "$def" ]] && { def=$(echo "$names" | head -1); [[ "$def" == \*.* ]] && def="n1.${def#*.}"; }
        read -rp "  统一设置这些协议的 SNI 为 [${def}] (留空跳过): " d
        if [[ -n "${d:-$def}" ]] && _ask_yes "确认把 ${d:-$def} 写入 ${n} 个协议?"; then
            d="${d:-$def}"
            if _cert_covers "$d"; then
                local c; c=$(_sync_protocols_sni "$d")
                echo "$d" >"$CFG/cert_domain"
                _ok "已更新 ${c} 个协议的 SNI 为 ${d}"
                _warn "客户端配置里的 SNI / 服务器地址需同步改为 ${d}"
            else
                _err "证书未覆盖 ${d}，已跳过 SNI 更新"
            fi
        fi
    fi
    reload_config
    # SNI/证书变了，订阅文件里的内容也必须跟着重生成，否则客户端拿到的还是旧值。
    _refresh_subscription_files
    _ok "证书配置完成"
    echo "" >&2
    _line
    echo -e "  ${W}下一步${NC}" >&2
    echo -e "  ${C}1.${NC} 「查看协议配置 / 分享链接」重新导出链接给客户端" >&2
    if [[ -f "$CFG/sub.info" ]]; then
        echo -e "  ${C}2.${NC} 订阅已重新生成，客户端刷新订阅即可" >&2
    else
        echo -e "  ${C}2.${NC} 本地订阅文件已重新生成；需要远程拉取时再启用订阅服务" >&2
    fi
    echo -e "  ${C}3.${NC} ${D}客户端的 insecure / 跳过证书验证 现在可以关掉了${NC}" >&2
    _line
}

cert_force_renew() {
    local acme; acme=$(_acme_bin) || { _err "未安装 acme.sh，请先申请一次证书"; return 1; }
    _is_real_cert || { _err "当前是自签/导入证书，无法通过 acme.sh 续期"; return 1; }
    local d ca method days
    d=$(_meta_get acme_domain) || d=$(cat "$CFG/cert_domain" 2>/dev/null)
    [[ -z "$d" ]] && { _err "未记录 acme 域名，请重新走一次申请流程"; return 1; }
    ca=$(_meta_get ca) || ca=""
    method=$(_meta_get method) || method=""
    days=$(_cert_days_left)

    echo "" >&2
    _line
    echo -e "  续期对象: ${G}${d}${NC}   CA: ${G}$(_ca_display "$ca")${NC}" >&2
    echo -e "  验证方式: ${G}${method:-未知}${NC}   证书剩余: ${G}${days:-?} 天${NC}" >&2
    _line

    # 长期过期 + 验证方式不明：续期成功率低，直接引导重签更省事
    if [[ -n "$days" && "$days" -lt -7 ]]; then
        _warn "证书已过期 ${days#-} 天，强制续期常常失败（验证环境早已变化）"
        echo -e "  ${C}更稳妥的做法: 重新签发一张证书；有通配符可用时一次覆盖所有子域${NC}" >&2
        if _ask_yes "改为重新签发?"; then cert_issue_new; return $?; fi
        _ask_yes "仍要尝试强制续期?" || return 0
    else
        case "$ca" in
            letsencrypt) _warn "强制续期消耗配额（Let's Encrypt 每域名每周 5 次）" ;;
            zerossl)     _warn "强制续期消耗 ZeroSSL 配额，请勿反复重试" ;;
            buypass)     _warn "强制续期消耗 Buypass 配额，请勿反复重试" ;;
            *)           _warn "强制续期会消耗 CA 配额，仅在确有必要时使用" ;;
        esac
        _ask_yes "确认强制续期?" || return 0
    fi

    #── 按验证方式准备环境 ──────────────────────────────────────────────────────
    local nginx_was=false
    case "$method" in
        dns_*)
            if ! _load_dns_creds && ! _import_dns_creds_from_acme; then
                _err "缺少 ${method} 的 API 凭据，无法完成 DNS 验证"
                echo -e "  ${C}请先在本菜单「DNS API 凭据管理」中录入${NC}" >&2
                return 1
            fi
            _ok "已载入 DNS API 凭据 (${DNS_PROVIDER})" ;;
        http-01|unknown|"")
            # unknown 时按 standalone 处理：acme.sh 的默认续期路径就是原验证方式，
            # 而 standalone 需要 socat + 空闲的 80 端口 + 域名解析到本机
            _info "按 HTTP-01 standalone 准备验证环境..."
            _ensure_socat || return 1
            allow_port 80 tcp
            check_domain_dns "$d" false
            if _is_cf_proxied "$d"; then
                _err "${d} 开着 Cloudflare 橙云，HTTP-01 无法完成验证"
                echo -e "  ${C}关掉小云朵后重试，或改用 DNS API 方式重新签发${NC}" >&2
                return 1
            fi
            if ss -tuln 2>/dev/null | grep -qE ':80[^0-9]'; then
                svc status nginx >/dev/null 2>&1 && { nginx_was=true; svc stop nginx; sleep 1; }
                if ss -tuln 2>/dev/null | grep -qE ':80[^0-9]'; then
                    _err "80 端口被占用，HTTP-01 无法进行"
                    ss -tulnp 2>/dev/null | grep -E ':80[^0-9]' | sed 's/^/    /' >&2
                    [[ "$nginx_was" == "true" ]] && svc start nginx
                    return 1
                fi
            fi ;;
        manual-dns)
            _err "原证书是手动 DNS TXT 模式，无法自动续期"
            echo -e "  ${C}请改用 DNS API 方式重新签发（本菜单 2）${NC}" >&2
            return 1 ;;
    esac

    _info "续期中..."
    local log ecc rc
    log=$(mktemp)
    ecc=$(_meta_get ecc) || ecc=true
    if [[ "$ecc" == "true" ]]; then
        "$acme" --renew -d "$d" --ecc --force >"$log" 2>&1
    else
        "$acme" --renew -d "$d" --force >"$log" 2>&1
    fi
    rc=$?
    grep -viE 'debug|^$' "$log" | tail -20 | sed 's/^/    /' >&2
    local ok=0
    _acme_explain_failure "$log" "$rc" || ok=1
    rm -f "$log"
    [[ "$nginx_was" == "true" ]] && svc start nginx

    if [[ "$ok" != "0" ]]; then
        _err "续期未成功，证书未改动"
        echo -e "  ${C}建议改用 DNS API 方式重新签发一张通配符证书（本菜单 2）${NC}" >&2
        return 1
    fi

    _install_cert_files "$d" "$ecc" || { _err "证书安装失败"; return 1; }
    if verify_cert; then
        _meta_set issued_at "$(date '+%F %T')"
        cert_ensure_autorenew true
        reload_config
        _refresh_subscription_files
        show_cert_status
    else
        _err "续期后证书仍异常，请检查 $HOME/.acme.sh/acme.sh.log"
        return 1
    fi
}

cert_gen_self() {
    echo "" >&2
    _warn "自签证书要求客户端勾选「跳过证书验证 / insecure」，NaiveProxy 不可用"
    local cur=""
    [[ -f "$CFG/cert_domain" ]] && cur=$(cat "$CFG/cert_domain")
    local d; read -rp "  伪装域名 [${cur:-www.bing.com}]: " d
    d="${d:-${cur:-www.bing.com}}"
    _is_valid_dns_name "$d" || { _err "域名格式无效"; return 1; }
    _ask_yes "确认生成自签证书 (会覆盖现有证书文件)?" || return 0
    if [[ -s "$SSL_DIR/server.crt" ]]; then
        cp -a "$SSL_DIR/server.crt" "$SSL_DIR/server.crt.bak" 2>/dev/null
        cp -a "$SSL_DIR/server.key" "$SSL_DIR/server.key.bak" 2>/dev/null
        _info "原证书已备份为 server.crt.bak / server.key.bak"
    fi
    gen_self_cert "$d" || { _err "生成失败"; return 1; }
    echo "$d" >"$CFG/cert_domain"
    local n; n=$(_cert_protocols_installed | grep -c .)
    if [[ "${n:-0}" -gt 0 ]] && _ask_yes "是否把 ${n} 个协议的 SNI 同步为 ${d}?"; then
        local c; c=$(_sync_protocols_sni "$d"); _ok "已更新 ${c} 个协议"
    fi
    reload_config
    _refresh_subscription_files
    _ok "自签证书已生成: $d"
}

cert_show_renew_task() {
    _line
    echo -e "  ${W}自动续期状态${NC}" >&2
    _line
    if [[ ! -s "$SSL_DIR/server.crt" ]]; then
        echo -e "  ${D}尚无证书${NC}" >&2; _line; return 1
    fi
    if ! _is_real_cert; then
        echo -e "  ${Y}自签证书，无需也无法续期${NC} ${D}(有效期 10 年)${NC}" >&2; _line; return 1
    fi

    local acme dir dom rc fc nxt ca method
    acme=$(_acme_bin) || acme=""
    if [[ -z "$acme" ]]; then
        echo -e "  acme.sh    : ${R}未安装${NC}" >&2
    else
        echo -e "  acme.sh    : ${G}${acme}${NC}" >&2
        local hd; hd=$(_acme_dnsapi_dir 2>/dev/null) || hd=""
        if [[ -n "$hd" ]]; then
            echo -e "  DNS hook   : ${G}$(ls "$hd"/*.sh 2>/dev/null | wc -l) 个可用${NC}" >&2
        else
            echo -e "  DNS hook   : ${R}缺失${NC} ${D}(DNS-01 续期会失败，请用本菜单 r 修复)${NC}" >&2
        fi
    fi

    dir=$(_meta_get acme_dir) || dir=""
    [[ -d "$dir" ]] || dir=$(_acme_match_dir) || dir=""
    ca=$(_meta_get ca) || ca=""
    method=$(_meta_get method) || method=""
    echo -e "  证书来源   : ${G}$(_ca_display "$ca")${NC}   验证方式: ${G}${method:-未知}${NC}" >&2

    if [[ -z "$dir" ]]; then
        echo -e "  acme 记录  : ${R}未找到${NC} ${D}(证书非本机 acme.sh 签发，无法自动续期)${NC}" >&2
        _line
        echo -e "  ${C}解决办法: 在本菜单选「申请 / 更换 Let's Encrypt 证书」重签一次${NC}" >&2
        _line
        return 1
    fi
    dom=$(_acme_conf_get "$dir" Le_Domain) || dom=""
    if [[ -z "$dom" ]]; then
        dom="${dir##*/}"; dom="${dom%_ecc}"
        echo -e "  acme 域名  : ${Y}${dom}${NC} ${D}(据目录名推断)${NC}" >&2
        if [[ -z "$(_acme_conf_files "$dir")" ]]; then
            echo -e "  acme 配置  : ${R}缺失${NC} ${D}(${dir} 下无 .conf，无法沿用原续期设置)${NC}" >&2
        else
            echo -e "  acme 配置  : ${Y}存在但关键字段读不到${NC} ${D}($(_acme_conf_files "$dir" | head -1))${NC}" >&2
        fi
    else
        echo -e "  acme 域名  : ${G}${dom}${NC}   ${D}(${dir##*/})${NC}" >&2
    fi
    if [[ "$method" == "unknown" || -z "$method" ]]; then
        echo -e "  ${Y}验证方式未知，续期方向无法确定，建议重新签发一次${NC}" >&2
    fi

    # acme.sh 自身 cron
    if ! check_cmd crontab; then
        echo -e "  续期任务   : ${R}系统缺少 crontab${NC} ${D}(无法安装定时任务)${NC}" >&2
    fi
    local acron; acron=$(crontab -l 2>/dev/null | grep 'acme.sh' | head -1)
    if [[ -n "$acron" ]]; then
        echo -e "  续期任务   : ${G}已安装${NC}" >&2
        echo -e "    ${D}${acron}${NC}" >&2
    else
        echo -e "  续期任务   : ${R}缺失${NC} ${D}(证书到期不会自动续签)${NC}" >&2
    fi

    # 本脚本巡检 cron
    if crontab -l 2>/dev/null | grep -q 'vless-cert-check'; then
        echo -e "  兜底巡检   : ${G}已安装${NC} ${D}(每天 04:10，剩余<20天时主动续期)${NC}" >&2
    else
        echo -e "  兜底巡检   : ${Y}缺失${NC}" >&2
    fi

    # reloadcmd 与安装路径
    rc=$(_acme_conf_get "$dir" Le_ReloadCmd) || rc=""
    fc=$(_acme_conf_get "$dir" Le_RealFullChainPath) || fc=""
    if [[ -n "$rc" ]]; then
        echo -e "  续期后动作 : ${G}已配置${NC} ${D}(会重启 ${SB_SVC})${NC}" >&2
    else
        echo -e "  续期后动作 : ${R}未配置${NC} ${D}(续期成功但服务仍用旧证书)${NC}" >&2
    fi
    if [[ "$fc" == "$SSL_DIR/server.crt" ]]; then
        echo -e "  安装路径   : ${G}${fc}${NC}" >&2
    else
        echo -e "  安装路径   : ${R}${fc:-未设置}${NC} ${D}(应为 ${SSL_DIR}/server.crt)${NC}" >&2
    fi

    # DNS 凭据
    if [[ "$method" == dns_* ]]; then
        if [[ -f "$DNS_API_CONF" ]]; then
            echo -e "  DNS 凭据   : ${G}已保存${NC} ${D}(${DNS_API_CONF})${NC}" >&2
        elif grep -q '^SAVED_CF_\|^SAVED_Ali_' "$HOME/.acme.sh/account.conf" 2>/dev/null; then
            echo -e "  DNS 凭据   : ${Y}仅存在于 acme.sh${NC} ${D}(可回收到本脚本)${NC}" >&2
        else
            echo -e "  DNS 凭据   : ${R}缺失${NC} ${D}(DNS-01 续期会失败)${NC}" >&2
        fi
    fi

    nxt=$(_acme_conf_get "$dir" Le_NextRenewTimeStr) || nxt=""
    [[ -n "$nxt" ]] && echo -e "  下次续期   : ${C}${nxt}${NC}" >&2
    local days; days=$(_cert_days_left)
    [[ -n "$days" ]] && echo -e "  证书剩余   : ${G}${days} 天${NC}" >&2
    _line

    if [[ -n "$days" && "$days" -lt 0 ]]; then
        _err "证书已过期 ${days#-} 天，修复自动续期无意义"
        echo -e "  ${C}请返回上一级选「2) 申请 / 更换 Let's Encrypt 证书」重新签发${NC}" >&2
        echo -e "  ${D}你有 *.example.com 这类通配符可用时，签一张通配符证书能一次覆盖所有节点${NC}" >&2
        if _ask_yes "现在就去重新签发?"; then
            cert_issue_new
        fi
        return 1
    fi
    if [[ -z "$acron" || -z "$rc" || "$fc" != "$SSL_DIR/server.crt" ]] ||
       ! crontab -l 2>/dev/null | grep -q 'vless-cert-check' ||
       { [[ "$method" == dns_* ]] && [[ ! -f "$DNS_API_CONF" ]]; }; then
        _warn "自动续期配置不完整"
        if _ask_yes "是否立即修复?"; then
            cert_ensure_autorenew
            local rc2=$?
            [[ "$rc2" == "2" ]] && _err "修复未完成，请重新申请一次证书" || _ok "修复完成"
        fi
    else
        _ok "自动续期配置完整"
    fi
}

manage_certificates() {
    while true; do
        _header
        echo -e "  ${W}证书管理${NC}" >&2
        show_cert_status
        _item "1" "查看证书详情 / 刷新"
        _item "2" "申请 / 更换 Let's Encrypt 证书 ${D}(需域名)${NC}"
        _item "3" "强制续期当前证书"
        _item "4" "生成自签证书"
        _item "5" "检查自动续期配置"
        _item "6" "手动导入证书文件"
        _item "7" "DNS API 凭据管理 ${D}(Cloudflare Token 等)${NC}"
        _item "9" "重新识别现有证书 ${D}(恢复备份后用)${NC}"
        _item "r" "修复 / 重装 acme.sh ${D}(DNS hook 缺失时用)${NC}"
        _item "8" "设置 SNI / 客户端连接地址 ${D}(双栈、CDN、换域名)${NC}"
        _item "0" "返回"
        _line
        local ch; read -rp "  请选择: " ch
        case "$ch" in
            1) show_cert_status; _pause ;;
            2) cert_issue_new; _pause ;;
            3) cert_force_renew; _pause ;;
            4) cert_gen_self; _pause ;;
            5) cert_show_renew_task; _pause ;;
            6)
                if _cert_import_files; then
                    local d; d=$(_cert_names | head -1)
                    [[ "$d" == \*.* ]] && d="n1.${d#*.}"
                    local in_d; read -rp "  各协议要使用的 SNI [${d}]: " in_d; d="${in_d:-$d}"
                    if _is_valid_dns_name "$d"; then
                        echo "$d" >"$CFG/cert_domain"
                        local n; n=$(_cert_protocols_installed | grep -c .)
                        [[ "${n:-0}" -gt 0 ]] && _ask_yes "同步 ${n} 个协议的 SNI 为 ${d}?" && _sync_protocols_sni "$d" >/dev/null
                        reload_config
                        _refresh_subscription_files
                        _ok "证书已导入并生效: $d"
                    fi
                fi
                _pause ;;
            7)
                _line
                if _load_dns_creds; then
                    echo -e "  当前 DNS API: ${G}${DNS_PROVIDER}${NC}" >&2
                    [[ -n "${CF_Token:-}" ]] && echo -e "  Cloudflare Token: ${D}已保存 (****${CF_Token: -4})${NC}" >&2
                    [[ -n "${CF_Email:-}" ]] && echo -e "  Cloudflare 邮箱 : ${D}${CF_Email}${NC}" >&2
                    [[ -n "${Ali_Key:-}" ]] && echo -e "  阿里云 Key      : ${D}已保存${NC}" >&2
                else
                    echo -e "  ${D}尚未保存 DNS API 凭据${NC}" >&2
                fi
                _line
                _item "1" "重新录入"
                _item "2" "删除已保存凭据"
                _item "0" "返回"
                _line
                local dc; read -rp "  请选择: " dc
                case "$dc" in
                    1) setup_dns_api ;;
                    2) rm -f "$DNS_API_CONF" && _ok "已删除 $DNS_API_CONF" ;;
                esac
                _pause ;;
            9)
                cert_adopt
                cert_ensure_autorenew
                _pause ;;
            r|R)
                _line
                if _acme_bin >/dev/null; then
                    local d; d=$(_acme_dnsapi_dir 2>/dev/null) || d=""
                    echo -e "  acme.sh : ${G}$(_acme_bin)${NC}" >&2
                    if [[ -n "$d" ]]; then
                        echo -e "  DNS hook: ${G}$(ls "$d"/*.sh 2>/dev/null | wc -l) 个${NC} ${D}(${d})${NC}" >&2
                    else
                        echo -e "  DNS hook: ${R}缺失${NC} ${D}(只装了主程序，DNS-01 会退回手动模式)${NC}" >&2
                    fi
                else
                    echo -e "  acme.sh : ${R}未安装${NC}" >&2
                fi
                _line
                _ask_yes "现在完整重装 acme.sh?" && install_acme_tool true
                _pause ;;
            8)
                local names d cur_addr
                names=$(_cert_names)
                _line
                echo -e "  ${W}SNI 与连接地址${NC}" >&2
                echo -e "  ${D}SNI      = TLS 校验用的名字，必须在证书覆盖范围内${NC}" >&2
                echo -e "  ${D}连接地址 = 客户端实际去连的目标，可填域名以固定入口${NC}" >&2
                echo -e "  ${D}两者可以不同：连接地址填 IPv6 域名走 v6，SNI 仍用证书里的名字${NC}" >&2
                [[ -n "$names" ]] && echo -e "  ${D}证书覆盖: ${names//$'\n'/ }${NC}" >&2
                _line
                read -rp "  SNI (留空不改): " d
                if [[ -n "$d" ]]; then
                    if ! _is_valid_dns_name "$d"; then _err "域名无效"; _pause; continue; fi
                    if ! _cert_covers "$d"; then
                        _err "证书未覆盖 ${d}，客户端会证书校验失败"
                        _ask_yes "仍要设置?" || { _pause; continue; }
                    fi
                fi
                echo -e "  ${D}连接地址示例: ipv6.example.com（IPv6）/ ipv4.example.com（IPv4）/ CDN 域名${NC}" >&2
                echo -e "  ${D}输入 - 表示清除覆盖，回退到自动探测的公网 IP${NC}" >&2
                read -rp "  连接地址 (留空不改): " cur_addr
                if [[ -n "$cur_addr" && "$cur_addr" != "-" ]]; then
                    _is_valid_host "$cur_addr" || { _err "地址无效"; _pause; continue; }
                    check_domain_dns "$cur_addr" false
                fi
                [[ -z "$d" && -z "$cur_addr" ]] && { _info "未做改动"; _pause; continue; }

                local changed=0 pp core
                for pp in $(db_all_protocols); do
                    core=$(proto_core "$pp")
                    if [[ -n "$cur_addr" ]]; then
                        if [[ "$cur_addr" == "-" ]]; then
                            db_set_inst_field "$core" "$pp" all address ""
                        else
                            db_set_inst_field "$core" "$pp" all address "$cur_addr"
                        fi
                        ((changed++))
                    fi
                done
                if [[ -n "$d" ]]; then
                    local c; c=$(_sync_protocols_sni "$d")
                    echo "$d" >"$CFG/cert_domain"
                    _ok "已更新 ${c} 个 TLS 协议的 SNI 为 ${d}"
                fi
                if [[ -n "$cur_addr" ]]; then
                    if [[ "$cur_addr" == "-" ]]; then _ok "已清除 ${changed} 个协议的连接地址覆盖"
                    else _ok "已把 ${changed} 个协议的连接地址设为 ${cur_addr}"; fi
                fi
                reload_config
                _refresh_subscription_files
                _warn "分享链接与订阅已重新生成，请让客户端重新拉取"
                _pause ;;
            0) return ;;
            *) _err "无效选择"; sleep 1 ;;
        esac
    done
}
#═══════════════════════════════════════════════════════════════════════════════
# 端口选择
#═══════════════════════════════════════════════════════════════════════════════
_recommend_port() {
    local proto="$1" p
    case "$proto" in
        vless-vision|vless-ws|vmess-ws|trojan|trojan-ws|naive|anytls|ss2022-shadowtls|snell-shadowtls|snell-v5-shadowtls)
            for p in 443 8443 2096; do
                ss -tuln 2>/dev/null | grep -qE ":${p}[^0-9]" && continue
                is_internal_port_occupied "$p" >/dev/null && continue
                echo "$p"; return
            done
            gen_port ;;
        *) gen_port ;;
    esac
}

_ask_port() {  # _ask_port <proto> [replace_port]
    local proto="$1" replace="${2:-}" rec
    rec="${replace:-$(_recommend_port "$proto")}"
    echo "" >&2
    _line
    echo -e "  ${W}端口配置 - $(get_protocol_name "$proto")${NC}" >&2
    case "$proto" in
        vless-reality) echo -e "  ${D}REALITY 伪装能力强，可使用任意高位端口${NC}" >&2 ;;
        hy2|tuic)      echo -e "  ${D}UDP 协议，请确认云安全组已放行对应 UDP 端口${NC}" >&2 ;;
        naive)         echo -e "  ${D}NaiveProxy 建议使用 443 端口以获得最佳伪装${NC}" >&2 ;;
    esac
    echo -e "  ${C}建议: ${G}${rec}${NC}" >&2
    echo -e "  ${D}(输入 0 取消)${NC}" >&2
    local port owner
    while true; do
        read -rp "  请输入端口 [回车使用 ${rec}]: " port
        port="${port:-$rec}"
        [[ "$port" == "0" ]] && return 1
        _is_valid_port "$port" || { _err "端口必须为 1-65535"; continue; }
        if [[ "$port" -lt 1024 && "$port" != 443 && "$port" != 80 ]]; then
            _warn "端口 $port 属系统保留范围"
            _ask_yes "仍要使用?" || continue
        fi
        owner=$(is_internal_port_occupied "$port" "$proto") && {
            if [[ -n "$replace" && "$port" == "$replace" ]]; then :; else
                _err "端口 $port 已被 [$owner] 占用"; continue
            fi
        }
        local own_ports; own_ports=$(db_list_ports "$(proto_core "$proto")" "$proto")
        if grep -qx "$port" <<<"$own_ports" && [[ "$port" != "$replace" ]]; then
            _err "$(get_protocol_name "$proto") 已在端口 $port 上运行"; continue
        fi
        if ss -tuln 2>/dev/null | grep -qE ":${port}[^0-9]"; then
            if [[ -n "$replace" && "$port" == "$replace" ]]; then echo "$port"; return 0; fi
            _warn "端口 $port 已被系统进程占用"
            _ask_yes "强制使用?" && { echo "$port"; return 0; }
            continue
        fi
        # 放行防火墙 + 可达性自检
        case "$proto" in
            hy2|tuic) allow_port_both "$port" >&2 ;;
            *)        allow_port "$port" tcp >&2 ;;
        esac
        if [[ "$proto" != "hy2" && "$proto" != "tuic" && "$proto" != "socks" ]]; then
            check_port_listen "$port" >&2
        fi
        echo "$port"; return 0
    done
}

_ask_sni() {
    local def; def=$(gen_sni)
    echo "" >&2
    _line
    echo -e "  ${W}伪装域名 (SNI / 握手目标)${NC}" >&2
    echo -e "  ${D}这是借用的第三方网站，与本机证书无关：未通过认证的握手会被${NC}" >&2
    echo -e "  ${D}原样转发给它，探测者看到的是那个网站的真实证书。${NC}" >&2
    echo -e "  ${R}不要填自己的域名${NC}${D}——会自握手失败，也会把代理和你的域名绑定${NC}" >&2
    _line
    _item "1" "使用随机大站 (${G}${def}${NC}) - 推荐"
    _item "2" "自定义"
    _line
    local ch; read -rp "  请选择 [1]: " ch; ch="${ch:-1}"
    if [[ "$ch" == "2" ]]; then
        local s
        while true; do
            read -rp "  伪装域名 [回车使用 ${def}]: " s; s="${s:-$def}"
            if ! _is_valid_dns_name "$s"; then
                _err "域名格式无效 (示例: www.microsoft.com)"; continue
            fi
            if check_reality_dest "$s" 443 >&2; then echo "$s"; return 0; fi
            echo "" >&2
            _item "1" "换一个域名"
            _item "2" "使用推荐值 ${G}${def}${NC}"
            _item "3" "无视检查，强行使用 ${s}"
            local rc; read -rp "  请选择 [1]: " rc
            case "${rc:-1}" in
                2) echo "$def"; return 0 ;;
                3) _warn "已强行使用 ${s}，若连不通请回来改"; echo "$s"; return 0 ;;
                *) continue ;;
            esac
        done
    fi
    echo "$def"
}

# Hysteria2 拥塞控制：BBR(自适应) 或 Brutal(固定速率)
_ask_hy2_cc() {
    HY2_UP=0; HY2_DOWN=0
    echo "" >&2
    _line
    echo -e "  ${W}Hysteria2 拥塞控制${NC}" >&2
    _line
    _item "1" "BBR ${D}(自适应，推荐；服务端忽略客户端申报带宽)${NC}"
    _item "2" "Brutal ${D}(固定速率，需手填带宽)${NC}"
    _line
    echo -e "  ${D}Brutal 在丢包率高的线路上明显更快，代价是对同链路其它流量不公平，${NC}" >&2
    echo -e "  ${D}且填错带宽会反向拖慢（填太高持续丢包，填太低跑不满）${NC}" >&2
    _line
    local c; read -rp "  请选择 [1]: " c
    [[ "${c:-1}" != "2" ]] && { echo -e "  ${C}使用 BBR${NC}" >&2; return 0; }

    echo -e "  ${D}填你这台 VPS 的实际带宽，不是客户端的；单位 Mbps${NC}" >&2
    local up down
    while true; do
        read -rp "  上行 (服务器→客户端) [100]: " down; down="${down:-100}"
        [[ "$down" =~ ^[0-9]+$ ]] && [[ "$down" -gt 0 ]] && break
        _err "请输入正整数"
    done
    while true; do
        read -rp "  下行 (客户端→服务器) [50]: " up; up="${up:-50}"
        [[ "$up" =~ ^[0-9]+$ ]] && [[ "$up" -gt 0 ]] && break
        _err "请输入正整数"
    done
    # sing-box 视角：up_mbps 是服务端上传（发给客户端），down_mbps 是服务端下载
    HY2_UP="$down"; HY2_DOWN="$up"
    echo -e "  ${C}Brutal: 上行 ${HY2_UP} / 下行 ${HY2_DOWN} Mbps${NC}" >&2
}

_ask_hop() {  # 设置 HOP_ENABLE / HOP_START / HOP_END
    HOP_ENABLE=0; HOP_START=20000; HOP_END=50000
    echo "" >&2
    echo -e "  ${W}端口跳跃 (Port Hopping)${NC}" >&2
    echo -e "  ${D}将一段 UDP 端口范围 REDIRECT 到服务端口；高位端口暴露有一定风险${NC}" >&2
    _ask_yes "是否启用端口跳跃?" || { echo -e "  ${D}已选择: 不启用${NC}" >&2; return 0; }
    local hs he
    read -rp "  起始端口 [${HOP_START}]: " hs; hs="${hs:-$HOP_START}"
    read -rp "  结束端口 [${HOP_END}]: " he; he="${he:-$HOP_END}"
    if _is_valid_port "$hs" && _is_valid_port "$he" && [[ "$hs" -lt "$he" ]]; then
        HOP_ENABLE=1; HOP_START="$hs"; HOP_END="$he"
        allow_port "${hs}:${he}" udp >&2
        echo -e "  ${C}将启用: ${G}${hs}-${he}${NC}" >&2
    else
        _warn "端口范围无效，已关闭端口跳跃"
    fi
}

# 处理协议已安装时的多端口选择：设置 INSTALL_REPLACE_PORT
_handle_existing_protocol() {
    local proto="$1" core; core=$(proto_core "$proto")
    INSTALL_REPLACE_PORT=""
    db_exists "$core" "$proto" || return 0
    local ports; ports=$(db_list_ports "$core" "$proto")
    echo "" >&2
    _line
    echo -e "  ${Y}$(get_protocol_name "$proto") 已安装，现有端口实例:${NC}" >&2
    local i=1 arr=() p
    while IFS= read -r p; do [[ -z "$p" ]] && continue; echo -e "    ${G}●${NC} 端口 ${G}${p}${NC}" >&2; arr+=("$p"); ((i++)); done <<<"$ports"
    _line
    _item "1" "添加新端口实例"
    _item "2" "覆盖现有端口配置"
    _item "0" "取消"
    _line
    local ch; read -rp "  请选择: " ch
    case "$ch" in
        1) return 0 ;;
        2)
            echo "" >&2
            i=1
            for p in "${arr[@]}"; do _item "$i" "端口 $p"; ((i++)); done
            _item "0" "取消"
            local pc; read -rp "  选择要覆盖的端口: " pc
            [[ "$pc" =~ ^[0-9]+$ ]] && (( pc >= 1 && pc <= ${#arr[@]} )) || { _info "已取消"; return 1; }
            INSTALL_REPLACE_PORT="${arr[$((pc-1))]}"
            return 0 ;;
        *) _info "已取消"; return 1 ;;
    esac
}

#═══════════════════════════════════════════════════════════════════════════════
# 协议选择
#═══════════════════════════════════════════════════════════════════════════════
select_protocol() {
    echo "" >&2
    _line
    echo -e "  ${W}选择代理协议${NC} ${D}(Sing-box 统一内核)${NC}" >&2
    _line
    _item "1"  "VLESS + REALITY ${D}(推荐，抗封锁)${NC}"
    _item "2"  "VLESS-Vision ${D}(TCP+TLS+xtls-rprx-vision)${NC}"
    _item "3"  "VLESS + WS + TLS ${D}(CDN 友好)${NC}"
    _item "4"  "VLESS + WS 无TLS ${D}(配合 CF Tunnel)${NC}"
    _item "5"  "VMess + WS + TLS"
    _item "6"  "Trojan ${D}(TCP+TLS)${NC}"
    _item "7"  "Trojan + WS + TLS"
    _item "8"  "Hysteria2 ${D}(UDP 高速)${NC}"
    _item "9"  "TUIC v5 ${D}(QUIC)${NC}"
    _item "10" "AnyTLS"
    _item "11" "Shadowsocks ${D}(SS2022 / 传统)${NC}"
    _item "12" "SOCKS5 ${D}(明文，建议仅本地监听)${NC}"
    _item "13" "NaïveProxy ${D}(需真实域名证书)${NC}"
    _item "14" "ShadowTLS(v3) + SS2022 ${D}(Sing-box 原生)${NC}"
    _line
    echo -e "  ${W}Surge 专属 (Snell 独立进程)${NC}" >&2
    _line
    _item "15" "Snell v4"
    _item "16" "Snell v5"
    _item "17" "Snell v6 ${D}(Beta)${NC}"
    _item "18" "Snell + ShadowTLS(v3)"
    _item "0"  "返回"
    _line
    echo -e "  ${D}已移除（Sing-box 不支持）: VLESS-XHTTP / XHTTP-CDN / VLESS-Encryption / SOCKS5+TLS${NC}" >&2
    echo -e "  ${D}支持多选：用空格或英文逗号分隔，例如 1 8 9 或 1,8,9${NC}" >&2
    echo -e "  ${D}会按你输入的顺序依次进入各协议的安装流程${NC}" >&2
    _line
    echo "" >&2

    SELECTED_PROTOCOLS=()
    local input tok seen=""
    while true; do
        read -rp "  选择协议 [0-18]: " input
        [[ -z "$input" ]] && { _err "不能为空"; continue; }
        input=$(echo "$input" | tr ',' ' ' | tr -s ' ')
        [[ "$input" == *"0"* ]] && { for tok in $input; do [[ "$tok" == "0" ]] && return 1; done; }

        SELECTED_PROTOCOLS=(); seen=""
        local bad=false p
        for tok in $input; do
            p=""
            case "$tok" in
                1)  p="vless-reality" ;;
                2)  p="vless-vision" ;;
                3)  p="vless-ws" ;;
                4)  p="vless-ws-notls" ;;
                5)  p="vmess-ws" ;;
                6)  p="trojan" ;;
                7)  p="trojan-ws" ;;
                8)  p="hy2" ;;
                9)  p="tuic" ;;
                10) p="anytls" ;;
                11)
                    echo "" >&2
                    echo -e "  ${W}[${tok}] Shadowsocks 变体${NC}" >&2
                    _item "1" "SS2022 ${D}(2022-blake3-*，支持多用户)${NC}"
                    _item "2" "传统 SS ${D}(aes-256-gcm 等，单用户)${NC}"
                    local sc; read -rp "  请选择 [1]: " sc
                    [[ "${sc:-1}" == "2" ]] && p="ss-legacy" || p="ss2022" ;;
                12) p="socks" ;;
                13) p="naive" ;;
                14) p="ss2022-shadowtls" ;;
                15) p="snell" ;;
                16) p="snell-v5" ;;
                17) p="snell-v6" ;;
                18)
                    echo "" >&2
                    echo -e "  ${W}[${tok}] Snell + ShadowTLS 版本${NC}" >&2
                    _item "1" "Snell v4 + ShadowTLS"
                    _item "2" "Snell v5 + ShadowTLS"
                    local sc2; read -rp "  请选择 [2]: " sc2
                    [[ "${sc2:-2}" == "1" ]] && p="snell-shadowtls" || p="snell-v5-shadowtls" ;;
                *) _err "无效选项: ${tok}"; bad=true; break ;;
            esac
            [[ -z "$p" ]] && continue
            if [[ " $seen " == *" $p "* ]]; then
                _warn "$(get_protocol_name "$p") 重复选择，已忽略"
                continue
            fi
            seen="$seen $p"
            SELECTED_PROTOCOLS+=("$p")
        done
        [[ "$bad" == "true" ]] && { SELECTED_PROTOCOLS=(); continue; }
        [[ ${#SELECTED_PROTOCOLS[@]} -eq 0 ]] && { _err "没有选中任何协议"; continue; }
        break
    done

    if [[ ${#SELECTED_PROTOCOLS[@]} -gt 1 ]]; then
        echo "" >&2
        _line
        echo -e "  ${W}将依次安装 ${#SELECTED_PROTOCOLS[@]} 个协议:${NC}" >&2
        local i=1
        for p in "${SELECTED_PROTOCOLS[@]}"; do
            echo -e "    ${C}${i}.${NC} $(get_protocol_name "$p")" >&2; ((i++))
        done
        _line
        _ask_yes "确认?" || return 1
    fi
    return 0
}

#═══════════════════════════════════════════════════════════════════════════════
# 安装流程
#═══════════════════════════════════════════════════════════════════════════════
# 批量安装时，多个 TLS 协议共用同一张证书：第一个配好之后，
# 后续协议只问一句是否复用，避免连续弹 4 次证书向导
_batch_setup_cert() {
    local proto="$1" req="${2:-false}"
    if [[ -n "${BATCH_CERT_DOMAIN:-}" ]] && _cert_covers "$BATCH_CERT_DOMAIN"; then
        if [[ "$req" != "true" ]] || _is_real_cert; then
            echo "" >&2
            _info "本批次已配置证书: ${BATCH_CERT_DOMAIN}"
            if _ask_yes "$(get_protocol_name "$proto") 复用同一张证书与 SNI?"; then
                CERT_DOMAIN="$BATCH_CERT_DOMAIN"
                _is_real_cert && CERT_MODE="real" || CERT_MODE="self"
                return 0
            fi
        fi
    fi
    setup_cert "$proto" "$req" || return $?
    BATCH_CERT_DOMAIN="$CERT_DOMAIN"
    return 0
}

# 单个协议的安装流程（依赖检测、内核安装等公共步骤由 do_install 统一做）
# 返回 0 成功 / 1 失败 / 2 用户取消
_install_one_protocol() {
    local proto="$1" core
    core=$(proto_core "$proto")

    _handle_existing_protocol "$proto" || return 2
    local replace="$INSTALL_REPLACE_PORT"

    [[ "$proto" == ss2022* ]] && sync_time

    # 内核按需安装（已装则内部直接返回）
    if [[ "$core" == "singbox" ]]; then
        install_singbox || { _err "Sing-box 安装失败"; return 1; }
        if [[ "$proto" == "anytls" ]]; then
            local _sbv; _sbv=$(_sb_version)
            if ! _version_ge "$_sbv" "1.12"; then
                _err "AnyTLS 入站需要 Sing-box >= 1.12（当前 v${_sbv:-未知}）"
                echo -e "  ${D}可先在「内核版本管理」中升级 Sing-box${NC}" >&2
                return 1
            fi
        fi
    else
        case "$proto" in
            snell)                install_snell    || return 1 ;;
            snell-v5)             install_snell_v5 || return 1 ;;
            snell-v6)             install_snell_v6 || return 1 ;;
            snell-shadowtls)      install_snell    && install_shadowtls || return 1 ;;
            snell-v5-shadowtls)   install_snell_v5 && install_shadowtls || return 1 ;;
        esac
    fi

    local port cfg="" secret="" sni=""
    #── 逐协议配置采集 ──────────────────────────────────────────────────────────
    case "$proto" in
        vless-reality)
            port=$(_ask_port "$proto" "$replace") || return 1
            select_handshake_target || { _info "已取消"; return 1; }
            sni="$HS_SNI"
            local keys pk pub sid uuid
            keys=$("$SB_BIN" generate reality-keypair 2>/dev/null)
            pk=$(echo "$keys" | awk '/PrivateKey/{print $2}')
            pub=$(echo "$keys" | awk '/PublicKey/{print $2}')
            [[ -z "$pk" || -z "$pub" ]] && { _err "REALITY 密钥生成失败"; _pause; return 1; }
            sid=$(gen_sid); uuid=$(gen_uuid); secret="$uuid"
            cfg=$(build_instance port "$port" uuid "$uuid" sni "$sni" \
                private_key "$pk" public_key "$pub" short_id "$sid" \
                handshake_host "$HS_HOST" handshake_port "$HS_PORT")
            _line
            echo -e "  端口: ${G}${port}${NC}   SNI: ${G}${sni}${NC}   ShortID: ${G}${sid}${NC}" >&2
            echo -e "  握手目标: ${G}${HS_HOST}:${HS_PORT}${NC}" >&2
            echo -e "  UUID: ${G}${uuid}${NC}" >&2 ;;
        vless-vision|vless-ws|vmess-ws|trojan|trojan-ws)
            _batch_setup_cert "$proto" false || return 2
            sni="$CERT_DOMAIN"
            [[ "$CERT_MODE" == "self" ]] && sni="$CERT_DOMAIN"
            port=$(_ask_port "$proto" "$replace") || return 1
            local path=""
            case "$proto" in
                vless-ws|vmess-ws|trojan-ws)
                    local defp; defp=$(gen_ws_path)
                    read -rp "  WS Path [回车使用 ${defp}]: " path; path="${path:-$defp}"
                    [[ "$path" != /* ]] && path="/$path" ;;
            esac
            if [[ "$proto" == "trojan" || "$proto" == "trojan-ws" ]]; then
                secret=$(ask_password 16 "Trojan 密码")
                cfg=$(build_instance port "$port" password "$secret" sni "$sni" path "$path")
            else
                secret=$(gen_uuid)
                cfg=$(build_instance port "$port" uuid "$secret" sni "$sni" path "$path")
            fi
            _line
            echo -e "  端口: ${G}${port}${NC}   SNI: ${G}${sni}${NC}" >&2
            [[ -n "$path" ]] && echo -e "  Path: ${G}${path}${NC}" >&2 ;;
        vless-ws-notls)
            port=$(_ask_port "$proto" "$replace") || return 1
            local defp; defp=$(gen_ws_path)
            local path host
            read -rp "  WS Path [回车使用 ${defp}]: " path; path="${path:-$defp}"
            [[ "$path" != /* ]] && path="/$path"
            read -rp "  Host 头 (可选，用于 CF Tunnel): " host
            secret=$(gen_uuid)
            cfg=$(build_instance port "$port" uuid "$secret" path "$path" host "$host")
            _line
            echo -e "  ${Y}本协议不启用 TLS，加密由 Cloudflare Tunnel 提供${NC}" >&2
            echo -e "  端口: ${G}${port}${NC}   Path: ${G}${path}${NC}" >&2 ;;
        hy2)
            _batch_setup_cert "$proto" false || return 2
            sni="$CERT_DOMAIN"
            port=$(_ask_port "$proto" "$replace") || return 1
            secret=$(ask_password 16 "Hysteria2 密码")
            _ask_hy2_cc
            _ask_hop
            cfg=$(build_instance port "$port" password "$secret" sni "$sni" \
                up_mbps "$HY2_UP" down_mbps "$HY2_DOWN" \
                hop_enable "$HOP_ENABLE" hop_start "$HOP_START" hop_end "$HOP_END")
            _line
            echo -e "  端口: ${G}${port}${NC} (UDP)   SNI: ${G}${sni}${NC}" >&2
            if [[ "$HY2_UP" -gt 0 ]]; then
                echo -e "  拥塞控制: ${G}Brutal${NC} ${D}(上行 ${HY2_UP} / 下行 ${HY2_DOWN} Mbps)${NC}" >&2
            else
                echo -e "  拥塞控制: ${G}BBR${NC} ${D}(自适应)${NC}" >&2
            fi ;;
        tuic)
            _batch_setup_cert "$proto" false || return 2
            sni="$CERT_DOMAIN"
            port=$(_ask_port "$proto" "$replace") || return 1
            local tpw; tpw=$(ask_password 16 "TUIC 密码")
            secret=$(gen_uuid)
            _ask_hop
            cfg=$(build_instance port "$port" uuid "$secret" password "$tpw" sni "$sni" \
                hop_enable "$HOP_ENABLE" hop_start "$HOP_START" hop_end "$HOP_END")
            _line
            echo -e "  端口: ${G}${port}${NC} (UDP/QUIC)   UUID: ${G}${secret}${NC}" >&2
            echo -e "  密码: ${G}${tpw}${NC}   SNI: ${G}${sni}${NC}" >&2 ;;
        anytls)
            _batch_setup_cert "$proto" false || return 2
            sni="$CERT_DOMAIN"
            port=$(_ask_port "$proto" "$replace") || return 1
            secret=$(ask_password 16 "AnyTLS 密码")
            cfg=$(build_instance port "$port" password "$secret" sni "$sni")
            _line
            echo -e "  端口: ${G}${port}${NC}   SNI: ${G}${sni}${NC}" >&2 ;;
        ss2022)
            port=$(_ask_port "$proto" "$replace") || return 1
            echo "" >&2
            _item "1" "2022-blake3-aes-128-gcm ${D}(推荐)${NC}"
            _item "2" "2022-blake3-aes-256-gcm"
            _item "3" "2022-blake3-chacha20-poly1305 ${D}(ARM 优化)${NC}"
            local mc method; read -rp "  加密方式 [1]: " mc; mc="${mc:-1}"
            case "$mc" in
                2) method="2022-blake3-aes-256-gcm" ;;
                3) method="2022-blake3-chacha20-poly1305" ;;
                *) method="2022-blake3-aes-128-gcm" ;;
            esac
            local server_psk; server_psk=$(gen_ss_psk "$method")
            secret=$(gen_ss_psk "$method")
            cfg=$(build_instance port "$port" method "$method" password "$server_psk")
            _line
            echo -e "  端口: ${G}${port}${NC}   加密: ${G}${method}${NC}" >&2
            echo -e "  ${D}服务端 PSK: ${server_psk}${NC}" >&2
            echo -e "  用户 PSK: ${G}${secret}${NC}" >&2
            echo -e "  ${D}客户端密码需填写: ${server_psk}:${secret}${NC}" >&2 ;;
        ss-legacy)
            port=$(_ask_port "$proto" "$replace") || return 1
            echo "" >&2
            _item "1" "aes-256-gcm ${D}(兼容性好)${NC}"
            _item "2" "aes-128-gcm"
            _item "3" "chacha20-ietf-poly1305"
            local mc method; read -rp "  加密方式 [1]: " mc; mc="${mc:-1}"
            case "$mc" in 2) method="aes-128-gcm" ;; 3) method="chacha20-ietf-poly1305" ;; *) method="aes-256-gcm" ;; esac
            secret=$(ask_password 16 "SS 密码")
            cfg=$(build_instance port "$port" method "$method" password "$secret")
            _line
            echo -e "  端口: ${G}${port}${NC}   加密: ${G}${method}${NC}   密码: ${G}${secret}${NC}" >&2 ;;
        socks)
            echo "" >&2
            _line
            echo -e "  ${Y}注意: Sing-box 的 SOCKS 入站不支持 TLS${NC}" >&2
            echo -e "  ${D}明文传输可能被 QoS/审计，建议仅监听 127.0.0.1 或 ::1 供本机程序使用${NC}" >&2
            _line
            _item "1" "用户名密码认证 ${D}(推荐)${NC}"
            _item "2" "无认证 ${D}(必须限定监听地址)${NC}"
            local ac; read -rp "  请选择 [1]: " ac; ac="${ac:-1}"
            local auth_mode="password" listen_addr="" uname_="" 
            if [[ "$ac" == "2" ]]; then
                auth_mode="noauth"
                local defl; if _has_ipv6 && _can_dual_stack; then defl="::1"; else defl="127.0.0.1"; fi
                read -rp "  监听地址 [回车使用 ${defl}]: " listen_addr; listen_addr="${listen_addr:-$defl}"
                _is_valid_host "$listen_addr" || { _err "监听地址无效"; _pause; return 1; }
            else
                uname_=$(ask_password 8 "SOCKS5 用户名")
                secret=$(ask_password 16 "SOCKS5 密码")
            fi
            port=$(_ask_port "$proto" "$replace") || return 1
            cfg=$(build_instance port "$port" auth_mode "$auth_mode" listen_addr "$listen_addr" username "$uname_" password "$secret")
            SOCKS_USERNAME="$uname_"
            _line
            echo -e "  端口: ${G}${port}${NC}   认证: ${G}${auth_mode}${NC}" >&2
            [[ -n "$listen_addr" ]] && echo -e "  监听: ${G}${listen_addr}${NC}" >&2
            [[ -n "$uname_" ]] && echo -e "  用户: ${G}${uname_}${NC}   密码: ${G}${secret}${NC}" >&2 ;;
        naive)
            echo "" >&2
            echo -e "  ${Y}NaiveProxy 客户端会严格校验证书，必须使用真实域名证书${NC}" >&2
            _batch_setup_cert "$proto" true || return 2
            sni="$CERT_DOMAIN"
            port=$(_ask_port "$proto" "$replace") || return 1
            local nuser; nuser=$(ask_password 8 "NaiveProxy 用户名")
            secret=$(ask_password 16 "NaiveProxy 密码")
            cfg=$(build_instance port "$port" domain "$sni" sni "$sni" username "$nuser" password "$secret")
            SOCKS_USERNAME="$nuser"
            _line
            echo -e "  域名: ${G}${sni}${NC}   端口: ${G}${port}${NC}" >&2
            echo -e "  用户: ${G}${nuser}${NC}   密码: ${G}${secret}${NC}" >&2 ;;
        ss2022-shadowtls)
            port=$(_ask_port "$proto" "$replace") || return 1
            local method server_psk stls_pw hs bport
            method="2022-blake3-aes-128-gcm"
            echo "" >&2
            _item "1" "2022-blake3-aes-128-gcm ${D}(推荐)${NC}"
            _item "2" "2022-blake3-aes-256-gcm"
            local mc; read -rp "  加密方式 [1]: " mc; [[ "$mc" == "2" ]] && method="2022-blake3-aes-256-gcm"
            server_psk=$(gen_ss_psk "$method")
            secret=$(gen_ss_psk "$method")
            stls_pw=$(ask_password 16 "ShadowTLS 密码")
            hs=$(_ask_sni)
            bport=$(gen_port)
            cfg=$(build_instance port "$port" method "$method" password "$server_psk" \
                stls_password "$stls_pw" sni "$hs" backend_port "$bport")
            _line
            echo -e "  对外端口: ${G}${port}${NC} (ShadowTLS v3)" >&2
            echo -e "  内部端口: ${D}${bport}${NC} (Shadowsocks，自动分配)" >&2
            echo -e "  握手域名: ${G}${hs}${NC}   加密: ${G}${method}${NC}" >&2
            echo -e "  ${D}客户端密码需填写: ${server_psk}:${secret}${NC}" >&2 ;;
        snell|snell-v5|snell-v6)
            port=$(_ask_port "$proto" "$replace") || return 1
            local version psk
            case "$proto" in snell) version=4 ;; snell-v5) version=5 ;; snell-v6) version=6 ;; esac
            if [[ "$version" == "6" ]]; then
                echo -e "  ${D}Snell v6 PSK 需 16-255 位字母数字${NC}" >&2
                while true; do
                    _read_secret psk "  PSK (回车随机生成): "
                    [[ -z "$psk" ]] && psk=$(gen_password 32)
                    [[ ${#psk} -ge 16 && ${#psk} -le 255 && "$psk" =~ ^[0-9A-Za-z]+$ ]] && break
                    _err "PSK 只能包含数字与字母，长度 16-255"
                done
            else
                psk=$(ask_password 20 "Snell PSK")
            fi
            secret="$psk"
            local extra=()
            if [[ "$version" == "6" ]]; then
                echo "" >&2
                _item "1" "default ${D}(PSK 派生流量整形，推荐)${NC}"
                _item "2" "unshaped"
                _item "3" "unsafe-raw ${D}(不建议)${NC}"
                local mc mode; read -rp "  混淆模式 [1]: " mc
                case "$mc" in 2) mode="unshaped" ;; 3) mode="unsafe-raw" ;; *) mode="default" ;; esac
                echo "" >&2
                # 没有 IPv6 出口就不要写 IPv6 DNS：c-ares 轮询到不可达地址会拖慢甚至拖死解析，
                # 表现为 TCP 连得上、但每个请求都超时
                local rec_dns="1.1.1.1,8.8.8.8"
                _has_ipv6_network && rec_dns="1.1.1.1,8.8.8.8,2001:4860:4860::8888"
                _item "1" "推荐 DNS ${D}(${rec_dns})${NC}"
                _item "2" "系统默认"
                _item "3" "自定义"
                local dc dns=""; read -rp "  DNS [1]: " dc
                case "$dc" in
                    2) dns="" ;;
                    3) read -rp "  DNS 列表 (逗号分隔): " dns; dns="${dns//[[:space:]]/}" ;;
                    *) dns="$rec_dns" ;;
                esac
                echo "" >&2
                _has_ipv6_network ||
                    echo -e "  ${D}本机无 IPv6 出口，请勿选择 prefer-ipv6 / ipv6-only${NC}" >&2
                _item "1" "default"; _item "2" "prefer-ipv4"; _item "3" "prefer-ipv6"
                _item "4" "ipv4-only"; _item "5" "ipv6-only"
                local pc pref; read -rp "  DNS IP 偏好 [1]: " pc
                case "$pc" in 2) pref="prefer-ipv4" ;; 3) pref="prefer-ipv6" ;; 4) pref="ipv4-only" ;; 5) pref="ipv6-only" ;; *) pref="default" ;; esac
                local tfo="true"; _ask_yes "客户端 TCP Fast Open (生成 Surge 配置用)? " || tfo="false"
                extra=(mode "$mode" dns "$dns" dns_ip_preference "$pref" tfo "$tfo")
            fi
            cfg=$(build_instance port "$port" psk "$psk" version "$version" "${extra[@]}")
            _line
            echo -e "  端口: ${G}${port}${NC}   版本: ${G}v${version}${NC}   PSK: ${G}${psk}${NC}" >&2 ;;
        snell-shadowtls|snell-v5-shadowtls)
            local version; [[ "$proto" == "snell-shadowtls" ]] && version=4 || version=5
            echo "" >&2
            echo -e "  ${D}ShadowTLS 对外监听端口（建议 443），Snell 后端自动分配内部端口${NC}" >&2
            port=$(_ask_port "$proto" "$replace") || return 1
            local psk stls_pw hs bport
            psk=$(ask_password 20 "Snell PSK"); secret="$psk"
            stls_pw=$(ask_password 16 "ShadowTLS 密码")
            hs=$(_ask_sni)
            bport=$(gen_port)
            cfg=$(build_instance port "$port" psk "$psk" version "$version" \
                stls_password "$stls_pw" sni "$hs" backend_port "$bport")
            _line
            echo -e "  对外端口: ${G}${port}${NC} (ShadowTLS v3)" >&2
            echo -e "  内部端口: ${D}${bport}${NC} (Snell v${version})" >&2
            echo -e "  握手域名: ${G}${hs}${NC}   PSK: ${G}${psk}${NC}" >&2 ;;
    esac

    [[ -z "$cfg" ]] && { _err "配置生成失败"; return 1; }
    _line
    echo "" >&2
    _ask_yes "确认安装 $(get_protocol_name "$proto")?" || { _info "已跳过"; return 2; }

    register_protocol "$proto" "$cfg" "$replace" || { _err "写入数据库失败"; return 1; }

    # 为支持多用户的协议创建 default 用户
    if is_multiuser_protocol "$proto" && [[ -n "$secret" ]]; then
        local uname="default"
        [[ -n "${SOCKS_USERNAME:-}" ]] && uname="$SOCKS_USERNAME"
        db_user_exists "$core" "$proto" "$uname" || db_add_user "$core" "$proto" "$uname" "$secret" 0 "" ""
    fi
    unset SOCKS_USERNAME

    INSTALLED_PORTS+=("${proto}:${port}")
    return 0
}

do_install() {
    _header
    echo -e "  ${W}协议安装向导${NC}" >&2
    echo -e "  系统: ${C}${DISTRO}${NC}   内核: ${C}$(uname -r)${NC}" >&2

    select_protocol || return 1
    [[ ${#SELECTED_PROTOCOLS[@]} -eq 0 ]] && return 1

    #── 公共前置：只做一次 ──────────────────────────────────────────────────────
    _info "检测基础依赖..."
    check_dependencies || { _err "依赖检测失败"; _pause; return 1; }
    ensure_dual_stack_listen

    local ipv4 ipv6
    ipv4=$(get_ipv4); ipv6=$(get_ipv6)
    echo -e "  IPv4: ${ipv4:-${R}无${NC}}   IPv6: ${ipv6:-${R}无${NC}}" >&2
    [[ -z "$ipv4" && -z "$ipv6" ]] && { _err "无法获取公网 IP"; _pause; return 1; }

    #── 逐个协议展开安装流程 ────────────────────────────────────────────────────
    INSTALLED_PORTS=()
    BATCH_CERT_DOMAIN=""
    local total=${#SELECTED_PROTOCOLS[@]} idx=1 proto rc
    local ok_list=() fail_list=() skip_list=()
    for proto in "${SELECTED_PROTOCOLS[@]}"; do
        if [[ "$total" -gt 1 ]]; then
            echo "" >&2
            _dline
            echo -e "  ${W}[${idx}/${total}] $(get_protocol_name "$proto")${NC}" >&2
            _dline
        fi
        _install_one_protocol "$proto"; rc=$?
        case "$rc" in
            0) ok_list+=("$proto") ;;
            2) skip_list+=("$proto") ;;
            *) fail_list+=("$proto")
               if [[ "$idx" -lt "$total" ]]; then
                   _ask_yes "该协议安装失败，继续安装剩下的?" || break
               fi ;;
        esac
        ((idx++))
    done

    if [[ ${#ok_list[@]} -eq 0 ]]; then
        _warn "没有协议被安装"
        _pause; return 1
    fi

    #── 公共收尾：只做一次 ──────────────────────────────────────────────────────
    _info "创建服务并启动..."
    if start_services; then
        create_shortcut
        sync_traffic_counters 2>/dev/null || true
        _refresh_subscription_files
        _dline
        _ok "安装完成：成功 ${#ok_list[@]} 个$( [[ ${#skip_list[@]} -gt 0 ]] && echo " / 跳过 ${#skip_list[@]} 个" )$( [[ ${#fail_list[@]} -gt 0 ]] && echo " / 失败 ${#fail_list[@]} 个" )"
        _dline
        local p
        [[ ${#skip_list[@]} -gt 0 ]] && { for p in "${skip_list[@]}"; do echo -e "  ${D}跳过: $(get_protocol_name "$p")${NC}" >&2; done; }
        [[ ${#fail_list[@]} -gt 0 ]] && { for p in "${fail_list[@]}"; do echo -e "  ${R}失败: $(get_protocol_name "$p")${NC}" >&2; done; }

        # UDP 协议统一提醒一次安全组
        local udp_ports=() e
        for e in "${INSTALLED_PORTS[@]}"; do
            case "${e%%:*}" in hy2|tuic) udp_ports+=("${e##*:}") ;; esac
        done
        if [[ ${#udp_ports[@]} -gt 0 ]]; then
            echo "" >&2
            _warn "请确认云服务商安全组已放行 UDP 端口: ${udp_ports[*]}"
        fi

        for e in "${INSTALLED_PORTS[@]}"; do
            show_single_protocol_info "${e%%:*}" false "${e##*:}"
        done
        _pause
    else
        _err "服务启动失败，请查看日志排查"
        _pause
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
# 卸载指定协议
#═══════════════════════════════════════════════════════════════════════════════
uninstall_specific_protocol() {
    local installed; installed=$(db_all_protocols)
    [[ -z "$installed" ]] && { _warn "未安装任何协议"; return; }
    _header
    echo -e "  ${W}卸载指定协议${NC}" >&2
    _line
    local i=1 arr=() p
    for p in $installed; do
        _item "$i" "$(get_protocol_name "$p") ${D}[端口: $(db_list_ports "$(proto_core "$p")" "$p" | tr '\n' ',' | sed 's/,$//')]${NC}"
        arr+=("$p"); ((i++))
    done
    _item "0" "返回"
    _line
    local ch; read -rp "  请选择: " ch
    [[ "$ch" == "0" || -z "$ch" ]] && return
    [[ "$ch" =~ ^[0-9]+$ ]] && (( ch >= 1 && ch <= ${#arr[@]} )) || { _err "无效选择"; return; }
    local proto="${arr[$((ch-1))]}" core; core=$(proto_core "$proto")

    local ports; ports=$(db_list_ports "$core" "$proto")
    local pcount; pcount=$(echo "$ports" | sed '/^$/d' | wc -l)
    local target="all"
    if [[ "$pcount" -gt 1 ]]; then
        echo "" >&2
        local j=1 parr=() pp
        while IFS= read -r pp; do [[ -z "$pp" ]] && continue; _item "$j" "端口 $pp"; parr+=("$pp"); ((j++)); done <<<"$ports"
        _item "$j" "全部端口"
        _item "0" "取消"
        local pc; read -rp "  选择要卸载的端口: " pc
        [[ "$pc" == "0" || -z "$pc" ]] && return
        if [[ "$pc" == "$j" ]]; then target="all"
        elif [[ "$pc" =~ ^[0-9]+$ ]] && (( pc >= 1 && pc < j )); then target="${parr[$((pc-1))]}"
        else _err "无效选择"; return; fi
    fi

    _ask_yes "确认卸载 $(get_protocol_name "$proto") ${target}?" || return

    if [[ "$target" == "all" ]]; then
        unregister_protocol "$proto"
    else
        db_remove_port "$core" "$proto" "$target"
    fi

    if [[ "$core" == "snell" ]] && ! db_exists snell "$proto"; then
        local svc="vless-${proto}"
        svc stop "$svc" 2>/dev/null; svc disable "$svc" 2>/dev/null
        svc stop "${svc}-backend" 2>/dev/null; svc disable "${svc}-backend" 2>/dev/null
        if [[ "$DISTRO" == "alpine" ]]; then
            rm -f "/etc/init.d/$svc" "/etc/init.d/${svc}-backend"
        else
            rm -f "/etc/systemd/system/${svc}.service" "/etc/systemd/system/${svc}-backend.service"
            systemctl daemon-reload
        fi
        rm -f "${SNELL_CONF[$proto]}"
    fi

    if [[ -z "$(get_singbox_protocols)" ]]; then
        svc stop "$SB_SVC" 2>/dev/null; svc disable "$SB_SVC" 2>/dev/null
        rm -f "$SB_CONFIG"
        _info "已无 Sing-box 协议，服务已停止"
    else
        reload_config
    fi
    sync_traffic_counters 2>/dev/null || true
    _refresh_subscription_files
    _ok "卸载完成"
    _pause
}

#═══════════════════════════════════════════════════════════════════════════════
# 用户管理
#═══════════════════════════════════════════════════════════════════════════════
_select_protocol_for_users() {
    SELECTED_CORE=""; SELECTED_PROTO=""
    local protos=() p
    for p in $(db_all_protocols); do is_multiuser_protocol "$p" && protos+=("$p"); done
    [[ ${#protos[@]} -eq 0 ]] && { _err "没有支持多用户的已安装协议"; return 1; }
    echo "" >&2
    _line
    echo -e "  ${W}选择协议${NC}" >&2
    _line
    local i=1
    for p in "${protos[@]}"; do
        _item "$i" "$(get_protocol_name "$p") ${D}($(db_count_users "$(proto_core "$p")" "$p") 个用户)${NC}"
        ((i++))
    done
    _item "0" "返回"
    _line
    local ch; read -rp "  请选择: " ch
    [[ "$ch" == "0" || -z "$ch" ]] && return 1
    [[ "$ch" =~ ^[0-9]+$ ]] && (( ch >= 1 && ch <= ${#protos[@]} )) || { _err "无效选择"; return 1; }
    SELECTED_PROTO="${protos[$((ch-1))]}"
    SELECTED_CORE=$(proto_core "$SELECTED_PROTO")
    return 0
}

_show_users_list() {
    local core="$1" proto="$2"
    echo "" >&2
    _dline
    echo -e "  ${C}$(get_protocol_name "$proto") 用户列表${NC}" >&2
    _dline
    local stats; stats=$(db_users_stats "$core" "$proto")
    [[ -z "$stats" ]] && { echo -e "  ${D}暂无用户${NC}" >&2; _line; return; }
    printf "  ${W}%-14s %-10s %-9s %-9s %-14s${NC}\n" "用户名" "配额" "状态" "到期" "出口路由" >&2
    _line
    local name secret used quota enabled routing expire q st ex rt days
    while IFS='|' read -r name secret used quota enabled routing expire; do
        [[ -z "$name" ]] && continue
        q="无限"; [[ "$quota" -gt 0 ]] && q=$(format_bytes "$quota")
        st="${G}启用${NC}"; [[ "$enabled" != "true" ]] && st="${R}禁用${NC}"
        ex="永久"
        if [[ -n "$expire" ]]; then
            days=$(db_user_days_left "$core" "$proto" "$name")
            if [[ -n "$days" ]]; then
                if   [[ "$days" -lt 0 ]]; then ex="${R}已过期${NC}"
                elif [[ "$days" -le 3 ]]; then ex="${Y}${days}天${NC}"
                else ex="${days}天"; fi
            fi
        fi
        rt="全局规则"; [[ -n "$routing" ]] && rt=$(_outbound_display "$routing")
        printf "  %-14s %-10s %-18b %-18b %-14s\n" "$name" "$q" "$st" "$ex" "$rt" >&2
    done <<<"$stats"
    _line
    echo -e "  ${D}注: Sing-box 官方版本无 CLI 流量查询接口，配额字段仅作记录，不会自动断流。${NC}" >&2
}

_add_user() {
    local core="$1" proto="$2"
    is_multiuser_protocol "$proto" || { _err "$(get_protocol_name "$proto") 不支持多用户"; return 1; }
    echo "" >&2
    _line
    echo -e "  ${W}添加用户 - $(get_protocol_name "$proto")${NC}" >&2
    _line
    local name
    while true; do
        read -rp "  用户名: " name
        [[ -z "$name" ]] && { _err "不能为空"; continue; }
        [[ "$name" =~ ^[a-zA-Z0-9_.-]+$ ]] || { _err "只能包含字母、数字、下划线、点、横线"; continue; }
        db_user_exists "$core" "$proto" "$name" && { _err "用户已存在"; continue; }
        break
    done
    local secret method
    case "$proto" in
        vless-*|vmess-ws|tuic) secret=$(gen_uuid) ;;
        ss2022|ss2022-shadowtls)
            method=$(db_field "$core" "$proto" method)
            secret=$(gen_ss_psk "$method") ;;
        *) secret=$(ask_password 16 "用户密码") ;;
    esac
    local quota_gb
    echo -e "  ${D}流量配额 (GB)，0 = 无限制（仅记录，不自动断流）${NC}" >&2
    read -rp "  配额 [0]: " quota_gb; quota_gb="${quota_gb:-0}"
    [[ "$quota_gb" =~ ^[0-9]+$ ]] || quota_gb=0

    local expire="" expire_in
    echo -e "  ${D}到期: 输入天数(如 30) 或日期(2026-03-01)，回车表示永不过期${NC}" >&2
    read -rp "  到期: " expire_in
    if [[ "$expire_in" =~ ^[0-9]+$ ]]; then
        expire=$(date -d "+${expire_in} days" '+%Y-%m-%d' 2>/dev/null || date -v+"${expire_in}"d '+%Y-%m-%d' 2>/dev/null)
    elif [[ "$expire_in" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        expire="$expire_in"
    fi

    local routing=""
    if _ask_yes "是否为该用户配置专属出口路由?"; then
        routing=$(_select_outbound "选择该用户的出口" "true") || routing=""
    fi

    echo "" >&2
    _line
    echo -e "  用户名: ${G}${name}${NC}" >&2
    echo -e "  凭证  : ${G}${secret}${NC}" >&2
    echo -e "  配额  : ${G}${quota_gb} GB${NC}   到期: ${G}${expire:-永久}${NC}" >&2
    echo -e "  出口  : ${G}$( [[ -n "$routing" ]] && _outbound_display "$routing" || echo "全局规则" )${NC}" >&2
    _line
    _ask_yes "确认添加?" || return 0

    if db_add_user "$core" "$proto" "$name" "$secret" "$quota_gb" "$expire" "$routing"; then
        _ok "用户 $name 已添加"
        [[ -n "$expire" ]] && install_expire_cron
        reload_config
        _refresh_subscription_files
    else
        _err "添加失败"
    fi
}

_pick_user() {  # 输出选中的用户名
    local core="$1" proto="$2" i=1 arr=() n
    while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        _item "$i" "$n"
        arr+=("$n"); ((i++))
    done < <(db_list_users "$core" "$proto")
    [[ ${#arr[@]} -eq 0 ]] && { _err "无用户"; return 1; }
    _item "0" "返回"
    _line
    local ch; read -rp "  请选择: " ch
    [[ "$ch" == "0" || -z "$ch" ]] && return 1
    [[ "$ch" =~ ^[0-9]+$ ]] && (( ch >= 1 && ch <= ${#arr[@]} )) || { _err "无效选择"; return 1; }
    echo "${arr[$((ch-1))]}"
}

_show_user_links() {
    local core="$1" proto="$2"
    _header
    echo -e "  ${W}$(get_protocol_name "$proto") 用户分享链接${NC}" >&2
    _line
    local ipv4 ipv6 addr cc cfg
    ipv4=$(get_ipv4); ipv6=$(get_ipv6); addr="$ipv4"; [[ -z "$addr" ]] && addr="$ipv6"
    cc=$(get_ip_country "$ipv4"); [[ -z "$cc" || "$cc" == "XX" ]] && cc=$(get_ip_country "$ipv6")
    while IFS= read -r cfg; do
        [[ -z "$cfg" ]] && continue
        echo -e "  ${Y}端口 $(echo "$cfg" | jq -r '.port')${NC}" >&2
        local un sec label link
        while IFS='|' read -r un sec; do
            [[ -z "$un" ]] && continue
            label=$(_node_label "$proto" "$cc" "$un")
            link=$(build_share_link "$proto" "$cfg" "$addr" "$label" "$sec" "$un")
            [[ -n "$link" ]] && echo -e "  ${G}${link}${NC}" >&2
            print_client_snippet "$proto" "$cfg" "$addr" "$label" "$sec" "$un"
        done < <(_instance_user_pairs "$proto" "$cfg")
        echo "" >&2
    done < <(db_instances "$core" "$proto")
    _line
}

install_expire_cron() {
    check_cmd crontab || { _warn "crontab 不可用，无法安装到期检查任务"; return 1; }
    crontab -l 2>/dev/null | grep -q "vless-check-expire" && return 0
    local script="$SYSTEM_SCRIPT"
    [[ -x "$script" ]] || script=$(readlink -f "$0")
    local entry="0 3 * * * /bin/bash $script --check-expire >> $CFG/expire.log 2>&1 # vless-check-expire"
    local cur; cur=$(crontab -l 2>/dev/null | grep -v "vless-check-expire")
    printf '%s\n%s\n' "$cur" "$entry" | awk 'NF' | crontab -
    _ok "已安装用户到期检查任务 (每天 03:00)"
}

check_and_disable_expired() {
    local count=0 line core proto name exp
    while IFS='|' read -r core proto name exp; do
        [[ -z "$name" ]] && continue
        db_set_user_enabled "$core" "$proto" "$name" false
        echo "[$(date '+%F %T')] 禁用过期用户: $name ($proto, 到期 $exp)" >>"$CFG/expire.log"
        ((count++))
    done < <(db_expired_users)
    if [[ "$count" -gt 0 ]]; then
        reload_config
        _refresh_subscription_files
    fi
    echo "$count"
}

manage_users() {
    while true; do
        _header
        echo -e "  ${W}用户管理${NC}" >&2
        _dline
        local p
        for p in $(db_all_protocols); do
            if is_multiuser_protocol "$p"; then
                echo -e "  • $(get_protocol_name "$p"): ${G}$(db_count_users "$(proto_core "$p")" "$p")${NC} 用户" >&2
            else
                echo -e "  • $(get_protocol_name "$p"): ${D}单用户协议${NC}" >&2
            fi
        done
        _line
        _item "1" "查看用户列表"
        _item "2" "添加用户"
        _item "3" "删除用户"
        _item "4" "设置用户配额 ${D}(记录用)${NC}"
        _item "5" "启用 / 禁用用户"
        _item "6" "设置到期日期"
        _item "7" "修改用户出口路由"
        _item "8" "查看用户分享链接"
        _item "9" "协议流量统计 ${D}(端口级)${NC}"
        _item "0" "返回"
        _line
        local ch; read -rp "  请选择: " ch
        case "$ch" in
            1) _select_protocol_for_users && { _show_users_list "$SELECTED_CORE" "$SELECTED_PROTO"; _pause; } ;;
            2) _select_protocol_for_users && { _add_user "$SELECTED_CORE" "$SELECTED_PROTO"; _pause; } ;;
            3)
                _select_protocol_for_users || continue
                _show_users_list "$SELECTED_CORE" "$SELECTED_PROTO"
                local u; u=$(_pick_user "$SELECTED_CORE" "$SELECTED_PROTO") || { _pause; continue; }
                if _ask_yes "确认删除用户 $u?"; then
                    db_del_user "$SELECTED_CORE" "$SELECTED_PROTO" "$u"
                    _ok "已删除"; reload_config
                    _refresh_subscription_files
                fi
                _pause ;;
            4)
                _select_protocol_for_users || continue
                _show_users_list "$SELECTED_CORE" "$SELECTED_PROTO"
                local u; u=$(_pick_user "$SELECTED_CORE" "$SELECTED_PROTO") || { _pause; continue; }
                local q; read -rp "  新配额 (GB, 0=无限): " q
                [[ "$q" =~ ^[0-9]+$ ]] || { _err "无效数字"; _pause; continue; }
                db_set_user_quota "$SELECTED_CORE" "$SELECTED_PROTO" "$u" "$q" && _ok "已设置"
                _pause ;;
            5)
                _select_protocol_for_users || continue
                _show_users_list "$SELECTED_CORE" "$SELECTED_PROTO"
                local u; u=$(_pick_user "$SELECTED_CORE" "$SELECTED_PROTO") || { _pause; continue; }
                local cur; cur=$(db_get_user_field "$SELECTED_CORE" "$SELECTED_PROTO" "$u" enabled)
                if [[ "$cur" == "true" ]]; then
                    db_set_user_enabled "$SELECTED_CORE" "$SELECTED_PROTO" "$u" false; _ok "$u 已禁用"
                else
                    db_set_user_enabled "$SELECTED_CORE" "$SELECTED_PROTO" "$u" true; _ok "$u 已启用"
                fi
                reload_config; _refresh_subscription_files; _pause ;;
            6)
                _select_protocol_for_users || continue
                _show_users_list "$SELECTED_CORE" "$SELECTED_PROTO"
                local u; u=$(_pick_user "$SELECTED_CORE" "$SELECTED_PROTO") || { _pause; continue; }
                echo -e "  ${D}输入天数或日期(YYYY-MM-DD)，输入 0 取消到期限制${NC}" >&2
                local e newe=""; read -rp "  到期: " e
                if [[ "$e" == "0" ]]; then newe=""
                elif [[ "$e" =~ ^[0-9]+$ ]]; then newe=$(date -d "+${e} days" '+%Y-%m-%d' 2>/dev/null || date -v+"${e}"d '+%Y-%m-%d' 2>/dev/null)
                elif [[ "$e" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then newe="$e"
                else _err "格式无效"; _pause; continue; fi
                db_set_user_expire "$SELECTED_CORE" "$SELECTED_PROTO" "$u" "$newe"
                _ok "到期日期已设为: ${newe:-永久}"
                [[ -n "$newe" ]] && install_expire_cron
                _pause ;;
            7)
                _select_protocol_for_users || continue
                _show_users_list "$SELECTED_CORE" "$SELECTED_PROTO"
                local u; u=$(_pick_user "$SELECTED_CORE" "$SELECTED_PROTO") || { _pause; continue; }
                local r; r=$(_select_outbound "选择该用户的出口" "true") || { _info "已取消"; _pause; continue; }
                db_set_user_routing "$SELECTED_CORE" "$SELECTED_PROTO" "$u" "$r"
                _ok "$u 出口已设为: $(_outbound_display "$r")"
                reload_config; _pause ;;
            8) _select_protocol_for_users && { _show_user_links "$SELECTED_CORE" "$SELECTED_PROTO"; _pause; } ;;
            9) sync_traffic_counters; show_port_traffic; _pause ;;
            0) return ;;
            *) _err "无效选择"; sleep 1 ;;
        esac
    done
}

#═══════════════════════════════════════════════════════════════════════════════
# 订阅服务
#═══════════════════════════════════════════════════════════════════════════════
get_sub_uuid() {
    local f="$CFG/sub_uuid" u tmp
    if [[ -f "$f" ]]; then
        u=$(head -1 "$f" 2>/dev/null | tr -d '\r\n')
        if [[ "$u" =~ ^[0-9a-fA-F-]{16,64}$ ]]; then
            echo "$u"
            return 0
        fi
        _warn "订阅 UUID 文件无效，将安全地重新生成"
    fi
    u=$(gen_uuid)
    [[ "$u" =~ ^[0-9a-fA-F-]{16,64}$ ]] || { _err "订阅 UUID 生成失败"; return 1; }
    mkdir -p "$CFG" || return 1
    tmp=$(mktemp "${f}.new.XXXXXX") || return 1
    if printf '%s\n' "$u" >"$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$f"; then
        echo "$u"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

_subscription_files_current() {
    local uuid dir f
    [[ -f "$CFG/sub_uuid" ]] || return 1
    uuid=$(head -1 "$CFG/sub_uuid" 2>/dev/null | tr -d '\r\n')
    [[ "$uuid" =~ ^[0-9a-fA-F-]{16,64}$ ]] || return 1
    dir="$CFG/subscription/$uuid"
    for f in base64 clash.yaml surge.conf; do
        [[ -f "$dir/$f" ]] || return 1
        [[ -f "$DB_FILE" && "$DB_FILE" -nt "$dir/$f" ]] && return 1
        [[ -f "$NODE_NAME_FILE" && "$NODE_NAME_FILE" -nt "$dir/$f" ]] && return 1
        [[ -f "$SSL_DIR/server.crt" && "$SSL_DIR/server.crt" -nt "$dir/$f" ]] && return 1
    done
    return 0
}

ensure_subscription_files() {
    [[ -n "$(db_all_protocols)" ]] || return 0
    _subscription_files_current && return 0
    _info "补齐或刷新本地订阅文件..."
    _refresh_subscription_files
}

_all_share_links_plain() {
    local ipv4 ipv6 addr cc proto core cfg un sec label link
    ipv4=$(get_ipv4); ipv6=$(get_ipv6); addr="$ipv4"; [[ -z "$addr" ]] && addr="$ipv6"
    cc=$(get_ip_country "$ipv4"); [[ -z "$cc" || "$cc" == "XX" ]] && cc=$(get_ip_country "$ipv6")
    for proto in $(db_all_protocols); do
        core=$(proto_core "$proto")
        while IFS= read -r cfg; do
            [[ -z "$cfg" ]] && continue
            while IFS='|' read -r un sec; do
                [[ -z "$un" ]] && continue
                label=$(_node_label "$proto" "$cc" "$un")
                link=$(build_share_link "$proto" "$cfg" "$addr" "$label" "$sec" "$un")
                [[ -n "$link" ]] && echo "$link"
            done < <(_instance_user_pairs "$proto" "$cfg")
        done < <(db_instances "$core" "$proto")
    done
}

gen_v2ray_sub() { _all_share_links_plain | base64 -w 0 2>/dev/null || _all_share_links_plain | base64 | tr -d '\n'; }

gen_clash_sub() {
    local ipv4 ipv6 addr cc proto core cfg names="" body=""
    ipv4=$(get_ipv4); ipv6=$(get_ipv6); addr="$ipv4"; [[ -z "$addr" ]] && addr="$ipv6"
    cc=$(get_ip_country "$ipv4"); [[ -z "$cc" || "$cc" == "XX" ]] && cc=$(get_ip_country "$ipv6")

    for proto in $(db_all_protocols); do
        core=$(proto_core "$proto")
        while IFS= read -r cfg; do
            [[ -z "$cfg" ]] && continue
            local iaddr port sni path method insec block
            iaddr=$(_instance_addr "$cfg" "$addr")
            port=$(echo "$cfg" | jq -r '.port')
            sni=$(echo "$cfg" | jq -r '.sni // empty')
            path=$(echo "$cfg" | jq -r '.path // "/"')
            method=$(echo "$cfg" | jq -r '.method // empty')
            _cert_real_for "$sni" && insec="false" || insec="true"
            local un sec label
            while IFS='|' read -r un sec; do
                [[ -z "$un" ]] && continue
                label=$(_node_label "$proto" "$cc" "$un")
                block=$(_clash_proxy_block "$proto" "$cfg" "$iaddr" "$label" "$sec" "$un" \
                            "$port" "$sni" "$path" "$method" "$insec")
                [[ -n "$block" ]] && { body+="${block}"$'\n'; names+="      - ${label}"$'\n'; }
            done < <(_instance_user_pairs "$proto" "$cfg")
        done < <(db_instances "$core" "$proto")
    done

    cat <<EOF
mixed-port: 7897
allow-lan: false
mode: rule
log-level: info
ipv6: true
external-controller: 127.0.0.1:9090

proxies:
${body}
proxy-groups:
  - name: Proxy
    type: select
    proxies:
${names}
  - name: Auto
    type: url-test
    url: http://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
    proxies:
${names}
rules:
  - GEOIP,CN,DIRECT
  - MATCH,Proxy
EOF
}

# 生成一个 Clash/Mihomo 代理条目（块状 YAML，2/4/6 空格缩进）
# _clash_proxy_block <proto> <cfg> <addr> <label> <secret> <user> <port> <sni> <path> <method> <insecure>
_clash_proxy_block() {
    local proto="$1" cfg="$2" addr="$3" label="$4" sec="$5" un="$6"
    local port="$7" sni="$8" path="$9" method="${10}" insec="${11}"
    local o=""
    _k() { o+="    $1"$'\n'; }          # 4 空格：条目内的键
    _k2() { o+="      $1"$'\n'; }       # 6 空格：嵌套键
    o+="  - name: ${label}"$'\n'

    case "$proto" in
        vless-reality)
            _k "type: vless"; _k "server: ${addr}"; _k "port: ${port}"
            _k "uuid: ${sec}"; _k "network: tcp"; _k "tls: true"; _k "udp: true"
            _k "flow: xtls-rprx-vision"
            _k "servername: ${sni}"
            _k "reality-opts:"
            _k2 "public-key: $(echo "$cfg" | jq -r '.public_key')"
            _k2 "short-id: $(echo "$cfg" | jq -r '.short_id')"
            _k "client-fingerprint: chrome" ;;
        vless-vision)
            _k "type: vless"; _k "server: ${addr}"; _k "port: ${port}"
            _k "uuid: ${sec}"; _k "network: tcp"; _k "tls: true"; _k "udp: true"
            _k "flow: xtls-rprx-vision"
            _k "servername: ${sni}"
            _k "skip-cert-verify: ${insec}"
            _k "client-fingerprint: chrome" ;;
        vless-ws)
            _k "type: vless"; _k "server: ${addr}"; _k "port: ${port}"
            _k "uuid: ${sec}"; _k "network: ws"; _k "tls: true"; _k "udp: true"
            _k "servername: ${sni}"; _k "skip-cert-verify: ${insec}"
            _k "client-fingerprint: chrome"
            _k "ws-opts:"; _k2 "path: ${path}"; _k2 "headers:"
            o+="        Host: ${sni}"$'\n' ;;
        vless-ws-notls)
            _k "type: vless"; _k "server: ${addr}"; _k "port: ${port}"
            _k "uuid: ${sec}"; _k "network: ws"; _k "tls: false"; _k "udp: true"
            _k "ws-opts:"; _k2 "path: ${path}"
            local host; host=$(echo "$cfg" | jq -r '.host // empty')
            [[ -n "$host" ]] && { _k2 "headers:"; o+="        Host: ${host}"$'\n'; } ;;
        vmess-ws)
            _k "type: vmess"; _k "server: ${addr}"; _k "port: ${port}"
            _k "uuid: ${sec}"; _k "alterId: 0"; _k "cipher: auto"
            _k "network: ws"; _k "tls: true"; _k "udp: true"
            _k "servername: ${sni}"; _k "skip-cert-verify: ${insec}"
            _k "client-fingerprint: chrome"
            _k "ws-opts:"; _k2 "path: ${path}"; _k2 "headers:"
            o+="        Host: ${sni}"$'\n' ;;
        trojan)
            _k "type: trojan"; _k "server: ${addr}"; _k "port: ${port}"
            _k "password: ${sec}"; _k "sni: ${sni}"; _k "udp: true"
            _k "skip-cert-verify: ${insec}"
            _k "client-fingerprint: chrome" ;;
        trojan-ws)
            _k "type: trojan"; _k "server: ${addr}"; _k "port: ${port}"
            _k "password: ${sec}"; _k "sni: ${sni}"; _k "udp: true"
            _k "skip-cert-verify: ${insec}"; _k "network: ws"
            _k "client-fingerprint: chrome"
            _k "ws-opts:"; _k2 "path: ${path}"; _k2 "headers:"
            o+="        Host: ${sni}"$'\n' ;;
        hy2)
            _k "type: hysteria2"; _k "server: ${addr}"; _k "port: ${port}"
            _k "password: ${sec}"; _k "sni: ${sni}"
            _k "skip-cert-verify: ${insec}"
            _k "alpn:"; o+="      - h3"$'\n'
            local hup hdown
            hup=$(echo "$cfg" | jq -r '.up_mbps // 0'); hdown=$(echo "$cfg" | jq -r '.down_mbps // 0')
            if [[ "$hup" -gt 0 && "$hdown" -gt 0 ]]; then
                # Brutal 模式客户端也要申报带宽，否则退回 BBR
                _k "up: \"${hdown} Mbps\""
                _k "down: \"${hup} Mbps\""
            fi
            local hs he
            hs=$(echo "$cfg" | jq -r '.hop_start // 0'); he=$(echo "$cfg" | jq -r '.hop_end // 0')
            [[ "$(echo "$cfg" | jq -r '.hop_enable // 0')" == "1" ]] && \
                _k "ports: ${hs}-${he}" ;;
        tuic)
            _k "type: tuic"; _k "server: ${addr}"; _k "port: ${port}"
            _k "uuid: ${sec}"; _k "password: $(echo "$cfg" | jq -r '.password')"
            _k "sni: ${sni}"; _k "congestion-controller: bbr"
            _k "udp-relay-mode: native"; _k "reduce-rtt: true"
            _k "skip-cert-verify: ${insec}"
            _k "alpn:"; o+="      - h3"$'\n' ;;
        anytls)
            _k "type: anytls"; _k "server: ${addr}"; _k "port: ${port}"
            _k "password: ${sec}"; _k "sni: ${sni}"; _k "udp: true"
            _k "skip-cert-verify: ${insec}"
            _k "client-fingerprint: chrome" ;;
        ss2022|ss-legacy)
            _k "type: ss"; _k "server: ${addr}"; _k "port: ${port}"
            _k "cipher: ${method}"
            _k "password: $(_ss_client_password "$cfg" "$sec")"
            _k "udp: true" ;;
        ss2022-shadowtls)
            _k "type: ss"; _k "server: ${addr}"; _k "port: ${port}"
            _k "cipher: ${method}"
            _k "password: $(_ss_client_password "$cfg" "$sec")"
            _k "udp: true"; _k "plugin: shadow-tls"
            _k "plugin-opts:"
            _k2 "host: ${sni}"
            _k2 "password: $(echo "$cfg" | jq -r '.stls_password')"
            _k2 "version: 3" ;;
        snell|snell-v5|snell-v6)
            _k "type: snell"; _k "server: ${addr}"; _k "port: ${port}"
            _k "psk: ${sec}"
            _k "version: $(echo "$cfg" | jq -r '.version // 4')"
            _k "udp: true" ;;
        socks)
            [[ "$(echo "$cfg" | jq -r '.auth_mode // "password"')" == "noauth" ]] && { echo ""; return; }
            _k "type: socks5"; _k "server: ${addr}"; _k "port: ${port}"
            _k "username: ${un}"; _k "password: ${sec}"; _k "udp: true" ;;
        *) echo ""; return ;;
    esac
    printf '%s' "$o"
}

gen_surge_sub() {
    local ipv4 ipv6 addr cc proto core cfg body="" names=""
    ipv4=$(get_ipv4); ipv6=$(get_ipv6); addr="$ipv4"; [[ -z "$addr" ]] && addr="$ipv6"
    cc=$(get_ip_country "$ipv4"); [[ -z "$cc" || "$cc" == "XX" ]] && cc=$(get_ip_country "$ipv6")
    for proto in $(db_all_protocols); do
        core=$(proto_core "$proto")
        while IFS= read -r cfg; do
            [[ -z "$cfg" ]] && continue
            local iaddr; iaddr=$(_instance_addr "$cfg" "$addr")
            local port sni method psk version stls scv
            port=$(echo "$cfg" | jq -r '.port'); sni=$(echo "$cfg" | jq -r '.sni // empty')
            method=$(echo "$cfg" | jq -r '.method // empty'); psk=$(echo "$cfg" | jq -r '.psk // empty')
            version=$(echo "$cfg" | jq -r '.version // empty'); stls=$(echo "$cfg" | jq -r '.stls_password // empty')
            _cert_real_for "$sni" && scv="false" || scv="true"
            local label line=""
            case "$proto" in
                snell|snell-v5|snell-v6)
                    label=$(_node_label "$proto" "$cc" "")
                    local stfo smode=""
                    stfo=$(echo "$cfg" | jq -r '.tfo // "true"')
                    [[ "$version" == "6" ]] && smode=", mode=$(echo "$cfg" | jq -r '.mode // "default"')"
                    line="${label} = snell, ${iaddr}, ${port}, psk=${psk}, version=${version}, reuse=true, tfo=${stfo}${smode}" ;;
                snell-shadowtls|snell-v5-shadowtls)
                    label=$(_node_label "$proto" "$cc" "")
                    local stfo2; stfo2=$(echo "$cfg" | jq -r '.tfo // "true"')
                    line="${label} = snell, ${iaddr}, ${port}, psk=${psk}, version=${version}, reuse=true, tfo=${stfo2}, shadow-tls-password=${stls}, shadow-tls-sni=${sni}, shadow-tls-version=3" ;;
                trojan|trojan-ws|hy2|anytls|ss-legacy|ss2022|tuic|ss2022-shadowtls|vmess-ws|socks|naive)
                    local un sec path
                    path=$(echo "$cfg" | jq -r '.path // "/"')
                    while IFS='|' read -r un sec; do
                        [[ -z "$un" ]] && continue
                        label=$(_node_label "$proto" "$cc" "$un")
                        case "$proto" in
                            trojan) line="${label} = trojan, ${iaddr}, ${port}, password=${sec}, sni=${sni}, skip-cert-verify=${scv}" ;;
                            trojan-ws) line="${label} = trojan, ${iaddr}, ${port}, password=${sec}, sni=${sni}, skip-cert-verify=${scv}, ws=true, ws-path=${path}, ws-headers=Host:${sni}" ;;
                            vmess-ws) line="${label} = vmess, ${iaddr}, ${port}, username=${sec}, tls=true, sni=${sni}, skip-cert-verify=${scv}, ws=true, ws-path=${path}, ws-headers=Host:${sni}, vmess-aead=true" ;;
                            naive) line="${label} = http, $(echo "$cfg" | jq -r '.domain // .sni'), ${port}, ${un}, ${sec}, tls=true" ;;
                            socks)
                                if [[ "$(echo "$cfg" | jq -r '.auth_mode // "password"')" == "noauth" ]]; then line=""
                                else line="${label} = socks5, ${iaddr}, ${port}, ${un}, ${sec}"; fi ;;
                            hy2)    line="${label} = hysteria2, ${iaddr}, ${port}, password=${sec}, sni=${sni}, skip-cert-verify=${scv}" ;;
                            anytls) line="${label} = anytls, ${iaddr}, ${port}, password=${sec}, sni=${sni}, skip-cert-verify=${scv}" ;;
                            tuic)   line="${label} = tuic-v5, ${iaddr}, ${port}, uuid=${sec}, password=$(echo "$cfg" | jq -r '.password'), sni=${sni}, alpn=h3, skip-cert-verify=${scv}" ;;
                            ss-legacy) line="${label} = ss, ${iaddr}, ${port}, encrypt-method=${method}, password=${sec}" ;;
                            ss2022) line="${label} = ss, ${iaddr}, ${port}, encrypt-method=${method}, password=$(_ss_client_password "$cfg" "$sec")" ;;
                            ss2022-shadowtls) line="${label} = ss, ${iaddr}, ${port}, encrypt-method=${method}, password=$(_ss_client_password "$cfg" "$sec"), shadow-tls-password=${stls}, shadow-tls-sni=${sni}, shadow-tls-version=3" ;;
                        esac
                        [[ -n "$line" ]] && { body+="$line"$'\n'; names+="${names:+, }${label}"; }
                        line=""
                    done < <(_instance_user_pairs "$proto" "$cfg")
                    ;;
            esac
            [[ -n "$line" ]] && { body+="$line"$'\n'; names+="${names:+, }${label}"; }
        done < <(db_instances "$core" "$proto")
    done
    cat <<EOF
[General]
loglevel = notify

[Proxy]
${body}
[Proxy Group]
Proxy = select, ${names}

[Rule]
GEOIP,CN,DIRECT
FINAL,Proxy
EOF
}

generate_sub_files() {
    local uuid dir stage f
    uuid=$(get_sub_uuid) || return 1
    dir="$CFG/subscription/$uuid"
    mkdir -p "$CFG/subscription" "$dir" || { _err "无法创建订阅目录"; return 1; }
    chmod 711 "$CFG/subscription" "$dir" 2>/dev/null
    stage=$(mktemp -d "$CFG/subscription/.generate.XXXXXX") || {
        _err "无法创建订阅文件暂存目录"; return 1; }
    if ! gen_v2ray_sub >"$stage/base64" ||
       ! gen_clash_sub >"$stage/clash.yaml" ||
       ! gen_surge_sub >"$stage/surge.conf"; then
        rm -rf "$stage"
        _err "订阅内容生成失败，原文件保持不变"
        return 1
    fi
    chmod 644 "$stage"/* 2>/dev/null || {
        rm -rf "$stage"; _err "订阅文件权限设置失败"; return 1; }
    # 三个文件均生成成功后再逐个原子替换，避免生成中途留下空文件。
    for f in base64 clash.yaml surge.conf; do
        mv -f "$stage/$f" "$dir/$f" || {
            rm -rf "$stage"; _err "订阅文件写入失败: $f"; return 1; }
    done
    rm -rf "$stage"
    _ok "订阅文件已生成"
}

# 本地订阅文件与 Nginx 是否公开访问完全解耦。协议/用户/证书变更后统一调用；
# 刷新失败只告警，不回滚已经成功生效的协议配置。
_refresh_subscription_files() {
    generate_sub_files && return 0
    _warn "协议配置已生效，但订阅文件刷新失败；可在 [订阅服务管理] 中重试"
    return 0
}

_write_sub_info() {
    local u="$1" p="$2" d="$3" https="$4"
    printf 'sub_uuid=%s\nsub_port=%s\nsub_domain=%s\nsub_https=%s\n' "$u" "$p" "$d" "$https" >"$CFG/sub.info"
    chmod 600 "$CFG/sub.info"
}
_load_sub_info() {
    local line k v
    sub_uuid=""; sub_port=""; sub_domain=""; sub_https=""
    [[ -f "$CFG/sub.info" ]] || return 1
    while IFS= read -r line; do
        k="${line%%=*}"; v="${line#*=}"
        case "$k" in
            sub_uuid)   [[ "$v" =~ ^[0-9a-fA-F-]{16,64}$ ]] && sub_uuid="$v" ;;
            sub_port)   _is_valid_port "$v" && sub_port="$v" ;;
            sub_domain) _is_valid_host "$v" || [[ -z "$v" ]] && sub_domain="$v" ;;
            sub_https)  [[ "$v" == "true" || "$v" == "false" ]] && sub_https="$v" ;;
        esac
    done <"$CFG/sub.info"
    [[ -n "$sub_uuid" && -n "$sub_port" ]]
}

install_nginx() {
    check_cmd nginx && return 0
    _info "安装 Nginx..."
    case "$DISTRO" in
        alpine) apk add --no-cache nginx >/dev/null 2>&1 ;;
        centos) yum install -y nginx >/dev/null 2>&1 ;;
        *) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx >/dev/null 2>&1 ;;
    esac
    check_cmd nginx && { _ok "Nginx 已安装"; return 0; }
    _err "Nginx 安装失败"; return 1
}

setup_subscription() {
    _header
    echo -e "  ${W}配置订阅服务${NC}" >&2
    _line
    install_nginx || { _pause; return 1; }

    if [[ -f "$CFG/sub.info" && -f "$CFG/sub_uuid" ]] &&
       _ask_yes "检测到已有订阅服务，是否重新生成 UUID（旧链接失效）?"; then
        local old; old=$(get_sub_uuid) || return 1
        rm -rf "$CFG/subscription/$old" "$CFG/sub_uuid"
        _ok "订阅 UUID 已重置"
    fi

    local port def=18443
    while true; do
        read -rp "  订阅端口 [${def}]: " port; port="${port:-$def}"
        _is_valid_port "$port" || { _err "端口无效"; continue; }
        local owner; owner=$(is_internal_port_occupied "$port") && { _err "端口被 [$owner] 占用"; continue; }
        if ss -tuln 2>/dev/null | grep -qE ":${port}[^0-9]"; then
            _ask_yes "端口 $port 已被系统占用，强制使用?" || continue
        fi
        break
    done
    local domain; read -rp "  域名 (可选，回车使用服务器 IP): " domain
    [[ -n "$domain" ]] && { _is_valid_host "$domain" || { _err "域名无效"; _pause; return 1; }; }
    local https="true"
    _ask_yes "启用 HTTPS?（自签证书部分客户端可能无法拉取，可选 n 用 HTTP）" || https="false"

    generate_sub_files || return 1
    local uuid dir conf_dir conf
    uuid=$(get_sub_uuid); dir="$CFG/subscription/$uuid"
    conf_dir="/etc/nginx/conf.d"; [[ -d /etc/nginx/http.d ]] && conf_dir="/etc/nginx/http.d"
    mkdir -p "$conf_dir" /var/www/html
    conf="$conf_dir/vless-sub.conf"

    local ssl_l="" ssl_b=""
    if [[ "$https" == "true" ]]; then
        [[ -s "$SSL_DIR/server.crt" ]] || gen_self_cert "${domain:-localhost}"
        ssl_l=" ssl"
        ssl_b="    ssl_certificate $SSL_DIR/server.crt;
    ssl_certificate_key $SSL_DIR/server.key;
    ssl_protocols TLSv1.2 TLSv1.3;"
    fi

    cat >"$conf" <<EOF
server {
    listen ${port}${ssl_l};
    listen [::]:${port}${ssl_l};
    server_name ${domain:-_};
${ssl_b}
    root /var/www/html;
    index index.html;

    location = /sub/${uuid}/v2ray { alias ${dir}/base64;     default_type text/plain; }
    location = /sub/${uuid}/clash { alias ${dir}/clash.yaml; default_type text/yaml; }
    location = /sub/${uuid}/surge { alias ${dir}/surge.conf; default_type text/plain; }

    location / { try_files \$uri \$uri/ =404; }
    server_tokens off;
}
EOF
    [[ -f /var/www/html/index.html ]] || cat >/var/www/html/index.html <<'EOFH'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Welcome</title></head>
<body style="font-family:Arial,sans-serif;padding:40px"><h1>Welcome</h1>
<p>This site is under maintenance.</p></body></html>
EOFH

    if nginx -t >/dev/null 2>&1; then
        svc enable nginx 2>/dev/null
        svc restart nginx >/dev/null 2>&1 || nginx -s reload >/dev/null 2>&1
        _write_sub_info "$uuid" "$port" "$domain" "$https"
        _ok "订阅服务已启用"
        show_sub_links
    else
        _err "Nginx 配置错误"; nginx -t 2>&1 | sed 's/^/    /' >&2
        rm -f "$conf"
        return 1
    fi
}

show_sub_links() {
    _load_sub_info || { _warn "订阅服务未配置"; return 1; }
    local scheme="http"; [[ "$sub_https" == "true" ]] && scheme="https"
    local host="${sub_domain:-$(get_ipv4)}"
    [[ -z "$host" ]] && host="[$(get_ipv6)]"
    local base="${scheme}://${host}:${sub_port}/sub/${sub_uuid}"
    _line
    echo -e "  ${W}订阅链接${NC}" >&2
    _line
    echo -e "  ${Y}Clash / Mihomo:${NC}  ${G}${base}/clash${NC}" >&2
    echo -e "  ${Y}Surge:${NC}           ${G}${base}/surge${NC}" >&2
    echo -e "  ${Y}V2Ray / 通用:${NC}    ${G}${base}/v2ray${NC}" >&2
    _line
    echo -e "  ${D}路径包含随机 UUID，请妥善保管${NC}" >&2
    [[ "$sub_https" == "true" && -z "$sub_domain" ]] && \
        echo -e "  ${Y}提示: 使用自签证书时部分客户端会拒绝拉取，建议绑定域名或改用 HTTP${NC}" >&2
}

manage_subscription() {
    while true; do
        _header
        echo -e "  ${W}订阅服务管理${NC}" >&2
        _line
        if _load_sub_info; then
            echo -e "  状态: ${G}已配置${NC}   端口: ${G}${sub_port}${NC}   HTTPS: ${G}${sub_https}${NC}" >&2
            [[ -n "$sub_domain" ]] && echo -e "  域名: ${G}${sub_domain}${NC}" >&2
            _line
            _item "1" "查看订阅链接"
            _item "2" "更新订阅内容"
            _item "3" "重新配置"
            _item "4" "停用订阅服务"
            _item "5" "节点命名设置 ${D}(当前: $(_node_label vless-reality "$(get_ip_country "$(get_ipv4)")" ""))${NC}"
        else
            echo -e "  状态: ${D}未配置${NC}" >&2
            if _subscription_files_current; then
                local local_uuid; local_uuid=$(head -1 "$CFG/sub_uuid")
                echo -e "  本地文件: ${G}已生成并自动维护${NC}   ${D}${CFG}/subscription/${local_uuid}${NC}" >&2
            else
                echo -e "  本地文件: ${Y}缺失或需要刷新${NC}" >&2
            fi
            _line
            _item "1" "启用订阅服务"
            _item "2" "立即更新本地订阅文件"
            _item "5" "节点命名设置 ${D}(当前: $(_node_label vless-reality "$(get_ip_country "$(get_ipv4)")" ""))${NC}"
        fi
        _item "0" "返回"
        _line
        local ch; read -rp "  请选择: " ch
        if _load_sub_info; then
            case "$ch" in
                1) show_sub_links; _pause ;;
                2) generate_sub_files; _pause ;;
                3) setup_subscription; _pause ;;
                5) set_node_name; _pause ;;
                4)
                    rm -f /etc/nginx/conf.d/vless-sub.conf /etc/nginx/http.d/vless-sub.conf "$CFG/sub.info"
                    local others; others=$(ls /etc/nginx/conf.d/*.conf /etc/nginx/http.d/*.conf 2>/dev/null | wc -l)
                    if [[ "$others" -eq 0 ]]; then svc stop nginx 2>/dev/null; _info "Nginx 已停止"
                    else nginx -s reload >/dev/null 2>&1; fi
                    _refresh_subscription_files
                    _ok "订阅服务已停用；本地订阅文件仍会自动维护"; _pause ;;
                0) return ;;
                *) _err "无效选择"; sleep 1 ;;
            esac
        else
            case "$ch" in
                1) setup_subscription; _pause ;;
                2) _refresh_subscription_files; _pause ;;
                5) set_node_name; _pause ;;
                0) return ;;
                *) _err "无效选择"; sleep 1 ;;
            esac
        fi
    done
}

# 节点命名：影响分享链接名、Clash/Surge 订阅里的节点名
set_node_name() {
    local cc cur new
    cc=$(get_ip_country "$(get_ipv4)"); [[ -z "$cc" || "$cc" == "XX" ]] && cc=$(get_ip_country "$(get_ipv6)")
    cur=$(node_name)
    echo "" >&2
    _line
    echo -e "  ${W}节点命名${NC}" >&2
    echo -e "  ${D}节点名会拼成: <国旗> <节点名>-<协议>[-用户]${NC}" >&2
    echo -e "  当前节点名: ${G}${cur}${NC}   识别到的地区: ${G}${cc:-未知} $(_flag_emoji "$cc")${NC}" >&2
    echo -e "  当前效果  : ${C}$(_node_label vless-reality "$cc" "")${NC}  /  ${C}$(_node_label tuic "$cc" "bob")${NC}" >&2
    _line
    echo -e "  ${D}只用字母数字与短横线；留空取消，输入 - 恢复自动（取主机名）${NC}" >&2
    read -rp "  新节点名: " new
    [[ -z "$new" ]] && { _info "未做改动"; return 0; }
    if [[ "$new" == "-" ]]; then
        rm -f "$NODE_NAME_FILE"
        _ok "已恢复自动命名: $(node_name)"
    else
        if [[ ! "$new" =~ ^[A-Za-z0-9._-]+$ ]]; then
            _err "只能包含字母、数字、点、下划线、短横线"; return 1
        fi
        echo "$new" >"$NODE_NAME_FILE"
        _ok "节点名已设为: ${new}"
    fi
    echo -e "  新效果: ${C}$(_node_label vless-reality "$cc" "")${NC}" >&2
    _refresh_subscription_files
    _warn "请重新导出分享链接，或让客户端刷新订阅"
}

#═══════════════════════════════════════════════════════════════════════════════
# 服务管理 / BBR / 日志
#═══════════════════════════════════════════════════════════════════════════════
manage_protocol_services() {
    while true; do
        _header
        echo -e "  ${W}协议服务管理${NC}" >&2
        show_services_status
        _item "1" "重启所有服务"
        _item "2" "停止所有服务"
        _item "3" "启动所有服务"
        _item "4" "重建 Sing-box 配置"
        _item "5" "校验 Sing-box 配置"
        echo -e "  ${D}───────────────────────────────────────────${NC}" >&2
        _item "6" "备份配置 ${D}(重装系统前导出)${NC}"
        _item "7" "从备份恢复 ${D}(重装系统后导入)${NC}"
        _item "8" "修改 REALITY / ShadowTLS 伪装域名 ${D}(保留密钥不变)${NC}"
        _item "9" "TCP Fast Open 开关 ${D}(默认关闭，可选)${NC}"
        _item "f" "防火墙足迹 / 托管开关 ${D}(查看脚本写了什么)${NC}"
        _item "0" "返回"
        _line
        local ch; read -rp "  请选择: " ch
        case "$ch" in
            1) restart_all_services && _ok "所有服务已重启"; _pause ;;
            2) stop_services; touch "$CFG/paused"; _ok "所有服务已停止"; _pause ;;
            3) start_services && _ok "所有服务已启动"; _pause ;;
            4) generate_singbox_config && reload_config && _refresh_subscription_files; _pause ;;
            5)
                if [[ -f "$SB_CONFIG" ]]; then
                    "$SB_BIN" check -c "$SB_CONFIG" && _ok "配置校验通过" || _err "配置校验失败"
                else
                    _warn "配置文件不存在"
                fi
                _pause ;;
            6)
                local bp; read -rp "  输出路径 [回车用默认 /root/songbox-backup-*.tar.gz]: " bp
                do_backup "$bp"; _pause ;;
            7) do_restore ""; _pause ;;
            8) manage_handshake_sni; _pause ;;
            9) manage_tfo ;;
            f|F) toggle_firewall_management; _pause ;;
            0) return ;;
            *) _err "无效选择"; sleep 1 ;;
        esac
    done
}

# 修改 REALITY / ShadowTLS 的伪装域名：只改 sni，密钥 / UUID / 端口全部保留
manage_handshake_sni() {
    local hs_protos="vless-reality ss2022-shadowtls snell-shadowtls snell-v5-shadowtls"
    local list=() p q
    for p in $(db_all_protocols); do
        for q in $hs_protos; do [[ "$p" == "$q" ]] && { list+=("$p"); break; }; done
    done
    if [[ ${#list[@]} -eq 0 ]]; then
        _warn "没有安装使用伪装域名的协议 (REALITY / ShadowTLS)"; return
    fi
    _header
    echo -e "  ${W}修改伪装域名${NC}" >&2
    echo -e "  ${D}伪装域名是借用的第三方网站，与本机证书无关；改动后客户端的${NC}" >&2
    echo -e "  ${D}SNI / servername 必须同步改成一样的值，否则连不上${NC}" >&2
    _line
    local i=1 core cur
    for p in "${list[@]}"; do
        core=$(proto_core "$p")
        cur=$(_db_q --arg c "$core" --arg p "$p" '[(.[$c][$p] // [])[] | "\(.port)=\(.sni // "-")"] | join("  ")')
        _item "$i" "$(get_protocol_name "$p") ${D}${cur}${NC}"
        ((i++))
    done
    _item "0" "返回"
    _line
    local ch; read -rp "  请选择: " ch
    [[ "$ch" == "0" || -z "$ch" ]] && return
    [[ "$ch" =~ ^[0-9]+$ ]] && (( ch >= 1 && ch <= ${#list[@]} )) || { _err "无效选择"; return; }
    local proto="${list[$((ch-1))]}" newsni
    core=$(proto_core "$proto")

    if [[ "$proto" == "vless-reality" ]]; then
        select_handshake_target || return
        echo "" >&2
        _ask_yes "把 REALITY 伪装域名改为 ${HS_SNI} (握手目标 ${HS_HOST}:${HS_PORT})?" || return
        db_set_inst_field "$core" "$proto" all sni "$HS_SNI"
        db_set_inst_field "$core" "$proto" all handshake_host "$HS_HOST"
        db_set_inst_field "$core" "$proto" all handshake_port "$HS_PORT"
        newsni="$HS_SNI"
    else
        newsni=$(_ask_sni) || return
        [[ -z "$newsni" ]] && return
        echo "" >&2
        _ask_yes "把 $(get_protocol_name "$proto") 的伪装域名改为 ${newsni}?" || return
        db_set_inst_field "$core" "$proto" all sni "$newsni"
    fi
    if [[ "$core" == "snell" ]]; then
        # ShadowTLS 前置是独立进程，需要重建服务单元
        restart_all_services >/dev/null 2>&1
    else
        reload_config
    fi
    _refresh_subscription_files
    _ok "已改为 ${newsni}"
    _warn "请重新导出分享链接给客户端，或让客户端刷新订阅"
    show_single_protocol_info "$proto" false ""
}

show_logs() {
    _header
    echo -e "  ${W}运行日志${NC}" >&2
    _line
    _item "1" "脚本日志 (最近 50 行)"
    _item "2" "Sing-box 服务日志"
    _item "3" "Snell 服务日志"
    _item "4" "Watchdog 日志"
    _item "5" "实时跟踪 Sing-box 日志"
    _item "0" "返回"
    _line
    local ch; read -rp "  请选择: " ch
    case "$ch" in
        1) _line; [[ -f "$LOG_FILE" ]] && tail -n 50 "$LOG_FILE" >&2 || _warn "日志不存在"; _pause ;;
        2)
            _line
            if [[ "$DISTRO" == "alpine" ]]; then
                grep -i "sing-box" /var/log/messages 2>/dev/null | tail -50 >&2 || _warn "无日志"
            else
                journalctl -u "$SB_SVC" --no-pager -n 50 >&2 2>/dev/null || _warn "无日志"
            fi
            _pause ;;
        3)
            _line
            local p
            for p in $(get_snell_protocols); do
                echo -e "  ${C}[vless-${p}]${NC}" >&2
                if [[ "$DISTRO" == "alpine" ]]; then
                    grep -i "snell" /var/log/messages 2>/dev/null | tail -20 >&2
                else
                    journalctl -u "vless-${p}" --no-pager -n 20 >&2 2>/dev/null
                fi
            done
            _pause ;;
        4) _line; [[ -f /var/log/vless-watchdog.log ]] && tail -50 /var/log/vless-watchdog.log >&2 || _warn "无日志"; _pause ;;
        5)
            if [[ "$DISTRO" == "alpine" ]]; then tail -f /var/log/messages
            else journalctl -u "$SB_SVC" -f; fi ;;
        0|"") return ;;
        *) _err "无效选择" ;;
    esac
}

#═══════════════════════════════════════════════════════════════════════════════
# 内核版本管理
#═══════════════════════════════════════════════════════════════════════════════
_singbox_service_file() {
    if [[ -n "${SONGBOX_SB_SERVICE_FILE:-}" ]]; then
        echo "$SONGBOX_SB_SERVICE_FILE"
    elif [[ "$DISTRO" == "alpine" ]]; then
        echo "/etc/init.d/${SB_SVC}"
    else
        echo "/etc/systemd/system/${SB_SVC}.service"
    fi
}

_atomic_install_file() {  # _atomic_install_file <source> <destination> <mode>
    local source="$1" destination="$2" mode="$3" stage
    mkdir -p "$(dirname "$destination")" || return 1
    stage="${destination}.songbox-new.$$"
    install -m "$mode" "$source" "$stage" || { rm -f "$stage"; return 1; }
    mv -f "$stage" "$destination" || { rm -f "$stage"; return 1; }
}

_singbox_runtime_healthy() {  # _singbox_runtime_healthy [config]
    local config="${1:-$SB_CONFIG}" attempt port ports_ok
    for attempt in 1 2 3 4 5; do
        if svc status "$SB_SVC" >/dev/null 2>&1; then
            ports_ok=true
            while IFS= read -r port; do
                [[ -n "$port" ]] || continue
                _port_listening "$port" || { ports_ok=false; break; }
            done < <(jq -r '[.inbounds[]?.listen_port // empty] | unique[]' "$config" 2>/dev/null)
            [[ "$ports_ok" == "true" ]] && return 0
        fi
        sleep 1
    done
    return 1
}

_rollback_singbox_upgrade() {  # <txn_dir> <had_bin> <had_config> <had_service> <was_running>
    local txn="$1" had_bin="$2" had_config="$3" had_service="$4" was_running="$5"
    local service_file; service_file=$(_singbox_service_file)
    svc stop "$SB_SVC" >/dev/null 2>&1 || true

    if [[ "$had_bin" == "true" ]]; then
        _atomic_install_file "$txn/old-bin" "$SB_BIN" 755 || _err "旧 Sing-box 核心恢复失败"
    else
        rm -f "$SB_BIN"
    fi
    if [[ "$had_config" == "true" ]]; then
        _atomic_install_file "$txn/old-config" "$SB_CONFIG" 600 || _err "旧 Sing-box 配置恢复失败"
    else
        rm -f "$SB_CONFIG"
    fi
    if [[ "$had_service" == "true" ]]; then
        cp -a "$txn/old-service" "$service_file" || _err "旧 Sing-box 服务单元恢复失败"
    else
        rm -f "$service_file"
    fi
    [[ "$DISTRO" != "alpine" ]] && systemctl daemon-reload >/dev/null 2>&1 || true

    if [[ "$was_running" == "true" ]]; then
        if svc start "$SB_SVC" >/dev/null 2>&1 && _singbox_runtime_healthy "$SB_CONFIG"; then
            _ok "已恢复旧版 Sing-box 并重新启动服务"
        else
            _err "旧版 Sing-box 已恢复，但服务未能重新启动，请立即检查日志"
        fi
    fi
}

upgrade_singbox_transactional() {  # upgrade_singbox_transactional [version]
    local requested="${1:-}" target current txn candidate candidate_config=""
    local had_bin=false had_config=false had_service=false was_running=false service_file
    target=$(_resolve_singbox_version "$requested") || return 1
    current=$(_sb_version)
    if [[ -n "$current" && "$current" == "$target" ]]; then
        _ok "Sing-box 已是 v${target}，无需重复安装"
        return 0
    fi

    txn=$(mktemp -d) || { _err "无法创建 Sing-box 升级暂存目录"; return 1; }
    candidate="$txn/sing-box"
    _info "下载并预检 Sing-box v${target}..."
    _download_singbox_binary "$target" "$candidate" || { rm -rf "$txn"; return 1; }

    if [[ -n "$(get_singbox_protocols)" ]]; then
        candidate_config="$txn/singbox.json"
        if ! SONGBOX_SB_VERSION_OVERRIDE="$target" SONGBOX_SB_CHECK_BIN="$candidate" \
             generate_singbox_config "$candidate_config"; then
            rm -rf "$txn"
            _err "新核心无法通过现有协议配置预检，未替换当前版本"
            return 1
        fi
    elif [[ -s "$SB_CONFIG" ]]; then
        candidate_config="$txn/singbox.json"
        cp -a "$SB_CONFIG" "$candidate_config" || { rm -rf "$txn"; return 1; }
        if ! "$candidate" check -c "$candidate_config" >/dev/null 2>&1; then
            rm -rf "$txn"
            _err "新核心无法通过现有配置预检，未替换当前版本"
            return 1
        fi
    fi

    if [[ -e "$SB_BIN" ]]; then cp -a "$SB_BIN" "$txn/old-bin" || { rm -rf "$txn"; return 1; }; had_bin=true; fi
    if [[ -e "$SB_CONFIG" ]]; then cp -a "$SB_CONFIG" "$txn/old-config" || { rm -rf "$txn"; return 1; }; had_config=true; fi
    service_file=$(_singbox_service_file)
    if [[ -e "$service_file" ]]; then cp -a "$service_file" "$txn/old-service" || { rm -rf "$txn"; return 1; }; had_service=true; fi
    svc status "$SB_SVC" >/dev/null 2>&1 && was_running=true
    if [[ "$was_running" == "true" ]] && ! svc stop "$SB_SVC" >/dev/null 2>&1; then
        rm -rf "$txn"
        _err "无法停止当前 Sing-box 服务，未执行升级"
        return 1
    fi

    if ! _atomic_install_file "$candidate" "$SB_BIN" 755 ||
       { [[ -n "$candidate_config" ]] && ! _atomic_install_file "$candidate_config" "$SB_CONFIG" 600; }; then
        _err "切换 Sing-box 核心或配置失败，正在回滚"
        _rollback_singbox_upgrade "$txn" "$had_bin" "$had_config" "$had_service" "$was_running"
        rm -rf "$txn"
        return 1
    fi

    if [[ -n "$candidate_config" ]] && ! create_singbox_service; then
        _err "重建 Sing-box 服务单元失败，正在回滚"
        _rollback_singbox_upgrade "$txn" "$had_bin" "$had_config" "$had_service" "$was_running"
        rm -rf "$txn"
        return 1
    fi
    if [[ "$(_sb_version)" != "$target" ]]; then
        _err "新核心版本复核失败，正在回滚"
        _rollback_singbox_upgrade "$txn" "$had_bin" "$had_config" "$had_service" "$was_running"
        rm -rf "$txn"
        return 1
    fi

    if [[ "$was_running" == "true" ]]; then
        if ! svc start "$SB_SVC" >/dev/null 2>&1 || ! _singbox_runtime_healthy "$SB_CONFIG"; then
            _err "新核心启动或端口验证失败，正在回滚"
            _rollback_singbox_upgrade "$txn" "$had_bin" "$had_config" "$had_service" "$was_running"
            rm -rf "$txn"
            return 1
        fi
    fi
    rm -rf "$txn"
    _ok "Sing-box 已安全更新到 v${target}"
    return 0
}

update_core_menu() {
    while true; do
        _header
        echo -e "  ${W}内核版本管理${NC}" >&2
        _line
        local sbv
        sbv=$(_sb_version); [[ -z "$sbv" ]] && sbv="未安装"
        echo -e "  ${W}Sing-box${NC}      当前: ${G}${sbv}${NC}" >&2
        local s4c s5c s6c s4r s5r s6r
        s4c=$(_snell_installed_version snell-server);    s4c="${s4c:-未安装}"
        s5c=$(_snell_installed_version snell-server-v5); s5c="${s5c:-未安装}"
        s6c=$(_snell_installed_version snell-server-v6); s6c="${s6c:-未安装}"
        # 先在父 shell 里抓一次发布说明，下面三个命令替换才能共用同一份缓存
        _snell_fetch_release_page
        s4r=$(_snell_version 4 quiet); s5r=$(_snell_version 5 quiet); s6r=$(_snell_version 6 quiet)
        echo -e "  ${W}Snell v4${NC}      当前: ${G}${s4c}${NC}   最新: ${C}${s4r:-查询失败}${NC}" >&2
        echo -e "  ${W}Snell v5${NC}      当前: ${G}${s5c}${NC}   最新: ${C}${s5r:-查询失败}${NC}" >&2
        echo -e "  ${W}Snell v6${NC}      当前: ${G}${s6c}${NC}   最新: ${C}${s6r:-本架构无构建}${NC} ${D}(Beta)${NC}" >&2
        _line
        _item "1" "更新 Sing-box 到最新版"
        _item "2" "安装 Sing-box 指定版本"
        _item "3" "更新 / 安装 Snell v4"
        _item "4" "更新 / 安装 Snell v5"
        _item "5" "更新 / 安装 Snell v6"
        _item "0" "返回"
        _line
        local ch; read -rp "  请选择: " ch
        case "$ch" in
            1)
                _ask_yes "确认更新 Sing-box？更新期间服务会短暂中断" || { _pause; continue; }
                if upgrade_singbox_transactional; then
                    _refresh_subscription_files
                    _ok "Sing-box 更新完成"
                else
                    _err "更新失败，当前核心与服务已尽量保持原状"
                fi
                _pause ;;
            2)
                local v; read -rp "  请输入版本号 (如 1.12.0): " v
                [[ -z "$v" ]] && { _pause; continue; }
                upgrade_singbox_transactional "$v" && {
                    _refresh_subscription_files
                }
                _pause ;;
            3) rm -f /usr/local/bin/snell-server; install_snell; restart_all_services >/dev/null; _refresh_subscription_files; _pause ;;
            4) rm -f /usr/local/bin/snell-server-v5; install_snell_v5; restart_all_services >/dev/null; _refresh_subscription_files; _pause ;;
            5) rm -f /usr/local/bin/snell-server-v6; install_snell_v6; restart_all_services >/dev/null; _refresh_subscription_files; _pause ;;
            0) return ;;
            *) _err "无效选择"; sleep 1 ;;
        esac
    done
}

#═══════════════════════════════════════════════════════════════════════════════
# 脚本更新 / 完全卸载
#═══════════════════════════════════════════════════════════════════════════════
# 从 GitHub 拉取最新脚本并对比版本
# 依赖 SCRIPT_RAW_URL（raw.githubusercontent.com），可用镜像回退
_raw_mirrors() {
    local u="$1"
    echo "$u"
    [[ "$u" != https://raw.githubusercontent.com/* ]] && return 0
    [[ "${ALLOW_THIRD_PARTY_MIRRORS:-0}" == "1" ]] || return 0

    # gh-proxy 直接前缀即可
    echo "https://gh-proxy.com/${u}"

    # jsdelivr 需要 owner/repo@branch/path 的形式，逐段解析而不是正则替换
    local rest owner repo branch path
    rest="${u#https://raw.githubusercontent.com/}"
    owner="${rest%%/*}"; rest="${rest#*/}"
    repo="${rest%%/*}";  rest="${rest#*/}"
    [[ "$rest" == refs/heads/* ]] && rest="${rest#refs/heads/}"
    branch="${rest%%/*}"; path="${rest#*/}"
    if [[ -n "$owner" && -n "$repo" && -n "$branch" && -n "$path" && "$path" != "$branch" ]]; then
        echo "https://cdn.jsdelivr.net/gh/${owner}/${repo}@${branch}/${path}"
    fi
}

_script_source_urls() {
    _raw_mirrors "$SCRIPT_RAW_URL"
    if [[ -z "${SONGBOX_SCRIPT_RAW_URL:-}" && -z "${VLESS_SCRIPT_RAW_URL:-}" && \
          "$SCRIPT_RAW_URL" != "$LEGACY_SCRIPT_RAW_URL" ]]; then
        _raw_mirrors "$LEGACY_SCRIPT_RAW_URL"
    fi
}

# 从 GitHub API 取仓库最近一次提交信息（失败静默）
_github_last_commit() {
    local repo="$1"
    [[ -z "$repo" ]] && return 1
    local api="https://api.github.com/repos/${repo}/commits?per_page=1"
    local out; out=$(curl -fsSL --connect-timeout 8 --max-time 15 "$api" 2>/dev/null) || return 1
    local msg date
    msg=$(echo "$out" | jq -r '.[0].commit.message // empty' 2>/dev/null | head -1)
    date=$(echo "$out" | jq -r '.[0].commit.committer.date // empty' 2>/dev/null)
    [[ -z "$msg" && -z "$date" ]] && return 1
    printf '%s|%s\n' "$date" "$msg"
}

# 从 REPO_URL 推出 owner/repo
_github_repo_slug() {
    [[ -z "$REPO_URL" ]] && return 1
    echo "$REPO_URL" | sed -n 's|^https\?://github.com/\([^/]*\)/\([^/]*\)/*.*$|\1/\2|p'
}

do_update() {
    _header
    echo -e "  ${W}检查脚本更新${NC} ${D}(来源: GitHub)${NC}" >&2
    _line
    echo -e "  当前版本: ${G}v${VERSION}${NC}" >&2
    [[ -n "$REPO_URL" ]] && echo -e "  仓库    : ${D}${REPO_URL}${NC}" >&2
    echo -e "  构建    : ${Y}${CUSTOM_BUILD}${NC}" >&2

    if [[ -z "$SCRIPT_RAW_URL" ]]; then
        _line
        _warn "更新地址未配置"
        echo -e "  ${D}在脚本头部填写 SCRIPT_RAW_URL，或临时用环境变量:${NC}" >&2
        echo -e "  ${C}VLESS_SCRIPT_RAW_URL=<raw地址> vless${NC}" >&2
        _line
        return 0
    fi

    check_cmd curl || { _err "缺少 curl"; return 1; }

    # 顺带展示最近一次提交，方便判断是否值得更新
    local slug ci
    slug=$(_github_repo_slug) && ci=$(_github_last_commit "$slug") && {
        echo -e "  最新提交: ${C}${ci%%|*}${NC}" >&2
        echo -e "            ${D}${ci#*|}${NC}" >&2
    }
    _line

    local tmp url fetched_url="" got=false
    tmp=$(mktemp) || return 1
    while IFS= read -r url; do
        [[ -z "$url" ]] && continue
        _info "拉取: ${url}"
        if curl -fsSL --connect-timeout 10 --max-time 60 -o "$tmp" "$url" 2>/dev/null &&
           [[ -s "$tmp" ]] && head -1 "$tmp" | grep -q '^#!.*bash'; then
            got=true; fetched_url="$url"; break
        fi
        _warn "该地址不可用，尝试下一个"
    done < <(_script_source_urls)

    if [[ "$got" != "true" ]]; then
        rm -f "$tmp"
        _err "下载失败：新旧 GitHub 仓库地址均不可达"
        [[ "${ALLOW_THIRD_PARTY_MIRRORS:-0}" != "1" ]] &&
            echo -e "  ${D}如确认镜像可信，可设置 ALLOW_THIRD_PARTY_MIRRORS=1 后重试${NC}" >&2
        echo -e "  ${D}可稍后重试，或手动下载到 $SYSTEM_SCRIPT${NC}" >&2
        return 1
    fi

    # 语法校验 + 版本提取，避免把坏脚本写进系统
    if ! bash -n "$tmp" 2>/dev/null; then
        rm -f "$tmp"; _err "下载的脚本语法校验失败，已放弃更新"; return 1
    fi
    if ! grep -qx 'readonly AUTHOR="NeverF1ower"' "$tmp" ||
       ! grep -qE '^readonly SCRIPT_NAME="(songbox|SingBox 万能工具箱)"$' "$tmp"; then
        rm -f "$tmp"; _err "下载文件的作者或脚本标识不匹配，已拒绝更新"; return 1
    fi
    local expected_script_sha="${SONGBOX_SCRIPT_SHA256:-${VLESS_SCRIPT_SHA256:-}}"
    if [[ -n "$expected_script_sha" ]] && ! _verify_sha256 "$tmp" "$expected_script_sha"; then
        rm -f "$tmp"; _err "下载脚本与 SONGBOX_SCRIPT_SHA256 / VLESS_SCRIPT_SHA256 不匹配"; return 1
    fi
    if [[ "$fetched_url" != "$SCRIPT_RAW_URL" ]]; then
        _warn "使用了兼容或镜像地址；未提供脚本 SHA-256 时请确认来源"
    fi
    local remote; remote=$(grep -m1 '^readonly VERSION=' "$tmp" | cut -d'"' -f2)
    if [[ -z "$remote" ]]; then
        rm -f "$tmp"; _err "无法识别远程版本号（文件可能不是本脚本）"; return 1
    fi
    echo -e "  远程版本: ${C}v${remote}${NC}" >&2

    if [[ "$remote" == "$VERSION" ]]; then
        # 版本号相同也可能有改动，用内容比对兜底
        local self; self=$(readlink -f "$0")
        if [[ -f "$self" ]] && cmp -s "$tmp" "$self"; then
            rm -f "$tmp"; _ok "已是最新版本，无需更新"; return 0
        fi
        _warn "版本号相同但文件内容有差异（作者可能未提版本号）"
        _ask_yes "仍要覆盖为远程版本?" || { rm -f "$tmp"; return 0; }
    elif _version_ge "$VERSION" "$remote" && [[ "${ALLOW_SCRIPT_DOWNGRADE:-0}" != "1" ]]; then
        rm -f "$tmp"
        _err "远程版本 v${remote} 旧于当前 v${VERSION}，已阻止降级"
        echo -e "  ${D}确需降级时可设置 ALLOW_SCRIPT_DOWNGRADE=1${NC}" >&2
        return 1
    else
        _ask_yes "更新到 v${remote}?" || { rm -f "$tmp"; return 0; }
    fi

    local self; self=$(readlink -f "$0")
    cp "$self" "${self}.bak" 2>/dev/null
    if install -m 755 "$tmp" "$SYSTEM_SCRIPT"; then
        if [[ "$self" != "$SYSTEM_SCRIPT" && "$self" != "$LEGACY_SYSTEM_SCRIPT" ]]; then
            install -m 755 "$tmp" "$self" 2>/dev/null || _warn "当前启动文件未覆盖，但系统脚本已更新"
        fi
        _install_script_links "$SYSTEM_SCRIPT" || {
            rm -f "$tmp"; _err "新脚本已写入，但兼容快捷链接创建失败"; return 1; }
        rm -f "$tmp"
        _dline
        _ok "更新完成: v${VERSION} → v${remote}"
        echo -e "  ${C}请重新执行 vless 进入新版本${NC}" >&2
        echo -e "  ${D}规范路径: $SYSTEM_SCRIPT；旧路径与 vless 快捷命令继续有效；旧版备份: ${self}.bak${NC}" >&2
        _dline
        exit 0
    fi
    rm -f "$tmp"; _err "写入失败（权限不足?）"; return 1
}

#═══════════════════════════════════════════════════════════════════════════════
# Realm TCP / UDP 端口转发（官方 Realm 内核，兼容 systemd / OpenRC）
#═══════════════════════════════════════════════════════════════════════════════
_realm_version() {
    [[ -x "$REALM_BIN" ]] || return 1
    "$REALM_BIN" --version 2>/dev/null | head -1 |
        grep -oE '[0-9]+\.[0-9]+\.[0-9]+([-.a-zA-Z0-9]*)?' | head -1
}

_realm_libc() {
    if [[ "$DISTRO" == "alpine" ]] ||
       ls /lib/ld-musl-*.so.1 >/dev/null 2>&1 ||
       (check_cmd ldd && ldd --version 2>&1 | grep -qi musl); then
        echo "musl"
    else
        echo "gnu"
    fi
}

_realm_target() {
    local libc; libc=$(_realm_libc)
    case "$(uname -m)" in
        x86_64|amd64)  echo "x86_64-unknown-linux-${libc}" ;;
        aarch64|arm64) echo "aarch64-unknown-linux-${libc}" ;;
        armv7l)        echo "armv7-unknown-linux-${libc}eabihf" ;;
        armv6l|arm)    echo "arm-unknown-linux-${libc}eabihf" ;;
        *) return 1 ;;
    esac
}

_realm_ensure_dependencies() {
    local missing=() cmd
    for cmd in curl jq tar install; do check_cmd "$cmd" || missing+=("$cmd"); done
    [[ ${#missing[@]} -eq 0 ]] && return 0
    _info "安装 Realm 所需依赖: ${missing[*]}"
    if check_cmd apk; then
        apk add --no-cache curl jq ca-certificates tar coreutils >/dev/null 2>&1
    elif check_cmd apt-get; then
        apt-get update >/dev/null 2>&1 &&
            DEBIAN_FRONTEND=noninteractive apt-get install -y curl jq ca-certificates tar coreutils >/dev/null 2>&1
    elif check_cmd yum; then
        yum install -y curl jq ca-certificates tar coreutils >/dev/null 2>&1
    else
        _err "无法识别包管理器，请手动安装: curl jq tar ca-certificates"
        return 1
    fi
    for cmd in curl jq tar install; do
        check_cmd "$cmd" || { _err "依赖安装失败: $cmd"; return 1; }
    done
}

_realm_init_config() {
    mkdir -p "$REALM_DIR" || { _err "无法创建 $REALM_DIR"; return 1; }
    chmod 700 "$REALM_DIR" 2>/dev/null || true
    if [[ ! -s "$REALM_CONF" ]]; then
        cat >"$REALM_CONF" <<'EOFREALM'
[network]
no_tcp = false
use_udp = true
ipv6_only = false
EOFREALM
        chmod 600 "$REALM_CONF"
        _ok "已创建 Realm 配置: $REALM_CONF"
    else
        chmod 600 "$REALM_CONF" 2>/dev/null || true
    fi
}

create_realm_service() {
    [[ -x "$REALM_BIN" ]] || { _err "Realm 核心不存在: $REALM_BIN"; return 1; }
    [[ -s "$REALM_CONF" ]] || _realm_init_config || return 1
    if [[ "$DISTRO" == "alpine" ]]; then
        _write_openrc "$REALM_SVC" "Realm TCP/UDP Relay" "$REALM_BIN" "-c $REALM_CONF" "" "0"
        cat >>"/etc/init.d/$REALM_SVC" <<EOF
output_log="/var/log/$REALM_SVC.log"
error_log="/var/log/$REALM_SVC.log"
EOF
        chmod 755 "/etc/init.d/$REALM_SVC"
    else
        _write_systemd "$REALM_SVC" "Realm TCP/UDP Relay" "$REALM_BIN -c $REALM_CONF"
    fi
}

install_realm_core() {
    local force="${1:-false}" ver_override="${2:-}"
    if [[ -x "$REALM_BIN" && "$force" != "true" ]]; then
        _realm_init_config || return 1
        create_realm_service || return 1
        _ok "Realm 已安装 (v$(_realm_version 2>/dev/null || echo 未知))"
        return 0
    fi

    _realm_ensure_dependencies || return 1
    local target; target=$(_realm_target) || {
        _err "Realm 暂不支持此架构: $(uname -m)"
        return 1
    }
    local tag="$ver_override"
    if [[ -z "$tag" ]]; then
        _info "查询 Realm 官方最新版本..."
        tag=$(_gh_latest_tag "$REALM_REPO")
    fi
    [[ -n "$tag" ]] || { _err "无法取得 Realm 最新版本"; return 1; }
    [[ "$tag" == v* ]] || tag="v$tag"

    local asset="realm-${target}.tar.gz"
    local url="https://github.com/$REALM_REPO/releases/download/$tag/$asset"
    local tmp archive expected candidate newbin was_running=false
    tmp=$(mktemp -d) || return 1
    archive="$tmp/$asset"
    _info "系统匹配: $DISTRO / $(uname -m) / $(_realm_libc)"
    _info "下载 Realm $tag: $asset"
    if ! curl -fL --retry 2 --connect-timeout 10 --max-time 180 -o "$archive" "$url"; then
        rm -rf "$tmp"; _err "Realm 下载失败: $url"; return 1
    fi

    expected=$(_gh_asset_sha256 "$REALM_REPO" "$tag" "$asset" 2>/dev/null || true)
    if [[ -n "$expected" ]]; then
        if ! _verify_sha256 "$archive" "$expected"; then
            rm -rf "$tmp"; _err "Realm SHA-256 校验失败，已拒绝安装"; return 1
        fi
        _ok "Realm SHA-256 校验通过"
    else
        _confirm_unverified "Realm $tag / $asset" || { rm -rf "$tmp"; return 1; }
    fi

    _archive_safe "$archive" "tar.gz" || {
        rm -rf "$tmp"; _err "Realm 压缩包路径校验失败"; return 1; }
    mkdir -p "$tmp/extract"
    tar -xzf "$archive" -C "$tmp/extract" 2>/dev/null || {
        rm -rf "$tmp"; _err "Realm 解包失败"; return 1; }
    candidate=$(find "$tmp/extract" -type f -name realm -print -quit 2>/dev/null)
    [[ -f "$candidate" ]] || { rm -rf "$tmp"; _err "压缩包中未找到 realm"; return 1; }
    chmod 755 "$candidate"
    "$candidate" --version >/dev/null 2>&1 || {
        rm -rf "$tmp"; _err "下载的 Realm 核心无法在本系统运行（资产: $asset）"; return 1; }

    svc status "$REALM_SVC" >/dev/null 2>&1 && was_running=true
    mkdir -p "$REALM_DIR"; chmod 700 "$REALM_DIR" 2>/dev/null || true
    newbin="$REALM_DIR/.realm.new"
    install -m 755 "$candidate" "$newbin" &&
        mv -f "$newbin" "$REALM_BIN" || {
            rm -f "$newbin"; rm -rf "$tmp"; _err "写入 Realm 核心失败"; return 1; }
    printf '%s\n' "$tag" >"$REALM_VERSION_FILE"
    chmod 600 "$REALM_VERSION_FILE"
    rm -rf "$tmp"

    _realm_init_config || return 1
    create_realm_service || return 1
    if [[ "$was_running" == "true" ]]; then
        svc restart "$REALM_SVC" >/dev/null 2>&1 || {
            _err "Realm 核心已更新，但服务重启失败"; return 1; }
    fi
    _ok "Realm $tag 安装完成 ($target)"
}

_realm_rule_count() {
    [[ -f "$REALM_CONF" ]] || { echo 0; return; }
    local n
    n=$(grep -c '^[[:space:]]*\[\[endpoints\]\][[:space:]]*$' "$REALM_CONF" 2>/dev/null || true)
    echo "${n:-0}"
}

_realm_rules_tsv() {
    [[ -f "$REALM_CONF" ]] || return 0
    awk '
        function value(line, x) {
            x=line
            sub(/^[^"]*"/, "", x)
            sub(/".*$/, "", x)
            return x
        }
        function flush() {
            if (!inside) return
            gsub(/\t/, " ", remark)
            print idx "\t" listen "\t" remote "\t" remark
        }
        /^[[:space:]]*\[\[endpoints\]\][[:space:]]*$/ {
            flush()
            inside=1; idx++; listen=""; remote=""; remark=""
            next
        }
        /^[[:space:]]*\[/ {
            if (inside) flush()
            inside=0
            next
        }
        inside && /^[[:space:]]*#[[:space:]]*备注[[:space:]]*:/ {
            remark=$0
            sub(/^[[:space:]]*#[[:space:]]*备注[[:space:]]*:[[:space:]]*/, "", remark)
            next
        }
        inside && /^[[:space:]]*listen[[:space:]]*=/ { listen=value($0); next }
        inside && /^[[:space:]]*remote[[:space:]]*=/ { remote=value($0); next }
        END { flush() }
    ' "$REALM_CONF"
}

_realm_listen_port() {
    local value="$1" port="${1##*:}"
    port="${port//[^0-9]/}"
    _is_valid_port "$port" && echo "$port"
}

_realm_format_addr() {
    local host="$1" port="$2"
    host="${host#[}"; host="${host%]}"
    if [[ "$host" == *:* ]]; then printf '[%s]:%s' "$host" "$port"
    else printf '%s:%s' "$host" "$port"; fi
}

_realm_default_listen() {
    local port="$1"
    if [[ -s /proc/net/if_inet6 ]] &&
       [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0)" != "1" ]]; then
        echo "[::]:$port"
    else
        echo "0.0.0.0:$port"
    fi
}

_realm_parse_remote() {
    local value="$1"
    REALM_PARSE_HOST=""; REALM_PARSE_PORT=""
    if [[ "$value" =~ ^\[([^][]+)\]:([0-9]+)$ ]]; then
        REALM_PARSE_HOST="${BASH_REMATCH[1]}"; REALM_PARSE_PORT="${BASH_REMATCH[2]}"
    elif [[ "$value" =~ ^([^:]+):([0-9]+)$ ]]; then
        REALM_PARSE_HOST="${BASH_REMATCH[1]}"; REALM_PARSE_PORT="${BASH_REMATCH[2]}"
    else
        return 1
    fi
    _is_valid_host "$REALM_PARSE_HOST" && _is_valid_port "$REALM_PARSE_PORT"
}

_realm_safe_remark() {
    local v="$1"
    v="${v//$'\r'/ }"; v="${v//$'\n'/ }"; v="${v//$'\t'/ }"
    v="${v//\\/}"; v="${v//|/／}"
    printf '%s' "$v"
}

_realm_port_in_config() {
    local wanted="$1" exclude="${2:-0}" idx listen remote remark port
    while IFS=$'\t' read -r idx listen remote remark; do
        [[ "$idx" == "$exclude" ]] && continue
        port=$(_realm_listen_port "$listen")
        [[ "$port" == "$wanted" ]] && return 0
    done < <(_realm_rules_tsv)
    return 1
}

_realm_append_rule() {
    local local_port="$1" remote_host="$2" remote_port="$3" remark="${4:-}"
    _is_valid_port "$local_port" || return 1
    _is_valid_host "$remote_host" || return 1
    _is_valid_port "$remote_port" || return 1
    remark=$(_realm_safe_remark "$remark")
    local listen remote
    listen=$(_realm_default_listen "$local_port")
    remote=$(_realm_format_addr "$remote_host" "$remote_port")
    printf '\n[[endpoints]]\n# 备注: %s\nlisten = "%s"\nremote = "%s"\n' \
        "$remark" "$listen" "$remote" >>"$REALM_CONF"
    chmod 600 "$REALM_CONF" 2>/dev/null || true
}

realm_show_rules() {
    local count; count=$(_realm_rule_count)
    if (( count == 0 )); then _warn "没有 Realm 转发规则"; return 1; fi
    _line
    printf '  %-4s %-8s %-34s %s\n' "序号" "本地端口" "远程地址" "备注" >&2
    _line
    local idx listen remote remark port
    while IFS=$'\t' read -r idx listen remote remark; do
        port=$(_realm_listen_port "$listen")
        printf '  %-4s %-8s %-34s %s\n' "$idx" "${port:--}" "${remote:--}" "${remark:--}" >&2
    done < <(_realm_rules_tsv)
    _line
    echo -e "  配置: ${C}$REALM_CONF${NC}" >&2
}

realm_show_logs() {
    _line
    if [[ "$DISTRO" == "alpine" ]]; then
        rc-service "$REALM_SVC" status 2>&1 | tail -20 >&2 || true
        if [[ -f "/var/log/$REALM_SVC.log" ]]; then
            echo -e "  ${D}最近日志:${NC}" >&2
            tail -n 80 "/var/log/$REALM_SVC.log" >&2
        else
            _info "暂无 /var/log/$REALM_SVC.log"
        fi
    else
        systemctl status "$REALM_SVC" --no-pager -l 2>&1 | tail -20 >&2 || true
        journalctl -u "$REALM_SVC" -n 80 --no-pager 2>/dev/null >&2 || true
    fi
    _line
}

realm_start_service() {
    [[ -x "$REALM_BIN" ]] || install_realm_core false || return 1
    _realm_init_config || return 1
    (( $(_realm_rule_count) > 0 )) || { _warn "请先添加至少一条转发规则"; return 1; }
    create_realm_service || return 1
    svc enable "$REALM_SVC" >/dev/null 2>&1 || true
    if svc status "$REALM_SVC" >/dev/null 2>&1; then
        svc restart "$REALM_SVC" >/dev/null 2>&1
    else
        svc start "$REALM_SVC" >/dev/null 2>&1
    fi
    sleep 1
    if svc status "$REALM_SVC" >/dev/null 2>&1; then
        _ok "Realm 服务运行中"
        return 0
    fi
    _err "Realm 服务启动失败"
    realm_show_logs
    return 1
}

realm_stop_service() {
    if svc status "$REALM_SVC" >/dev/null 2>&1; then
        svc stop "$REALM_SVC" >/dev/null 2>&1
        _ok "Realm 服务已停止"
    else
        _info "Realm 服务未运行"
    fi
}

realm_restart_service() {
    [[ -x "$REALM_BIN" && -s "$REALM_CONF" ]] || {
        _err "Realm 核心或配置不存在"; return 1; }
    (( $(_realm_rule_count) > 0 )) || { _warn "没有转发规则，不启动服务"; return 1; }
    create_realm_service || return 1
    svc enable "$REALM_SVC" >/dev/null 2>&1 || true
    svc restart "$REALM_SVC" >/dev/null 2>&1 || svc start "$REALM_SVC" >/dev/null 2>&1
    sleep 1
    if svc status "$REALM_SVC" >/dev/null 2>&1; then
        _ok "Realm 服务已重启"
        return 0
    fi
    _err "Realm 服务重启失败"
    realm_show_logs
    return 1
}

realm_add_rule() {
    [[ -x "$REALM_BIN" ]] || install_realm_core false || return 1
    _realm_init_config || return 1
    local local_port remote_host remote_port remark
    while true; do
        read -rp "  本地监听端口: " local_port
        _is_valid_port "$local_port" || { _err "端口必须是 1-65535"; continue; }
        _realm_port_in_config "$local_port" && { _err "Realm 已使用本地端口 $local_port"; continue; }
        if _port_listening "$local_port"; then
            _err "端口 $local_port 已被其它进程监听"; continue
        fi
        break
    done
    while true; do
        read -rp "  远程主机/IP: " remote_host
        remote_host="${remote_host#[}"; remote_host="${remote_host%]}"
        _is_valid_host "$remote_host" && break
        _err "远程主机无效"
    done
    while true; do
        read -rp "  远程端口: " remote_port
        _is_valid_port "$remote_port" && break
        _err "端口必须是 1-65535"
    done
    read -rp "  备注 [可留空]: " remark
    _realm_append_rule "$local_port" "$remote_host" "$remote_port" "$remark" || {
        _err "写入规则失败"; return 1; }
    allow_port "$local_port" tcp
    allow_port "$local_port" udp
    _ok "已添加: $(_realm_default_listen "$local_port") → $(_realm_format_addr "$remote_host" "$remote_port")"
    realm_start_service
}

realm_modify_rule() {
    local count; count=$(_realm_rule_count)
    (( count > 0 )) || { _warn "没有可修改的规则"; return 1; }
    realm_show_rules || return 1
    local pick; read -rp "  要修改的序号 [0 返回]: " pick
    [[ "$pick" == "0" || -z "$pick" ]] && return 0
    [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= count )) || {
        _err "无效序号"; return 1; }

    local idx listen remote remark old_port="" old_host="" old_remote_port=""
    while IFS=$'\t' read -r idx listen remote remark; do
        [[ "$idx" == "$pick" ]] || continue
        old_port=$(_realm_listen_port "$listen")
        _realm_parse_remote "$remote" && {
            old_host="$REALM_PARSE_HOST"; old_remote_port="$REALM_PARSE_PORT"; }
        break
    done < <(_realm_rules_tsv)
    [[ -n "$old_port" && -n "$old_host" ]] || {
        _err "无法解析该规则，请使用「手动编辑 config.toml」"; return 1; }

    local local_port remote_host remote_port new_remark
    while true; do
        read -rp "  本地端口 [$old_port]: " local_port
        local_port="${local_port:-$old_port}"
        _is_valid_port "$local_port" || { _err "端口无效"; continue; }
        _realm_port_in_config "$local_port" "$pick" && {
            _err "其它 Realm 规则已使用该端口"; continue; }
        if [[ "$local_port" != "$old_port" ]] && _port_listening "$local_port"; then
            _err "端口 $local_port 已被其它进程监听"; continue
        fi
        break
    done
    while true; do
        read -rp "  远程主机 [$old_host]: " remote_host
        remote_host="${remote_host:-$old_host}"
        remote_host="${remote_host#[}"; remote_host="${remote_host%]}"
        _is_valid_host "$remote_host" && break
        _err "远程主机无效"
    done
    while true; do
        read -rp "  远程端口 [$old_remote_port]: " remote_port
        remote_port="${remote_port:-$old_remote_port}"
        _is_valid_port "$remote_port" && break
        _err "远程端口无效"
    done
    read -rp "  备注 [${remark:-无}]: " new_remark
    new_remark="${new_remark:-$remark}"
    new_remark=$(_realm_safe_remark "$new_remark")

    local backup tmp
    backup="$REALM_CONF.bak.$(date '+%Y%m%d-%H%M%S')"
    cp -a "$REALM_CONF" "$backup"
    tmp=$(mktemp "$REALM_DIR/config.XXXXXX") || return 1
    local new_listen new_remote
    new_listen=$(_realm_default_listen "$local_port")
    new_remote=$(_realm_format_addr "$remote_host" "$remote_port")
    awk -v target="$pick" -v listen="$new_listen" -v remote="$new_remote" -v remark="$new_remark" '
        /^[[:space:]]*\[\[endpoints\]\][[:space:]]*$/ {
            idx++; selected=(idx == target)
            print
            if (selected) print "# 备注: " remark
            next
        }
        /^[[:space:]]*\[/ { selected=0 }
        selected && /^[[:space:]]*#[[:space:]]*备注[[:space:]]*:/ { next }
        selected && /^[[:space:]]*listen[[:space:]]*=/ {
            print "listen = \"" listen "\""; next
        }
        selected && /^[[:space:]]*remote[[:space:]]*=/ {
            print "remote = \"" remote "\""; next
        }
        { print }
    ' "$REALM_CONF" >"$tmp" && mv "$tmp" "$REALM_CONF" || {
        rm -f "$tmp"; _err "修改配置失败"; return 1; }
    chmod 600 "$REALM_CONF"
    allow_port "$local_port" tcp
    allow_port "$local_port" udp
    _ok "规则已修改（旧配置: $backup）"
    if svc status "$REALM_SVC" >/dev/null 2>&1; then realm_restart_service; fi
}

_realm_delete_endpoint() {
    local target="$1" tmp
    tmp=$(mktemp "$REALM_DIR/config.XXXXXX") || return 1
    awk -v target="$target" '
        /^[[:space:]]*\[\[endpoints\]\][[:space:]]*$/ {
            idx++; skip=(target == "all" || idx == target)
            if (!skip) print
            next
        }
        /^[[:space:]]*\[/ {
            if ($0 !~ /^[[:space:]]*\[\[endpoints\]\][[:space:]]*$/) skip=0
        }
        !skip { print }
    ' "$REALM_CONF" >"$tmp" && mv "$tmp" "$REALM_CONF" || {
        rm -f "$tmp"; return 1; }
    chmod 600 "$REALM_CONF"
}

realm_delete_rule() {
    local count; count=$(_realm_rule_count)
    (( count > 0 )) || { _warn "没有可删除的规则"; return 1; }
    realm_show_rules || return 1
    local pick label
    read -rp "  删除序号（a=全部，0=返回）: " pick
    [[ "$pick" == "0" || -z "$pick" ]] && return 0
    if [[ "$pick" != "a" && "$pick" != "A" ]]; then
        [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= count )) || {
            _err "无效序号"; return 1; }
        label="第 $pick 条规则"
    else
        pick="all"; label="全部规则"
    fi
    _ask_yes "确认删除$label?" || return 0
    local backup
    backup="$REALM_CONF.bak.$(date '+%Y%m%d-%H%M%S')"
    cp -a "$REALM_CONF" "$backup"
    _realm_delete_endpoint "$pick" || { _err "删除失败"; return 1; }
    _ok "已删除（旧配置: $backup）"
    if (( $(_realm_rule_count) == 0 )); then
        realm_stop_service
    elif svc status "$REALM_SVC" >/dev/null 2>&1; then
        realm_restart_service
    fi
}

realm_edit_config() {
    _realm_init_config || return 1
    local editor=""
    if [[ -n "${VISUAL:-}" ]] && check_cmd "$VISUAL"; then
        editor="$VISUAL"
    elif [[ -n "${EDITOR:-}" ]] && check_cmd "$EDITOR"; then
        editor="$EDITOR"
    else
        local e
        for e in nano vi vim; do check_cmd "$e" && { editor="$e"; break; }; done
    fi
    [[ -n "$editor" ]] || {
        _err "未找到文本编辑器，请安装 nano/vi，或设置 EDITOR"; return 1; }
    local backup
    backup="$REALM_CONF.bak.$(date '+%Y%m%d-%H%M%S')"
    cp -a "$REALM_CONF" "$backup"
    _info "使用 $editor 编辑 $REALM_CONF"
    "$editor" "$REALM_CONF"
    local rc=$?
    chmod 600 "$REALM_CONF" 2>/dev/null || true
    (( rc == 0 )) || {
        _warn "编辑器异常退出，原配置保留在 $backup"; return "$rc"; }
    _ok "配置已保存（编辑前备份: $backup）"
    echo -e "  ${D}Realm 没有独立的只读校验命令；重启结果就是实际配置校验。${NC}" >&2
    if svc status "$REALM_SVC" >/dev/null 2>&1 &&
       _ask_yes "立即重启 Realm 应用配置?"; then
        if ! realm_restart_service; then
            _warn "新配置未能启动"
            if _ask_yes "恢复编辑前配置并重启?"; then
                cp -a "$backup" "$REALM_CONF"
                realm_restart_service
            fi
        fi
    fi
}

realm_export_rules() {
    local count; count=$(_realm_rule_count)
    (( count > 0 )) || { _warn "没有可导出的规则"; return 1; }
    local out
    read -rp "  导出路径 [默认 /root/realm-rules-时间.txt]: " out
    out="${out:-/root/realm-rules-$(date '+%Y%m%d-%H%M%S').txt}"
    mkdir -p "$(dirname "$out")" 2>/dev/null || {
        _err "无法创建输出目录"; return 1; }
    {
        echo "# EZRealm 兼容格式: 序号|本地端口|远程IP:端口|备注"
        local idx listen remote remark port
        while IFS=$'\t' read -r idx listen remote remark; do
            port=$(_realm_listen_port "$listen")
            printf '%s|%s|%s|%s\n' "$idx" "$port" "$remote" "$remark"
        done < <(_realm_rules_tsv)
    } >"$out" || { _err "写入 $out 失败"; return 1; }
    chmod 600 "$out"
    _ok "已导出 $count 条规则: $out"
    echo -e "  ${D}文件格式与 EZRealm 的导入/导出格式兼容。${NC}" >&2
}

realm_import_rules() {
    [[ -x "$REALM_BIN" ]] || install_realm_core false || return 1
    _realm_init_config || return 1
    local src tmp own_tmp=false
    read -rp "  导入文件路径 [留空后粘贴，单独输入 END 结束]: " src
    if [[ -n "$src" ]]; then
        [[ -f "$src" ]] || { _err "文件不存在: $src"; return 1; }
        tmp="$src"
    else
        tmp=$(mktemp) || return 1
        own_tmp=true
        echo -e "  ${D}格式: 序号|本地端口|远程IP:端口|备注${NC}" >&2
        echo -e "  ${D}例如: 1|8080|192.0.2.10:80|web；粘贴后单独输入 END${NC}" >&2
        local line
        while IFS= read -r line; do
            [[ "$line" == "END" ]] && break
            printf '%s\n' "$line" >>"$tmp"
        done
    fi
    [[ -s "$tmp" ]] || {
        [[ "$own_tmp" == "true" ]] && rm -f "$tmp"
        _warn "没有输入规则"; return 1; }
    _ask_yes "确认追加导入（不会覆盖现有规则）?" || {
        [[ "$own_tmp" == "true" ]] && rm -f "$tmp"; return 0; }

    local raw_index local_port remote_addr remark extra
    local ok=0 skipped=0
    while IFS='|' read -r raw_index local_port remote_addr remark extra ||
          [[ -n "$raw_index" ]]; do
        raw_index="${raw_index//$'\r'/}"
        [[ "$raw_index" =~ ^[0-9]+$ ]] || continue
        _is_valid_port "$local_port" || { ((skipped++)); continue; }
        _realm_parse_remote "$remote_addr" || { ((skipped++)); continue; }
        _realm_port_in_config "$local_port" && { ((skipped++)); continue; }
        _port_listening "$local_port" && { ((skipped++)); continue; }
        _realm_append_rule "$local_port" "$REALM_PARSE_HOST" "$REALM_PARSE_PORT" "$remark" || {
            ((skipped++)); continue; }
        allow_port "$local_port" tcp
        allow_port "$local_port" udp
        ((ok++))
    done <"$tmp"
    [[ "$own_tmp" == "true" ]] && rm -f "$tmp"
    if (( ok == 0 )); then
        _err "没有导入有效规则（无效、重复或端口被占用: $skipped）"
        return 1
    fi
    _ok "成功导入 $ok 条规则；跳过 $skipped 条"
    realm_start_service
}

_realm_remove_cron() {
    check_cmd crontab || return 0
    local tmp; tmp=$(mktemp) || return 1
    crontab -l 2>/dev/null | grep -v '# vless-realm-restart$' >"$tmp" || true
    crontab "$tmp" 2>/dev/null
    rm -f "$tmp"
}

_realm_set_cron() {
    local expr="$1"
    check_cmd crontab || {
        if check_cmd apk; then
            apk add --no-cache cronie >/dev/null 2>&1 ||
                apk add --no-cache dcron >/dev/null 2>&1
            rc-service cronie start >/dev/null 2>&1 ||
                rc-service crond start >/dev/null 2>&1 || true
            rc-update add cronie default >/dev/null 2>&1 ||
                rc-update add crond default >/dev/null 2>&1 || true
        elif check_cmd apt-get; then
            apt-get update >/dev/null 2>&1 &&
                DEBIAN_FRONTEND=noninteractive apt-get install -y cron >/dev/null 2>&1
            systemctl enable --now cron >/dev/null 2>&1 || true
        elif check_cmd yum; then
            yum install -y cronie >/dev/null 2>&1
            systemctl enable --now crond >/dev/null 2>&1 || true
        fi
    }
    check_cmd crontab || { _err "crontab 不可用"; return 1; }
    create_shortcut >/dev/null 2>&1 || true
    local tmp; tmp=$(mktemp) || return 1
    crontab -l 2>/dev/null | grep -v '# vless-realm-restart$' >"$tmp" || true
    echo "$expr $SYSTEM_SCRIPT --realm-restart >/dev/null 2>&1 # vless-realm-restart" >>"$tmp"
    crontab "$tmp" || {
        rm -f "$tmp"; _err "写入 crontab 失败"; return 1; }
    rm -f "$tmp"
}

realm_schedule_menu() {
    _line
    echo -e "  ${W}Realm 定时重启${NC}" >&2
    local current state
    current=$(crontab -l 2>/dev/null | grep '# vless-realm-restart$' | head -1)
    if [[ -n "$current" ]]; then state="${G}$current${NC}"
    else state="${D}未设置${NC}"; fi
    echo -e "  当前: $state" >&2
    _line
    _item "1" "每 N 小时重启"
    _item "2" "每天固定小时重启"
    _item "3" "移除定时重启"
    _item "0" "返回"
    _line
    local ch n
    read -rp "  请选择: " ch
    case "$ch" in
        1)
            read -rp "  间隔小时 [1-23]: " n
            [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= 23 )) || {
                _err "小时无效"; return 1; }
            _realm_set_cron "0 */$n * * *" && _ok "已设置每 $n 小时重启 Realm" ;;
        2)
            read -rp "  每天几点 [0-23]: " n
            [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 0 && n <= 23 )) || {
                _err "小时无效"; return 1; }
            _realm_set_cron "0 $n * * *" && _ok "已设置每天 $n:00 重启 Realm" ;;
        3)
            _realm_remove_cron && _ok "已移除 Realm 定时重启" ;;
    esac
}

realm_uninstall() {
    local confirmed="${1:-false}"
    if [[ "$confirmed" != "true" ]]; then
        _ask_yes "确认卸载 Realm 核心、服务与 $REALM_DIR?" || return 0
    fi
    svc stop "$REALM_SVC" >/dev/null 2>&1 || true
    svc disable "$REALM_SVC" >/dev/null 2>&1 || true
    if [[ "$DISTRO" == "alpine" ]]; then
        rm -f "/etc/init.d/$REALM_SVC"
    else
        rm -f "/etc/systemd/system/$REALM_SVC.service"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    _realm_remove_cron >/dev/null 2>&1 || true
    rm -rf "$REALM_DIR"
    _ok "Realm 已卸载（核心、配置、服务和定时任务均已删除）"
}

show_realm_summary() {
    [[ -x "$REALM_BIN" || -f "$REALM_CONF" ]] || return 0
    local state rules ver
    if svc status "$REALM_SVC" >/dev/null 2>&1; then
        state="${G}● 运行中${NC}"
    else
        state="${D}○ 已停止${NC}"
    fi
    rules=$(_realm_rule_count)
    ver=$(_realm_version 2>/dev/null || echo 未安装)
    echo -e "  Realm: $state  ${D}v$ver / $rules 条转发${NC}" >&2
}

realm_menu() {
    while true; do
        _header
        echo -e "  ${W}Realm TCP / UDP 端口转发${NC}" >&2
        echo -e "  ${D}目录: $REALM_DIR${NC}" >&2
        echo -e "  ${D}配置: $REALM_CONF（可手动编辑）${NC}" >&2
        local target
        target=$(_realm_target 2>/dev/null || echo "不支持-$(uname -m)")
        echo -e "  ${D}系统匹配: $DISTRO / $target${NC}" >&2
        show_realm_summary
        _line
        _item "1" "安装 / 更新 Realm 官方核心"
        _item "2" "添加转发规则"
        _item "3" "查看转发规则"
        _item "4" "修改转发规则"
        _item "5" "删除转发规则"
        _item "6" "手动编辑 config.toml ${D}(自动备份/可回滚)${NC}"
        _item "7" "导入规则 ${D}(兼容 EZRealm 格式)${NC}"
        _item "8" "导出规则 ${D}(兼容 EZRealm 格式)${NC}"
        echo -e "  ${D}───────────────────────────────────────────${NC}" >&2
        _item "9" "启动 Realm"
        _item "10" "停止 Realm"
        _item "11" "重启 Realm"
        _item "12" "查看状态 / 日志"
        _item "13" "定时重启"
        _item "14" "卸载 Realm"
        _item "0" "返回"
        _line
        local ch; read -rp "  请选择: " ch
        case "$ch" in
            1) install_realm_core true ;;
            2) realm_add_rule ;;
            3) realm_show_rules ;;
            4) realm_modify_rule ;;
            5) realm_delete_rule ;;
            6) realm_edit_config ;;
            7) realm_import_rules ;;
            8) realm_export_rules ;;
            9) realm_start_service ;;
            10) realm_stop_service ;;
            11) realm_restart_service ;;
            12) realm_show_logs ;;
            13) realm_schedule_menu ;;
            14) realm_uninstall ;;
            0) return ;;
            *) _err "无效选择"; sleep 1; continue ;;
        esac
        _pause
    done
}

do_uninstall() {
    [[ -f "$DB_FILE" || -f "$REALM_CONF" ]] || { _warn "未安装"; return; }
    _header
    echo -e "  ${W}完全卸载${NC}" >&2
    _line
    _ask_yes "确认卸载所有协议与配置?" || return

    _info "停止所有服务..."
    stop_services
    [[ -x "$REALM_BIN" || -f "$REALM_CONF" ]] && realm_uninstall true
    svc stop nginx 2>/dev/null

    if [[ "$(db_get_warp_mode)" != "disabled" ]]; then
        _ask_yes "是否同时卸载 WARP?" && uninstall_warp
    fi

    _info "删除服务单元..."
    local s
    if [[ "$DISTRO" == "alpine" ]]; then
        for s in /etc/init.d/vless-*; do
            [[ -f "$s" ]] && { rc-update del "$(basename "$s")" default 2>/dev/null; rm -f "$s"; }
        done
    else
        systemctl stop 'vless-*' 2>/dev/null
        systemctl disable 'vless-*' 2>/dev/null
        rm -f /etc/systemd/system/vless-*.service
        systemctl daemon-reload
    fi

    _info "清理 Nginx 订阅配置与伪装站..."
    rm -f /etc/nginx/conf.d/vless-sub.conf /etc/nginx/http.d/vless-sub.conf
    rm -f /etc/nginx/conf.d/vless-decoy.conf /etc/nginx/http.d/vless-decoy.conf
    rm -f "$SITE_PORT_FILE" 2>/dev/null
    nginx -t >/dev/null 2>&1 && nginx -s reload >/dev/null 2>&1 || true

    _info "清理 iptables 规则..."
    cleanup_hop_nat
    check_cmd iptables && {
        iptables -D INPUT -j "$TRAFFIC_CHAIN" 2>/dev/null
        iptables -F "$TRAFFIC_CHAIN" 2>/dev/null
        iptables -X "$TRAFFIC_CHAIN" 2>/dev/null
    }

    crontab -l 2>/dev/null | grep -vE "vless-check-expire|vless-cert-check|vless-realm-restart" | crontab - 2>/dev/null

    _info "删除配置文件（保留证书）..."
    rm -f "$CFG"/*.json "$CFG"/*.conf "$CFG"/*.sh "$CFG"/sub.info "$CFG"/sub_uuid "$CFG"/cache.db 2>/dev/null
    rm -rf "$CFG/subscription" "$RULESET_DIR" 2>/dev/null

    rm -f /usr/local/bin/vless /usr/bin/vless "$SYSTEM_SCRIPT" "$LEGACY_SYSTEM_SCRIPT" 2>/dev/null

    _ok "卸载完成"
    _line
    echo -e "  ${Y}已保留:${NC}" >&2
    echo -e "  • 二进制: ${D}sing-box, snell-server*, shadow-tls${NC}" >&2
    echo -e "  • 证书目录: ${G}$SSL_DIR${NC} ${D}(下次安装可复用)${NC}" >&2
    echo "" >&2
    echo -e "  ${C}如需彻底清理:${NC}" >&2
    echo -e "  ${G}rm -f /usr/local/bin/{sing-box,snell-server,snell-server-v5,snell-server-v6,shadow-tls}${NC}" >&2
    echo -e "  ${G}rm -rf ${CFG}${NC}" >&2
    _line
}

#═══════════════════════════════════════════════════════════════════════════════
# 配置备份 / 恢复（重装系统迁移用）
#═══════════════════════════════════════════════════════════════════════════════
# 备份包内部结构:
#   etc/     -> $CFG 下需要保留的文件（db.json 是核心，含全部协议参数与用户）
#   acme/    -> ~/.acme.sh 账户与证书状态（保证真实证书可继续自动续期）
#   site/    -> 本机 HTTPS 伪装站内容（如果存在）
#   meta.txt -> 版本 / 时间 / 主机信息
#   manifest.sha256 -> 包内文件完整性清单

_backup_state_files() {
    printf '%s\n' db.json warp.json sub_uuid sub.info cert_domain cert_meta \
        dns_api.conf decoy_site_port node_name no_firewall
}

_write_backup_manifest() {  # _write_backup_manifest <package-root>
    local root="$1" file rel digest
    : >"$root/manifest.sha256" || return 1
    while IFS= read -r file; do
        rel="${file#"$root"/}"
        [[ "$rel" == "manifest.sha256" ]] && continue
        [[ "$rel" == *$'\t'* || "$rel" == *$'\r'* || "$rel" == *$'\n'* ]] && {
            _err "备份文件名包含不可移植字符: $rel"; return 1; }
        digest=$(_sha256_file "$file")
        [[ "$digest" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
        printf '%s\t%s\n' "${digest,,}" "$rel" >>"$root/manifest.sha256"
    done < <(find "$root" -type f -print 2>/dev/null | LC_ALL=C sort)
    [[ -s "$root/manifest.sha256" ]]
}

_verify_backup_manifest() {  # _verify_backup_manifest <package-root>
    local root="$1" manifest="$1/manifest.sha256" expected rel file count=0 actual=0
    local -A seen=()
    [[ -f "$manifest" ]] || return 2
    while IFS=$'\t' read -r expected rel; do
        [[ "$expected" =~ ^[0-9a-fA-F]{64}$ && -n "$rel" ]] || return 1
        case "$rel" in /*|../*|*/../*|*/..|..|*\\*|*$'\r'*|*$'\n'*) return 1 ;; esac
        [[ -z "${seen[$rel]:-}" ]] || return 1
        seen["$rel"]=1
        [[ -f "$root/$rel" ]] || return 1
        _verify_sha256 "$root/$rel" "$expected" || return 1
        ((count++))
    done <"$manifest"
    (( count > 0 )) || return 1

    # 清单不仅要校验已列出的文件，还必须覆盖包内全部普通文件。
    # 否则攻击者可追加一个未登记的 acme.sh 脚本而不触发哈希失败。
    while IFS= read -r file; do
        rel="${file#"$root"/}"
        [[ "$rel" == "manifest.sha256" ]] && continue
        [[ -n "${seen[$rel]:-}" ]] || return 1
        ((actual++))
    done < <(find "$root" -type f -print 2>/dev/null | LC_ALL=C sort)
    (( actual == count ))
}

RESTORE_PACKAGE_ROOT=""
RESTORE_CFG_SOURCE=""
_detect_restore_payload() {  # _detect_restore_payload <extracted-root>
    local root="$1" db rel first rest package cfg count=0
    RESTORE_PACKAGE_ROOT=""; RESTORE_CFG_SOURCE=""
    while IFS= read -r -d '' db; do
        rel="${db#"$root"/}"
        package="$root"; cfg=""
        case "$rel" in
            db.json) cfg="$root" ;;
            etc/db.json) cfg="$root/etc" ;;
            vless-reality/db.json) cfg="$root/vless-reality" ;;
            etc/vless-reality/db.json) cfg="$root/etc/vless-reality" ;;
            *)
                [[ "$rel" == */* ]] || continue
                first="${rel%%/*}"; rest="${rel#*/}"; package="$root/$first"
                case "$rest" in
                    db.json) cfg="$package" ;;
                    etc/db.json) cfg="$package/etc" ;;
                    vless-reality/db.json) cfg="$package/vless-reality" ;;
                    etc/vless-reality/db.json) cfg="$package/etc/vless-reality" ;;
                    *) continue ;;
                esac
                ;;
        esac
        ((count++))
        RESTORE_PACKAGE_ROOT="$package"
        RESTORE_CFG_SOURCE="$cfg"
    done < <(find "$root" -maxdepth 5 -type f -name db.json -print0 2>/dev/null)
    (( count == 1 ))
}

_prepare_restore_package() {  # _prepare_restore_package <archive> <work-dir>
    local src="$1" raw="$2/raw" pkg="$2/pkg"
    local max_bytes="${SONGBOX_MAX_BACKUP_BYTES:-${VLESS_MAX_BACKUP_BYTES:-536870912}}"
    local entry_count expanded_kb archive_bytes f acme_src="" site_src="" candidate manifest_rc
    [[ "$max_bytes" =~ ^[0-9]+$ ]] || { _err "SONGBOX_MAX_BACKUP_BYTES 必须是整数"; return 1; }
    archive_bytes=$(stat -c%s "$src" 2>/dev/null || stat -f%z "$src" 2>/dev/null || echo 0)
    (( archive_bytes > 0 && archive_bytes <= max_bytes )) || { _err "备份大小异常或超过上限"; return 1; }
    _archive_safe "$src" tar.gz || { _err "备份包路径或文件类型不安全"; return 1; }
    entry_count=$(tar -tf "$src" 2>/dev/null | wc -l)
    (( entry_count > 0 && entry_count <= 20000 )) || { _err "备份条目数量异常"; return 1; }

    mkdir -p "$raw" "$pkg/etc" || return 1
    ( ulimit -f $((max_bytes / 512)); tar -xf "$src" -C "$raw" 2>/dev/null ) || {
        _err "解包失败或单个文件超过大小上限"; return 1; }
    _tree_safe "$raw" || { _err "备份解包后包含链接、特殊文件或危险权限"; return 1; }
    expanded_kb=$(du -sk "$raw" 2>/dev/null | awk '{print $1}')
    (( ${expanded_kb:-0} <= max_bytes / 1024 )) || { _err "备份解包后超过允许大小"; return 1; }

    _detect_restore_payload "$raw" || {
        _err "无法唯一识别备份中的 db.json（支持 etc/db.json、etc/vless-reality/db.json 和旧版目录包）"
        return 1
    }
    if [[ -f "$RESTORE_PACKAGE_ROOT/manifest.sha256" ]]; then
        _verify_backup_manifest "$RESTORE_PACKAGE_ROOT"; manifest_rc=$?
        (( manifest_rc == 0 )) || { _err "备份内部完整性校验失败"; return 1; }
        cp -a "$RESTORE_PACKAGE_ROOT/manifest.sha256" "$pkg/"
    else
        _warn "旧版备份不含内部完整性清单，将按兼容模式恢复"
    fi

    while IFS= read -r f; do
        [[ -e "$RESTORE_CFG_SOURCE/$f" ]] && cp -a "$RESTORE_CFG_SOURCE/$f" "$pkg/etc/"
    done < <(_backup_state_files)
    [[ -d "$RESTORE_CFG_SOURCE/certs" ]] && cp -a "$RESTORE_CFG_SOURCE/certs" "$pkg/etc/"
    if [[ -s "$RESTORE_CFG_SOURCE/realm/config.toml" ]]; then
        mkdir -p "$pkg/etc/realm"
        cp -a "$RESTORE_CFG_SOURCE/realm/config.toml" "$pkg/etc/realm/"
    fi
    [[ -f "$pkg/etc/db.json" ]] || { _err "备份中缺少可恢复的 db.json"; return 1; }

    for candidate in \
        "$RESTORE_PACKAGE_ROOT/acme" "$RESTORE_PACKAGE_ROOT/.acme.sh" \
        "$RESTORE_PACKAGE_ROOT/root/.acme.sh" "$raw/acme" "$raw/.acme.sh" "$raw/root/.acme.sh"; do
        [[ -d "$candidate" ]] || continue
        acme_src="$candidate"; break
    done
    [[ -n "$acme_src" ]] && { mkdir -p "$pkg/acme"; cp -a "$acme_src/." "$pkg/acme/"; }

    for candidate in \
        "$RESTORE_PACKAGE_ROOT/site" "$RESTORE_PACKAGE_ROOT/var/www/decoy" \
        "$raw/site" "$raw/var/www/decoy"; do
        [[ -d "$candidate" ]] || continue
        site_src="$candidate"; break
    done
    [[ -n "$site_src" ]] && { mkdir -p "$pkg/site"; cp -a "$site_src/." "$pkg/site/"; }

    if [[ -f "$RESTORE_PACKAGE_ROOT/meta.txt" ]]; then
        cp -a "$RESTORE_PACKAGE_ROOT/meta.txt" "$pkg/"
    elif [[ -f "$raw/meta.txt" ]]; then
        cp -a "$raw/meta.txt" "$pkg/"
    else
        printf 'backup_format=legacy\nsource_layout=%s\n' \
            "${RESTORE_CFG_SOURCE#"$raw"/}" >"$pkg/meta.txt"
    fi
    _tree_safe "$pkg" || { _err "规范化后的备份内容不安全"; return 1; }
}

_rollback_restore_switch() {  # stamp cfg_previous acme_previous site_previous acme_touched site_touched
    local stamp="$1" cfg_previous="$2" acme_previous="$3" site_previous="$4"
    local acme_touched="${5:-false}" site_touched="${6:-false}"
    if [[ -d "$CFG" ]]; then mv "$CFG" "${CFG}.failed-restore-${stamp}" 2>/dev/null || true; fi
    [[ -n "$cfg_previous" && -d "$cfg_previous" ]] && mv "$cfg_previous" "$CFG" 2>/dev/null
    if [[ "$acme_touched" == "true" && -d "$HOME/.acme.sh" ]]; then
        mv "$HOME/.acme.sh" "$HOME/.acme.sh.failed-restore-${stamp}" 2>/dev/null || true
    fi
    [[ -n "$acme_previous" && -d "$acme_previous" ]] && mv "$acme_previous" "$HOME/.acme.sh" 2>/dev/null
    if [[ "$site_touched" == "true" && -d "$SITE_ROOT" ]]; then
        mv "$SITE_ROOT" "${SITE_ROOT}.failed-restore-${stamp}" 2>/dev/null || true
    fi
    [[ -n "$site_previous" && -d "$site_previous" ]] && mv "$site_previous" "$SITE_ROOT" 2>/dev/null
}

do_backup() {
    local out="${1:-}"
    if [[ ! -f "$DB_FILE" ]]; then
        [[ -f "$REALM_CONF" ]] && init_db
    fi
    [[ -f "$DB_FILE" ]] || {
        _err "未找到协议或 Realm 配置，没有可备份的内容"; return 1; }
    check_cmd tar || { _err "缺少 tar 命令"; return 1; }
    check_cmd jq || { _err "缺少 jq，无法校验数据库"; return 1; }
    jq -e 'type == "object"' "$DB_FILE" >/dev/null 2>&1 || {
        _err "$DB_FILE 不是有效的 JSON 对象，已拒绝生成不可恢复的备份"; return 1; }
    if [[ -z "$out" ]]; then
        out="/root/songbox-backup-$(hostname -s 2>/dev/null || echo host)-$(date '+%Y%m%d-%H%M%S').tar.gz"
    fi
    mkdir -p "$(dirname "$out")" 2>/dev/null || { _err "无法创建目录: $(dirname "$out")"; return 1; }

    local tmp tmp_out validate_tmp f
    tmp=$(mktemp -d) || return 1
    mkdir -p "$tmp/pkg/etc"
    while IFS= read -r f; do
        [[ -e "$CFG/$f" ]] && cp -a "$CFG/$f" "$tmp/pkg/etc/"
    done < <(_backup_state_files)
    if [[ -f "$REALM_CONF" ]]; then
        mkdir -p "$tmp/pkg/etc/realm"
        cp -a "$REALM_CONF" "$tmp/pkg/etc/realm/"
    fi
    [[ -d "$SSL_DIR" ]] && cp -a "$SSL_DIR" "$tmp/pkg/etc/"
    [[ -d "$HOME/.acme.sh" ]] && cp -a "$HOME/.acme.sh" "$tmp/pkg/acme"
    [[ -d "$SITE_ROOT" ]] && { mkdir -p "$tmp/pkg/site"; cp -a "$SITE_ROOT/." "$tmp/pkg/site/"; }

    {
        echo "project=songbox"
        echo "backup_format=2"
        echo "script_version=$VERSION"
        echo "backup_time=$(date '+%F %T %z')"
        echo "hostname=$(hostname 2>/dev/null)"
        echo "ipv4=$(get_ipv4)"
        echo "ipv6=$(get_ipv6)"
        echo "protocols=$(db_all_protocols | tr '\n' ' ')"
        echo "realm_rules=$(_realm_rule_count)"
    } >"$tmp/pkg/meta.txt"

    _tree_safe "$tmp/pkg" || { rm -rf "$tmp"; _err "备份源中包含链接、特殊文件或危险权限"; return 1; }
    _write_backup_manifest "$tmp/pkg" || { rm -rf "$tmp"; _err "生成备份完整性清单失败"; return 1; }

    tmp_out=$(mktemp "${out}.tmp.XXXXXX") || { rm -rf "$tmp"; return 1; }
    if tar -czf "$tmp_out" -C "$tmp/pkg" . 2>/dev/null && _archive_safe "$tmp_out" tar.gz; then
        # 发布前再走一次恢复解析器，确保本次产物确实可读取。
        validate_tmp=$(mktemp -d) || { rm -rf "$tmp" "$tmp_out"; return 1; }
        if ! _prepare_restore_package "$tmp_out" "$validate_tmp" ||
           ! jq -e 'type == "object"' "$validate_tmp/pkg/etc/db.json" >/dev/null 2>&1; then
            rm -rf "$tmp" "$tmp_out" "$validate_tmp"
            _err "备份自检失败，未覆盖目标文件"
            return 1
        fi
        rm -rf "$validate_tmp"
        chmod 600 "$tmp_out"
        mv -f "$tmp_out" "$out" || { rm -rf "$tmp" "$tmp_out"; _err "发布备份文件失败"; return 1; }
        rm -rf "$tmp"
        _dline
        _ok "备份完成并通过恢复自检"
        echo -e "  文件: ${G}${out}${NC}" >&2
        echo -e "  大小: ${C}$(du -h "$out" | cut -f1)${NC}   SHA256: ${D}$(_sha256_file "$out")${NC}" >&2
        echo -e "  含  : ${C}$(db_all_protocols | tr '\n' ' ')${NC}" >&2
        [[ -f "$REALM_CONF" ]] &&
            echo -e "         ${C}Realm $(_realm_rule_count) 条转发规则${NC}" >&2
        [[ -d "$SITE_ROOT" ]] && echo -e "         ${C}伪装站页面${NC}" >&2
        _dline
        echo -e "  ${Y}请立刻把它下载到本地（备份内含全部密钥，务必妥善保管）:${NC}" >&2
        echo -e "  ${C}scp root@$(get_ipv4 || echo YOUR_IP):${out} ./${NC}" >&2
        _line
        return 0
    fi
    rm -rf "$tmp" "$tmp_out"; _err "打包或归档校验失败"; return 1
}

do_list_backup() {  # do_list_backup <archive> [verify-only]
    local src="$1" verify_only="${2:-false}" tmp
    [[ -f "$src" ]] || { _err "文件不存在: $src"; return 1; }
    check_cmd tar || { _err "缺少 tar 命令"; return 1; }
    check_cmd jq || { _err "缺少 jq 命令"; return 1; }
    tmp=$(mktemp -d) || return 1
    if ! _prepare_restore_package "$src" "$tmp"; then rm -rf "$tmp"; return 1; fi
    jq -e 'type == "object"' "$tmp/pkg/etc/db.json" >/dev/null 2>&1 || {
        rm -rf "$tmp"; _err "备份中的 db.json 不是合法 JSON"; return 1; }
    _ok "备份结构与完整性检查通过"
    if [[ "$verify_only" != "true" ]]; then
        sed 's/^/  /' "$tmp/pkg/meta.txt" 2>/dev/null
        echo "--- 协议与端口 ---"
        jq -r '
            [((.singbox // {}) | to_entries[]), ((.snell // {}) | to_entries[])]
            | sort_by(.key)[]
            | "\(.key)\t端口 \([.value[].port] | join(","))\t用户 \([.value[].users // [] | length] | add // 0)"' \
            "$tmp/pkg/etc/db.json"
        [[ -s "$tmp/pkg/etc/realm/config.toml" ]] && echo "realm\t包含转发配置"
        [[ -f "$tmp/pkg/site/index.html" ]] && echo "decoy-site\t包含伪装站页面"
        [[ -d "$tmp/pkg/acme" ]] && echo "acme.sh\t包含账户与续期状态"
    fi
    rm -rf "$tmp"
}

# do_restore <备份文件> [只恢复的协议,逗号分隔|all]
do_restore() {
    local src="${1:-}" keep_csv="${2:-}"
    if [[ -z "$src" ]]; then
        read -rp "  备份文件路径: " src
    fi
    [[ -f "$src" ]] || { _err "文件不存在: $src"; return 1; }
    check_dependencies false || { _err "恢复所需依赖安装失败"; return 1; }
    local backup_size max_backup_size="${SONGBOX_MAX_BACKUP_BYTES:-${VLESS_MAX_BACKUP_BYTES:-536870912}}"
    backup_size=$(stat -c%s "$src" 2>/dev/null || stat -f%z "$src" 2>/dev/null || echo 0)
    [[ "$max_backup_size" =~ ^[0-9]+$ ]] || { _err "SONGBOX_MAX_BACKUP_BYTES 必须是整数"; return 1; }
    (( backup_size > 0 && backup_size <= max_backup_size )) || {
        _err "备份大小异常或超过上限 (${max_backup_size} bytes)"; return 1; }
    local restore_sha; restore_sha=$(_sha256_file "$src")
    _info "备份 SHA-256: ${restore_sha}"
    local expected_sha="${SONGBOX_RESTORE_SHA256:-${VLESS_RESTORE_SHA256:-}}"
    if [[ -n "$expected_sha" ]] && ! _verify_sha256 "$src" "$expected_sha"; then
        _err "备份与 SONGBOX_RESTORE_SHA256 / VLESS_RESTORE_SHA256 不匹配，已拒绝恢复"
        return 1
    fi

    local -A avail_map=()
    local tmp; tmp=$(mktemp -d) || return 1
    _prepare_restore_package "$src" "$tmp" || { rm -rf "$tmp"; return 1; }
    jq -e 'type == "object"' "$tmp/pkg/etc/db.json" >/dev/null 2>&1 || {
        rm -rf "$tmp"; _err "备份中的 db.json 不是合法 JSON"; return 1; }
    local backup_has_realm=false
    [[ -s "$tmp/pkg/etc/realm/config.toml" ]] && backup_has_realm=true
    local backup_has_site=false
    [[ -f "$tmp/pkg/site/index.html" ]] && backup_has_site=true

    _line
    echo -e "  ${W}备份包信息${NC}" >&2
    if [[ -f "$tmp/pkg/meta.txt" ]]; then sed 's/^/    /' "$tmp/pkg/meta.txt" >&2; fi
    _line

    #── 选择性恢复 ──────────────────────────────────────────────────────────────
    local bk_db="$tmp/pkg/etc/db.json"
    local avail=() ap
    while IFS= read -r ap; do [[ -n "$ap" ]] && avail+=("$ap"); done < <(
        jq -r '[((.singbox // {}) | keys[]), ((.snell // {}) | keys[])] | sort | .[]' "$bk_db" 2>/dev/null)
    if [[ ${#avail[@]} -eq 0 && "$backup_has_realm" != "true" ]]; then
        rm -rf "$tmp"; _err "备份中没有协议或 Realm 配置"; return 1
    elif [[ ${#avail[@]} -eq 0 ]]; then
        keep_csv="all"
        _info "这是 Realm-only 备份，将恢复 config.toml 并按当前系统重装核心"
    fi

    if [[ -z "$keep_csv" && ${#avail[@]} -gt 1 && -t 0 ]]; then
        echo -e "  ${W}备份中包含 ${#avail[@]} 个协议${NC}" >&2
        local i=1 pp
        for pp in "${avail[@]}"; do
            printf '    %2d) %-22s %s\n' "$i" "$(get_protocol_name "$pp")" \
                "$(jq -r --arg p "$pp" '[((.singbox[$p] // []), (.snell[$p] // []))[] | .port] | join(", ") | "端口 " + .' "$bk_db" 2>/dev/null)" >&2
            avail_map[$i]="$pp"; ((i++))
        done
        _line
        _item "a" "全部恢复"
        echo -e "  ${D}或输入序号选择部分协议，空格/逗号分隔，例如: 1 3 或 1,3${NC}" >&2
        _line
        local sel picks=() tok idx
        while true; do
            read -rp "  请选择 [a]: " sel
            sel="${sel:-a}"
            if [[ "$sel" == "a" || "$sel" == "A" ]]; then keep_csv="all"; break; fi
            picks=(); local bad=0
            for tok in ${sel//,/ }; do
                [[ "$tok" =~ ^[0-9]+$ ]] || { bad=1; break; }
                idx="$tok"
                [[ -n "${avail_map[$idx]:-}" ]] || { bad=1; break; }
                picks+=("${avail_map[$idx]}")
            done
            if [[ "$bad" == "1" || ${#picks[@]} -eq 0 ]]; then _err "输入无效，请重新选择"; continue; fi
            keep_csv=$(printf '%s,' "${picks[@]}"); keep_csv="${keep_csv%,}"
            break
        done
    fi
    [[ -z "$keep_csv" ]] && keep_csv="all"

    if [[ "$keep_csv" != "all" ]]; then
        # 校验请求的协议都在备份里
        local want=() bad_names=() w
        for w in ${keep_csv//,/ }; do
            w=$(echo "$w" | tr -d '[:space:]'); [[ -z "$w" ]] && continue
            if printf '%s\n' "${avail[@]}" | grep -qx "$w"; then want+=("$w")
            else bad_names+=("$w"); fi
        done
        if [[ ${#bad_names[@]} -gt 0 ]]; then
            rm -rf "$tmp"
            _err "备份中不存在这些协议: ${bad_names[*]}"
            echo -e "  ${D}可用: ${avail[*]}${NC}" >&2
            return 1
        fi
        [[ ${#want[@]} -eq 0 ]] && { rm -rf "$tmp"; _err "未选择任何协议"; return 1; }

        local keep_json; keep_json=$(printf '%s\n' "${want[@]}" | jq -R . | jq -sc .)
        local filtered="$tmp/db.filtered.json"
        # 注意: 必须先 .key as $k 再 index，否则管道右侧的 . 已是 $keep 数组
        jq --argjson keep "$keep_json" '
              .singbox = ((.singbox // {}) | with_entries(select(.key as $k | ($keep | index($k)) != null)))
            | .snell   = ((.snell   // {}) | with_entries(select(.key as $k | ($keep | index($k)) != null)))
        ' "$bk_db" >"$filtered" 2>/dev/null && jq -e . "$filtered" >/dev/null 2>&1 || {
            rm -rf "$tmp"; _err "过滤协议失败"; return 1; }
        mv "$filtered" "$bk_db"
        local dropped
        dropped=$(printf '%s\n' "${avail[@]}" | grep -vxF -f <(printf '%s\n' "${want[@]}") | tr '\n' ' ')
        _ok "将只恢复: ${want[*]}"
        [[ -n "$dropped" ]] && {
            _warn "本次不恢复: ${dropped}"
            echo -e "  ${D}它们的参数仍保留在备份包里，以后可再次 --restore 单独取回${NC}" >&2
        }
        _line
    fi

    local realm_restore=false
    if [[ "$backup_has_realm" == "true" && "$keep_csv" == "all" ]]; then
        realm_restore=true
    else
        rm -rf "$tmp/pkg/etc/realm"
    fi

    [[ ! -e "$CFG" || -d "$CFG" ]] || { rm -rf "$tmp"; _err "$CFG 不是目录，无法安全恢复"; return 1; }
    local has_existing=false
    [[ -d "$CFG" || -d "$HOME/.acme.sh" || ( "$backup_has_site" == "true" && -d "$SITE_ROOT" ) ]] && has_existing=true
    if [[ "$has_existing" == "true" ]]; then
        _warn "当前服务器已有状态，恢复会原子替换 songbox 配置及备份中包含的 ACME / 伪装站内容"
    fi
    if [[ -z "$expected_sha" && -d "$tmp/pkg/acme" ]]; then
        _warn "未提供外部可信哈希；备份中的 acme.sh 状态含可执行脚本"
    fi
    if [[ "${SONGBOX_RESTORE_ASSUME_YES:-0}" != "1" ]]; then
        if [[ ! -t 0 ]]; then
            rm -rf "$tmp"
            _err "非交互恢复需要显式设置 SONGBOX_RESTORE_ASSUME_YES=1"
            return 1
        fi
        _ask_yes "确认信任该备份并继续?" || { rm -rf "$tmp"; _info "已取消"; return 0; }
    fi

    local restore_stamp cfg_stage cfg_previous="" acme_stage="" acme_previous=""
    local site_stage="" site_previous="" acme_touched=false site_touched=false
    restore_stamp="$(date '+%Y%m%d-%H%M%S')-$$"
    mkdir -p "$(dirname "$CFG")" || { rm -rf "$tmp"; return 1; }
    cfg_stage=$(mktemp -d "${CFG}.restore.XXXXXX") || { rm -rf "$tmp"; return 1; }
    cp -a "$tmp/pkg/etc/." "$cfg_stage/" || {
        rm -rf "$tmp" "$cfg_stage"; _err "暂存恢复配置失败"; return 1; }
    _tree_safe "$cfg_stage" || {
        rm -rf "$tmp" "$cfg_stage"; _err "暂存配置包含不安全文件"; return 1; }
    chown -R root:root "$cfg_stage" 2>/dev/null || true
    find "$cfg_stage" -type d -exec chmod 700 {} + 2>/dev/null
    find "$cfg_stage" -type f -exec chmod 600 {} + 2>/dev/null

    if [[ -d "$tmp/pkg/acme" ]]; then
        acme_stage=$(mktemp -d "$HOME/.acme.sh.restore.XXXXXX") || {
            rm -rf "$tmp" "$cfg_stage"; return 1; }
        cp -a "$tmp/pkg/acme/." "$acme_stage/" || {
            rm -rf "$tmp" "$cfg_stage" "$acme_stage"; _err "暂存 acme.sh 状态失败"; return 1; }
        _tree_safe "$acme_stage" || {
            rm -rf "$tmp" "$cfg_stage" "$acme_stage"; _err "acme.sh 状态包含不安全文件"; return 1; }
        chown -R root:root "$acme_stage" 2>/dev/null || true
        chmod -R go-w "$acme_stage" 2>/dev/null
        acme_touched=true
    fi

    if [[ "$backup_has_site" == "true" ]]; then
        mkdir -p "$(dirname "$SITE_ROOT")" || {
            rm -rf "$tmp" "$cfg_stage" ${acme_stage:+"$acme_stage"}; return 1; }
        site_stage=$(mktemp -d "${SITE_ROOT}.restore.XXXXXX") || {
            rm -rf "$tmp" "$cfg_stage" ${acme_stage:+"$acme_stage"}; return 1; }
        cp -a "$tmp/pkg/site/." "$site_stage/" || {
            rm -rf "$tmp" "$cfg_stage" ${acme_stage:+"$acme_stage"} "$site_stage"
            _err "暂存伪装站内容失败"; return 1
        }
        _tree_safe "$site_stage" || {
            rm -rf "$tmp" "$cfg_stage" ${acme_stage:+"$acme_stage"} "$site_stage"
            _err "伪装站内容包含不安全文件"; return 1
        }
        find "$site_stage" -type d -exec chmod 755 {} + 2>/dev/null
        find "$site_stage" -type f -exec chmod 644 {} + 2>/dev/null
        site_touched=true
    fi

    # 先按当前数据库停止旧服务，再切换目录；否则会按备份数据库漏停旧实例。
    stop_services >/dev/null 2>&1 || true
    svc stop "$REALM_SVC" >/dev/null 2>&1 || true
    if [[ -d "$CFG" ]]; then
        cfg_previous="${CFG}.before-restore-${restore_stamp}"
        mv "$CFG" "$cfg_previous" || {
            rm -rf "$tmp" "$cfg_stage" ${acme_stage:+"$acme_stage"} ${site_stage:+"$site_stage"}
            _err "备份现有配置目录失败"; return 1
        }
    fi
    if ! mv "$cfg_stage" "$CFG"; then
        [[ -n "$cfg_previous" ]] && mv "$cfg_previous" "$CFG" 2>/dev/null
        rm -rf "$tmp" ${acme_stage:+"$acme_stage"} ${site_stage:+"$site_stage"}
        _err "切换恢复配置失败，已回滚"; return 1
    fi

    if [[ "$acme_touched" == "true" ]]; then
        if [[ -d "$HOME/.acme.sh" ]]; then
            acme_previous="$HOME/.acme.sh.before-restore-${restore_stamp}"
            mv "$HOME/.acme.sh" "$acme_previous" || {
                _rollback_restore_switch "$restore_stamp" "$cfg_previous" "" "" false false
                rm -rf "$tmp" "$acme_stage" ${site_stage:+"$site_stage"}
                _err "备份现有 acme.sh 状态失败，配置已回滚"; return 1
            }
        fi
        if ! mv "$acme_stage" "$HOME/.acme.sh"; then
            _rollback_restore_switch "$restore_stamp" "$cfg_previous" "$acme_previous" "" false false
            rm -rf "$tmp" ${site_stage:+"$site_stage"}
            _err "切换 acme.sh 状态失败，配置已回滚"; return 1
        fi
        _info "已恢复 acme.sh 账户与证书状态"
    fi

    if [[ "$site_touched" == "true" ]]; then
        if [[ -d "$SITE_ROOT" ]]; then
            site_previous="${SITE_ROOT}.before-restore-${restore_stamp}"
            mv "$SITE_ROOT" "$site_previous" || {
                _rollback_restore_switch "$restore_stamp" "$cfg_previous" "$acme_previous" "" "$acme_touched" false
                rm -rf "$tmp" "$site_stage"; _err "备份现有伪装站失败，配置已回滚"; return 1
            }
        fi
        if ! mv "$site_stage" "$SITE_ROOT"; then
            _rollback_restore_switch "$restore_stamp" "$cfg_previous" "$acme_previous" "$site_previous" "$acme_touched" false
            rm -rf "$tmp"; _err "切换伪装站内容失败，配置已回滚"; return 1
        fi
        _info "已恢复本机 HTTPS 伪装站内容"
    fi

    chmod 711 "$CFG" 2>/dev/null
    chmod 600 "$DB_FILE" 2>/dev/null
    [[ -d "$SSL_DIR" ]] && chmod 700 "$SSL_DIR" 2>/dev/null
    [[ -d "$REALM_DIR" ]] && chmod 700 "$REALM_DIR" 2>/dev/null
    [[ -f "$REALM_CONF" ]] && chmod 600 "$REALM_CONF" 2>/dev/null
    _ok "配置文件已原子切换"

    local restore_ok=true
    db_migrate_legacy || restore_ok=false

    # 恢复过来的证书可能来自旧版本（没有 cert_meta）或另一台机器，
    # 这里重新识别来源并把自动续期链路补齐
    if [[ -s "$SSL_DIR/server.crt" ]]; then
        _info "识别恢复的证书..."
        cert_adopt
        cert_ensure_autorenew
    fi

    _info "重建服务（缺失的内核二进制会自动补装）..."
    [[ "$restore_ok" == "true" ]] && start_services || restore_ok=false
    if [[ "$realm_restore" == "true" ]]; then
        _info "按当前系统的架构与 libc 重装 Realm 核心..."
        if ! install_realm_core true; then
            restore_ok=false
        elif (( $(_realm_rule_count) > 0 )) && ! realm_start_service; then
            restore_ok=false
        fi
    fi
    if [[ "$restore_ok" == "true" ]]; then
        create_shortcut
        _refresh_subscription_files
        [[ -f "$CFG/sub.info" ]] && install_nginx >/dev/null 2>&1
        if [[ "$backup_has_site" == "true" && -s "$SITE_PORT_FILE" ]]; then
            local restored_site_port; restored_site_port=$(cat "$SITE_PORT_FILE" 2>/dev/null)
            if _is_real_cert; then
                setup_decoy_site "$restored_site_port" keep >/dev/null ||
                    _warn "伪装站文件已恢复，但 Nginx 配置重建失败，请从菜单重试"
            else
                _warn "伪装站文件已恢复；当前证书不是可信证书，未自动启用 Nginx 站点"
            fi
        fi
        db_expired_users >/dev/null 2>&1 && install_expire_cron >/dev/null 2>&1
        sync_traffic_counters 2>/dev/null || true
        _dline
        _ok "恢复完成，所选协议与 Realm 配置已重建"
        _dline
        show_status
        show_realm_summary
        echo "" >&2
        local oip nip
        oip=$(awk -F= '/^ipv4=/{print $2}' "$tmp/pkg/meta.txt" 2>/dev/null)
        nip=$(get_ipv4)
        if [[ -n "$oip" && -n "$nip" && "$oip" != "$nip" ]]; then
            _warn "服务器 IP 已变化: ${oip} → ${nip}"
            echo -e "  ${D}协议参数不变，但客户端里的服务器地址需要改成新 IP${NC}" >&2
            echo -e "  ${D}（若用域名接入且 DNS 已更新，客户端无需改动）${NC}" >&2
        fi
        rm -rf "$tmp"
        echo -e "  ${C}建议执行「查看协议配置 / 分享链接」核对一遍${NC}" >&2
        return 0
    fi
    if [[ "$has_existing" == "true" ]]; then
        _warn "恢复后的服务验证失败，正在回滚到恢复前状态..."
        stop_services >/dev/null 2>&1 || true
        svc stop "$REALM_SVC" >/dev/null 2>&1 || true
        _rollback_restore_switch "$restore_stamp" "$cfg_previous" "$acme_previous" "$site_previous" \
            "$acme_touched" "$site_touched"
        if [[ -f "$DB_FILE" ]]; then
            start_services >/dev/null 2>&1 || _warn "原配置已还原，但旧服务需要手动启动"
        fi
        [[ -f "$REALM_CONF" ]] && realm_start_service >/dev/null 2>&1 || true
        rm -rf "$tmp"
        _err "恢复后的服务启动失败，已回滚；失败配置保留在 ${CFG}.failed-restore-${restore_stamp}"
        return 1
    fi
    rm -rf "$tmp"
    _err "服务启动失败；这是新服务器，没有旧配置可回滚，已保留恢复内容供排查"
    return 1
}

#═══════════════════════════════════════════════════════════════════════════════
# 状态概览与主菜单
#═══════════════════════════════════════════════════════════════════════════════
show_status() {
    if [[ ! -f "$DB_FILE" ]]; then echo -e "  状态: ${D}○ 未安装${NC}" >&2; return; fi
    local installed; installed=$(db_all_protocols)
    [[ -z "$installed" ]] && { echo -e "  状态: ${D}○ 未安装${NC}" >&2; return; }

    local total=0 running=0 proto core
    local sb; sb=$(get_singbox_protocols)
    local sb_up=false
    [[ -n "$sb" ]] && svc status "$SB_SVC" >/dev/null 2>&1 && sb_up=true
    for proto in $sb; do ((total++)); [[ "$sb_up" == "true" ]] && ((running++)); done
    for proto in $(get_snell_protocols); do
        ((total++)); svc status "vless-${proto}" >/dev/null 2>&1 && ((running++))
    done

    if is_paused; then echo -e "  状态: ${Y}⏸ 已暂停${NC}" >&2
    elif [[ "$running" -eq "$total" && "$total" -gt 0 ]]; then echo -e "  状态: ${G}● 运行中${NC}" >&2
    elif [[ "$running" -gt 0 ]]; then echo -e "  状态: ${Y}● 部分运行${NC} (${running}/${total})" >&2
    else echo -e "  状态: ${R}● 已停止${NC}" >&2; fi

    echo -e "  协议: ${C}已安装 ${total} 个${NC}" >&2
    for proto in $installed; do
        core=$(proto_core "$proto")
        echo -e "    ${G}•${NC} $(get_protocol_name "$proto") ${D}- 端口: $(db_list_ports "$core" "$proto" | tr '\n' ',' | sed 's/,$//')${NC}" >&2
    done

    local rcount; rcount=$(db_routing_rules | jq 'length')
    if [[ "${rcount:-0}" -gt 0 ]]; then
        echo -e "  分流: ${G}${rcount} 条规则${NC}   节点: ${G}$(db_chain_count)${NC}   WARP: $( [[ "$(db_get_warp_mode)" == "disabled" ]] && echo "${D}未启用${NC}" || echo "${G}$(db_get_warp_mode)${NC}" )" >&2
    fi
    access_restriction_enabled && echo -e "  访问限制: ${G}已启用${NC}" >&2
}

main_menu() {
    check_root
    init_log
    init_db
    db_migrate_legacy
    cert_selfheal
    ensure_subscription_files
    _auto_sync_system_script

    while true; do
        _header
        echo -e "  ${W}服务端管理${NC}" >&2
        local osv=""
        [[ -f /etc/os-release ]] && osv=$(grep -m1 '^PRETTY_NAME=' /etc/os-release | cut -d'"' -f2)
        echo -e "  ${D}系统: ${osv:-$DISTRO} | $(uname -r)${NC}" >&2
        echo -e "  ${D}内核: Sing-box $(_sb_version 2>/dev/null || echo 未安装)${NC}" >&2
        echo "" >&2
        show_status
        show_realm_summary
        echo "" >&2
        _line

        local installed; installed=$(db_all_protocols)
        if [[ -n "$installed" ]]; then
            _item "1" "安装新协议 ${D}(多协议共存)${NC}"
            _item "2" "内核版本管理 ${D}(Sing-box / Snell)${NC}"
            _item "3" "卸载指定协议"
            _item "4" "用户管理"
            echo -e "  ${D}───────────────────────────────────────────${NC}" >&2
            _item "5" "查看协议配置 / 分享链接"
            _item "6" "订阅服务管理"
            _item "7" "管理协议服务"
            _item "8" "分流管理"
            echo -e "  ${D}───────────────────────────────────────────${NC}" >&2
            _item "9" "BBR3 / 双栈 / NAT 自适应优化"
            _item "10" "查看运行日志"
            _item "11" "检查脚本更新"
            _item "12" "完全卸载"
            _item "13" "证书管理 ${D}(申请 / 续期 / 换域名)${NC}"
            _item "14" "备份 / 恢复配置 ${D}(重装系统迁移)${NC}"
        else
            _item "1" "安装协议"
            echo -e "  ${D}───────────────────────────────────────────${NC}" >&2
            _item "9" "网络调优 ${D}(BBR3 / 双栈 / NAT / sysctl)${NC}"
            _item "11" "检查脚本更新"
            if [[ -f "$REALM_CONF" ]]; then
                _item "14" "备份 / 恢复配置 ${D}(含 Realm config.toml)${NC}"
            else
                _item "14" "从备份恢复配置 ${D}(重装系统后使用)${NC}"
            fi
        fi
        _item "15" "Realm 端口转发 ${D}(TCP/UDP / Debian/Alpine)${NC}"
        _item "0" "退出"
        _line

        local ch; read -rp "  请选择: " ch || exit 0
        local skip=false
        case "$ch" in
            1)  do_install; skip=true ;;
            2)  [[ -n "$installed" ]] && { update_core_menu; skip=true; } || _err "请先安装协议" ;;
            3)  [[ -n "$installed" ]] && { uninstall_specific_protocol; skip=true; } || _err "无效选择" ;;
            4)  [[ -n "$installed" ]] && { manage_users; skip=true; } || _err "无效选择" ;;
            5)  [[ -n "$installed" ]] && { show_all_protocols_info; skip=true; } || _err "无效选择" ;;
            6)  [[ -n "$installed" ]] && { manage_subscription; skip=true; } || _err "无效选择" ;;
            7)  [[ -n "$installed" ]] && { manage_protocol_services; skip=true; } || _err "无效选择" ;;
            8)  [[ -n "$installed" ]] && { manage_routing; skip=true; } || _err "无效选择" ;;
            9)  network_tuning_menu; skip=true ;;
            10) [[ -n "$installed" ]] && { show_logs; skip=true; } || _err "无效选择" ;;
            11) do_update ;;
            12) [[ -n "$installed" ]] && do_uninstall || _err "无效选择" ;;
            13) [[ -n "$installed" ]] && { manage_certificates; skip=true; } || _err "无效选择" ;;
            14)
                if [[ -z "$installed" && ! -f "$REALM_CONF" ]]; then
                    do_restore ""
                else
                    _header
                    echo -e "  ${W}备份 / 恢复配置${NC}" >&2
                    _line
                    _item "1" "备份当前配置 ${D}(重装系统前导出)${NC}"
                    _item "2" "从备份恢复 ${D}(可只恢复部分协议；完整恢复含 Realm)${NC}"
                    _item "0" "返回"
                    _line
                    local bc; read -rp "  请选择: " bc
                    case "$bc" in
                        1) local bp; read -rp "  输出路径 [回车用默认]: " bp; do_backup "$bp" ;;
                        2) do_restore "" ;;
                    esac
                    skip=false
                fi ;;
            15) realm_menu; skip=true ;;
            0)  exit 0 ;;
            *)  _err "无效选择"; skip=true; sleep 1 ;;
        esac
        [[ "$skip" == "false" ]] && _pause
    done
}

#═══════════════════════════════════════════════════════════════════════════════
# 命令行入口
#═══════════════════════════════════════════════════════════════════════════════
if [[ "${SONGBOX_SOURCE_ONLY:-0}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

case "${1:-}" in
    --check-expire)
        check_root; init_db
        n=$(check_and_disable_expired)
        echo "已禁用过期用户: $n 个"
        exit 0 ;;
    --sync-ruleset)
        check_root; init_db; sync_all_rulesets; reload_config; exit 0 ;;
    --regen-config)
        check_root; init_db
        gen_hop_nat_script
        generate_singbox_config && {
            create_singbox_service
            svc restart "$SB_SVC" 2>/dev/null
            _refresh_subscription_files
        }
        exit 0 ;;
    --show-traffic)
        check_root; init_db; sync_traffic_counters; show_port_traffic; exit 0 ;;
    --cert-check)
        check_root; init_db; cert_check_and_renew; exit 0 ;;
    --firewall-status)
        check_root; init_db; show_firewall_footprint; exit 0 ;;
    --cert-fix)
        check_root; init_db; cert_adopt; cert_ensure_autorenew; exit $? ;;
    --cert-status)
        check_root; init_db; cert_selfheal; show_cert_status; cert_show_renew_task; exit 0 ;;
    --realm-restart)
        check_root; init_log; realm_restart_service; exit $? ;;
    --backup)
        check_root; init_log; do_backup "${2:-}"; exit $? ;;
    --restore)
        check_root; init_log
        [[ -z "${2:-}" ]] && { echo "用法: $0 --restore <备份文件.tar.gz> [--only 协议1,协议2]"; exit 1; }
        _only=""
        [[ "${3:-}" == "--only" ]] && _only="${4:-}"
        do_restore "$2" "$_only"; exit $? ;;
    --list-backup)
        [[ -z "${2:-}" ]] && { echo "用法: $0 --list-backup <备份文件.tar.gz>"; exit 1; }
        do_list_backup "$2"; exit $? ;;
    --verify-backup)
        [[ -z "${2:-}" ]] && { echo "用法: $0 --verify-backup <备份文件.tar.gz>"; exit 1; }
        do_list_backup "$2" true; exit $? ;;
    --help|-h)
        cat <<EOF
用法: $0 [选项]

选项:
  --check-expire    检查并禁用过期用户（用于定时任务）
  --sync-ruleset    重新下载 geosite / geoip 规则集并重载配置
  --regen-config    重新生成 Sing-box 配置并重启服务
  --show-traffic    显示端口级流量统计
  --cert-check      检查证书剩余天数，不足 20 天时自动续期（用于定时任务）
  --cert-status     显示证书状态与各协议 SNI
  --firewall-status 审计脚本写入了哪些防火墙规则
  --cert-fix        重新识别现有证书并补齐自动续期链路（恢复备份后用）
  --realm-restart   重启 Realm 服务（供定时任务调用）
  --backup [路径]   导出配置备份（含协议、用户、证书及 Realm 配置），重装前使用
  --restore <文件> [--only p1,p2]
                    从备份恢复并重建服务；--only 可只恢复指定协议
  --list-backup <文件>
                    查看备份包里有哪些协议、端口、用户数（不做任何改动）
  --verify-backup <文件>
                    完整校验归档结构、文件类型、大小、哈希与 db.json
  --help, -h        显示帮助

无参数时进入交互式菜单。
EOF
        exit 0 ;;
    "")
        main_menu ;;
    *)
        echo "未知参数: $1（使用 --help 查看帮助）"
        exit 1 ;;
esac
