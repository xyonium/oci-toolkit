#!/usr/bin/env bash
#
# optimize-oracle-vps.sh — Oracle Cloud E2.1.Micro (1GB RAM) 系统级优化脚本（幂等）
#
# 用法:
#   ./optimize-oracle-vps.sh [user@]host ... [--apply] [-J jump_host]
#   ./optimize-oracle-vps.sh --local [--apply]
#   不加 --apply 时默认 dry-run（只检查并打印将要执行的改动，不实际修改）
#
# ─── 优化项与实测根因（2026-10 排查 4 台 E2.1.Micro 得出）───────────────────
#   1. oracle-cloud-agent snap 清理旧 disabled 修订版:
#      注：oracle-cloud-agent 自身的 updater 插件启动时会自动给自身加 snap hold（由它自己
#      控制更新节奏），属于官方正常行为，仅当版本过旧时刷新一次并清理残留的 disabled 历史修订版。
#   2. systemd-journald 日志体积上限（SystemMaxUse=100M / RuntimeMaxUse=32M）:
#      老实例多年累积的 /var/log/journal 高达 3.9GB；当执行 podman logs（journald 驱动）
#      时会全量扫描数 GB 日志，瞬间冲垮 1GB 微机仅有的 ~600MB Page Cache，触发 kswapd0
#      把常驻服务（如 snap squashfs 挂载页）踢出物理内存，引发连环缺页中断与 IO 脉冲。
#   3. 清理多余包（dlocate / dctrl-tools / supercat）:
#      保持 1GB 微机最小包集合；Podman 包版本查询改由 setup-podman.sh 的零依赖内存垫片加速。
#   4. 虚拟内存参数与残留冷 SwapCached 回收:
#      保持 vm.swappiness=10；当 MemAvailable > 350MB 且 SwapUsed > 0 时，自动执行
#      swapoff -a && swapon -a 将跨版本升级遗留的冷 SwapCached 页收回物理内存。

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
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
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

CHANGED=0
echo "  系统: $(lsb_release -ds 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d\" -f2) | 内核: $(uname -r)"
if [ "$DRY_RUN" = "1" ]; then
    echo "  ── dry-run：以下为检查结果与将要执行的改动 ──"
fi

# 1. oracle-cloud-agent 清理旧 disabled 修订版（若仍停在旧版 <=126 则刷新一次）
echo
echo "  ── 1. oracle-cloud-agent (保持最新稳定版，清理旧 disabled 修订版) ──"
if command -v snap >/dev/null 2>&1 && snap list oracle-cloud-agent >/dev/null 2>&1; then
    oca_info=$(snap list oracle-cloud-agent | awk "NR==2 {print \$3, \$6}")
    oca_rev=$(printf "%s" "$oca_info" | awk "{print \$1}")
    oca_notes=$(printf "%s" "$oca_info" | awk "{print \$2}")
    if [ "${oca_rev:-0}" -le 126 ] 2>/dev/null; then
        if [ "$DRY_RUN" = "1" ]; then
            echo "     + [dry-run] 将刷新旧版 oracle-cloud-agent (当前 rev=${oca_rev}, notes=${oca_notes}) 至最新稳定版"
        else
            snap refresh --unhold oracle-cloud-agent >/dev/null 2>&1 || true
            snap refresh oracle-cloud-agent >/dev/null 2>&1 || true
            echo "     ✅ 已更新: $(snap list oracle-cloud-agent | awk "NR==2 {print \"rev=\"\$3, \$6}")"
            CHANGED=$((CHANGED + 1))
        fi
    else
        echo "     ○ 已处于最新稳定版: rev=${oca_rev} (${oca_notes})"
    fi
    # 清理已 disabled 的旧 snap 修订版残留的 loop 镜像
    for old_rev in $(snap list oracle-cloud-agent --all | awk "/disabled/{print \$3}"); do
        if [ "$DRY_RUN" = "1" ]; then
            echo "     + [dry-run] 将移除 disabled 旧修订版: oracle-cloud-agent rev=$old_rev"
        else
            snap remove oracle-cloud-agent --revision="$old_rev" >/dev/null 2>&1 || true
            echo "     ✅ 已移除 disabled 旧修订版: rev=$old_rev"
        fi
    done
else
    echo "     ○ 未安装 oracle-cloud-agent snap，跳过"
fi

# 2. systemd-journald 日志上限 (100M)
echo
echo "  ── 2. systemd-journald 容量限制 (SystemMaxUse=100M) ──"
JCONF="/etc/systemd/journald.conf.d/99-size-limit.conf"
EXPECTED_JCONF="[Journal]
SystemMaxUse=100M
SystemMaxFileSize=20M
RuntimeMaxUse=32M"

current_jconf=""
if [ -f "$JCONF" ]; then
    current_jconf=$(cat "$JCONF")
fi

if [ "$current_jconf" = "$EXPECTED_JCONF" ]; then
    echo "     ○ 配置文件已就绪: $JCONF"
else
    if [ "$DRY_RUN" = "1" ]; then
        echo "     + [dry-run] 将写入 $JCONF (SystemMaxUse=100M, SystemMaxFileSize=20M, RuntimeMaxUse=32M) 并压缩历史日志"
    else
        mkdir -p /etc/systemd/journald.conf.d
        printf "%s\n" "$EXPECTED_JCONF" > "$JCONF"
        systemctl restart systemd-journald
        journalctl --vacuum-size=100M >/dev/null 2>&1 || true
        echo "     ✅ 已写入 $JCONF 并执行 vacuum-size=100M"
        CHANGED=$((CHANGED + 1))
    fi
fi
echo "     当前日志占用: $(journalctl --disk-usage 2>/dev/null | sed "s/.*take up //")"

# 3. 清理非最小集合的多余包 (dlocate / dctrl-tools / supercat)
echo
echo "  ── 3. 最小包集合检查 (移除 dlocate/dctrl-tools/supercat) ──"
EXTRA_PKGS=()
for pkg in dlocate dctrl-tools supercat; do
    if dpkg-query -W -f='\''${Status}'\'' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
        EXTRA_PKGS+=("$pkg")
    fi
done
if [ ${#EXTRA_PKGS[@]} -eq 0 ]; then
    echo "     ○ 无多余包"
else
    if [ "$DRY_RUN" = "1" ]; then
        echo "     + [dry-run] 将卸载多余包: ${EXTRA_PKGS[*]}"
    else
        export DEBIAN_FRONTEND=noninteractive
        apt-get purge -y -qq "${EXTRA_PKGS[@]}" >/dev/null
        rm -rf /var/lib/dlocate
        echo "     ✅ 已卸载: ${EXTRA_PKGS[*]}"
        CHANGED=$((CHANGED + 1))
    fi
fi

# 4. vm.swappiness 与冷 SwapCached 回收
echo
echo "  ── 4. 内存与 Swap 状态 ──"
swp_val=$(sysctl -n vm.swappiness 2>/dev/null || echo 60)
if [ "$swp_val" -le 10 ]; then
    echo "     ○ vm.swappiness = $swp_val (<=10)"
else
    if [ "$DRY_RUN" = "1" ]; then
        echo "     + [dry-run] 将设置 vm.swappiness=10 (当前 $swp_val)"
    else
        sysctl -w vm.swappiness=10 >/dev/null
        mkdir -p /etc/sysctl.d
        printf "vm.swappiness = 10\n" > /etc/sysctl.d/99-swappiness.conf
        echo "     ✅ 已设置并持久化 vm.swappiness=10"
        CHANGED=$((CHANGED + 1))
    fi
fi

mem_avail_kb=$(awk "/^MemAvailable:/{print \$2}" /proc/meminfo)
swap_total_kb=$(awk "/^SwapTotal:/{print \$2}" /proc/meminfo)
swap_free_kb=$(awk "/^SwapFree:/{print \$2}" /proc/meminfo)
swap_used_kb=$((swap_total_kb - swap_free_kb))

if [ "$swap_used_kb" -gt 10240 ] && [ "$mem_avail_kb" -gt 350000 ]; then
    if [ "$DRY_RUN" = "1" ]; then
        echo "     + [dry-run] 检测到 SwapUsed=$((swap_used_kb / 1024))MB 且 MemAvailable=$((mem_avail_kb / 1024))MB 充裕，将执行 swapoff/swapon 回收残留冷页"
    else
        swapoff -a && swapon -a
        echo "     ✅ 已回收残留 Swap 页回物理内存"
        CHANGED=$((CHANGED + 1))
    fi
else
    echo "     ○ MemAvailable=$((mem_avail_kb / 1024))MB, SwapUsed=$((swap_used_kb / 1024))MB (无需回收)"
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
