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
#   可能让 DAD 失败、IPv6 连通性整体中断。
#
#   按 RFC 4890（Recommendations for Filtering ICMPv6 Messages in Firewalls）
#   §4.4.1「Traffic That Must Not Be Dropped」逐 type 放行，而非放行整个
#   icmpv6 —— 后者可行但偏松，RFC 明确建议精细化。见下方 ICMPV6_TYPES 注释。
#   未列入的 type（如 Redirect 137）按 RFC §4.4.4「应明确定义策略」丢弃。
#
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
    "-i lo"
    "-p tcp -m state --state NEW -m tcp --dport 22"
)

# ICMPv6 按 RFC 4890 §4.4.1「必须放行」清单逐 type 放行，而非放行整个 icmpv6。
# 这些 type 承载 IPv6 的基础功能，缺一个都可能造成难以诊断的间歇性故障：
#   1    Destination Unreachable  —— 全 code
#   2    Packet Too Big           —— PMTUD，丢了大包连接会静默卡死
#   3    Time Exceeded            —— code 0（traceroute）
#   4    Parameter Problem        —— code 1/2
#   128/129 Echo Request/Reply    —— ping
#   133/134 Router Solicitation/Advertisement —— SLAAC，无 RA 就拿不到默认路由
#   135/136 Neighbor Solicitation/Advertisement —— 等价 IPv4 的 ARP，且用于
#                                   DAD 重复地址检测；被拦会导致地址配置失败
#   130/131/132/143 MLD           —— 组播监听发现
#   141/142 Inverse ND            —— 反查 IPv6 地址对应链路层地址（RFC 3122）
#
# ⚠️ 名称必须逐个实测：RFC 用的是描述性称呼，与 iptables 接受的名字并不一致。
#    在目标机（ip6tables 1.8.10）实测的对照：
#      listener-query/listener-report/listener-done  →  iptables 不认识，
#          正确名是 mld-listener-query / mld-listener-report / mld-listener-done
#      mld2-listener-report (type 143)  →  不被接受
#      ind-neighbor-solicitation / ind-neighbor-advertisement (141/142)
#          完全没有对应名称 → 只能用数字 type（iptables 支持 "141" 这种写法）
#      neigh-solicitation（缩写）也不被接受，必须是 neighbour-solicitation
#
# ⚠️ mld-listener-reduction 是 132 的别名，不是 143！它和 mld-listener-done
#    写入内核后是同一条规则（实测 -S 显示都是 --icmpv6-type 132）。
#    首版把它当成 143 写进数组，结果 143 从未被放行，而 132 重复了一遍。
#    type 143（MLDv2 Report）iptables 没有名字，只能用数字。
#    教训：别从名称推断 type 号，要用 ip6tables -S 看写进去的号。
#
#    首版直接照 RFC 描述取名，16 个里错了 6 个；错误名会让 ip6tables 整条规则
#    加载失败（"Unknown ICMPv6 type"），若发生在持久化文件里，重启后
#    netfilter-persistent restore 会失败 → 整机防火墙起不来。
#    本文件里的名称已全部在目标机逐个验证通过。
#
# 未列入的 type（如 Redirect 137）按 RFC §4.4.4「应明确定义策略」处理，此处丢弃。
ICMPV6_TYPES=(
    "destination-unreachable"
    "packet-too-big"
    "time-exceeded"
    "parameter-problem"
    "echo-request"
    "echo-reply"
    "router-solicitation"
    "router-advertisement"
    "neighbour-solicitation"
    "neighbour-advertisement"
    "mld-listener-query"
    "mld-listener-report"
    "mld-listener-done"
    "143"
    "141"
    "142"
)

# 本机前置自检：逐个验证 ICMPv6 type 名合法。
# 放进持久化文件的非法 type 名会让 netfilter-persistent restore 在重启时整体失败，
# 等于开机后防火墙完全起不来 —— 必须在执行前拦下，不能等到重启才发现。
# 用一次性的临时链做校验，不触碰 INPUT/FORWARD。
# 参数: $1=目标主机, 其余=待校验的 type 名；输出里出现 BAD 即视为不合法。
validate_icmpv6_types() {
    local target="$1"; shift
    # 通过 ssh 的位置参数传 type 名（ssh 会把它们拼成远端命令的参数），
    # 远端脚本再从 "$@" 读取。不能用管道传 stdin：远端脚本本体已占用 stdin，
    # 两者会互相覆盖（首版就是这样，导致校验拿到空列表、错误名全部漏网）。
    ssh "${SSH_OPTS[@]}" "$target" 'bash -s "$@"' _ "$@" 2>&1 <<'VALIDATE'
shift   # 丢掉占位的 _
TESTCHAIN=ip6t_validate_$$
if ! sudo -n ip6tables -N "$TESTCHAIN" 2>/dev/null; then
    echo "FAIL 无法创建临时链（sudo 免密是否可用？）"
    exit 1
fi
for t in "$@"; do
    out=$(sudo -n ip6tables -A "$TESTCHAIN" -p ipv6-icmp --icmpv6-type "$t" -j ACCEPT 2>&1)
    [ -n "$out" ] && echo "BAD $t -> $out"
done
# 回读内核里实际写进去的 type 号，暴露「名称是别名、号不是我以为的那个」这类问题。
# 例：mld-listener-reduction 写进去是 132（与 mld-listener-done 同号），
#     曾因此漏放行 143。名字合法不等于号对，必须回读确认。
actual=$(sudo -n ip6tables -S "$TESTCHAIN" 2>/dev/null | grep -oE 'icmpv6-type [0-9]+' | awk '{print $2}' | sort -n | uniq | tr '\n' ' ')
echo "RESOLVED $actual"
sudo -n ip6tables -F "$TESTCHAIN" 2>/dev/null
sudo -n ip6tables -X "$TESTCHAIN" 2>/dev/null
VALIDATE
}

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

# 移除「放行整个 icmpv6」的过宽规则（早期版本留下来的）。
# 精确规则必须在它之前就位后再删，否则中间会出现 ICMPv6 全断的窗口。
drop_broad_icmpv6() {
    local cmd="ip6tables" ln=""
    # 必须用 -S（完整规则文本）而不是 -L 来找。
    # -L 的精简输出里，"-p ipv6-icmp -j ACCEPT" 和
    # "-p ipv6-icmp --icmpv6-type 1 -j ACCEPT" 都显示为 "ACCEPT 58"，无法区分。
    # 首版用 -L 匹配行号，结果误删了 --icmpv6-type 1（Destination Unreachable），
    # 而它恰恰是 RFC 4890 要求必须放行的第一个 type —— 删掉后 PMTUD/路径不可达
    # 反馈全部丢失，会表现为「大文件传一半卡住」这类极难定位的故障。
    # 判据：规则文本含 "-p ipv6-icmp" 且含 ACCEPT，但不含 "--icmpv6-type"。
    #
    # 用 while read 逐行处理而非 $(...) 管道：本函数体最终会被嵌入远端 heredoc，
    # 而 $( ) 在 heredoc 定义时就会被本地 shell 展开（曾导致整段变成
    # "command not found"）。while read 里的变量展开发生在远端，不受影响。
    local idx=0 line
    while IFS= read -r line; do
        idx=$((idx + 1))
        case "$line" in
            *"-p ipv6-icmp"*) ;;
            *) continue ;;
        esac
        case "$line" in
            *ACCEPT*) ;;
            *) continue ;;
        esac
        case "$line" in
            *"--icmpv6-type"*) continue ;;
        esac
        ln=$idx
        break
    done < <($cmd -S INPUT 2>/dev/null)
    if [ -z "$ln" ]; then
        echo "     ○ 无过宽的 -p ipv6-icmp 规则，跳过"
        return 0
    fi
    if [ "$DRY_RUN" = "1" ]; then
        echo "     + [dry-run] 将移除第 $ln 条（-S 输出中）过宽规则: -p ipv6-icmp -j ACCEPT"
        return 0
    fi
    $cmd -D INPUT "$ln" || { echo "     ❌ 移除第 $ln 条失败"; return 1; }
    echo "     ✅ 已移除过宽规则：原为 -p ipv6-icmp 全放行（无 type 限定）"
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
echo "  说明: v6 原本无任何规则（完全放行），需补建基础骨架 + ICMPv6 + 端口规则 + REJECT 兜底"
ensure_accepts ip6tables "${BASE_V6[@]}" || exit 1
echo "  ── ICMPv6（按 RFC 4890 §4.4.1 逐 type 放行）──"
for t in "${ICMPV6_TYPES[@]}"; do
    ensure_accepts ip6tables "-p ipv6-icmp --icmpv6-type $t" || exit 1
done
echo "  ── v6 端口规则 ──"
ensure_accepts ip6tables "${PORTS[@]}" || exit 1
echo "  ── 收紧 ICMPv6（移除过宽的全放行规则）──"
# 必须放在精细 type 规则之后：先有精确规则，再删宽泛规则，避免中间断网窗口
drop_broad_icmpv6 || exit 1
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
    echo "     ICMPv6 已按 RFC 4890 §4.4.1 逐 type 放行，覆盖邻居发现/PMTUD/SLAAC。"
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

    # 前置自检：ICMPv6 type 名必须全部合法。非法名一旦写入持久化文件，
    # 重启时 restore 会整体失败 → 防火墙完全起不来，属于必须提前拦下的故障。
    echo "  ── ICMPv6 type 名自检 ──"
    vout=$(validate_icmpv6_types "$target" "${ICMPV6_TYPES[@]}")
    if printf '%s' "$vout" | grep -q "BAD\|FAIL"; then
        echo "  ❌ 存在不被本机 ip6tables 接受的 type 名，中止："
        printf '%s\n' "$vout" | grep -E "BAD|FAIL" | sed 's/^/     /'
        echo "     （请对照 iptables 接受的名称修正 ICMPV6_TYPES）"
        rc_all=1
        continue
    fi
    resolved=$(printf '%s' "$vout" | sed -n 's/^RESOLVED //p')
    n_names=${#ICMPV6_TYPES[@]}
    n_types=$(printf '%s' "$resolved" | wc -w)
    echo "     ✅ $n_names 个 type 名全部有效，解析出 $n_types 个不同的 ICMPv6 type 号:"
    echo "        $resolved"
    # 名称数 ≠ type 号数，说明有别名指向了同一个号（如 mld-listener-reduction
    # 与 mld-listener-done 都是 132），意味着某个目标 type 实际没被放行。
    if [ "$n_types" -ne "$n_names" ]; then
        echo "     ⚠️  名称数与 type 号数不符 → 存在别名重复，可能漏放行某个 type，请核对"
    fi

    {
        declare -p PORTS BASE_V6 ICMPV6_TYPES
        printf '%s\n' "$REMOTE_SCRIPT"
    } | ssh "${SSH_OPTS[@]}" "$target" 'sudo -n bash -s' || rc_all=1
    echo
done

exit "$rc_all"
