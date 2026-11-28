#!/usr/bin/env bash
#
# setup-podman.sh — Oracle Ubuntu 24.04+ Podman 容器环境标准化脚本（严格前置校验 + 幂等）
#
# 用法:
#   ./setup-podman.sh [user@]host ... [--apply] [-J jump_host]
#   ./setup-podman.sh --local [--apply]
#   不加 --apply 时默认 dry-run（只检查并打印将要执行的改动，不实际修改）
#
# ─── 设计原则：脏状态一律先报错中止（Fail-fast），绝不盲目自动拼接/篡改 ──────
#   前置安全闸门（任一不满足即报错退出，不修改任何配置）：
#     1. Docker 必须已彻底卸载，且内核运行态中无任何 DOCKER* 链或 :FORWARD DROP 策略
#        （若刚卸载 Docker 尚未重启，内核中仍会有残留链，必须先 reboot 清空）。
#     2. /etc/iptables/rules.v4 与 rules.v6 持久化文件必须纯净：
#        不得包含 *raw、*nat、DOCKER、NETAVARK 或 :FORWARD DROP 等误执行
#        netfilter-persistent save 固化进去的动态表/脏规则。若发现污染，打印具体
#        污染行并报错退出，由人工核对清理，绝不在脏文件上强行修改。
#     3. /etc/iptables/rules.v4 与 rules.v6 必须已完成基础骨架初始化（含 22 端口放行与
#        INPUT/FORWARD 的 REJECT 兜底，即已执行过 init-iptables.sh）。
#
#   前置校验通过后执行的标准化项：
#     1. 安装最小容器包集合: podman + crun + podman-compose（启用 podman.socket）
#     2. 写入 /etc/systemd/system/podman-restart.service.d/override.conf
#        同时过滤 --filter restart-policy=always 与 unless-stopped（修复 Podman 4.9.3 Bug #28152）
#     3. 在 v4 与 v6 防火墙的 REJECT 兜底前对称补齐 3 条 Podman 规则（live + 静态文件）：
#        -A INPUT -i podman+ -p udp -m udp --dport 53 -j ACCEPT   (netavark 1.4.0 Issue #742 容器 DNS)
#        -A INPUT -i podman+ -p tcp -m tcp --dport 53 -j ACCEPT
#        -A FORWARD -o podman+ -j ACCEPT                          (容器端口映射 DNAT 入站放行)
#        注意：直接精确写入静态文件并注入 live 内核，绝不调用会把 NETAVARK 动态 nat 表
#        一并存盘的 netfilter-persistent save！
#     4. 部署零依赖 /usr/bin/rpm 内存缓存垫片（将 libpod/version 与 info 耗时从 4.2s 降至 0.2s）

set -uo pipefail

DRY_RUN=1
LOCAL_MODE=0
JUMP_HOST=""
HOSTS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)   DRY_RUN=0 ;;
        --dry-run) DRY_RUN=1 ;;
        --local)   LOCAL_MODE=1 ;;
        -J)        shift; JUMP_HOST="${1:-}" ;;
        -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
        *)         HOSTS+=("$1") ;;
    esac
    shift
done

if [ "$LOCAL_MODE" -eq 0 ] && [ ${#HOSTS[@]} -eq 0 ]; then
    echo "错误: 请指定至少一台主机，或使用 --local 在本机运行" >&2
    echo "用法: $0 [user@]host ... [--apply] [-J jump_host]" >&2
    exit 2
fi

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
if [ -n "$JUMP_HOST" ]; then
    SSH_OPTS+=(-o "ProxyCommand=ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -W %h:%p $JUMP_HOST")
fi

REMOTE_SCRIPT='
set -uo pipefail

echo "  系统: $(lsb_release -ds 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d\" -f2)"
if [ "$DRY_RUN" = "1" ]; then
    echo "  ── dry-run：以下为检查结果与将要执行的改动 ──"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 阶段 0：前置安全闸门（Preflight Gate）—— 发现任何脏状态立即报错退出
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "  ── 0. 前置安全闸门校验 (Docker 残留 / 持久化文件纯净度 / 基础骨架) ──"
PREFLIGHT_FAIL=0

# 0.0 两个正交维度（不要合成一个标志位）
#
# 维度 A：NETAVARK_FW —— 本次装上/已装的 netavark 用哪套防火墙驱动
#   决定 podman 起容器时规则写进 nft，还是写进 iptables(-nft 兼容层)
#   取值：nft / iptables
#
# 维度 B：HOST_FW —— 本机主机防火墙（dsh_firewall）的形态
#   决定要不要检查 /etc/iptables/rules.v4 与 rules.v6
#   取值：nft-only（已收敛）/ iptables-persistent（旧形态）
#
# 为什么必须正交：
#   旧版把两者 OR 成一个 NFT_MODE，于是「26.04 已收敛、但还没装 podman」
#   （netavark 未装 → 版本判成 <1.16）会被误判成 iptables 世代，再被
#   自己的高危拦截挡住，提示语还叫一台 26.04 去「先升级到 26.04」。
#   两个维度各自取值后，这类组合才能被正确表达。

# ── 维度 A：netavark 的防火墙驱动 ──
# 版本来源优先级：
#   1. 已装版本（dpkg-query，且必须 install ok installed，排除 rc 残留）
#   2. apt 候选版本（还没装时预判将要装的是什么）
#   3. 都拿不到 → 用 /etc/os-release 的 VERSION_ID 兜底（26.04+ 视为 nft）
NETAVARK_VER=""
NETAVARK_SRC=""
if dpkg-query -W -f='\''${Status}'\'' netavark 2>/dev/null | grep -q "install ok installed"; then
    NETAVARK_VER=$(dpkg-query -W -f='\''${Version}'\'' netavark 2>/dev/null | sed -E '\''s/^[0-9]+://; s/-[^-]*$//'\'' || true)
    NETAVARK_SRC="已装"
else
    NETAVARK_VER=$(apt-cache policy netavark 2>/dev/null | awk '\''$1=="Candidate:"{print $2}'\'' | sed -E '\''s/^[0-9]+://; s/-[^-]*$//'\'' || true)
    [ "$NETAVARK_VER" = "(none)" ] && NETAVARK_VER=""
    NETAVARK_SRC="apt 候选"
fi

NETAVARK_FW=""
if [ -n "$NETAVARK_VER" ] && command -v dpkg >/dev/null 2>&1; then
    # 用 dpkg 自己比版本，别手写解析（1.16~rc1 / 1.16.1+ds1 / 1:1.16.1 都能正确处理）
    if dpkg --compare-versions "$NETAVARK_VER" ge "1.16" 2>/dev/null; then
        NETAVARK_FW="nft"
    else
        NETAVARK_FW="iptables"
    fi
fi
if [ -z "$NETAVARK_FW" ]; then
    _osv=$(sed -n '\''s/^VERSION_ID="\{0,1\}\([0-9.]*\)"\{0,1\}$/\1/p'\'' /etc/os-release 2>/dev/null | head -1)
    case "$_osv" in
        26.04|2[7-9].[0-9]*|[3-9][0-9].[0-9]*)
            NETAVARK_FW="nft"; NETAVARK_VER="未知（按 OS ${_osv} 推断）"; NETAVARK_SRC="OS 版本兜底" ;;
        *)
            NETAVARK_FW="iptables"; NETAVARK_VER="${NETAVARK_VER:-未知}"; NETAVARK_SRC="${NETAVARK_SRC:-OS 版本兜底}" ;;
    esac
fi

# ── 维度 B：主机防火墙形态 ──
HOST_FW="iptables-persistent"
if [ ! -f /etc/iptables/rules.v4 ] && [ ! -f /etc/iptables/rules.v6 ] && { [ -f /etc/dsh-firewall.conf ] || nft list table inet dsh_firewall >/dev/null 2>&1; }; then
    HOST_FW="nft-only"
fi

echo "     ◆ netavark 驱动: $NETAVARK_FW（版本 $NETAVARK_VER，来源 $NETAVARK_SRC）"
if [ "$NETAVARK_FW" = "nft" ]; then
    echo "       → podman 起容器时规则写进 table inet netavark"
else
    echo "       → podman 起容器时规则写进 iptables 的 NETAVARK_* 链（nft 兼容层）"
fi
echo "     ◆ 主机防火墙形态: $HOST_FW"
if [ "$HOST_FW" = "nft-only" ]; then
    echo "       → 跳过 rules.v4/v6 检查（已收敛成纯 nft）"
else
    echo "       → 检查 rules.v4/v6 纯净度与骨架"
fi

# ── 组合相容性提示（只提示，不拦截）──
#
# 三种组合都能跑，只是运维方式不同：
#   nft + nft-only                  → 理想形态（26.04）
#   iptables + iptables-persistent  → 传统形态（24.04 未收敛）
#   iptables + nft-only             → 混合形态（24.04 已收敛但 netavark 还是 1.4）
#
# 混合形态为什么能跑（2026-11-22 核实，此前误判为「端口全断」）：
#   · 24.04 的 /usr/sbin/iptables 就是 iptables-nft（实测 v1.8.10 nf_tables）
#   · netavark 1.4 调 iptables 建出来的 table ip filter / table ip nat
#     本身就是 nft 的 base chain，挂在 forward / prerouting hook 上，照样生效
#   · inet dsh_firewall 的 forward 链是 policy accept + 一条
#     iifname @wan_ifaces oifname @wan_ifaces reject（只拒公网借道转发），
#     容器出站（iif=podman*）与回程（oif=podman*）都不匹配，不会互相打架
#   → 结论：混合形态容器能通。但规则分散在两处，排障成本高，建议尽快升 26.04。
if [ "$NETAVARK_FW" = "iptables" ] && [ "$HOST_FW" = "nft-only" ]; then
    echo ""
    echo "     ⚠️ 混合形态：主机防火墙已是纯 nft，但 netavark 是 $NETAVARK_VER（< 1.16，走 iptables）"
    echo "          · 容器规则落在 iptables-nft 建出的 table ip filter / table ip nat"
    echo "          · 功能正常（已核实 24.04 的 iptables 就是 iptables-nft）"
    echo "          · 规则分散两处，排障成本高 —— 建议升级到 26.04 统一成 table inet netavark"
    echo ""
fi

# 0.1 检查 Docker 软件包或守护进程
DOCKER_PKGS=()
for pkg in docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin docker-ce-rootless-extras docker.io; do
    if dpkg-query -W -f='\''${Status}'\'' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
        DOCKER_PKGS+=("$pkg")
    fi
done
if [ ${#DOCKER_PKGS[@]} -gt 0 ] || command -v docker >/dev/null 2>&1; then
    echo "     ❌ [中止] 检测到未卸载的 Docker 组件: ${DOCKER_PKGS[*]:-docker binary}"
    echo "        请先人工停止所有 Docker 容器、卸载 Docker 并重启机器后再运行本脚本。"
    PREFLIGHT_FAIL=1
else
    echo "     ✅ Docker 软件包与命令已确认不存在"
fi

# 0.2 检查内核 live 规则是否有 DOCKER 链或 FORWARD DROP 残留
if iptables-save 2>/dev/null | grep -qE "DOCKER|:FORWARD DROP" || ip6tables-save 2>/dev/null | grep -qE "DOCKER|:FORWARD DROP"; then
    echo "     ❌ [中止] 内核运行态 iptables/ip6tables 中仍残留 DOCKER 链或 :FORWARD DROP 策略："
    iptables-save 2>/dev/null | grep -nE "DOCKER|:FORWARD DROP" | head -10 | sed "s/^/        [v4 live] /"
    ip6tables-save 2>/dev/null | grep -nE "DOCKER|:FORWARD DROP" | head -10 | sed "s/^/        [v6 live] /"
    echo "        请先清理持久化文件并重启机器以清空内核残留链。"
    PREFLIGHT_FAIL=1
else
    echo "     ✅ 内核运行态无 DOCKER 链与 :FORWARD DROP 残留"
fi

# 0.3 检查静态文件 /etc/iptables/rules.v4 与 rules.v6 是否被动态表/Docker/Netavark 污染
#
# 主机防火墙是 nft-only 时（已收敛成纯 nft）：
#   iptables-persistent 已卸、rules.v4/v6 已删，这套检查没有对象。
#   改为验证「iptables/ip6tables 里确实没有残留」，并确认 rules.v4/v6 真的不在了
#   （否则重启时 netfilter-persistent 会把 REJECT 又加载回来，等于埋个定时炸弹）。
#
# ⚠️ 必须 v4 + v6 都查：ip6 filter 里残留的 `-A FORWARD -j REJECT` 同样跨表终局。
# ⚠️ 默认策略只接受 ACCEPT：`-P INPUT DROP` 会绕过 0.2 只查 `:FORWARD DROP` 的盲点。
if [ "$HOST_FW" = "nft-only" ]; then
    if command -v iptables >/dev/null 2>&1; then
        _ipt_left=$(iptables -S 2>/dev/null | grep -vE '\''^-P (INPUT|FORWARD|OUTPUT) ACCEPT$'\'' || true)
        if [ -n "$_ipt_left" ]; then
            echo "     ❌ [中止] nft-only 主机防火墙，但 iptables(v4) 仍有非 ACCEPT 策略或残留："
            printf "%s\n" "$_ipt_left" | head -15 | sed "s/^/        /"
            echo "        预期只有 3 行 -P ... ACCEPT。先收敛（参考 vpsetup/init-firewall.sh --converge-legacy）"
            PREFLIGHT_FAIL=1
        else
            echo "     ✅ v4: iptables 仅剩 3 行 ACCEPT 默认策略，无残留"
        fi
    else
        echo "     ○ v4: 本机没有 iptables 命令（纯 nft 环境，正常）"
    fi

    if command -v ip6tables >/dev/null 2>&1; then
        _ip6_left=$(ip6tables -S 2>/dev/null | grep -vE '\''^-P (INPUT|FORWARD|OUTPUT) ACCEPT$'\'' || true)
        if [ -n "$_ip6_left" ]; then
            echo "     ❌ [中止] nft-only 主机防火墙，但 ip6tables(v6) 仍有非 ACCEPT 策略或残留："
            printf "%s\n" "$_ip6_left" | head -15 | sed "s/^/        /"
            PREFLIGHT_FAIL=1
        else
            echo "     ✅ v6: ip6tables 仅剩 3 行 ACCEPT 默认策略，无残留"
        fi
    else
        echo "     ○ v6: 本机没有 ip6tables 命令（纯 nft 环境，正常）"
    fi

    _rules_back=""
    for _f in /etc/iptables/rules.v4 /etc/iptables/rules.v6; do
        [ -f "$_f" ] && _rules_back="$_rules_back $_f"
    done
    if [ -n "$_rules_back" ]; then
        echo "     ❌ [中止] nft-only 主机防火墙，但持久化文件仍在:$_rules_back"
        echo "        重启时 netfilter-persistent 会把 REJECT 带回来。"
        echo "        请确认 netfilter-persistent 已停用并删除这两个文件（--converge-legacy 会做）。"
        PREFLIGHT_FAIL=1
    else
        echo "     ✅ 持久化文件已清除（rules.v4 / rules.v6 均不存在）"
    fi

    if ! command -v nft >/dev/null 2>&1; then
        echo "     ❌ [中止] nft-only 主机防火墙，但找不到 nft 命令（nftables 包未装？）"
        PREFLIGHT_FAIL=1
    else
        echo "     ✅ nft 命令可用"
    fi
else
for f in /etc/iptables/rules.v4 /etc/iptables/rules.v6; do
    if [ ! -f "$f" ]; then
        _other="/etc/iptables/rules.v4"
        [ "$f" = "/etc/iptables/rules.v4" ] && _other="/etc/iptables/rules.v6"
        if [ -f "$_other" ]; then
            echo "     ❌ [中止] 缺少 $f（但 $_other 存在）—— 典型的「半边收敛」状态"
            echo "        两个文件必须同时存在（iptables 形态）或同时不存在（nft-only 形态）。"
        else
            echo "     ❌ [中止] 缺少防火墙持久化文件: $f"
        fi
        PREFLIGHT_FAIL=1
        continue
    fi
    dirty_lines=$(grep -nE '\''^\*raw|^\*nat|^\*mangle|DOCKER|NETAVARK|:FORWARD DROP|-i wt0|-o wt0'\'' "$f" || true)
    if [ -n "$dirty_lines" ]; then
        echo "     ❌ [中止] $f 包含误保存的动态表/容器/隧道残留规则（拒绝自动修改脏文件）："
        printf "%s\n" "$dirty_lines" | head -15 | sed "s/^/        /"
        echo "        请先对照原始干净备份筛除上述污染行，确认只有纯净的 *filter 骨架后再重跑。"
        PREFLIGHT_FAIL=1
    else
        echo "     ✅ $f 纯净度校验通过（仅含静态 *filter 规则）"
    fi

    if ! grep -q "^-A INPUT .*--dport 22 -j ACCEPT" "$f" || \
       ! grep -q "^-A INPUT -j REJECT" "$f" || \
       ! grep -q "^-A FORWARD -j REJECT" "$f"; then
        echo "     ❌ [中止] $f 尚未完成基础防火墙骨架初始化（缺少 22 放行或 REJECT 兜底）"
        echo "        请先执行 ./init-iptables.sh <host> --apply 完成基础初始化。"
        PREFLIGHT_FAIL=1
    fi
done
fi   # ← 结束 HOST_FW 条件（0.3）


if [ "$PREFLIGHT_FAIL" -ne 0 ]; then
    echo
    echo "  🛑 前置安全闸门未通过，脚本已安全中止（未做任何改动）。"
    exit 1
fi

# ══════════════════════════════════════════════════════════════════════════════
# 阶段 1：安装最小集合 podman + crun + podman-compose 及短名镜像配置
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "  ── 1. Podman 最小组件集合 (podman + crun + podman-compose) 与短名配置 ──"
# 包清单按防火墙世代区分：
#   iptables 世代：podman + crun + podman-compose（netavark 作为依赖自动带入）
#   nft 世代：额外显式装 netavark + aardvark-dns —— 26.04 上它们是 podman 的
#             Recommends，被 --no-install-recommends 或最小化镜像裁掉时就没了，
#             缺 netavark 的 podman 起容器会报 no network backend。
if [ "$NETAVARK_FW" = "nft" ]; then
    PODMAN_PKGS="podman crun podman-compose netavark aardvark-dns"
else
    PODMAN_PKGS="podman crun podman-compose netavark"
fi
MISSING_PKGS=()
for pkg in $PODMAN_PKGS; do
    if ! dpkg-query -W -f='\''${Status}'\'' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
        MISSING_PKGS+=("$pkg")
    fi
done
if [ ${#MISSING_PKGS[@]} -eq 0 ]; then
    echo "     ○ 已安装: $(podman --version), crun, podman-compose"
else
    if [ "$DRY_RUN" = "1" ]; then
        echo "     + [dry-run] 将安装: ${MISSING_PKGS[*]}"
    else
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq "${MISSING_PKGS[@]}" >/dev/null
        systemctl enable --now podman.socket podman-restart.service >/dev/null 2>&1 || true
        echo "     ✅ 已安装: ${MISSING_PKGS[*]}"
    fi
fi

SHORTNAMES_FILE="/etc/containers/registries.conf.d/00-shortnames.conf"
EXPECTED_SHORTNAMES="unqualified-search-registries = [\"docker.io\"]
short-name-mode = \"permissive\""
cur_shortnames=""
if [ -f "$SHORTNAMES_FILE" ]; then
    cur_shortnames=$(cat "$SHORTNAMES_FILE")
fi
if [ "$cur_shortnames" = "$EXPECTED_SHORTNAMES" ]; then
    echo "     ○ 短名镜像配置已就绪: $SHORTNAMES_FILE"
else
    if [ "$DRY_RUN" = "1" ]; then
        echo "     + [dry-run] 将写入 $SHORTNAMES_FILE 并确保 /opt/arcane 与 /opt/compose-projects 存在"
    else
        mkdir -p /etc/containers/registries.conf.d /opt/arcane /opt/compose-projects
        printf "%s\n" "$EXPECTED_SHORTNAMES" > "$SHORTNAMES_FILE"
        chmod 644 "$SHORTNAMES_FILE"
        echo "     ✅ 已写入 $SHORTNAMES_FILE 并准备 /opt/arcane 与 /opt/compose-projects"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# 阶段 2：podman-restart.service override.conf (always + unless-stopped)
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "  ── 2. podman-restart.service 开机自启 drop-in (always + unless-stopped) ──"
DROPIN_DIR="/etc/systemd/system/podman-restart.service.d"
DROPIN_FILE="$DROPIN_DIR/override.conf"
EXPECTED_DROPIN="[Service]
ExecStart=
ExecStart=/usr/bin/podman \$LOGGING start --all --filter restart-policy=always --filter restart-policy=unless-stopped"

cur_dropin=""
if [ -f "$DROPIN_FILE" ]; then
    cur_dropin=$(cat "$DROPIN_FILE")
fi
if [ "$cur_dropin" = "$EXPECTED_DROPIN" ] && systemctl is-enabled podman-restart.service >/dev/null 2>&1; then
    echo "     ○ 已就绪: $DROPIN_FILE (podman-restart.service enabled)"
else
    if [ "$DRY_RUN" = "1" ]; then
        echo "     + [dry-run] 将写入 $DROPIN_FILE 并启用 podman-restart.service"
    else
        mkdir -p "$DROPIN_DIR"
        printf "%s\n" "$EXPECTED_DROPIN" > "$DROPIN_FILE"
        systemctl daemon-reload
        systemctl enable podman-restart.service >/dev/null 2>&1 || true
        echo "     ✅ 已更新 $DROPIN_FILE 并启用 podman-restart.service"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# 阶段 3：防火墙规则补齐 (v4 + v6 对称: INPUT 53/udp+tcp, FORWARD -o podman+)
# 注意：绝不调用 netfilter-persistent save（防止将运行态 NETAVARK nat 表存盘）
# ══════════════════════════════════════════════════════════════════════════════
echo
if [ "$NETAVARK_FW" = "nft" ]; then
    # ── netavark >= 1.16：podman 自建 table inet netavark，脚本不该插手 ──
    #
    # 三条链（podman 第一次起容器时生成，此时可能还没有，属正常）：
    #   INPUT      : 容器 DNS（saddr 网段 dport 53 accept）
    #   FORWARD    : isolation + established,related + saddr accept
    #   POSTROUTING: masquerade
    #
    # ⚠️ 不要再往 iptables 里补 podman+ 规则 —— 那是 24.04 时代的补丁。
    #    26.04 上 iptables 已无 hook，补了不生效，反而制造「两套规则」的错觉。
    #
    # ⚠️ 也不再需要 --enable-podman-dnat（2026-11-17 已停用，值被彻底忽略）：
    #    发布端口的 DNAT 入站由 netavark 自己做，进 forward 时 oif=podman*，
    #    dsh_firewall 那条「只拒公网借道转发」的规则不匹配，自然放行。
    echo "  ── 3. Podman 防火墙规则（netavark >= 1.16：自管 table inet netavark）──"

    if nft list table inet netavark >/dev/null 2>&1; then
        _nv_chains=$(nft list table inet netavark 2>/dev/null | grep -cE "^[[:space:]]*chain " || true)
        echo "     ○ table inet netavark 已存在（${_nv_chains} 条链，podman 已初始化过网络）"
    else
        echo "     ○ table inet netavark 尚未创建（正常：还没起过容器）"
        echo "       首次 podman run 时 netavark 会自动建立"
    fi

    # ── 只读核验：确认没有别的 forward base chain 会一票否决容器流量 ──
    # 几个 forward hook 串联，任何一处 policy drop 都是终局裁决。
    _bad_fwd=$(nft list chains 2>/dev/null | awk '\''$0 ~ /hook forward/ && $0 ~ /policy drop/ {print prev} {prev=$0}'\'' | grep -oE '\''chain [^ ]+'\'' | sort -u || true)
    if [ -n "$_bad_fwd" ]; then
        echo "     ⚠️ 以下 forward 链 policy 是 drop，容器流量可能被拦："
        printf "%s\n" "$_bad_fwd" | sed "s/^/          - /"
    else
        echo "     ✅ 没有 policy drop 的 forward 链"
    fi

    # ── 核验 --restrict-container-host：开了会让容器 DNS 断 ──
    # 该开关把 container_ifaces（podman*）也跳进 wan_in，而 wan_in 里没有 53 放行；
    # netavark 自己那张表的 accept 跨表不终局，aardvark-dns 会被 dsh_firewall reject。
    _rch=$(grep -E "^FWSAVED_RESTRICT_CONTAINER_HOST=" /etc/dsh-firewall.conf 2>/dev/null | cut -d= -f2 | tr -d '\''"'\'' || true)
    if [ "$_rch" = "1" ]; then
        echo "     ⚠️ 主机开了 --restrict-container-host：容器内 DNS 解析可能失败"
        echo "          wan_in 里没有 53 放行，而 netavark 的 accept 跨表不终局。"
        echo "          建议：init-firewall.sh 加 --extra-udp 53 --extra-tcp 53，或关掉该开关。"
    fi

    # ── 核验 nftables.conf 里没有 flush ruleset ──
    # flush ruleset 是**设计如此**（init-firewall.sh 有意保留它，让 nftables.conf
    # 成为规则的唯一真相源）。代价是重启 nftables 会连 netavark 的表一起冲掉，
    # 需要 podman network reload --all 恢复 —— 这是已知运维动作，不是缺陷。
    if grep -qE "^[[:space:]]*flush[[:space:]]+ruleset" /etc/nftables.conf 2>/dev/null; then
        echo "     ○ nftables.conf 有 flush ruleset（设计如此）"
        echo "       重启 nftables 后需 podman network reload --all 恢复容器网络"
    fi

    # ── 核验 containers.conf 没有把 firewall_driver 钉死成 iptables ──
    _cfd=$(grep -rhE "^[[:space:]]*firewall_driver[[:space:]]*=" /etc/containers/containers.conf /etc/containers/containers.conf.d/*.conf 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '\'' "'\'' || true)
    if [ -n "$_cfd" ] && [ "$_cfd" != "nftables" ]; then
        echo "     ⚠️ containers.conf 的 firewall_driver=$_cfd（不是 nftables）"
        echo "          这会让 netavark 1.16 退回 iptables 驱动，与本脚本的判定不一致。"
    fi
elif [ "$HOST_FW" = "nft-only" ]; then
    # ── 混合形态：netavark 走 iptables，但主机防火墙已收敛成纯 nft ──
    #
    # 24.04「已收敛成纯 nft、但 netavark 还是 1.4」就是这种组合（alius/aliuk/dmit）。
    # 什么都不用写，理由：
    #   · 24.04 的 /usr/sbin/iptables 就是 iptables-nft（实测 v1.8.10 nf_tables）
    #   · netavark 1.4 调 iptables 建出来的 table ip filter / table ip nat
    #     本身就是 nft 的 base chain，挂在 forward / prerouting hook 上，照样生效
    #   · inet dsh_firewall 的 forward 链是 policy accept + 一条
    #     「iifname @wan_ifaces oifname @wan_ifaces reject」（只拒公网借道转发），
    #     容器出站（iif=podman*）与回程（oif=podman*）都不匹配
    #   → 容器出站、回程、发布端口 DNAT 三条路径都通，不需要任何补丁
    #
    # ⚠️ 绝不能去写 /etc/iptables/rules.v4 —— 混合形态下这个文件不存在，
    #    写进去也不会被加载（netfilter-persistent 已卸）。
    #    旧逻辑在这里会 grep 不存在的文件，报「integer expression expected」。
    echo "  ── 3. Podman 防火墙规则（混合形态：netavark 走 iptables-nft，主机已纯 nft）──"
    echo "     ○ 无需写入任何规则"
    echo "       容器规则由 netavark 1.4 通过 iptables-nft 自建（table ip filter / ip nat）"
    echo "       主机侧 dsh_firewall 的 forward 链对容器流量弃权（只拒公网借道转发）"
    echo "     ⚠️ 建议尽快升级到 26.04：netavark 1.16 改用 table inet netavark，规则集中一处更好排障"
else
echo "  ── 3. Podman 防火墙规则 (v4 + v6: INPUT 53/udp+tcp, FORWARD -o podman+) ──"
ensure_podman_fw() {
    local cmd="$1" file="$2" label="$3"

    # 3.1 检查并插入 live 规则（插在 REJECT 之前）
    for proto in udp tcp; do
        if $cmd -C INPUT -i podman+ -p "$proto" -m "$proto" --dport 53 -j ACCEPT 2>/dev/null; then
            echo "     ○ $label live 已存在: INPUT -i podman+ -p $proto --dport 53 -j ACCEPT"
        else
            if [ "$DRY_RUN" = "1" ]; then
                echo "     + [dry-run] $label live 将在 INPUT REJECT 前插入: -i podman+ -p $proto --dport 53 -j ACCEPT"
            else
                local ln
                ln=$($cmd -L INPUT --line-numbers -n | awk "/REJECT/{print \$1; exit}")
                $cmd -I INPUT "$ln" -i podman+ -p "$proto" -m "$proto" --dport 53 -j ACCEPT
                echo "     ✅ $label live 已插入: INPUT -i podman+ -p $proto --dport 53 -j ACCEPT"
            fi
        fi
    done

    if $cmd -C FORWARD -o podman+ -j ACCEPT 2>/dev/null; then
        echo "     ○ $label live 已存在: FORWARD -o podman+ -j ACCEPT"
    else
        if [ "$DRY_RUN" = "1" ]; then
            echo "     + [dry-run] $label live 将在 FORWARD REJECT 前插入: -o podman+ -j ACCEPT"
        else
            local ln
            ln=$($cmd -L FORWARD --line-numbers -n | awk "/REJECT/{print \$1; exit}")
            $cmd -I FORWARD "$ln" -o podman+ -j ACCEPT
            echo "     ✅ $label live 已插入: FORWARD -o podman+ -j ACCEPT"
        fi
    fi

    # 3.2 检查并在静态持久化文件的 REJECT 前精确插入（不调用 iptables-save 避免污染）
    local has_udp has_tcp has_fwd
    has_udp=$(grep -c "^-A INPUT -i podman+ -p udp.*--dport 53 -j ACCEPT" "$file" || true)
    has_tcp=$(grep -c "^-A INPUT -i podman+ -p tcp.*--dport 53 -j ACCEPT" "$file" || true)
    has_fwd=$(grep -c "^-A FORWARD -o podman+ -j ACCEPT" "$file" || true)

    if [ "$has_udp" -eq 1 ] && [ "$has_tcp" -eq 1 ] && [ "$has_fwd" -eq 1 ]; then
        echo "     ○ $file 静态文件已包含全部 3 条 podman+ 规则"
    else
        if [ "$DRY_RUN" = "1" ]; then
            echo "     + [dry-run] 将在 $file 的 REJECT 行前补齐 podman+ 规则 (当前 udp53=$has_udp, tcp53=$has_tcp, fwd=$has_fwd)"
        else
            cp "$file" "${file}.bak-$(date +%Y%m%d-%H%M%S)"
            if [ "$has_udp" -eq 0 ]; then
                sed -i "/^-A INPUT -j REJECT/i -A INPUT -i podman+ -p udp -m udp --dport 53 -j ACCEPT" "$file"
            fi
            if [ "$has_tcp" -eq 0 ]; then
                sed -i "/^-A INPUT -j REJECT/i -A INPUT -i podman+ -p tcp -m tcp --dport 53 -j ACCEPT" "$file"
            fi
            if [ "$has_fwd" -eq 0 ]; then
                sed -i "/^-A FORWARD -j REJECT/i -A FORWARD -o podman+ -j ACCEPT" "$file"
            fi
            echo "     ✅ 已更新静态文件: $file"
        fi
    fi
}

ensure_podman_fw iptables  /etc/iptables/rules.v4 "IPv4"
ensure_podman_fw ip6tables /etc/iptables/rules.v6 "IPv6"
fi   # ← 结束 NETAVARK_FW 条件（阶段 3）

# ══════════════════════════════════════════════════════════════════════════════
# 阶段 4：部署零依赖 /usr/bin/dlocate 自动缓存垫片（不伪造 /usr/bin/rpm）
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "  ── 4. Podman 包版本查询自动缓存垫片 (/usr/bin/dlocate -> /run/podman-pkg-cache) ──"
DLOCATE_SHIM="/usr/bin/dlocate"
EXPECTED_SHIM="#!/bin/sh
# Minimal auto-cached dlocate -F implementation for Podman queryPackageVersion
if [ \"\$1\" = \"-F\" ] && [ -n \"\$2\" ]; then
    f=\"/run/podman-pkg-cache/dlocate_\${2##*/}\"
    if [ -r \"\$f\" ] && [ \"\$f\" -nt /var/lib/dpkg/status ] && read -r line < \"\$f\"; then
        printf '\''%s\\n'\'' \"\$line\"
        exit 0
    fi
    mkdir -p /run/podman-pkg-cache
    out=\$(dpkg-query -S \"\$2\" 2>/dev/null | head -n 1)
    if [ -n \"\$out\" ]; then
        printf '\''%s\\n'\'' \"\$out\" > \"\$f\"
        printf '\''%s\\n'\'' \"\$out\"
        exit 0
    fi
fi
exit 1"

# 若残留旧版 /usr/bin/rpm 垫片（非真实 rpm 包），先清理掉，避免误导其他脚本的发行版探测
if [ -f /usr/bin/rpm ] && ! dpkg-query -W -f='\''${Status}'\'' rpm 2>/dev/null | grep -q "install ok installed"; then
    if [ "$DRY_RUN" = "1" ]; then
        echo "     + [dry-run] 将移除旧的 /usr/bin/rpm 垫片"
    else
        rm -f /usr/bin/rpm
        echo "     ✅ 已移除旧的 /usr/bin/rpm 垫片"
    fi
fi

if dpkg-query -W -f='\''${Status}'\'' dlocate 2>/dev/null | grep -q "install ok installed"; then
    echo "     ⚠️ 检测到系统安装了 apt dlocate 包，请先运行 optimize-oracle-vps.sh 卸载"
else
    cur_shim=""
    if [ -f "$DLOCATE_SHIM" ]; then
        cur_shim=$(cat "$DLOCATE_SHIM")
    fi
    if [ "$cur_shim" = "$EXPECTED_SHIM" ] && [ -x "$DLOCATE_SHIM" ]; then
        echo "     ○ 垫片已就绪: $DLOCATE_SHIM (自动校验 /var/lib/dpkg/status 时间戳)"
    else
        if [ "$DRY_RUN" = "1" ]; then
            echo "     + [dry-run] 将写入零依赖自动缓存垫片: $DLOCATE_SHIM"
        else
            printf "%s\n" "$EXPECTED_SHIM" > "$DLOCATE_SHIM"
            chmod 755 "$DLOCATE_SHIM"
            curl -s --unix-socket /run/podman/podman.sock http://d/v4.0.0/libpod/version >/dev/null 2>&1 || true
            curl -s --unix-socket /run/podman/podman.sock http://d/v4.0.0/libpod/info >/dev/null 2>&1 || true
            echo "     ✅ 已部署 $DLOCATE_SHIM 并完成缓存预热"
        fi
    fi
fi
'

if [ "$LOCAL_MODE" -eq 1 ]; then
    echo "════════ local ($(hostname)) ════════"
    {
        printf 'DRY_RUN=%q\n' "$DRY_RUN"
        printf '%s\n' "$REMOTE_SCRIPT"
    } | sudo -n bash -s
    exit $?
fi

rc_all=0
for target in "${HOSTS[@]}"; do
    echo "════════ $target ════════"
    {
        printf 'DRY_RUN=%q\n' "$DRY_RUN"
        printf '%s\n' "$REMOTE_SCRIPT"
    } | ssh "${SSH_OPTS[@]}" "$target" 'sudo -n bash -s' || rc_all=1
    echo
done

exit "$rc_all"
