#!/usr/bin/env bash
#
# init-iptables.sh — 把 JP 旧主机的 iptables 放行规则迁移到新主机（v4 + v6 对称）
#
# 用法: ./init-iptables.sh [user@]host ... [--apply]
#   不加 --apply 时默认 dry-run（只打印，不改动）
#
# ─── 实测依据（2026-08-29 对比 4 台主机得出）─────────────────────────────────
#   对比对象：JP 两台 Ubuntu 22.04（oraclejp / oraclejp-2，均为 iptables 1.8.4）
#             UK 两台 Ubuntu 24.04（uk-x86-1 / uk-x86-2，iptables 1.8.7）
#   同区域两台配置完全一致，故只需一套规则。
#
#   1. rules.v4 的 Oracle 默认骨架两边完全相同：InstanceServices 链整条
#      （169.254.0.0/16 那批 15 条，含 169.254.0.2/32、169.254.169.254/32 等）、
#      OUTPUT 跳转、FORWARD/INPUT 的 REJECT 收尾。这部分原样保留，不复制。
#      唯一差异：UK 的写法少了冗余的 "-m udp"，语义等价。
#
#   2. 差异全部集中在 INPUT 链：JP 比 UK 多 7 条放行规则，均为纯端口匹配，
#      无一条绑定 v4 私有地址 → 可 1:1 翻译到 v6。
#
#   3. rules.v6 在 4 台上都只是空表头（三链 ACCEPT + COMMIT，零条规则）。
#      JP 内核里那 7 条 ip6tables 规则经查全是 Docker 自建链（DOCKER-FORWARD /
#      DOCKER-BRIDGE / DOCKER-CT 等），由 Docker 自行管理，不属于迁移范围，
#      写入持久化文件会与 Docker 争抢规则 → 本脚本只操作 filter 表 INPUT/FORWARD。
#
#   4. 结构约束：默认策略是 ACCEPT，靠链尾一条 "-A INPUT -j REJECT" 兜底。
#      因此放行规则必须插在 REJECT 之前（-I <行号> 而非 -A），否则永不生效。
#
# ─── v6 与 v4 的关键差异（必须特殊处理）─────────────────────────────────────
#   IPv6 的 ICMPv6 不是可选项：它承担邻居发现（等价 IPv4 的 ARP）、PMTUD、
#   SLAAC 地址重复检测（DAD）。若照抄 v4 的 "-p icmp" 并加上 REJECT 兜底，
#   可能让 DAD 失败、IPv6 连通性整体中断。故 v6 用 "ipv6-icmp" 显式全放行。
#   REJECT 类型也不同：v4 用 icmp-host-prohibited，v6 用 icmp6-adm-prohibited。
#
# ─── 安全措施 ───────────────────────────────────────────────────────────────
#   - 幂等：iptables -C 已存在则跳过，可重复执行
#   - 防 SSH 锁死：持久化前校验 22 端口在放行列表内，否则拒绝保存
#   - 先全量就位再 netfilter-persistent save，避免半成品被持久化

set -uo pipefail

DRY_RUN=1
HOSTS=()
for arg in "$@"; do
    case "$arg" in
        --apply)   DRY_RUN=0 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
        *)         HOSTS+=("$arg") ;;
    esac
done

if [ ${#HOSTS[@]} -eq 0 ]; then
    echo "错误: 请指定至少一台主机" >&2
    echo "用法: $0 [user@]host ... [--apply]" >&2
    exit 2
fi

# JP 有而 UK 默认没有的 7 条端口放行规则（纯端口匹配，v4/v6 通用）
# 注意：22 端口不在此列——它属于基础骨架，UK 的 v4 已有，v6 由 BASE_V6 补上
PORTS=(
    "-p udp -m udp --sport 123"
    "-p udp -m udp --dport 443"
    "-p udp -m udp --dport 8443"
    "-p udp -m udp --dport 9993:65535"
    "-p tcp -m state --state NEW -m tcp --dport 9993:65535"
    "-p tcp -m state --state NEW -m tcp --dport 443"
    "-p tcp -m state --state NEW -m tcp --dport 80"
)

# v6 需要补建的基础骨架（UK 的 v4 已有等价物，v6 完全没有）
BASE_V6=(
    "-m state --state RELATED,ESTABLISHED"
    "-p ipv6-icmp"
    "-i lo"
    "-p tcp -m state --state NEW -m tcp --dport 22"
)

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)

# 远端主体。规则数组以 declare -p 序列化后随脚本一同从 stdin 注入，
# 规避 ssh 嵌套引号问题（曾因嵌套单引号破坏 python 的 ['data'] 取值）。
REMOTE_SCRIPT='
set -uo pipefail
DRY_RUN="'"$DRY_RUN"'"
CHANGED=0

echo "  系统: $(. /etc/os-release && echo "$PRETTY_NAME")"

if ! command -v netfilter-persistent >/dev/null 2>&1; then
    echo "  ❌ 未安装 netfilter-persistent，中止（规则无法持久化）"
    exit 1
fi

# 在指定链中确保一批 ACCEPT 规则就位，且位于 REJECT 兜底之前
ensure_accepts() {
    local cmd="$1"; shift
    local rules=("$@")
    local reject_line
    reject_line=$($cmd -L INPUT --line-numbers -n 2>/dev/null | grep "REJECT" | head -1 | awk "{print \$1}")

    for args in "${rules[@]}"; do
        # 幂等检查：-C 存在时 rc=0
        if $cmd -C INPUT $args -j ACCEPT 2>/dev/null; then
            echo "     ○ 已存在: $args"
            continue
        fi
        if [ "$DRY_RUN" = "1" ]; then
            if [ -n "$reject_line" ]; then
                echo "     + [dry-run] 插入到 REJECT 前(第 $reject_line 行): $args"
            else
                echo "     + [dry-run] 追加: $args"
            fi
            continue
        fi
        if [ -n "$reject_line" ]; then
            $cmd -I INPUT "$reject_line" $args -j ACCEPT \
                || { echo "     ❌ 添加失败: $args"; return 1; }
            echo "     ✅ 插入 REJECT 前(第 $reject_line 行): $args"
        else
            $cmd -A INPUT $args -j ACCEPT \
                || { echo "     ❌ 添加失败: $args"; return 1; }
            echo "     ✅ 追加: $args"
        fi
        CHANGED=$((CHANGED + 1))
    done
    return 0
}

# 确保链尾 REJECT 兜底存在（v6 原本没有，需要补建）
ensure_reject_tail() {
    local cmd="$1" chain="$2" rtype="$3"
    if $cmd -C "$chain" -j REJECT --reject-with "$rtype" 2>/dev/null; then
        echo "     ○ 已存在 REJECT 兜底 ($chain --reject-with $rtype)"
        return 0
    fi
    if [ "$DRY_RUN" = "1" ]; then
        echo "     + [dry-run] 将补建 REJECT 兜底: $chain --reject-with $rtype"
        return 0
    fi
    $cmd -A "$chain" -j REJECT --reject-with "$rtype" \
        || { echo "     ❌ 补建 REJECT 失败 ($chain)"; return 1; }
    echo "     ✅ 已补建 REJECT 兜底: $chain --reject-with $rtype"
    CHANGED=$((CHANGED + 1))
}

if [ "$DRY_RUN" = "1" ]; then
    echo "  ── dry-run：以下为将要执行的改动 ──"
fi

echo
echo "  ── IPv4 (iptables) ──"
echo "  说明: v4 基础骨架与 InstanceServices 链已由 Oracle 镜像提供，仅补 JP 的端口规则"
ensure_accepts iptables "${PORTS[@]}" || exit 1

echo
echo "  ── IPv6 (ip6tables) ──"
echo "  说明: v6 原本无任何规则（完全放行），需补建基础骨架 + 端口规则 + REJECT 兜底"
ensure_accepts ip6tables "${BASE_V6[@]}" "${PORTS[@]}" || exit 1
echo "  ── v6 REJECT 兜底 ──"
# INPUT 的兜底必须在放行规则全部就位之后补建，否则后加的放行规则会被它挡在后面。
# 缺了它，上面 11 条 ACCEPT 形同虚设：policy 是 ACCEPT，等于 v6 仍然全放行。
# （首版漏了 INPUT 只补了 FORWARD，导致 v6 规则看似添加成功实则无效。）
ensure_reject_tail ip6tables INPUT icmp6-adm-prohibited || exit 1
ensure_reject_tail ip6tables FORWARD icmp6-adm-prohibited || exit 1

if [ "$DRY_RUN" = "1" ]; then
    echo
    echo "  ℹ️  dry-run 结束，未做任何改动。确认无误后加 --apply 实际执行。"
    echo "     注意: v6 补建 REJECT 兜底是行为变更（此前 v6 完全放行）。"
    echo "     ICMPv6 已显式全放行以避免中断邻居发现/PMTUD/SLAAC。"
    exit 0
fi

# 持久化前的安全闸门：22 必须在放行列表内，两栈都要
echo
echo "  ── 持久化前校验 ──"
for c in iptables ip6tables; do
    if $c -C INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT 2>/dev/null; then
        echo "     ✅ $c: 22 端口已放行"
    else
        echo "     ❌ $c: 22 端口未在放行列表 → 拒绝持久化，避免锁死 SSH"
        exit 1
    fi
done

if [ "$CHANGED" -eq 0 ]; then
    echo "  ○ 无改动，跳过持久化"
    exit 0
fi

if netfilter-persistent save 2>&1 | sed "s/^/     /"; then
    echo "  ✅ 已持久化到 /etc/iptables/rules.v4 与 rules.v6"
else
    echo "  ❌ 持久化失败（内核规则已生效，但重启后会丢失）"
    exit 1
fi
'

rc_all=0
for target in "${HOSTS[@]}"; do
    echo "════════ $target ════════"
    if ! ssh "${SSH_OPTS[@]}" "$target" 'true' 2>/dev/null; then
        echo "  ❌ 无法连接（密钥未授权或主机不可达），跳过"
        rc_all=1
        continue
    fi

    {
        declare -p PORTS BASE_V6
        printf '%s\n' "$REMOTE_SCRIPT"
    } | ssh "${SSH_OPTS[@]}" "$target" 'sudo -n bash -s' || rc_all=1
    echo
done

exit "$rc_all"
