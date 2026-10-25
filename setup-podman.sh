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
for f in /etc/iptables/rules.v4 /etc/iptables/rules.v6; do
    if [ ! -f "$f" ]; then
        echo "     ❌ [中止] 缺少防火墙持久化文件: $f"
        PREFLIGHT_FAIL=1
        continue
    fi
    dirty_lines=$(grep -nE "^\*raw|^\*nat|^\*mangle|DOCKER|NETAVARK|:FORWARD DROP|-i wt0|-o wt0" "$f" || true)
    if [ -n "$dirty_lines" ]; then
        echo "     ❌ [中止] $f 包含误保存的动态表/容器/隧道残留规则（拒绝自动修改脏文件）："
        printf "%s\n" "$dirty_lines" | head -15 | sed "s/^/        /"
        echo "        请先对照原始干净备份筛除上述污染行，确认只有纯净的 *filter 骨架后再重跑。"
        PREFLIGHT_FAIL=1
    else
        echo "     ✅ $f 纯净度校验通过（仅含静态 *filter 规则，无 DOCKER/NETAVARK/*nat 污染）"
    fi

    # 校验必须已有 INPUT REJECT、FORWARD REJECT 与 22 端口放行（即已跑过 init-iptables.sh）
    if ! grep -q "^-A INPUT .*--dport 22 -j ACCEPT" "$f" || \
       ! grep -q "^-A INPUT -j REJECT" "$f" || \
       ! grep -q "^-A FORWARD -j REJECT" "$f"; then
        echo "     ❌ [中止] $f 尚未完成基础防火墙骨架初始化（缺少 22 放行或 INPUT/FORWARD REJECT 兜底）"
        echo "        请先执行 ./init-iptables.sh <host> --apply 完成基础初始化。"
        PREFLIGHT_FAIL=1
    fi
done

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
MISSING_PKGS=()
for pkg in podman crun podman-compose; do
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
