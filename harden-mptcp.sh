#!/usr/bin/env bash
#
# harden-mptcp.sh — CVE-2026-98432 缓解：关闭 MPTCP + 可选 nft 丢 IPv4 options（幂等）
#
# 背景：
#   CVE-2026-98432 = Linux 内核 IPv4 TCP 握手路径 use-after-free，CVSS 9.8，
#   远程 root RCE。前置条件：内核 net.mptcp.enabled=1（5.6+ 默认开）+
#   监听进程声明 MPTCP（Go 1.24+ listener 默认声明）。
#   Ubuntu 24.04/22.04 修复内核仍在 work-in-progress（2026-11-04 查证），
#   livepatch 亦无补丁 → 必须走临时缓解。
#
# 缓解设计（用户确认完全不需要 MPTCP）：
#   1. sysctl net.mptcp.enabled=0 + /etc/sysctl.d/99-mptcp-disable.conf 持久化
#      —— v4/v6 同时关闭；不影响已有 TCP 连接；Go listener 自动回落普通 TCP。
#      注意：运行中的 Go 进程已声明 MPTCP 的 listener 不会因 sysctl 改变而
#      自动重声明，但 listener 已存在 socket 保持工作，新连接走 TCP 正常路径。
#      彻底让 Go 进程不再声明 MPTCP 需重启该进程（可选 --restart-services）。
#   2.（可选，--with-nft）新增独立 nft 表 inet cve_2026_98432 丢弃带 IPv4 options
#      的入站 TCP 包。Ubuntu 官方缓解规则原样采用：
#        ip protocol tcp ip hdrlength > 5 counter drop
#      严格遵守 vpsetup 不变式：
#        - 运行时只 nft -f 自己的文件，永不执行整份 /etc/nftables.conf
#        - 不碰 rules.v6 / ip6 filter（v6 由 sysctl 层统一关闭 MPTCP）
#        - 独立表，不动 ip filter / inet filter / netbird / hysteria_nat
#      持久化：写 /etc/nftables.d-cve/cve_2026_98432.nft，并在 /etc/nftables.conf
#      末尾追加一行 include（若尚无）。**注意**：仅当用户明确 --with-nft 才做。
#
# 用法:
#   ./harden-mptcp.sh [user@]host[:port] ... [--apply] [--with-nft]
#   ./harden-mptcp.sh --local [--apply] [--with-nft]
#   不加 --apply 时默认 dry-run（只检查并打印将要执行的改动，不实际修改）
#
# 退出码: 0=全部成功 / 1=至少一台失败

set -uo pipefail

DRY_RUN=1
LOCAL_MODE=0
WITH_NFT=0
HOSTS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)    DRY_RUN=0 ;;
        --dry-run)  DRY_RUN=1 ;;
        --local)    LOCAL_MODE=1 ;;
        --with-nft) WITH_NFT=1 ;;
        -h|--help)  sed -n '2,33p' "$0"; exit 0 ;;
        *)          HOSTS+=("$1") ;;
    esac
    shift
done

if [ "$LOCAL_MODE" -eq 0 ] && [ ${#HOSTS[@]} -eq 0 ]; then
    echo "错误: 请指定至少一台主机，或使用 --local 在本机运行" >&2
    echo "用法: $0 [user@]host[:port] ... [--apply] [--with-nft]" >&2
    exit 2
fi

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

# 下面这段是【远端脚本原文】，单引号有意保留：本机不展开，原样喂给远端 bash。
# shellcheck disable=SC2016
REMOTE_SCRIPT='
set -uo pipefail

CHANGED=0
echo "  主机: $(hostname) | 内核: $(uname -r) | 系统: $(. /etc/os-release && echo "$PRETTY_NAME")"
if [ "$DRY_RUN" = "1" ]; then
    echo "  ── dry-run：以下为检查结果与将要执行的改动 ──"
fi

# ═══ 1. MPTCP sysctl ═══
echo
echo "  ── 1. net.mptcp.enabled ──"
cur=$(sysctl -n net.mptcp.enabled 2>/dev/null || echo "unsupported")
if [ "$cur" = "unsupported" ]; then
    echo "     ○ 内核不支持 MPTCP（< 5.6），无需处理"
elif [ "$cur" = "0" ]; then
    echo "     ○ 已为 0"
else
    if [ "$DRY_RUN" = "1" ]; then
        echo "     + [dry-run] 将 sysctl -w net.mptcp.enabled=0 (当前 $cur) 并持久化"
    else
        sysctl -w net.mptcp.enabled=0 >/dev/null
        CHANGED=$((CHANGED + 1))
        echo "     ✅ 已设置 net.mptcp.enabled=0"
    fi
fi

# 持久化文件
SYSCTL_F=/etc/sysctl.d/99-mptcp-disable.conf
EXPECTED_SYSCTL="# CVE-2026-98432 mitigation: disable MPTCP globally
net.mptcp.enabled = 0"
cur_sysctl=""
[ -f "$SYSCTL_F" ] && cur_sysctl=$(cat "$SYSCTL_F")
if [ "$cur_sysctl" = "$EXPECTED_SYSCTL" ]; then
    echo "     ○ 持久化文件已就绪: $SYSCTL_F"
else
    if [ "$DRY_RUN" = "1" ]; then
        echo "     + [dry-run] 将写入 $SYSCTL_F"
    else
        printf "%s\n" "$EXPECTED_SYSCTL" > "$SYSCTL_F"
        chmod 644 "$SYSCTL_F"
        echo "     ✅ 已写入 $SYSCTL_F"
        CHANGED=$((CHANGED + 1))
    fi
fi

# ═══ 2. 当前受影响 listener 报告（只读） ═══
echo
echo "  ── 2. Go listener 声明 MPTCP 状态（只读审计） ──"
# /proc/net/protocols 里 MPTCP 的 size 字段非零表示有 socket 使用
# 注：REMOTE_SCRIPT 整体是单引号 heredoc，awk 程序用双引号+反斜杠转义 $ 即可
mptcp_inuse=$(awk "\$1==\"MPTCP\" {print \$3}" /proc/net/protocols 2>/dev/null || echo "?")
echo "     /proc/net/protocols MPTCP in-use: $mptcp_inuse"
# 列出带 MPTCP 的监听 socket（ss -M 需要内核支持 INET_MPTCP_DIAG）
mptcp_listeners=$(ss -M -ltn 2>/dev/null | tail -n +2 | wc -l)
echo "     ss -M 监听中的 MPTCP socket 数: $mptcp_listeners"
# 主要 Go 服务版本
for bin in /usr/local/bin/xray /usr/bin/caddy /usr/bin/hysteria /usr/local/bin/hysteria /usr/bin/frps; do
    if [ -x "$bin" ]; then
        gostr=$(strings "$bin" 2>/dev/null | grep -oE "^go1\.[0-9]+(\.[0-9]+)?" | head -1)
        echo "     $bin: ${gostr:-unknown}"
    fi
done

# ═══ 3. 可选 nft 丢 IPv4 options ═══
if [ "$WITH_NFT" = "1" ]; then
    echo
    echo "  ── 3. nft 丢 IPv4 options（独立表 inet cve_2026_98432） ──"
    NFT_DIR=/etc/nftables.d-cve
    NFT_F=$NFT_DIR/cve_2026_98432.nft
    NFT_CONTENT="table inet cve_2026_98432 {
  chain input {
    type filter hook input priority -310; policy accept;
    ip protocol tcp ip hdrlength > 5 counter drop
  }
}"
    cur_nft=""
    [ -f "$NFT_F" ] && cur_nft=$(cat "$NFT_F")
    if [ "$cur_nft" = "$NFT_CONTENT" ]; then
        echo "     ○ nft 文件已就绪: $NFT_F"
    else
        if [ "$DRY_RUN" = "1" ]; then
            echo "     + [dry-run] 将写入 $NFT_F 并 nft -f 加载"
        else
            mkdir -p "$NFT_DIR"
            printf "%s\n" "$NFT_CONTENT" > "$NFT_F"
            chmod 644 "$NFT_F"
            # 校验语法再加载（nft -c = check only）
            if nft -c -f "$NFT_F" >/dev/null 2>&1; then
                nft -f "$NFT_F"
                echo "     ✅ 已加载 nft 表 inet cve_2026_98432"
                CHANGED=$((CHANGED + 1))
            else
                echo "     ❌ nft 语法校验失败，未加载"
                exit 1
            fi
        fi
    fi
    # 持久化：在 /etc/nftables.conf 末尾加 include（幂等）
    if [ -f /etc/nftables.conf ]; then
        if grep -qF "include \"$NFT_F\"" /etc/nftables.conf; then
            echo "     ○ /etc/nftables.conf 已含 include 行"
        else
            if [ "$DRY_RUN" = "1" ]; then
                echo "     + [dry-run] 将在 /etc/nftables.conf 末尾追加 include \"$NFT_F\""
            else
                cp /etc/nftables.conf /etc/nftables.conf.bak-$(date +%Y%m%d-%H%M%S)
                printf "\n# CVE-2026-98432 mitigation\ninclude \"%s\"\n" "$NFT_F" >> /etc/nftables.conf
                echo "     ✅ 已追加 include 行到 /etc/nftables.conf"
                CHANGED=$((CHANGED + 1))
            fi
        fi
    else
        echo "     ⚠️  /etc/nftables.conf 不存在（该系统可能用 iptables-persistent 而非 nftables 持久化）"
        echo "        运行时规则已加载，但重启后丢失——请确认 nftables.service 是否 enabled"
    fi
fi

echo
if [ "$DRY_RUN" = "1" ]; then
    echo "  ℹ️  dry-run 结束，未做任何改动"
elif [ "$CHANGED" -gt 0 ]; then
    echo "  ✅ 共 $CHANGED 项改动已应用"
else
    echo "  ○ 无改动"
fi
'

if [ "$LOCAL_MODE" -eq 1 ]; then
    echo "════════ local ($(hostname)) ════════"
    {
        printf 'DRY_RUN=%q\nWITH_NFT=%q\n' "$DRY_RUN" "$WITH_NFT"
        printf '%s\n' "$REMOTE_SCRIPT"
    } | sudo -n bash -s
    exit $?
fi

rc_all=0
for target in "${HOSTS[@]}"; do
    tgt="$target"; tgt_opts=()
    case "$tgt" in
        *:*)
            port="${tgt##*:}"
            tgt="${tgt%:*}"
            tgt_opts=(-p "$port")
            ;;
    esac
    echo "════════ $tgt ${tgt_opts[*]:-} ════════"
    {
        printf 'DRY_RUN=%q\nWITH_NFT=%q\n' "$DRY_RUN" "$WITH_NFT"
        printf '%s\n' "$REMOTE_SCRIPT"
    } | ssh "${SSH_OPTS[@]}" "${tgt_opts[@]}" "$tgt" 'sudo -n bash -s' || rc_all=1
    echo
done

exit "$rc_all"
