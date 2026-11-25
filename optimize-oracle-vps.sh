#!/usr/bin/env bash
#
# optimize-oracle-vps.sh — Linux VPS 系统级优化脚本（幂等，兼容 Oracle/阿里云/搬瓦工/DMIT/腾讯云等）
#   注意：oracle-cloud-agent 段仅在装了 OCI 官方 snap 的主机上生效；其他 VPS 会自动跳过。
#
# 用法:
#   ./optimize-oracle-vps.sh [user@]host[:port] ... [--apply] [-J jump_host]
#        例: ./optimize-oracle-vps.sh root@node.example.com:26320 --apply
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
#   5. mask fwupd / fwupd-refresh.service / fwupd-refresh.timer / multipathd:
#      OCI 虚拟机内 fwupd 只能看到 QEMU 虚拟主板/虚拟 SCSI 盘/vCPU，无任何可刷写固件
#      （固件与微码由 Oracle 宿主机侧维护；Ubuntu 官方 cloud image 亦已移除 fwupd），
#      但 fwupd-refresh.timer 每天唤醒一次常驻 ~34MB。multipathd 对单路径 iSCSI 根盘
#      （/dev/sda 直挂，multipath -ll 无 map）无管理对象，常驻 ~26MB。两者合计 ~60MB，
#      2026-10-15/16 已在 JP/UK 手工 mask 并跨重启验证无影响，此处固化为脚本步骤。
#   6. 512MB /swapfile（fstab 持久化）:
#      1GB 微机的内存兜底；JP/UK 已于 2026-10-15/16 手工创建，本次起对全部主机统一。
#      已挂载则跳过；已挂载但 fstab 缺条目则补写。根分区余量不足 1GB 时跳过并告警。
#   7. BBR + fq（保留 mq 多队列）+ tcp_mtu_probing=1:
#      99-zz-dsh-bbr.conf + 独立 /usr/local/sbin/dsh-apply-fq + dsh-bbr-qdisc.service，
#      解决 Oracle 26.04 initramfs 阶段 ens3 落入 pfifo_fast 的问题，同时保留 mq 多队列。

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

# 支持 "user@host:port" 写法（如 root@node.example.com:26320）。
# 目标里带 :PORT 时拆出来单独塞 -p，避免影响其他主机。
read -r -d '' DSH_BBR_BLOCK <<'DSH_BBR_PAYLOAD_EOF' || true
# BEGIN DSH_BBR_BASELINE
_bbr_info() { printf '\033[32m[+]\033[0m %s\n' "$*"; }
_bbr_warn() { printf '\033[33m[!]\033[0m %s\n' "$*" >&2; }
_bbr_err()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; }

_dsh_bbr_init_paths() {
    DSH_BBR_SYSCTL_FILE="${SYSCTL_CONF_FILE:-/etc/sysctl.d/99-zz-dsh-bbr.conf}"
    # 顺序遵循 systemd-sysctl 优先级（高优先在前，同名覆盖低优先）
    DSH_BBR_SYSCTL_SEARCH="${SYSCTL_SEARCH_DIRS:-/etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d /lib/sysctl.d}"
    DSH_BBR_MAIN_SYSCTL="${SYSCTL_MAIN_CONF:-/etc/sysctl.conf}"
    DSH_BBR_MODLOAD_FILE="${MODULES_LOAD_FILE:-/etc/modules-load.d/99-zz-dsh-bbr.conf}"
    DSH_BBR_APPLY_BIN="${APPLY_FQ_BIN:-/usr/local/sbin/dsh-apply-fq}"
    DSH_BBR_SVC_FILE="${QDISC_SERVICE_FILE:-/etc/systemd/system/dsh-bbr-qdisc.service}"
    DSH_BBR_LEGACY_SVC="${LEGACY_QDISC_SERVICE_FILE:-/etc/systemd/system/apply-fq-qdisc.service}"
    DSH_BBR_LEGACY_SYSCTL="${LEGACY_SYSCTL_FILE:-/etc/sysctl.d/99-bbr.conf}"
    DSH_BBR_LEGACY_MODLOAD="${LEGACY_MODULES_FILE:-/etc/modules-load.d/99-bbr.conf}"
    DSH_BBR_BACKUP_DIR="${BACKUP_DIR:-/var/backups/dsh-sysctl}"
    # 独立专用状态目录变量，绝不复用通用的 STATE_DIR，防止与 optimize-baseline.sh 碰撞
    DSH_BBR_STATE_ROOT="${DSH_BBR_STATE_DIR:-/var/lib/dsh-bbr}"
    DSH_BBR_SYSFS_NET="${SYSFS_NET_DIR:-/sys/class/net}"
}

_dsh_bbr_is_builtin() {
    local mod="$1" kver minfo="" cfg_key=""
    kver="$(uname -r 2>/dev/null || true)"
    if [ -n "$kver" ] && [ -r "/lib/modules/${kver}/modules.builtin" ] && \
       grep -qE "(^|/)${mod}\.ko" "/lib/modules/${kver}/modules.builtin" 2>/dev/null; then
        return 0
    fi
    if command -v modinfo >/dev/null 2>&1; then
        minfo="$(modinfo -F filename "$mod" 2>/dev/null || true)"
        if [ "$minfo" = "(builtin)" ]; then
            return 0
        fi
    fi
    case "$mod" in
        sch_fq)  cfg_key="CONFIG_NET_SCH_FQ=y" ;;
        tcp_bbr) cfg_key="CONFIG_TCP_CONG_BBR=y" ;;
    esac
    if [ -n "$cfg_key" ]; then
        if [ -n "$kver" ] && [ -r "/boot/config-${kver}" ] && grep -qxF "$cfg_key" "/boot/config-${kver}" 2>/dev/null; then
            return 0
        fi
        if [ -r /proc/config.gz ] && command -v zgrep >/dev/null 2>&1 && zgrep -qxF "$cfg_key" /proc/config.gz 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

_dsh_bbr_need_modload() {
    local mod="$1" minfo=""
    if _dsh_bbr_is_builtin "$mod"; then
        return 1
    fi
    if command -v modinfo >/dev/null 2>&1; then
        minfo="$(modinfo -F filename "$mod" 2>/dev/null || true)"
        if [ -n "$minfo" ] && [ "$minfo" != "(builtin)" ]; then
            return 0
        fi
    fi
    return 1
}

_dsh_bbr_have_mod() {
    local mod="$1"
    if [ "$mod" = "tcp_bbr" ]; then
        if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
            return 0
        fi
        if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
            return 0
        fi
    fi
    if [ "$mod" = "sch_fq" ] && [ -d /sys/module/sch_fq ]; then
        return 0
    fi
    if _dsh_bbr_is_builtin "$mod"; then
        return 0
    fi
    if _dsh_bbr_need_modload "$mod"; then
        return 0
    fi
    return 1
}

_dsh_bbr_is_wan_dev() {
    local d="${1:-}" allow_virtual="${2:-0}" iftype
    [ -n "$d" ] || return 1
    case "$d" in
        lo|wg*|wt*|zt*|tun*|tap*|docker*|veth*|podman*|sit*|virbr*|tailscale*|ipv6net*|he-ipv6*|ip6tnl*|ipip*) return 1 ;;
    esac
    if [ "$allow_virtual" != "1" ]; then
        case "$d" in
            br[0-9]*|br-*|vmbr*|cni*|flannel*|cali*|cilium*|lxcbr*|lxdbr*|vxlan*|macvlan*|ipvlan*|gre*) return 1 ;;
        esac
        if [ -r "$DSH_BBR_SYSFS_NET/$d/type" ]; then
            iftype="$(cat "$DSH_BBR_SYSFS_NET/$d/type" 2>/dev/null || echo 1)"
            [ "$iftype" = "1" ] || return 1
        fi
    fi
    [ -d "$DSH_BBR_SYSFS_NET/$d" ] || return 1
    return 0
}

_dsh_bbr_detect_wan_devs() {
    local line d raw=""
    while IFS= read -r line; do
        while IFS= read -r d; do
            if [ -n "$d" ] && _dsh_bbr_is_wan_dev "$d" 0; then
                raw+="${d}"$'\n'
            fi
        done < <(printf '%s\n' "$line" | awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}')
    done < <(
        ip -4 -o route get 1.1.1.1 2>/dev/null || true
        ip -6 -o route get 2606:4700:4700::1111 2>/dev/null || true
        ip -4 -o route show default 2>/dev/null || true
        ip -6 -o route show default 2>/dev/null || true
    )
    printf '%s' "$raw" | awk 'NF && !seen[$0]++'
}

_dsh_bbr_backup_file() {
    local src="$1" prefix="$2" stamp="$3" dst
    [ -e "$src" ] || return 0
    mkdir -p "$DSH_BBR_BACKUP_DIR" || return 1
    dst="$DSH_BBR_BACKUP_DIR/${prefix}-$(basename "$src").${stamp}"
    cp -a "$src" "$dst" || return 1
    printf '%s\n' "$dst"
}

_dsh_bbr_render_apply_fq_script() {
    cat <<'DSH_APPLY_FQ_EOF'
#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SYSFS_NET_DIR="${SYSFS_NET_DIR:-/sys/class/net}"
WAIT_SECS="${DSH_APPLY_FQ_WAIT:-0}"
CHECK_ONLY=0
EXPLICIT_ARG=""

while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK_ONLY=1 ;;
        -*) echo "未知选项：$1" >&2; exit 2 ;;
        *)
            if [ -z "$EXPLICIT_ARG" ]; then
                EXPLICIT_ARG="$1"
            else
                EXPLICIT_ARG="$EXPLICIT_ARG,$1"
            fi
            ;;
    esac
    shift
done

is_wan_dev() {
    local d="${1:-}" allow_virtual="${2:-0}" iftype
    [ -n "$d" ] || return 1
    case "$d" in
        lo|wg*|wt*|zt*|tun*|tap*|docker*|veth*|podman*|sit*|virbr*|tailscale*|ipv6net*|he-ipv6*|ip6tnl*|ipip*) return 1 ;;
    esac
    if [ "$allow_virtual" != "1" ]; then
        case "$d" in
            br[0-9]*|br-*|vmbr*|cni*|flannel*|cali*|cilium*|lxcbr*|lxdbr*|vxlan*|macvlan*|ipvlan*|gre*) return 1 ;;
        esac
        if [ -r "$SYSFS_NET_DIR/$d/type" ]; then
            iftype="$(cat "$SYSFS_NET_DIR/$d/type" 2>/dev/null || echo 1)"
            [ "$iftype" = "1" ] || return 1
        fi
    fi
    [ -d "$SYSFS_NET_DIR/$d" ] || return 1
    return 0
}

detect_devs() {
    local line d raw=""
    while IFS= read -r line; do
        while IFS= read -r d; do
            if [ -n "$d" ] && is_wan_dev "$d" 0; then
                raw+="${d}"$'\n'
            fi
        done < <(printf '%s\n' "$line" | awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}')
    done < <(
        ip -4 -o route get 1.1.1.1 2>/dev/null || true
        ip -6 -o route get 2606:4700:4700::1111 2>/dev/null || true
        ip -4 -o route show default 2>/dev/null || true
        ip -6 -o route show default 2>/dev/null || true
    )
    printf '%s' "$raw" | awk 'NF && !seen[$0]++'
}

read_qdisc_lines() {
    local dev="$1"
    tc qdisc show dev "$dev" 2>/dev/null | sed 's/ \\qdisc /\nqdisc /g; s/\\$//'
}

# 严格提取属于 mq 根的直系 TX 子队列（过滤 clsact / ingress 等 parent ffff:fff1 钩子）
extract_mq_tx_children() {
    local root_handle="$1" qout="$2"
    awk -v rh="$root_handle" '
        $1=="qdisc" && $2!="clsact" && $2!="ingress" {
            for(i=1;i<NF;i++) {
                if($i=="parent") {
                    p=$(i+1)
                    if ((rh=="0:" || rh=="") && p ~ /^:[0-9]+$/) {
                        print p, $2
                    } else if (rh!="0:" && rh!="" && index(p, rh)==1 && substr(p, length(rh)+1) ~ /^[0-9]+$/) {
                        print p, $2
                    }
                    break
                }
            }
        }
    ' <<<"$qout"
}

apply_one_dev() {
    local dev="$1" allow_explicit="$2" qout root root_handle item parent kind need_change=0
    local -a children=()
    if ! is_wan_dev "$dev" "$allow_explicit"; then
        echo "非法或受保护的非物理出口网卡：$dev" >&2
        return 1
    fi
    qout="$(read_qdisc_lines "$dev")"
    root="$(awk '$1=="qdisc" {for(i=1;i<=NF;i++) if($i=="root"){print $2; exit}}' <<<"$qout")"
    root_handle="$(awk '$1=="qdisc" {for(i=1;i<=NF;i++) if($i=="root"){print $3; exit}}' <<<"$qout")"
    [ -n "$root" ] || { echo "无法读取 $dev 的根 qdisc" >&2; return 1; }

    case "$root" in
        fq)
            if [ "$CHECK_ONLY" = "1" ]; then
                echo "[CHECK] $dev: 已是 root fq [IMPACT: no-op]"
            else
                echo "[ok] $dev 已是 root fq（no-op）"
            fi
            return 0
            ;;
        pfifo_fast|fq_codel|pfifo|bfifo)
            if [ "$CHECK_ONLY" = "1" ]; then
                echo "[CHECK] $dev: $root -> root fq [IMPACT: dev_deactivate 单次瞬时重挂]"
                return 0
            fi
            tc qdisc replace dev "$dev" root fq || return 1
            echo "[ok] $dev: $root -> root fq"
            ;;
        mq)
            mapfile -t children < <(extract_mq_tx_children "$root_handle" "$qout")
            [ "${#children[@]}" -gt 0 ] || { echo "$dev 根为 mq 但未检出 TX 子队列" >&2; return 1; }
            for item in "${children[@]}"; do
                kind="${item##* }"
                case "$kind" in
                    fq) ;;
                    pfifo_fast|fq_codel|pfifo|bfifo) need_change=1 ;;
                    *)
                        echo "拒绝覆盖 $dev 的非默认子 qdisc：$item" >&2
                        return 1
                        ;;
                esac
            done
            if [ "$need_change" = "0" ]; then
                if [ "$CHECK_ONLY" = "1" ]; then
                    echo "[CHECK] $dev: 已是 mq + 全 fq 子队列 [IMPACT: no-op]"
                else
                    echo "[ok] $dev 已是 mq + 全 fq 子队列（no-op）"
                fi
                return 0
            elif [ "$root_handle" = "0:" ] || [ -z "$root_handle" ]; then
                if [ "$CHECK_ONLY" = "1" ]; then
                    echo "[CHECK] $dev: mq 0: -> root handle 1: mq (fq leaves) [IMPACT: dev_deactivate 单次毫秒级瞬时重挂]"
                    return 0
                fi
                if [ "$(sysctl -n net.core.default_qdisc 2>/dev/null || true)" != "fq" ]; then
                    echo "$dev 根为 mq 0: 但 default_qdisc 不是 fq，拒绝重建" >&2
                    return 1
                fi
                tc qdisc replace dev "$dev" root handle 1: mq || return 1
                echo "[ok] $dev: mq 0: -> root handle 1: mq (fq leaves)"
            else
                if [ "$CHECK_ONLY" = "1" ]; then
                    echo "[CHECK] $dev: mq $root_handle 非 fq 子队列逐条替换 [IMPACT: dev_deactivate 毫秒级瞬时重挂]"
                    return 0
                fi
                for item in "${children[@]}"; do
                    parent="${item%% *}"
                    kind="${item##* }"
                    if [ "$kind" != "fq" ]; then
                        tc qdisc replace dev "$dev" parent "$parent" fq || return 1
                        echo "[ok] $dev parent $parent: $kind -> fq"
                    fi
                done
            fi
            ;;
        noqueue)
            echo "$dev 为 noqueue（若为 bond/VLAN 请改用 --dev 指定底层物理从口），拒绝挂载 fq" >&2
            return 1
            ;;
        *)
            echo "拒绝覆盖 $dev 的自定义策略 qdisc：$root" >&2
            return 1
            ;;
    esac

    # 读回验证（mq 根不得被拍扁，且所有 TX 子队列必须为 fq）
    qout="$(read_qdisc_lines "$dev")"
    root="$(awk '$1=="qdisc" {for(i=1;i<=NF;i++) if($i=="root"){print $2; exit}}' <<<"$qout")"
    root_handle="$(awk '$1=="qdisc" {for(i=1;i<=NF;i++) if($i=="root"){print $3; exit}}' <<<"$qout")"
    if [ "$root" = "fq" ]; then
        return 0
    elif [ "$root" = "mq" ]; then
        mapfile -t children < <(extract_mq_tx_children "$root_handle" "$qout")
        [ "${#children[@]}" -gt 0 ] || return 1
        for item in "${children[@]}"; do
            [ "${item##* }" = "fq" ] || { echo "$dev 校验失败：子队列仍为 $item" >&2; return 1; }
        done
        return 0
    fi
    echo "$dev 校验失败：当前根 qdisc=$root" >&2
    return 1
}

TARGETS=""
ALLOW_EXPLICIT=0
if [ -n "$EXPLICIT_ARG" ]; then
    TARGETS="$(printf '%s\n' "$EXPLICIT_ARG" | tr ',' '\n' | awk 'NF && !seen[$0]++')"
    ALLOW_EXPLICIT=1
else
    elapsed=0
    while true; do
        TARGETS="$(detect_devs || true)"
        [ -n "$TARGETS" ] && break
        if [ "$CHECK_ONLY" = "1" ] || [ "$elapsed" -ge "$WAIT_SECS" ]; then
            break
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
fi

if [ -z "$TARGETS" ]; then
    echo "未找到可用的默认路由物理出口网卡（已等待 ${WAIT_SECS}s；正式内网/特殊路由请显式传 --dev <NIC>）" >&2
    exit 1
fi

rc=0
while IFS= read -r dev; do
    [ -n "$dev" ] || continue
    apply_one_dev "$dev" "$ALLOW_EXPLICIT" || rc=1
done <<<"$TARGETS"
exit "$rc"
DSH_APPLY_FQ_EOF
}

# 纯用户态 sysctl 文件优先级与冲突检查（严禁任何形式调用 sysctl --system！）
_dsh_bbr_check_sysctl_conflicts() {
    local want_cc="$1" want_qd="$2" want_mtu="$3" force_conflict="${4:-0}"
    local target_base d f b kv k v buf_warns="" after_conflicts="" main_conflicts=""
    local -A seen_base=()
    local -a active_files=()

    target_base="$(basename "$DSH_BBR_SYSCTL_FILE")"

    # 按 systemd-sysctl 目录优先级收集唯一文件名（高优先目录屏蔽低优先目录同名文件）
    for d in $DSH_BBR_SYSCTL_SEARCH; do
        [ -d "$d" ] || continue
        for f in "$d"/*.conf; do
            [ -f "$f" ] || continue
            b="$(basename "$f")"
            [ "$f" = "$DSH_BBR_SYSCTL_FILE" ] && continue
            [ "$f" = "$DSH_BBR_LEGACY_SYSCTL" ] && continue
            if [ -z "${seen_base[$b]:-}" ]; then
                seen_base[$b]="$f"
            fi
        done
    done

    # 按 LC_ALL=C 字典序遍历生效的 sysctl.d/*.conf
    if [ "${#seen_base[@]}" -gt 0 ]; then
        mapfile -t active_files < <(
            for b in "${!seen_base[@]}"; do
                printf '%s\t%s\n' "$b" "${seen_base[$b]}"
            done | LC_ALL=C sort -k1,1 | awk -F'\t' '{print $2}'
        )
    fi

    for f in "${active_files[@]}"; do
        b="$(basename "$f")"
        # 在全部 sysctl.d 文件中巡检超大缓冲
        local bw
        bw="$(grep -nE '^[[:space:]]*(net\.core\.(r|w)mem_max|net\.ipv4\.tcp_(r|w)mem)[[:space:]]*=' "$f" 2>/dev/null || true)"
        if [ -n "$bw" ]; then
            buf_warns+="$(printf '%s\n' "$bw" | sed "s|^|$f:|")"$'\n'
        fi

        # 在 LC_ALL=C 下排在 99-zz-dsh-bbr.conf 之后的文件（如字母开头的 local.conf / zz-*.conf）
        if [[ "$(LC_ALL=C printf '%s\n%s\n' "$target_base" "$b" | LC_ALL=C sort | tail -n 1)" = "$b" ]] && [ "$b" != "$target_base" ]; then
            while IFS= read -r kv; do
                [ -n "$kv" ] || continue
                local lno line clean
                lno="${kv%%:*}"
                line="${kv#*:}"
                clean="${line%%#*}"
                k="$(printf '%s' "$clean" | cut -d= -f1 | tr -d '[:space:]')"
                v="$(printf '%s' "$clean" | cut -d= -f2- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
                case "$k" in
                    net.ipv4.tcp_congestion_control)
                        [ -n "$want_cc" ] && [ "$v" != "$want_cc" ] && after_conflicts+="$f:$lno:$line"$'\n' ;;
                    net.core.default_qdisc)
                        [ -n "$want_qd" ] && [ "$v" != "$want_qd" ] && after_conflicts+="$f:$lno:$line"$'\n' ;;
                    net.ipv4.tcp_mtu_probing)
                        [ -n "$want_mtu" ] && [ "$v" != "$want_mtu" ] && after_conflicts+="$f:$lno:$line"$'\n' ;;
                esac
            done < <(grep -nE '^[[:space:]]*(net\.core\.default_qdisc|net\.ipv4\.tcp_congestion_control|net\.ipv4\.tcp_mtu_probing)[[:space:]]*=' "$f" 2>/dev/null || true)
        fi
    done

    if [ -f "$DSH_BBR_MAIN_SYSCTL" ]; then
        local mbw
        mbw="$(grep -nE '^[[:space:]]*(net\.core\.(r|w)mem_max|net\.ipv4\.tcp_(r|w)mem)[[:space:]]*=' "$DSH_BBR_MAIN_SYSCTL" 2>/dev/null || true)"
        if [ -n "$mbw" ]; then
            buf_warns+="$(printf '%s\n' "$mbw" | sed "s|^|$DSH_BBR_MAIN_SYSCTL:|")"$'\n'
        fi
        while IFS= read -r kv; do
            [ -n "$kv" ] || continue
            local lno line clean
            lno="${kv%%:*}"
            line="${kv#*:}"
            clean="${line%%#*}"
            k="$(printf '%s' "$clean" | cut -d= -f1 | tr -d '[:space:]')"
            v="$(printf '%s' "$clean" | cut -d= -f2- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
            case "$k" in
                net.ipv4.tcp_congestion_control)
                    [ -n "$want_cc" ] && main_conflicts+="$DSH_BBR_MAIN_SYSCTL:$lno:$line (v=$v)"$'\n' ;;
                net.core.default_qdisc)
                    [ -n "$want_qd" ] && main_conflicts+="$DSH_BBR_MAIN_SYSCTL:$lno:$line (v=$v)"$'\n' ;;
                net.ipv4.tcp_mtu_probing)
                    [ -n "$want_mtu" ] && main_conflicts+="$DSH_BBR_MAIN_SYSCTL:$lno:$line (v=$v)"$'\n' ;;
            esac
        done < <(grep -nE '^[[:space:]]*(net\.core\.default_qdisc|net\.ipv4\.tcp_congestion_control|net\.ipv4\.tcp_mtu_probing)[[:space:]]*=' "$DSH_BBR_MAIN_SYSCTL" 2>/dev/null || true)
    fi

    if [ -n "$buf_warns" ]; then
        _bbr_warn "发现磁盘 sysctl 文件中包含 rmem/wmem 缓冲区配置（小内存机器请核对避免 OOM）："
        printf '%s' "$buf_warns" | sed '/^$/d; s/^/     /' >&2
    fi

    if [ -n "$after_conflicts" ] || [ -n "$main_conflicts" ]; then
        if [ -n "$after_conflicts" ]; then
            _bbr_warn "发现字典序在 $target_base 之后（在 systemd-sysctl 中会覆盖本配置）的冲突项："
            printf '%s' "$after_conflicts" | sed '/^$/d; s/^/     /' >&2
        fi
        if [ -n "$main_conflicts" ]; then
            _bbr_warn "发现 $DSH_BBR_MAIN_SYSCTL 中存在网络冲突键（Ubuntu 22.04/24.04 下 sysctl --system 会最后读取它）："
            printf '%s' "$main_conflicts" | sed '/^$/d; s/^/     /' >&2
        fi
        if [ "$force_conflict" != "1" ]; then
            _bbr_err "存在高优先级 sysctl 冲突，已阻断修改（先清理冲突文件，或显式加 --force-conflict）"
            return 1
        fi
    fi
    return 0
}

_dsh_bbr_snapshot_nic_qdiscs() {
    local dev_csv="$1" d qout root root_handle kids_str="" out=""
    local -a snap_devs=()
    IFS=',' read -ra snap_devs <<< "$dev_csv"
    for d in "${snap_devs[@]}"; do
        [ -n "$d" ] || continue
        qout="$(tc qdisc show dev "$d" 2>/dev/null | sed 's/ \\qdisc /\nqdisc /g; s/\\$//' || true)"
        root="$(awk '$1=="qdisc" {for(i=1;i<=NF;i++) if($i=="root"){print $2; exit}}' <<<"$qout")"
        root_handle="$(awk '$1=="qdisc" {for(i=1;i<=NF;i++) if($i=="root"){print $3; exit}}' <<<"$qout")"
        if [ "$root" = "mq" ]; then
            kids_str="$(awk -v rh="$root_handle" '
                $1=="qdisc" && $2!="clsact" && $2!="ingress" {
                    for(i=1;i<NF;i++) {
                        if($i=="parent") {
                            p=$(i+1)
                            if ((rh=="0:" || rh=="") && p ~ /^:[0-9]+$/) {
                                printf "%s%s=%s", sep, p, $2; sep=","
                            } else if (rh!="0:" && rh!="" && index(p, rh)==1 && substr(p, length(rh)+1) ~ /^[0-9]+$/) {
                                printf "%s%s=%s", sep, p, $2; sep=","
                            }
                            break
                        }
                    }
                }
            ' <<<"$qout")"
            out+="${out:+;}${d}=mq@${root_handle:-0:}@${kids_str}"
        elif [ -n "$root" ]; then
            out+="${out:+;}${d}=root@${root}"
        fi
    done
    printf '%s' "$out"
}

dsh_bbr_baseline_apply() {
    local dry_run="${1:-1}" explicit_dev="${2:-}" mtu_probing="${3:-1}" install_svc="${4:-1}"
    local live_qdisc="${5:-1}" apply_bbr="${6:-1}" apply_qdisc="${7:-1}" force_conflict="${8:-0}"
    local apply_default_qdisc="${9:-1}"
    _dsh_bbr_init_paths
    [ "$(id -u)" -eq 0 ] || { _bbr_err "需要 root"; return 1; }
    command -v ip >/dev/null 2>&1 || { _bbr_err "缺少 ip 命令（iproute2）"; return 1; }
    if [ "$apply_qdisc" = "1" ] || [ "$live_qdisc" = "1" ] || [ "$install_svc" = "1" ]; then
        command -v tc >/dev/null 2>&1 || { _bbr_err "缺少 tc 命令（iproute2）"; return 1; }
    fi

    # ── 阶段 A：全量只读预检（在任何文件/内核改动前执行，--dry-run 与 --apply 同一闸门）──
    if [ "$install_svc" = "1" ] && [ -e "$DSH_BBR_SVC_FILE" ]; then
        if ! grep -qF "# Managed by vpsetup/setup-bbr-sysctl.sh" "$DSH_BBR_SVC_FILE" 2>/dev/null; then
            _bbr_err "$DSH_BBR_SVC_FILE 已存在且非本脚本创建，拒绝覆盖"
            return 1
        fi
    fi

    local devs="" dev_csv=""
    if [ "$apply_qdisc" = "1" ] || [ "$live_qdisc" = "1" ] || [ "$install_svc" = "1" ]; then
        if [ -n "$explicit_dev" ]; then
            dev_csv="$explicit_dev"
            devs="$(printf '%s\n' "$dev_csv" | tr ',' '\n')"
        else
            devs="$(_dsh_bbr_detect_wan_devs || true)"
            dev_csv="$(printf '%s' "$devs" | awk 'NF{printf "%s%s", sep, $0; sep=","}')"
        fi
        _bbr_info "目标物理出口网卡: ${dev_csv:-（未检出）}"
        if [ -z "$dev_csv" ]; then
            _bbr_err "未检出可用的物理出口网卡（正式内网/多路由环境请显式传 --dev <NIC>）"
            return 1
        fi
    fi

    # 1) 内核模块探测（先于任何写入，绝不留坏掉的 modules-load）
    local need_fq=0 need_bbr=0
    [ "$apply_bbr" = "1" ] && need_bbr=1
    if [ "$apply_qdisc" = "1" ] || [ "$live_qdisc" = "1" ] || [ "$install_svc" = "1" ] || [ "$apply_default_qdisc" = "1" ]; then
        need_fq=1
    fi

    if [ "$dry_run" = "0" ]; then
        if [ "$need_fq" = "1" ] && ! _dsh_bbr_is_builtin sch_fq && command -v modprobe >/dev/null 2>&1; then
            modprobe sch_fq >/dev/null 2>&1 || true
        fi
        if [ "$need_bbr" = "1" ] && ! _dsh_bbr_is_builtin tcp_bbr && command -v modprobe >/dev/null 2>&1; then
            modprobe tcp_bbr >/dev/null 2>&1 || true
        fi
    fi
    if [ "$need_fq" = "1" ] && ! _dsh_bbr_have_mod sch_fq; then
        _bbr_err "当前内核缺少 sch_fq，已中止（零改动）"
        return 1
    fi
    if [ "$need_bbr" = "1" ] && ! _dsh_bbr_have_mod tcp_bbr; then
        _bbr_err "当前内核缺少 tcp_bbr，已中止（零改动）"
        return 1
    fi

    # 2) sysctl 冲突检查（纯用户态解析，绝不跑 sysctl --system）
    local want_cc="" want_qd="" want_mtu=""
    [ "$apply_bbr" = "1" ] && want_cc="bbr"
    if [ "$apply_default_qdisc" = "1" ] && { [ "$apply_bbr" = "1" ] || [ "$apply_qdisc" = "1" ]; }; then
        want_qd="fq"
    fi
    [ "$mtu_probing" = "1" ] && want_mtu="1"

    _dsh_bbr_check_sysctl_conflicts "$want_cc" "$want_qd" "$want_mtu" "$force_conflict" || return 1

    # 3) 网卡 qdisc 白名单预检（利用同一份 dsh-apply-fq 逻辑在临时文件中 --check）
    local check_tmp=""
    if [ "$apply_qdisc" = "1" ] || [ "$live_qdisc" = "1" ] || [ "$install_svc" = "1" ]; then
        check_tmp="$(mktemp)" || return 1
        _dsh_bbr_render_apply_fq_script > "$check_tmp"
        chmod 700 "$check_tmp"
        if ! DSH_APPLY_FQ_WAIT=0 SYSFS_NET_DIR="$DSH_BBR_SYSFS_NET" bash "$check_tmp" --check "$dev_csv"; then
            rm -f "$check_tmp"
            _bbr_err "网卡 qdisc 预检未通过，已中止（零改动）"
            return 1
        fi
        rm -f "$check_tmp"
    fi

    local cur_cc cur_qd cur_mtu
    cur_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
    cur_qd="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
    cur_mtu="$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo '?')"
    _bbr_info "当前 sysctl: cc=$cur_cc default_qdisc=$cur_qd tcp_mtu_probing=$cur_mtu"

    local sysctl_body="# BBR + Fair Queue baseline (managed by vpsetup/setup-bbr-sysctl.sh)"
    [ -n "$want_qd" ]  && sysctl_body+=$'\n'"net.core.default_qdisc = $want_qd"
    [ -n "$want_cc" ]  && sysctl_body+=$'\n'"net.ipv4.tcp_congestion_control = $want_cc"
    [ -n "$want_mtu" ] && sysctl_body+=$'\n'"net.ipv4.tcp_mtu_probing = $want_mtu"

    local modload_lines=""
    if [ "$need_fq" = "1" ] && _dsh_bbr_need_modload sch_fq; then
        modload_lines+="sch_fq"$'\n'
    fi
    if [ "$need_bbr" = "1" ] && _dsh_bbr_need_modload tcp_bbr; then
        modload_lines+="tcp_bbr"$'\n'
    fi

    if [ "$dry_run" = "1" ]; then
        printf '  [dry-run] 写入 %s（临时文件 sysctl -p 校验后原子 mv，绝不调用 sysctl --system）\n' "$DSH_BBR_SYSCTL_FILE"
        if [ -n "$modload_lines" ]; then
            printf '  [dry-run] 写入 %s（逐行模块：%s）\n' "$DSH_BBR_MODLOAD_FILE" "$(printf '%s' "$modload_lines" | tr '\n' ' ')"
        fi
        if [ "$live_qdisc" = "1" ]; then
            printf '  [dry-run] 现场切换网卡 %s qdisc（含瞬时重挂，详见上方 [CHECK]）\n' "$dev_csv"
        else
            printf '  [dry-run] 跳过现场 tc qdisc 切换（--no-live-qdisc / 仅 sysctl 模式，零热切抖动）\n'
        fi
        if [ "$install_svc" = "1" ]; then
            printf '  [dry-run] 安装 %s 与 %s（替代旧版 apply-fq-qdisc.service）\n' "$DSH_BBR_APPLY_BIN" "$DSH_BBR_SVC_FILE"
        fi
        return 0
    fi

    # ── 阶段 B：状态锁与完整原始快照（每网卡精确 qdisc + 已有文件 + unit 状态）──
    local stamp tmp
    stamp="$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$DSH_BBR_STATE_ROOT" || return 1
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$DSH_BBR_STATE_ROOT/.lock"
        flock -n 9 || { _bbr_err "已有并发 BBR 配置/回滚操作在运行，请稍后重试"; return 1; }
    fi

    if [ ! -f "$DSH_BBR_STATE_ROOT/prev.env" ]; then
        local init_bk_dir="$DSH_BBR_STATE_ROOT/init-backups"
        local bk_sysctl="" bk_modload="" bk_apply_bin="" bk_svc=""
        local bk_svc_en="" bk_svc_ac=""
        local bk_leg_svc="" bk_leg_svc_en="" bk_leg_svc_ac="" bk_leg_sys="" bk_leg_mod=""
        local nic_qdiscs=""

        mkdir -p "$init_bk_dir" || return 1
        [ -n "$dev_csv" ] && nic_qdiscs="$(_dsh_bbr_snapshot_nic_qdiscs "$dev_csv")"

        if [ -e "$DSH_BBR_SYSCTL_FILE" ]; then
            bk_sysctl="$init_bk_dir/sysctl.conf"
            cp -a "$DSH_BBR_SYSCTL_FILE" "$bk_sysctl" || return 1
        fi
        if [ -e "$DSH_BBR_MODLOAD_FILE" ]; then
            bk_modload="$init_bk_dir/modules-load.conf"
            cp -a "$DSH_BBR_MODLOAD_FILE" "$bk_modload" || return 1
        fi
        if [ -e "$DSH_BBR_APPLY_BIN" ]; then
            bk_apply_bin="$init_bk_dir/dsh-apply-fq"
            cp -a "$DSH_BBR_APPLY_BIN" "$bk_apply_bin" || return 1
        fi
        if [ -e "$DSH_BBR_SVC_FILE" ]; then
            bk_svc="$init_bk_dir/dsh-bbr-qdisc.service"
            cp -a "$DSH_BBR_SVC_FILE" "$bk_svc" || return 1
            bk_svc_en="$(systemctl is-enabled "$(basename "$DSH_BBR_SVC_FILE")" 2>/dev/null || echo disabled)"
            bk_svc_ac="$(systemctl is-active "$(basename "$DSH_BBR_SVC_FILE")" 2>/dev/null || echo inactive)"
        fi
        if [ -e "$DSH_BBR_LEGACY_SVC" ]; then
            bk_leg_svc="$init_bk_dir/legacy-apply-fq-qdisc.service"
            cp -a "$DSH_BBR_LEGACY_SVC" "$bk_leg_svc" || return 1
            bk_leg_svc_en="$(systemctl is-enabled "$(basename "$DSH_BBR_LEGACY_SVC")" 2>/dev/null || echo disabled)"
            bk_leg_svc_ac="$(systemctl is-active "$(basename "$DSH_BBR_LEGACY_SVC")" 2>/dev/null || echo inactive)"
        fi
        if [ -e "$DSH_BBR_LEGACY_SYSCTL" ] && [ "$DSH_BBR_LEGACY_SYSCTL" != "$DSH_BBR_SYSCTL_FILE" ]; then
            bk_leg_sys="$init_bk_dir/legacy-99-bbr.conf"
            cp -a "$DSH_BBR_LEGACY_SYSCTL" "$bk_leg_sys" || return 1
        fi
        if [ -e "$DSH_BBR_LEGACY_MODLOAD" ] && [ "$DSH_BBR_LEGACY_MODLOAD" != "$DSH_BBR_MODLOAD_FILE" ]; then
            bk_leg_mod="$init_bk_dir/legacy-modules-99-bbr.conf"
            cp -a "$DSH_BBR_LEGACY_MODLOAD" "$bk_leg_mod" || return 1
        fi

        tmp="$(mktemp "$DSH_BBR_STATE_ROOT/.prev.XXXXXX")" || return 1
        {
            printf 'PREV_CC=%s\n' "$cur_cc"
            printf 'PREV_QD=%s\n' "$cur_qd"
            printf 'PREV_MTU=%s\n' "$cur_mtu"
            printf 'PREV_DEVS=%s\n' "$dev_csv"
            printf 'PREV_NIC_QDISCS=%s\n' "$nic_qdiscs"
            printf 'BK_SYSCTL=%s\n' "$bk_sysctl"
            printf 'BK_MODLOAD=%s\n' "$bk_modload"
            printf 'BK_APPLY_BIN=%s\n' "$bk_apply_bin"
            printf 'BK_SVC=%s\n' "$bk_svc"
            printf 'BK_SVC_ENABLED=%s\n' "$bk_svc_en"
            printf 'BK_SVC_ACTIVE=%s\n' "$bk_svc_ac"
            printf 'BK_LEGACY_SVC=%s\n' "$bk_leg_svc"
            printf 'BK_LEGACY_SVC_ENABLED=%s\n' "$bk_leg_svc_en"
            printf 'BK_LEGACY_SVC_ACTIVE=%s\n' "$bk_leg_svc_ac"
            printf 'BK_LEGACY_SYSCTL=%s\n' "$bk_leg_sys"
            printf 'BK_LEGACY_MODLOAD=%s\n' "$bk_leg_mod"
        } > "$tmp"
        chmod 600 "$tmp"
        mv -f "$tmp" "$DSH_BBR_STATE_ROOT/prev.env"
    fi

    # ── 阶段 C：原子写入、校验生效与单次切换 ──
    if [ -n "$modload_lines" ]; then
        mkdir -p "$(dirname "$DSH_BBR_MODLOAD_FILE")" || return 1
        tmp="$(mktemp "$(dirname "$DSH_BBR_MODLOAD_FILE")/.99-zz-dsh-bbr.XXXXXX")" || return 1
        printf '%s' "$modload_lines" > "$tmp"
        chmod 644 "$tmp"
        mv -f "$tmp" "$DSH_BBR_MODLOAD_FILE"
        _bbr_info "已写入 $DSH_BBR_MODLOAD_FILE"
    fi

    mkdir -p "$(dirname "$DSH_BBR_SYSCTL_FILE")" || return 1
    tmp="$(mktemp "$(dirname "$DSH_BBR_SYSCTL_FILE")/.99-zz-dsh-bbr.XXXXXX")" || return 1
    printf '%s\n' "$sysctl_body" > "$tmp"
    chmod 644 "$tmp"
    if ! sysctl -p "$tmp" >/dev/null; then
        rm -f "$tmp"
        _bbr_err "sysctl -p 校验失败，$DSH_BBR_SYSCTL_FILE 未改动"
        return 1
    fi
    _dsh_bbr_backup_file "$DSH_BBR_SYSCTL_FILE" "sysctl" "$stamp" >/dev/null || return 1
    mv -f "$tmp" "$DSH_BBR_SYSCTL_FILE"
    _bbr_info "已写入并验证 $DSH_BBR_SYSCTL_FILE"

    local cleaned_legacy=0
    if [ -e "$DSH_BBR_LEGACY_SVC" ]; then
        _dsh_bbr_backup_file "$DSH_BBR_LEGACY_SVC" "svc" "$stamp" >/dev/null || return 1
        systemctl disable --now "$(basename "$DSH_BBR_LEGACY_SVC")" >/dev/null 2>&1 || true
        systemctl reset-failed "$(basename "$DSH_BBR_LEGACY_SVC")" >/dev/null 2>&1 || true
        rm -f "$DSH_BBR_LEGACY_SVC" || return 1
        cleaned_legacy=1
        _bbr_info "已清理旧版 $DSH_BBR_LEGACY_SVC"
    fi
    if [ -e "$DSH_BBR_LEGACY_SYSCTL" ] && [ "$DSH_BBR_LEGACY_SYSCTL" != "$DSH_BBR_SYSCTL_FILE" ]; then
        _dsh_bbr_backup_file "$DSH_BBR_LEGACY_SYSCTL" "legacy-sysctl" "$stamp" >/dev/null || return 1
        rm -f "$DSH_BBR_LEGACY_SYSCTL" || return 1
        _bbr_info "已清理旧版 $DSH_BBR_LEGACY_SYSCTL"
    fi
    if [ -e "$DSH_BBR_LEGACY_MODLOAD" ] && [ "$DSH_BBR_LEGACY_MODLOAD" != "$DSH_BBR_MODLOAD_FILE" ]; then
        _dsh_bbr_backup_file "$DSH_BBR_LEGACY_MODLOAD" "legacy-modload" "$stamp" >/dev/null || return 1
        rm -f "$DSH_BBR_LEGACY_MODLOAD" || return 1
        _bbr_info "已清理旧版 $DSH_BBR_LEGACY_MODLOAD"
    fi

    if [ "$apply_qdisc" = "1" ] || [ "$live_qdisc" = "1" ] || [ "$install_svc" = "1" ]; then
        mkdir -p "$(dirname "$DSH_BBR_APPLY_BIN")" || return 1
        tmp="$(mktemp "$(dirname "$DSH_BBR_APPLY_BIN")/.dsh-apply-fq.XXXXXX")" || return 1
        _dsh_bbr_render_apply_fq_script > "$tmp"
        chmod 755 "$tmp"
        mv -f "$tmp" "$DSH_BBR_APPLY_BIN"
        _bbr_info "已安装 $DSH_BBR_APPLY_BIN"
    fi

    if [ "$install_svc" = "1" ]; then
        mkdir -p "$(dirname "$DSH_BBR_SVC_FILE")" || return 1
        tmp="$(mktemp "$(dirname "$DSH_BBR_SVC_FILE")/.dsh-bbr-qdisc.XXXXXX")" || return 1
        cat > "$tmp" <<EOF
# Managed by vpsetup/setup-bbr-sysctl.sh
[Unit]
Description=Apply fq qdisc to default route NICs without flattening mq
After=systemd-modules-load.service systemd-sysctl.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=DSH_APPLY_FQ_WAIT=30
ExecStart=$DSH_BBR_APPLY_BIN${explicit_dev:+ $explicit_dev}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        chmod 644 "$tmp"
        mv -f "$tmp" "$DSH_BBR_SVC_FILE"
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable "$(basename "$DSH_BBR_SVC_FILE")" >/dev/null 2>&1 || { _bbr_err "enable $(basename "$DSH_BBR_SVC_FILE") 失败"; return 1; }
        if [ "$live_qdisc" = "1" ]; then
            # 仅通过 service 现场执行一次（避免重复两次触发 dev_deactivate）
            systemctl restart "$(basename "$DSH_BBR_SVC_FILE")" >/dev/null 2>&1 || { _bbr_err "restart $(basename "$DSH_BBR_SVC_FILE") 失败"; return 1; }
            _bbr_info "已启用并运行 $(basename "$DSH_BBR_SVC_FILE")"
        else
            _bbr_info "已启用 $(basename "$DSH_BBR_SVC_FILE")（--no-live-qdisc：下次重启生效，本次未现场切换网卡）"
        fi
    else
        [ "$cleaned_legacy" = "1" ] && { systemctl daemon-reload >/dev/null 2>&1 || true; }
        if [ "$live_qdisc" = "1" ]; then
            DSH_APPLY_FQ_WAIT=0 SYSFS_NET_DIR="$DSH_BBR_SYSFS_NET" "$DSH_BBR_APPLY_BIN" ${explicit_dev:+"$explicit_dev"} || {
                _bbr_err "$DSH_BBR_APPLY_BIN 执行失败"
                return 1
            }
        fi
    fi

    # 读回验证
    local new_cc new_qd new_mtu
    new_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
    new_qd="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
    new_mtu="$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo '?')"
    [ -z "$want_cc" ]  || [ "$new_cc" = "$want_cc" ]   || { _bbr_err "tcp_congestion_control=$new_cc != $want_cc"; return 1; }
    [ -z "$want_qd" ]  || [ "$new_qd" = "$want_qd" ]   || { _bbr_err "default_qdisc=$new_qd != $want_qd"; return 1; }
    [ -z "$want_mtu" ] || [ "$new_mtu" = "$want_mtu" ] || { _bbr_err "tcp_mtu_probing=$new_mtu != $want_mtu"; return 1; }
    _bbr_info "基线生效：cc=$new_cc default_qdisc=$new_qd tcp_mtu_probing=$new_mtu"
}

_dsh_bbr_env_get() {
    local file="$1" key="$2"
    awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/, ""); print; exit}' "$file" 2>/dev/null || true
}

_dsh_bbr_restore_svc_state() {
    local unit_name="$1" want_en="$2" want_ac="$3"
    case "$want_en" in
        enabled)  systemctl enable "$unit_name" >/dev/null 2>&1 || return 1 ;;
        disabled) systemctl disable "$unit_name" >/dev/null 2>&1 || return 1 ;;
    esac
    case "$want_ac" in
        active)   systemctl restart "$unit_name" >/dev/null 2>&1 || return 1 ;;
        inactive) systemctl stop "$unit_name" >/dev/null 2>&1 || true ;;
    esac
    return 0
}

dsh_bbr_baseline_restore() {
    local dry_run="${1:-1}" force_default="${2:-0}"
    _dsh_bbr_init_paths
    [ "$(id -u)" -eq 0 ] || { _bbr_err "需要 root"; return 1; }

    local prev_env="$DSH_BBR_STATE_ROOT/prev.env"
    local prev_cc="cubic" prev_qd="fq_codel" prev_mtu="0" prev_devs="" prev_nic_qdiscs=""
    local bk_sysctl="" bk_modload="" bk_apply_bin="" bk_svc="" bk_svc_en="" bk_svc_ac=""
    local bk_leg_svc="" bk_leg_svc_en="" bk_leg_svc_ac="" bk_leg_sys="" bk_leg_mod=""

    if [ -f "$prev_env" ]; then
        prev_cc="$(_dsh_bbr_env_get "$prev_env" "PREV_CC")"
        prev_qd="$(_dsh_bbr_env_get "$prev_env" "PREV_QD")"
        prev_mtu="$(_dsh_bbr_env_get "$prev_env" "PREV_MTU")"
        prev_devs="$(_dsh_bbr_env_get "$prev_env" "PREV_DEVS")"
        prev_nic_qdiscs="$(_dsh_bbr_env_get "$prev_env" "PREV_NIC_QDISCS")"
        bk_sysctl="$(_dsh_bbr_env_get "$prev_env" "BK_SYSCTL")"
        bk_modload="$(_dsh_bbr_env_get "$prev_env" "BK_MODLOAD")"
        bk_apply_bin="$(_dsh_bbr_env_get "$prev_env" "BK_APPLY_BIN")"
        bk_svc="$(_dsh_bbr_env_get "$prev_env" "BK_SVC")"
        bk_svc_en="$(_dsh_bbr_env_get "$prev_env" "BK_SVC_ENABLED")"
        bk_svc_ac="$(_dsh_bbr_env_get "$prev_env" "BK_SVC_ACTIVE")"
        bk_leg_svc="$(_dsh_bbr_env_get "$prev_env" "BK_LEGACY_SVC")"
        bk_leg_svc_en="$(_dsh_bbr_env_get "$prev_env" "BK_LEGACY_SVC_ENABLED")"
        bk_leg_svc_ac="$(_dsh_bbr_env_get "$prev_env" "BK_LEGACY_SVC_ACTIVE")"
        bk_leg_sys="$(_dsh_bbr_env_get "$prev_env" "BK_LEGACY_SYSCTL")"
        bk_leg_mod="$(_dsh_bbr_env_get "$prev_env" "BK_LEGACY_MODLOAD")"
    elif [ "$force_default" != "1" ]; then
        _bbr_err "未找到状态快照 $prev_env，拒绝猜测回滚（确认需按默认值回退请加 --force-default-restore）"
        return 1
    fi

    [ -n "$prev_cc" ] && [ "$prev_cc" != "?" ] || prev_cc="cubic"
    [ -n "$prev_qd" ] && [ "$prev_qd" != "?" ] || prev_qd="fq_codel"
    [ -n "$prev_mtu" ] && [ "$prev_mtu" != "?" ] || prev_mtu="0"

    if [ "$dry_run" = "1" ]; then
        printf '  [dry-run] 回滚 %s / %s / %s / %s，恢复 cc=%s default_qdisc=%s tcp_mtu_probing=%s\n' \
            "$DSH_BBR_SVC_FILE" "$DSH_BBR_APPLY_BIN" "$DSH_BBR_SYSCTL_FILE" "$DSH_BBR_MODLOAD_FILE" \
            "$prev_cc" "$prev_qd" "$prev_mtu"
        [ -n "$prev_nic_qdiscs" ] && printf '  [dry-run] 每网卡精确还原 qdisc：%s\n' "$prev_nic_qdiscs"
        return 0
    fi

    local rc=0
    if [ -n "$bk_svc" ] && [ -f "$bk_svc" ]; then
        cp -a "$bk_svc" "$DSH_BBR_SVC_FILE" || { _bbr_err "还原 $DSH_BBR_SVC_FILE 失败"; rc=1; }
        systemctl daemon-reload >/dev/null 2>&1 || true
        _dsh_bbr_restore_svc_state "$(basename "$DSH_BBR_SVC_FILE")" "$bk_svc_en" "$bk_svc_ac" || { _bbr_err "还原 $(basename "$DSH_BBR_SVC_FILE") 状态失败"; rc=1; }
    elif [ -e "$DSH_BBR_SVC_FILE" ]; then
        systemctl disable --now "$(basename "$DSH_BBR_SVC_FILE")" >/dev/null 2>&1 || { _bbr_err "停用 $(basename "$DSH_BBR_SVC_FILE") 失败"; rc=1; }
        systemctl reset-failed "$(basename "$DSH_BBR_SVC_FILE")" >/dev/null 2>&1 || true
        rm -f "$DSH_BBR_SVC_FILE" || rc=1
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    if [ -n "$bk_leg_svc" ] && [ -f "$bk_leg_svc" ]; then
        cp -a "$bk_leg_svc" "$DSH_BBR_LEGACY_SVC" || { _bbr_err "还原 $DSH_BBR_LEGACY_SVC 失败"; rc=1; }
        systemctl daemon-reload >/dev/null 2>&1 || true
        _dsh_bbr_restore_svc_state "$(basename "$DSH_BBR_LEGACY_SVC")" "$bk_leg_svc_en" "$bk_leg_svc_ac" || { _bbr_err "还原 $(basename "$DSH_BBR_LEGACY_SVC") 状态失败"; rc=1; }
    fi
    if [ -n "$bk_leg_sys" ] && [ -f "$bk_leg_sys" ]; then
        cp -a "$bk_leg_sys" "$DSH_BBR_LEGACY_SYSCTL" || { _bbr_err "还原 $DSH_BBR_LEGACY_SYSCTL 失败"; rc=1; }
    fi
    if [ -n "$bk_leg_mod" ] && [ -f "$bk_leg_mod" ]; then
        cp -a "$bk_leg_mod" "$DSH_BBR_LEGACY_MODLOAD" || { _bbr_err "还原 $DSH_BBR_LEGACY_MODLOAD 失败"; rc=1; }
    fi

    if [ -n "$bk_apply_bin" ] && [ -f "$bk_apply_bin" ]; then
        cp -a "$bk_apply_bin" "$DSH_BBR_APPLY_BIN" || { _bbr_err "还原 $DSH_BBR_APPLY_BIN 失败"; rc=1; }
    else
        rm -f "$DSH_BBR_APPLY_BIN" || rc=1
    fi

    if [ -n "$bk_sysctl" ] && [ -f "$bk_sysctl" ]; then
        cp -a "$bk_sysctl" "$DSH_BBR_SYSCTL_FILE" || { _bbr_err "还原 $DSH_BBR_SYSCTL_FILE 失败"; rc=1; }
    else
        rm -f "$DSH_BBR_SYSCTL_FILE" || rc=1
    fi

    if [ -n "$bk_modload" ] && [ -f "$bk_modload" ]; then
        cp -a "$bk_modload" "$DSH_BBR_MODLOAD_FILE" || { _bbr_err "还原 $DSH_BBR_MODLOAD_FILE 失败"; rc=1; }
    else
        rm -f "$DSH_BBR_MODLOAD_FILE" || rc=1
    fi

    sysctl -w "net.ipv4.tcp_congestion_control=$prev_cc" >/dev/null 2>&1 || { _bbr_err "恢复 tcp_congestion_control=$prev_cc 失败"; rc=1; }
    sysctl -w "net.core.default_qdisc=$prev_qd" >/dev/null 2>&1 || { _bbr_err "恢复 default_qdisc=$prev_qd 失败"; rc=1; }
    sysctl -w "net.ipv4.tcp_mtu_probing=$prev_mtu" >/dev/null 2>&1 || { _bbr_err "恢复 tcp_mtu_probing=$prev_mtu 失败"; rc=1; }

    # 优先按每网卡精确快照回滚；若无快照（--force-default-restore）才退回 prev_devs
    if [ -n "$prev_nic_qdiscs" ]; then
        local -a entries=()
        local ent d spec kind_spec cur_qout cur_root cur_rh
        IFS=';' read -ra entries <<< "$prev_nic_qdiscs"
        for ent in "${entries[@]}"; do
            [ -n "$ent" ] || continue
            d="${ent%%=*}"
            spec="${ent#*=}"
            cur_qout="$(tc qdisc show dev "$d" 2>/dev/null | sed 's/ \\qdisc /\nqdisc /g; s/\\$//' || true)"
            cur_root="$(awk '$1=="qdisc" {for(i=1;i<=NF;i++) if($i=="root"){print $2; exit}}' <<<"$cur_qout")"
            cur_rh="$(awk '$1=="qdisc" {for(i=1;i<=NF;i++) if($i=="root"){print $3; exit}}' <<<"$cur_qout")"
            case "$spec" in
                root@*)
                    kind_spec="${spec#root@}"
                    if [ "$cur_root" != "$kind_spec" ]; then
                        tc qdisc replace dev "$d" root "$kind_spec" >/dev/null 2>&1 || { _bbr_err "恢复 $d root $kind_spec 失败"; rc=1; }
                    fi
                    ;;
                mq@*)
                    local rest="${spec#mq@}" orig_kids
                    orig_kids="${rest#*@}"
                    if [ "$cur_root" = "mq" ] && [ "$cur_rh" != "0:" ] && [ -n "$cur_rh" ]; then
                        local -a orig_pairs=() cur_parents=()
                        local pair okind idx=0
                        IFS=',' read -ra orig_pairs <<< "$orig_kids"
                        mapfile -t cur_parents < <(
                            awk -v rh="$cur_rh" '
                                $1=="qdisc" && $2!="clsact" && $2!="ingress" {
                                    for(i=1;i<NF;i++) {
                                        if($i=="parent") {
                                            p=$(i+1)
                                            if (index(p, rh)==1 && substr(p, length(rh)+1) ~ /^[0-9]+$/) print p
                                            break
                                        }
                                    }
                                }
                            ' <<<"$cur_qout"
                        )
                        for pair in "${orig_pairs[@]}"; do
                            okind="${pair#*=}"
                            if [ "$idx" -lt "${#cur_parents[@]}" ]; then
                                tc qdisc replace dev "$d" parent "${cur_parents[$idx]}" "$okind" >/dev/null 2>&1 || { _bbr_err "恢复 $d parent ${cur_parents[$idx]} -> $okind 失败"; rc=1; }
                            fi
                            idx=$((idx+1))
                        done
                    elif [ "$cur_root" = "mq" ]; then
                        tc qdisc replace dev "$d" root handle 1: mq >/dev/null 2>&1 || { _bbr_err "恢复 $d mq qdisc 失败"; rc=1; }
                    fi
                    ;;
            esac
        done
    elif [ -n "$prev_devs" ]; then
        local -a devs_arr=()
        local d qout root root_handle parent
        IFS=',' read -ra devs_arr <<< "$prev_devs"
        for d in "${devs_arr[@]}"; do
            [ -n "$d" ] || continue
            qout="$(tc qdisc show dev "$d" 2>/dev/null | sed 's/ \\qdisc /\nqdisc /g; s/\\$//' || true)"
            root="$(awk '$1=="qdisc" {for(i=1;i<=NF;i++) if($i=="root"){print $2; exit}}' <<<"$qout")"
            root_handle="$(awk '$1=="qdisc" {for(i=1;i<=NF;i++) if($i=="root"){print $3; exit}}' <<<"$qout")"
            if [ "$root" = "mq" ]; then
                if [ "$root_handle" = "0:" ] || [ -z "$root_handle" ]; then
                    tc qdisc replace dev "$d" root handle 1: mq >/dev/null 2>&1 || { _bbr_err "恢复 $d mq qdisc 失败"; rc=1; }
                else
                    while IFS= read -r parent; do
                        [ -n "$parent" ] || continue
                        tc qdisc replace dev "$d" parent "$parent" "$prev_qd" >/dev/null 2>&1 || { _bbr_err "恢复 $d parent $parent 失败"; rc=1; }
                    done < <(awk -v rh="$root_handle" '
                        $1=="qdisc" && $2!="clsact" && $2!="ingress" {
                            for(i=1;i<NF;i++) if($i=="parent") {
                                p=$(i+1)
                                if (index(p, rh)==1 && substr(p, length(rh)+1) ~ /^[0-9]+$/) print p
                                break
                            }
                        }
                    ' <<<"$qout")
                fi
            elif [ "$root" = "fq" ] && [ "$prev_qd" != "fq" ]; then
                tc qdisc replace dev "$d" root "$prev_qd" >/dev/null 2>&1 || { _bbr_err "恢复 $d root $prev_qd 失败"; rc=1; }
            fi
        done
    fi

    # 回滚后读回验证
    if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)" != "$prev_cc" ]; then
        _bbr_err "回滚后校验失败：tcp_congestion_control 未恢复为 $prev_cc"; rc=1
    fi
    if [ "$(sysctl -n net.core.default_qdisc 2>/dev/null || true)" != "$prev_qd" ]; then
        _bbr_err "回滚后校验失败：default_qdisc 未恢复为 $prev_qd"; rc=1
    fi
    if [ "$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || true)" != "$prev_mtu" ]; then
        _bbr_err "回滚后校验失败：tcp_mtu_probing 未恢复为 $prev_mtu"; rc=1
    fi

    if [ "$rc" -ne 0 ]; then
        _bbr_err "回滚未完全成功，已保留 $prev_env 与备份供排查"
        return 1
    fi
    rm -rf "$prev_env" "$DSH_BBR_STATE_ROOT/init-backups"
    _bbr_info "BBR 基线已回滚：cc=$prev_cc default_qdisc=$prev_qd tcp_mtu_probing=$prev_mtu"
}

# 严格只读验收（零写入、零 modprobe、零 tc replace、零 sysctl --system）
dsh_bbr_baseline_verify() {
    local explicit_dev="${1:-}" expect_mtu="${2:-1}" expect_bbr="${3:-1}" expect_qdisc="${4:-1}" expect_def_qd="${5:-1}"
    _dsh_bbr_init_paths
    local rc=0 cc qd mtu dev_csv devs d qout root rh tx_cnt bad_kids kid_cnt

    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
    qd="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
    mtu="$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo '?')"
    _bbr_info "只读验收 sysctl: cc=$cc default_qdisc=$qd tcp_mtu_probing=$mtu"

    if [ "$expect_bbr" = "1" ] && [ "$cc" != "bbr" ]; then
        _bbr_err "verify 失败：tcp_congestion_control=$cc != bbr"; rc=1
    fi
    if [ "$expect_def_qd" = "1" ] && [ "$qd" != "fq" ]; then
        _bbr_err "verify 失败：default_qdisc=$qd != fq"; rc=1
    fi
    if [ "$expect_mtu" = "1" ] && [ "$mtu" != "1" ]; then
        _bbr_err "verify 失败：tcp_mtu_probing=$mtu != 1"; rc=1
    fi

    if [ "$expect_qdisc" = "1" ]; then
        command -v tc >/dev/null 2>&1 || { _bbr_err "verify 失败：缺少 tc 命令"; return 1; }
        if [ -n "$explicit_dev" ]; then
            dev_csv="$explicit_dev"
        else
            devs="$(_dsh_bbr_detect_wan_devs || true)"
            dev_csv="$(printf '%s' "$devs" | awk 'NF{printf "%s%s", sep, $0; sep=","}')"
        fi
        if [ -z "$dev_csv" ]; then
            _bbr_err "verify 失败：未检出任何默认路由物理出口网卡"; return 1
        fi
        local -a vdevs=()
        IFS=',' read -ra vdevs <<< "$dev_csv"
        for d in "${vdevs[@]}"; do
            [ -n "$d" ] || continue
            qout="$(tc qdisc show dev "$d" 2>/dev/null | sed 's/ \\qdisc /\nqdisc /g; s/\\$//' || true)"
            root="$(awk '$1=="qdisc" {for(i=1;i<=NF;i++) if($i=="root"){print $2; exit}}' <<<"$qout")"
            rh="$(awk '$1=="qdisc" {for(i=1;i<=NF;i++) if($i=="root"){print $3; exit}}' <<<"$qout")"
            tx_cnt="$(ls -d "$DSH_BBR_SYSFS_NET/$d/queues/tx-"* 2>/dev/null | wc -l || echo 1)"
            if [ "$root" = "fq" ]; then
                if [ "${tx_cnt:-1}" -gt 1 ]; then
                    _bbr_err "verify 失败：$d 为多队列（$tx_cnt TX）但被拍扁成单队列 fq"; rc=1
                else
                    _bbr_info "网卡 $d: root fq [OK]"
                fi
            elif [ "$root" = "mq" ]; then
                bad_kids="$(awk -v rh="$rh" '$1=="qdisc" && $2!="clsact" && $2!="ingress" {for(i=1;i<NF;i++) if($i=="parent"){p=$(i+1); if(((rh=="0:"||rh=="") && p ~ /^:[0-9]+$/) || (rh!="0:" && rh!="" && index(p,rh)==1 && substr(p,length(rh)+1) ~ /^[0-9]+$/)){if($2!="fq") print p":"$2}; break}}' <<<"$qout" | tr '\n' ' ')"
                kid_cnt="$(awk -v rh="$rh" '$1=="qdisc" && $2!="clsact" && $2!="ingress" {for(i=1;i<NF;i++) if($i=="parent"){p=$(i+1); if(((rh=="0:"||rh=="") && p ~ /^:[0-9]+$/) || (rh!="0:" && rh!="" && index(p,rh)==1 && substr(p,length(rh)+1) ~ /^[0-9]+$/)) c++; break}} END{print c+0}' <<<"$qout")"
                if [ -z "$bad_kids" ] && [ "${kid_cnt:-0}" -ge 1 ]; then
                    _bbr_info "网卡 $d: mq ${rh:-0:} + ${kid_cnt}x fq [OK]"
                else
                    _bbr_err "verify 失败：$d mq 子队列异常（${bad_kids:-无子队列}）"; rc=1
                fi
            else
                _bbr_err "verify 失败：$d 当前 qdisc=${root:-未知}（期望 fq 或 mq+fq）"; rc=1
            fi
        done
        if [ -e "$DSH_BBR_SVC_FILE" ]; then
            local en ac
            en="$(systemctl is-enabled "$(basename "$DSH_BBR_SVC_FILE")" 2>/dev/null || echo '?')"
            if systemctl is-active --quiet "$(basename "$DSH_BBR_SVC_FILE")"; then
                ac="active"
            else
                ac="inactive"
            fi
            if [ "$en" != "enabled" ] || [ "$ac" != "active" ]; then
                _bbr_err "verify 失败：$(basename "$DSH_BBR_SVC_FILE") 状态 $en/$ac"; rc=1
            fi
        fi
    fi
    return "$rc"
}
# END DSH_BBR_BASELINE
DSH_BBR_PAYLOAD_EOF

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
if [ -n "$JUMP_HOST" ]; then
    SSH_OPTS+=(-o "ProxyCommand=ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -W %h:%p $JUMP_HOST")
fi

# 下面这段是【远端脚本原文】，单引号有意保留：本机不展开，原样喂给远端 bash。
# shellcheck disable=SC2016
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
    # shellcheck disable=SC2016  # 这里的 ${Status} 是 dpkg 的格式串，不能由本机展开
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

# 5. mask fwupd / fwupd-refresh.timer / multipathd（OCI VM 无可刷固件、单路径根盘无 multipath 对象）
echo
echo "  ── 5. 禁用无用常驻服务 (fwupd / fwupd-refresh service+timer / multipathd) ──"
for unit in fwupd.service fwupd-refresh.service fwupd-refresh.timer multipathd.service; do
    unit_state=$(systemctl is-enabled "$unit" 2>/dev/null || true)
    case "$unit_state" in
        masked)
            echo "     ○ $unit 已 masked"
            continue
            ;;
        not-found|"")
            echo "     ○ $unit 不存在，跳过"
            continue
            ;;
    esac
    if [ "$DRY_RUN" = "1" ]; then
        echo "     + [dry-run] 将 mask 并停止: $unit (当前 $unit_state)"
    else
        systemctl mask --now "$unit" >/dev/null 2>&1 || true
        # mask 之后必须 reset-failed：mask 一个已经 failed 的单元，它的
        # failed 状态会留在 systemd 里，`systemctl --failed` 照样能数到它，
        # 于是验收脚本会报「failed-units = 1」（2026-11-22 oraclejp 实测：
        # fwupd-refresh.service 长期 failed，但 fwupd-refresh.timer 已 mask）。
        systemctl reset-failed "$unit" >/dev/null 2>&1 || true
        echo "     ✅ 已 mask 并停止: $unit"
        CHANGED=$((CHANGED + 1))
    fi
done

# 同一批单元的残留 failed 状态统一清一次（幂等，已 masked 的也要清）
for unit in fwupd.service fwupd-refresh.service fwupd-refresh.timer multipathd.service; do
    systemctl reset-failed "$unit" >/dev/null 2>&1 || true
done

# 6. 512MB /swapfile（1GB 微机内存兜底，对齐 JP/UK；fstab 持久化）
echo
SWAP_SIZE_MB=512
echo "  ── 6. Swap 文件 (${SWAP_SIZE_MB}MB) ──"
if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "/swapfile"; then
    echo "     ○ /swapfile 已挂载: $(swapon --show=SIZE,USED --noheadings /swapfile 2>/dev/null)"
else
    if [ "$DRY_RUN" = "1" ]; then
        echo "     + [dry-run] 将创建并挂载 /swapfile (${SWAP_SIZE_MB}MB) 并写入 fstab"
    else
        disk_avail_mb=$(df -m --output=avail / | tail -1 | tr -d " ")
        if [ "${disk_avail_mb:-0}" -lt $((SWAP_SIZE_MB + 512)) ]; then
            echo "     ⚠️ 根分区可用 ${disk_avail_mb}MB，不足 ${SWAP_SIZE_MB}MB swap + 512MB 余量，跳过创建"
        else
            if [ ! -f /swapfile ]; then
                fallocate -l "${SWAP_SIZE_MB}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_SIZE_MB" status=none
                chmod 600 /swapfile
                mkswap /swapfile >/dev/null
            fi
            swapon /swapfile
            echo "     ✅ 已创建并挂载 /swapfile (${SWAP_SIZE_MB}MB)"
            CHANGED=$((CHANGED + 1))
        fi
    fi
fi
# fstab 持久化（覆盖「swap 已挂载但 fstab 缺条目」的遗留状态）
if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "/swapfile" && ! grep -qE "^/swapfile[[:space:]]" /etc/fstab; then
    if [ "$DRY_RUN" = "1" ]; then
        echo "     + [dry-run] /swapfile 已挂载但 fstab 缺条目，将补写"
    else
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
        echo "     ✅ 已补写 fstab 条目"
        CHANGED=$((CHANGED + 1))
    fi
fi

# 7. BBR + fq（保留 mq 多队列）+ tcp_mtu_probing=1
echo
echo "  ── 7. BBR + fq + tcp_mtu_probing=1 ──"
if [ "$DRY_RUN" = "1" ]; then
    dsh_bbr_baseline_apply 1 "" 1 1 || { echo "     ❌ BBR 基线预检失败"; exit 1; }
else
    dsh_bbr_baseline_apply 0 "" 1 1 || { echo "     ❌ BBR 基线应用失败"; exit 1; }
    CHANGED=$((CHANGED + 1))
fi
'

if [ "$LOCAL_MODE" -eq 1 ]; then
    echo "════════ local ($(hostname)) ════════"
    {
        printf 'DRY_RUN=%q\n' "$DRY_RUN"
        printf '%s\n' "$DSH_BBR_BLOCK"
        printf '%s\n' "$REMOTE_SCRIPT"
    } | sudo -n bash -s
    exit $?
fi

rc_all=0
for target in "${HOSTS[@]}"; do
    # 支持 user@host:port（如 root@node.example.com:26320）
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
        printf 'DRY_RUN=%q\n' "$DRY_RUN"
        printf '%s\n' "$DSH_BBR_BLOCK"
        printf '%s\n' "$REMOTE_SCRIPT"
    } | ssh "${SSH_OPTS[@]}" "${tgt_opts[@]}" "$tgt" 'sudo -n bash -s' || rc_all=1
    echo
done

exit "$rc_all"
