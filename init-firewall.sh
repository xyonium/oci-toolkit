#!/usr/bin/env bash
#
# init-firewall.sh — 代理节点 v4+v6 统一防火墙（白名单 + REJECT 兜底，幂等）
#
# 方案：nft inet dsh_firewall 表（独立于 iptables-nft 转换层，不碰 ip6 filter / rules.v6）
#
# 用法:
#   ./init-firewall.sh [user@]host[:port] ... [--apply] [选项]
#   ./init-firewall.sh --local [--apply] [选项]
#   不加 --apply 时默认 dry-run（只打印将生成的规则和将要执行的改动）
#
# 预设 profile（一台机器的角色）:
#   proxy    默认。SSH + 80/tcp + 443/tcp + 443/udp + hy2 + 端口跳跃（= 全家桶节点）
#   hy2      只跑 hysteria2：SSH + hy2 + 端口跳跃
#   web      只跑 HTTP(S)：SSH + 80/tcp + 443/tcp + 443/udp
#   minimal  只放 SSH（跳板机 / 未部署服务的新机基线）
#
# 选项:
#   --profile NAME      预设组合，见上（默认 proxy）
#   --ssh-port PORT     SSH 监听端口（默认 22；bwg 用 26320）
#   --hy2-port PORT     hysteria2 监听端口（默认 8443）
#   --hy2-hop SPEC      端口跳跃 UDP 放行范围（默认 20000-30000）
#   --no-hy2-hop        关闭端口跳跃放行（只留 --hy2-port 单端口）
#   --no-http3          不放行 443/udp（Quic/HTTP3；proxy/web 默认放行）
#   --extra-tcp LIST    额外放行 TCP 端口/区间，逗号或空格分隔，可重复
#   --extra-udp LIST    额外放行 UDP 端口/区间，逗号或空格分隔，可重复
#   --enable-frps       放行 frps 端口（7102 TCP+UDP + 7001 UDP）
#   --enable-xmpp       放行 XMPP 端口（5222/5223/5269/5280 TCP）
#
# 示例:
#   ./init-firewall.sh root@node-a.example.com --apply
#   ./init-firewall.sh root@node-b.example.com:26320 --apply --ssh-port 26320 --enable-frps
#   ./init-firewall.sh root@relay.example.com --apply --profile minimal --extra-tcp 9000-9100
#   ./init-firewall.sh --local --profile hy2 --hy2-port 9443 --no-hy2-hop
#   （真实主机清单在本地未入库的 fleet 文件里，示例一律用占位域名）
#
# 持久化：/etc/nftables.d-dsh/firewall.nft + /etc/nftables.conf include（幂等）

set -uo pipefail

DRY_RUN=1
LOCAL_MODE=0
PROFILE=proxy
SSH_PORT=22
HY2_PORT=8443
HY2_HOP="20000-30000"
HTTP3=auto          # auto = 跟 profile 走；1/0 由命令行强制
ENABLE_FRPS=0
ENABLE_XMPP=0
EXTRA_TCP=""        # 空格分隔的已校验端口表达式，多组用 " | " 分层记录
EXTRA_UDP=""
HOSTS=()

usage() { sed -n '2,36p' "$0"; }

die() { echo "错误: $*" >&2; exit 2; }

# ── 端口表达式校验 ──
# 只允许 nft 能接受、且无法注入额外规则的字符集：数字、单连字符（区间）、逗号、空格。
# 然后逐段校验数值范围，杜绝 "443 accept; ..." 这类注入和手滑的 70000。
# 结果写进 NORMPORTS（不用 $(...) 取值：die 在子 shell 里 exit 不会终止主脚本）。
NORMPORTS=""
norm_portspec() {
    local spec="$1" what="$2" out="" tok lo hi
    NORMPORTS=""
    [[ "$spec" =~ ^[0-9]+(-[0-9]+)?([,[:space:]]+[0-9]+(-[0-9]+)?)*$ ]] \
        || die "$what 端口表达式非法：'$spec'（只允许数字、逗号、空格、区间连字符）"
    for tok in ${spec//,/ }; do
        if [[ "$tok" == *-* ]]; then
            lo="${tok%%-*}"; hi="${tok##*-}"
            [[ "$lo" -le "$hi" ]] || die "$what 区间起点大于终点：'$tok'"
        else
            lo="$tok"; hi="$tok"
        fi
        [[ "$lo" -ge 1 && "$hi" -le 65535 ]] || die "$what 端口越界（1-65535）：'$tok'"
        out+="${out:+ }$tok"
    done
    NORMPORTS="$out"
}

# 取选项值：分支里 shift 之后调用，值缺失（或空）时统一报错退出
need_arg() {
    [ -n "${2:-}" ] || die "$1 需要参数（--help 查看用法）"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)        DRY_RUN=0 ;;
        --dry-run)      DRY_RUN=1 ;;
        --local)        LOCAL_MODE=1 ;;
        --profile)      shift; need_arg --profile "${1:-}"; PROFILE="$1" ;;
        --ssh-port)     shift; need_arg --ssh-port "${1:-}"; SSH_PORT="$1" ;;
        --hy2-port)     shift; need_arg --hy2-port "${1:-}"; HY2_PORT="$1" ;;
        --hy2-hop)      shift; need_arg --hy2-hop "${1:-}"; HY2_HOP="$1" ;;
        --no-hy2-hop)   HY2_HOP="" ;;
        --http3)        HTTP3=1 ;;
        --no-http3)     HTTP3=0 ;;
        --extra-tcp)    shift; need_arg --extra-tcp "${1:-}"; norm_portspec "$1" '--extra-tcp'
                        EXTRA_TCP+="${EXTRA_TCP:+ | }$NORMPORTS" ;;
        --extra-udp)    shift; need_arg --extra-udp "${1:-}"; norm_portspec "$1" '--extra-udp'
                        EXTRA_UDP+="${EXTRA_UDP:+ | }$NORMPORTS" ;;
        --enable-frps)  ENABLE_FRPS=1 ;;
        --enable-xmpp)  ENABLE_XMPP=1 ;;
        -h|--help)      usage; exit 0 ;;
        -*)             die "未知选项 '$1'（--help 查看用法）" ;;
        *)              HOSTS+=("$1") ;;
    esac
    shift
done

# ── profile 展开 ──
DO_WEB=0; DO_HY2=0
case "$PROFILE" in
    proxy)   DO_WEB=1; DO_HY2=1 ;;
    hy2)     DO_WEB=0; DO_HY2=1 ;;
    web)     DO_WEB=1; DO_HY2=0 ;;
    minimal) DO_WEB=0; DO_HY2=0 ;;
    *)       die "未知 profile '$PROFILE'（可选 proxy / hy2 / web / minimal）" ;;
esac

# HTTP3 默认跟 profile：有 web 端口就开 443/udp
if [ "$HTTP3" = "auto" ]; then
    if [ "$DO_WEB" = "1" ]; then HTTP3=1; else HTTP3=0; fi
fi

# 单端口校验（--ssh-port / --hy2-port）
check_port() {
    local val="$1" what="$2"
    case "$val" in
        ''|*[!0-9]*) die "$what 非法：'$val'（只接受数字端口）" ;;
    esac
    if [ "$val" -lt 1 ] || [ "$val" -gt 65535 ]; then
        die "$what 越界（1-65535）：'$val'"
    fi
}

check_port "$SSH_PORT" '--ssh-port'
check_port "$HY2_PORT" '--hy2-port'
[ -n "$HY2_HOP" ] && { norm_portspec "$HY2_HOP" '--hy2-hop'; HY2_HOP="$NORMPORTS"; }

if [ "$LOCAL_MODE" -eq 0 ] && [ ${#HOSTS[@]} -eq 0 ]; then
    echo "错误: 请指定至少一台主机，或使用 --local 在本机运行" >&2
    usage >&2
    exit 2
fi

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

profile_summary() {
    echo "  profile=$PROFILE SSH=$SSH_PORT"
    [ "$DO_WEB" = "1" ] && echo "  web: 80/tcp 443/tcp$([ "$HTTP3" = "1" ] && echo ' 443/udp')"
    [ "$DO_HY2" = "1" ] && echo "  hy2: ${HY2_PORT}/udp${HY2_HOP:+ + 跳跃 ${HY2_HOP}/udp}"
    [ -n "$EXTRA_TCP" ] && echo "  extra-tcp: ${EXTRA_TCP// | /, }"
    [ -n "$EXTRA_UDP" ] && echo "  extra-udp: ${EXTRA_UDP// | /, }"
    [ "$ENABLE_FRPS" = "1" ] && echo "  frps: 7102/tcp 7102/udp 7001/udp"
    [ "$ENABLE_XMPP" = "1" ] && echo "  xmpp: 5222 5223 5269 5280/tcp"
    return 0
}

# ── 生成 nft 规则 ──
generate_nft() {
    cat << 'HEADER'
#!/usr/sbin/nft -f
# dsh_firewall — v4+v6 白名单 + REJECT 兜底（由 init-firewall.sh 生成，幂等）
table inet dsh_firewall
delete table inet dsh_firewall

table inet dsh_firewall {
  chain input {
    type filter hook input priority filter; policy accept;

    iifname "lo" accept
    ct state established,related accept
HEADER

    # SSH（端口可配）
    printf '    tcp dport %s ct state new accept\n' "$SSH_PORT"

    # HTTP(S) 与 QUIC
    if [ "$DO_WEB" = "1" ]; then
        cat << 'WEB'
    tcp dport 80 ct state new accept
    tcp dport 443 ct state new accept
WEB
        [ "$HTTP3" = "1" ] && printf '    udp dport 443 accept\n'
    fi

    # hysteria2 + 端口跳跃
    if [ "$DO_HY2" = "1" ]; then
        printf '    udp dport %s accept\n' "$HY2_PORT"
        [ -n "$HY2_HOP" ] && printf '    # hy2 端口跳跃\n    udp dport %s accept\n' "$HY2_HOP"
    fi

    # 额外端口（可重复，已校验）
    local spec; local -a groups=()
    if [ -n "$EXTRA_TCP" ]; then
        IFS='|' read -ra groups <<< "$EXTRA_TCP"
        for spec in "${groups[@]}"; do
            spec="${spec# }"; spec="${spec% }"
            printf '    # extra-tcp\n    tcp dport { %s } ct state new accept\n' "${spec// /, }"
        done
    fi
    if [ -n "$EXTRA_UDP" ]; then
        IFS='|' read -ra groups <<< "$EXTRA_UDP"
        for spec in "${groups[@]}"; do
            spec="${spec# }"; spec="${spec% }"
            printf '    # extra-udp\n    udp dport { %s } accept\n' "${spec// /, }"
        done
    fi

    # frps（可选）
    if [ "$ENABLE_FRPS" = "1" ]; then
        cat << 'FRPS'
    # frps
    tcp dport 7102 ct state new accept
    udp dport 7102 accept
    udp dport 7001 accept
FRPS
    fi

    # XMPP（可选，默认关闭）
    if [ "$ENABLE_XMPP" = "1" ]; then
        cat << 'XMPP'
    # XMPP (ejabberd)
    tcp dport 5222 ct state new accept
    tcp dport 5223 ct state new accept
    tcp dport 5269 ct state new accept
    tcp dport 5280 ct state new accept
XMPP
    fi

    # ICMP + DHCPv6 + REJECT 兜底
    cat << 'TAIL'
    ip protocol icmp accept
    icmpv6 type { 1, 2, 3, 4, 128, 129, 133, 134, 135, 136, 130, 131, 132, 143, 141, 142 } accept
    udp sport 547 udp dport 546 ip6 saddr fe80::/10 accept
    udp dport 546 ip6 saddr fe80::/10 accept
    ip protocol tcp reject with tcp reset
    ip protocol udp reject with icmp port-unreachable
    ip6 nexthdr tcp reject with tcp reset
    ip6 nexthdr udp reject with icmpv6 port-unreachable
    reject
  }

  chain forward {
    type filter hook forward priority filter; policy accept;
    ct state established,related accept
    reject
  }

  chain output {
    type filter hook output priority filter; policy accept;
  }
}
TAIL
}

# ── 远程执行 ──
apply_remote() {
    local target="$1"
    local tgt="$target"; local tgt_opts=()
    case "$tgt" in
        *:*) tgt_opts=(-p "${tgt##*:}"); tgt="${tgt%:*}" ;;
    esac

    echo "════════ $tgt ${tgt_opts[*]:-} ════════"
    profile_summary

    # 生成 nft 文件到本地临时文件
    local tmpf
    tmpf=$(mktemp /tmp/dsh-firewall-XXXXXX.nft)
    generate_nft > "$tmpf"

    if [ "$DRY_RUN" = "1" ]; then
        echo "  ── dry-run：将生成的规则如下 ──"
        sed 's/^/    /' "$tmpf"
        rm -f "$tmpf"
        echo
        return 0
    fi

    # scp 到目标（注意：scp 端口参数是大写 -P，与 ssh 的 -p 不同）
    local scp_opts=()
    case "$target" in
        *:*) scp_opts=(-P "${target##*:}") ;;
    esac
    scp "${SSH_OPTS[@]}" "${scp_opts[@]}" "$tmpf" "$tgt":/tmp/dsh-firewall.nft || { echo "  ❌ scp 失败"; rm -f "$tmpf"; return 1; }
    rm -f "$tmpf"

    # 远程执行
    ssh "${SSH_OPTS[@]}" "${tgt_opts[@]}" "$tgt" 'sudo -n bash -c "
        set -e
        # 语法校验
        nft -c -f /tmp/dsh-firewall.nft || { echo \"❌ nft 语法错误\"; exit 1; }
        # 加载
        nft -f /tmp/dsh-firewall.nft
        echo \"✅ nft 规则已加载\"
        # 持久化
        mkdir -p /etc/nftables.d-dsh
        cp /tmp/dsh-firewall.nft /etc/nftables.d-dsh/firewall.nft
        chmod 644 /etc/nftables.d-dsh/firewall.nft
        if ! grep -qF \"include \\\"/etc/nftables.d-dsh/firewall.nft\\\"\" /etc/nftables.conf 2>/dev/null; then
            cp /etc/nftables.conf /etc/nftables.conf.bak-\$(date +%Y%m%d-%H%M%S) 2>/dev/null || true
            printf \"\\n# dsh_firewall\ninclude \\\"/etc/nftables.d-dsh/firewall.nft\\\"\\n\" >> /etc/nftables.conf
            echo \"✅ include 行已追加\"
        else
            echo \"○ include 行已存在\"
        fi
        systemctl is-enabled nftables >/dev/null 2>&1 || systemctl enable nftables
        echo \"✅ 持久化完成\"
    "' || { echo "  ❌ 远程执行失败"; return 1; }

    # 验证：新 SSH session
    if ssh "${SSH_OPTS[@]}" "${tgt_opts[@]}" "$tgt" 'true' 2>/dev/null; then
        echo "  ✅ 新 SSH 连接 OK"
    else
        echo "  ❌ SSH 连接失败——可能被防火墙锁死！"
        return 1
    fi
    echo
}

if [ "$LOCAL_MODE" -eq 1 ]; then
    echo "════════ local ($(hostname)) ════════"
    profile_summary
    tmpf=$(mktemp /tmp/dsh-firewall-XXXXXX.nft)
    generate_nft > "$tmpf"
    if [ "$DRY_RUN" = "1" ]; then
        echo "  ── dry-run ──"
        sed 's/^/    /' "$tmpf"
        rm -f "$tmpf"
        exit 0
    fi
    sudo -n bash -c "
        nft -c -f $tmpf && nft -f $tmpf && echo '✅ 规则已加载'
        mkdir -p /etc/nftables.d-dsh
        cp $tmpf /etc/nftables.d-dsh/firewall.nft
        grep -qF 'include \"/etc/nftables.d-dsh/firewall.nft\"' /etc/nftables.conf 2>/dev/null || \
            printf '\ninclude \"/etc/nftables.d-dsh/firewall.nft\"\n' >> /etc/nftables.conf
        systemctl is-enabled nftables >/dev/null 2>&1 || systemctl enable nftables
        echo '✅ 持久化完成'
    "
    rm -f "$tmpf"
    exit $?
fi

rc_all=0
for target in "${HOSTS[@]}"; do
    apply_remote "$target" || rc_all=1
done
exit "$rc_all"
