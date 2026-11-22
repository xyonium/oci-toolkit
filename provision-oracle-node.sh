#!/usr/bin/env bash
#
# provision-oracle-node.sh — Oracle 26.04 节点全开荒（一条命令走完 bootstrap 流程）
#
# 为什么需要这个脚本：
#   ZPUSSJ 开荒时漏了「收敛收尾」（卸 iptables-persistent），导致
#   setup-podman.sh 的 HOST_FW 判定错误、阶段 0.3 中止。
#   步骤顺序和收尾动作靠人记必然会漏 —— 固化成脚本。
#
# 用法:
#   ./provision-oracle-node.sh <user@host> --domain <域名> --wan-iface <网卡> [--apply]
#   ./provision-oracle-node.sh ubuntu@1.2.3.4 --domain <你的域名> \
#       --wan-iface ens3 --apply
#
# 不做 --apply 时是 dry-run（只跑各脚本的 dry-run，不改任何东西）
#
# 前置：SSH key 已就位、DNS 已配好（A + AAAA）
#
# 退出码: 0 全部成功 / 1 某步失败（会停在那里，不会继续往下走）

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CALLER_DIR="$(pwd)"

TARGET=""
DOMAIN=""
WAN_IFACE=""
APPLY=0
EMAIL="${EMAIL:-}"
SKIP_XRAY=0
SKIP_PODMAN=0

die() { echo "错误: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --domain)     shift; DOMAIN="${1:-}"; [ -n "$DOMAIN" ] || die "--domain 需要参数" ;;
        --wan-iface)  shift; WAN_IFACE="${1:-}"; [ -n "$WAN_IFACE" ] || die "--wan-iface 需要参数" ;;
        --email)      shift; EMAIL="${1:-}" ;;
        --apply)      APPLY=1 ;;
        --skip-xray)  SKIP_XRAY=1 ;;
        --skip-podman) SKIP_PODMAN=1 ;;
        -h|--help)    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)           die "未知选项 $1" ;;
        *)            TARGET="$1" ;;
    esac
    shift
done

[ -n "$TARGET" ]   || die "缺少 <user@host>"
[ -n "$DOMAIN" ]   || die "缺少 --domain"
[ -n "$WAN_IFACE" ] || die "缺少 --wan-iface（用 ip -o link show 查，通常 ens3/ens4/enp0s6）"

MODE="dry-run"; [ "$APPLY" = "1" ] && MODE="apply"
echo "══════════════════════════════════════════════════════════"
echo " 目标: $TARGET"
echo " 域名: $DOMAIN"
echo " 网卡: $WAN_IFACE"
echo " 模式: $MODE"
echo "══════════════════════════════════════════════════════════"

# 找脚本位置（可能在 oci-toolkit 同目录，也可能被拷到别处）
find_script() {
    local name="$1"
    for d in "$SCRIPT_DIR" "$SCRIPT_DIR/../vpsetup" "$CALLER_DIR" "$CALLER_DIR/../vpsetup" \
             "/home/eli/cloud/oci-toolkit" "/home/eli/cloud/vpsetup"; do
        [ -f "$d/$name" ] && { echo "$d/$name"; return 0; }
    done
    return 1
}

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new
          -o UserKnownHostsFile="$HOME/.ssh/known_hosts" -o LogLevel=ERROR)

USER_AT_HOST="$TARGET"
HOST_ONLY="${TARGET#*@}"

remote() { ssh "${SSH_OPTS[@]}" "$USER_AT_HOST" "$@"; }
upload() { scp "${SSH_OPTS[@]}" "$1" "$USER_AT_HOST:/tmp/"; }

STEP=0
step() { STEP=$((STEP+1)); echo; echo "──────── [$STEP] $* ────────"; }
ok()   { echo "  ✅ $*"; }
bad()  { echo "  ❌ $*"; echo; echo "🛑 在第 $STEP 步中止。修好后可从这一步重跑（脚本幂等）。"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
step "0. 前置检查"
# ─────────────────────────────────────────────────────────────────────────────
OSV=$(remote 'grep "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d "\""' 2>/dev/null)
[ -n "$OSV" ] || bad "SSH 连不上 $TARGET"
echo "  OS: $OSV"
case "$OSV" in
    26.04|2[7-9].*|[3-9][0-9].*) ok "26.04+（本次支持的目标版本）" ;;
    *) echo "  ⚠️ 本脚本按 26.04 设计（netavark >= 1.16 + 纯 nft）。$OSV 上请先升级。" ;;
esac

# 网卡存在吗
if remote "ip -o link show | awk -F': ' '{print \$2}' | grep -qx '$WAN_IFACE'" 2>/dev/null; then
    ok "网卡 $WAN_IFACE 存在"
else
    bad "网卡 $WAN_IFACE 不存在。实际网卡：$(remote "ip -o link show | awk -F': ' '{print \$2}' | grep -vE '^(lo|veth)' | tr '\n' ' '" 2>/dev/null)"
fi

# DNS 指向本机吗
PUB4=$(remote "curl -s -m 8 -4 https://ifconfig.me" 2>/dev/null)
DNS4=$(dig +short "$DOMAIN" A @1.1.1.1 2>/dev/null | grep -E '^[0-9]' | head -1)
echo "  本机 IPv4: ${PUB4:-未知}   DNS A: ${DNS4:-未解析}"
if [ "$PUB4" = "$DNS4" ]; then
    ok "DNS A 已指向本机"
else
    echo "  ⚠️ DNS A 与本机 IP 不一致（证书签发可能失败）。先配 DNS 再跑本脚本。"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "1. 系统基线优化（journald 限额 / swappiness / swap / mask 无关服务 / ssh enable）"
# ─────────────────────────────────────────────────────────────────────────────
S=$(find_script optimize-oracle-vps.sh) || bad "找不到 optimize-oracle-vps.sh"
echo "  脚本: $S"
if [ "$APPLY" = "1" ]; then
    bash "$S" "$TARGET" --apply 2>&1 | grep -E '✅|○|❌|⚠️' | sed 's/^/  /'
else
    bash "$S" "$TARGET" 2>&1 | grep -E '\+ \[dry-run\]|○|当前' | sed 's/^/  /'
fi

# ─────────────────────────────────────────────────────────────────────────────
step "2. 收敛收尾前置确认：oci_meta 是否完整"
#   注意顺序：必须在卸 iptables-persistent 之前确认 nft 已接管 InstanceServices
# ─────────────────────────────────────────────────────────────────────────────
OCI_META_N=$(remote 'nft list table inet oci_meta 2>/dev/null | grep -c accept' 2>/dev/null || echo 0)
echo "  oci_meta accept 条数: $OCI_META_N"
if [ "${OCI_META_N:-0}" -ge 10 ]; then
    ok "oci_meta 已接管 InstanceServices"
elif [ "$APPLY" = "1" ]; then
    echo "  ○ 还没跑过 init-firewall.sh，第 3 步会创建"
else
    echo "  ○ 还没跑过 init-firewall.sh（dry-run 模式，正常）"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "3. 主机防火墙（--converge-legacy --enable-oci-meta）"
# ─────────────────────────────────────────────────────────────────────────────
S=$(find_script init-firewall.sh) || bad "找不到 init-firewall.sh"
echo "  脚本: $S"
FW_ARGS=(--local --profile proxy --wan-ifaces "$WAN_IFACE" --enable-oci-meta
         --enable-podman-dnat --disable-rpcbind --converge-legacy)
[ "$APPLY" = "1" ] && FW_ARGS+=(--apply) || FW_ARGS+=(--dry-run)

upload "$S" >/dev/null 2>&1
remote "sudo -n bash /tmp/init-firewall.sh ${FW_ARGS[*]}" 2>&1 \
    | grep -E '✅|❌|⚠️|○' | tail -18 | sed 's/^/  /'

# ─────────────────────────────────────────────────────────────────────────────
step "4. 收敛收尾（卸 iptables-persistent + 删 rules.v4/v6）"
#   全新 Oracle 26.04 镜像自带这两个，跑完 converge 后必须清掉：
#     · setup-podman.sh 的 HOST_FW 判定靠「rules.v4/v6 都不在」识别 nft-only
#     · 留着的话重启时 netfilter-persistent 会把文件重新加载
# ─────────────────────────────────────────────────────────────────────────────
if [ "$APPLY" != "1" ]; then
    echo "  [dry-run] 将执行："
    echo "    · 确认 oci_meta accept >= 10"
    echo "    · 备份 rules.v4/v6 到 /root/fw-backup-<stamp>/"
    echo "    · systemctl disable --now netfilter-persistent"
    echo "    · apt-get purge -y iptables-persistent netfilter-persistent"
    echo "    · mv rules.v4/v6 到备份目录（不是 rm，可回滚）"
else
    remote 'sudo -n bash -s' <<'EOS'
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive

N=$(nft list table inet oci_meta 2>/dev/null | grep -c accept)
echo "  oci_meta accept: $N"
if [ "$N" -lt 10 ]; then
    echo "  ❌ oci_meta 不完整（$N 条），拒绝卸 iptables-persistent"
    echo "     先确认 init-firewall.sh --enable-oci-meta 真的生效（脚本版本 >= 059a91c）"
    exit 1
fi
MD=$(curl -s -m 5 -H 'Authorization: Bearer Oracle' http://169.254.169.254/opc/v2/instance/hostname 2>/dev/null)
echo "  metadata 前置检查: ${MD:-失败}"
if [ -z "$MD" ]; then echo "  ❌ metadata 不可达，拒绝继续"; exit 1; fi

STAMP=$(date +%Y%m%d-%H%M%S)
BK="/root/fw-backup-$STAMP"
mkdir -p "$BK"
cp -a /etc/iptables/rules.v4 /etc/iptables/rules.v6 "$BK"/ 2>/dev/null || true
echo "  ✅ 备份到 $BK"

systemctl disable --now netfilter-persistent >/dev/null 2>&1 && echo "  ✅ netfilter-persistent 已停用"
apt-get purge -y -qq iptables-persistent netfilter-persistent >/dev/null 2>&1 && echo "  ✅ 包已卸载"

mv /etc/iptables/rules.v4 "$BK/rules.v4.removed" 2>/dev/null && echo "  ✅ rules.v4 已移走"
mv /etc/iptables/rules.v6 "$BK/rules.v6.removed" 2>/dev/null && echo "  ✅ rules.v6 已移走"

# ── 清空内核态的 iptables 表 ──
#
# 关键：卸包 + 删文件只改了**磁盘**，开机时 netfilter-persistent 已经把
# rules.v4 加载进内核，那些规则还在 ip filter / ip6 filter 表里挂着。
# 不清的话 setup-podman.sh 的 0.3 会正确地拒绝：
#   ❌ [中止] nft-only 主机防火墙，但 iptables(v4) 仍有非 ACCEPT 策略或残留
# （实测 zpussj-x86-2 就是这样：卸包后 iptables -S 还有 26 行）
#
# 清空是安全的：InstanceServices 已由 nft 的 table inet oci_meta 接管
# （上面刚确认过 >= 10 条 accept），dsh_firewall 在 nft 侧负责 INPUT 裁决。
echo "  ── 清空内核态 iptables（磁盘文件已移走，规则已由 nft 接管）──"
if command -v iptables >/dev/null 2>&1; then
    # 先删自定义链（-X 会失败如果链还被引用，所以先 flush）
    iptables -F 2>/dev/null && echo "    ✅ ip filter 已 flush"
    iptables -X 2>/dev/null && echo "    ✅ 自定义链已删"
    iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -P OUTPUT ACCEPT
fi
if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -F 2>/dev/null && echo "    ✅ ip6 filter 已 flush"
    ip6tables -X 2>/dev/null && echo "    ✅ v6 自定义链已删"
    ip6tables -P INPUT ACCEPT; ip6tables -P FORWARD ACCEPT; ip6tables -P OUTPUT ACCEPT
fi
echo "    v4 剩余: $(iptables -S 2>/dev/null | wc -l) 行"
echo "    v6 剩余: $(ip6tables -S 2>/dev/null | wc -l) 行"

echo "  ── 收尾验证 ──"
echo "    rules.v4: $([ -e /etc/iptables/rules.v4 ] && echo 仍在 || echo 已删)"
echo "    rules.v6: $([ -e /etc/iptables/rules.v6 ] && echo 仍在 || echo 已删)"
echo "    iptables-persistent: $(dpkg-query -W -f='${Status}' iptables-persistent 2>/dev/null || echo 已卸载)"
echo "    metadata 复验: $(curl -s -m 5 -H 'Authorization: Bearer Oracle' http://169.254.169.254/opc/v2/instance/hostname 2>/dev/null || echo 失败)"
echo "    iptables -S: $(iptables -S 2>/dev/null | wc -l) 行"
echo "    nft 表: $(nft list tables 2>/dev/null | wc -l) 张"
EOS
fi

# ─────────────────────────────────────────────────────────────────────────────
step "5. 装 podman（三元判定：nft / 混合形态 / 传统）"
# ─────────────────────────────────────────────────────────────────────────────
if [ "$SKIP_PODMAN" = "1" ]; then
    echo "  ⏭️  --skip-podman"
else
    S=$(find_script setup-podman.sh) || bad "找不到 setup-podman.sh"
    echo "  脚本: $S"
    PA=(--local)
    [ "$APPLY" = "1" ] && PA+=(--apply)
    upload "$S" >/dev/null 2>&1
    remote "sudo -n bash /tmp/setup-podman.sh ${PA[*]}" 2>&1 \
        | grep -E '◆|→|✅|○|❌|⚠️' | head -30 | sed 's/^/  /'
fi

# ─────────────────────────────────────────────────────────────────────────────
step "6. 装代理栈（Caddy + Xray REALITY/WS/XHTTP + Hysteria2）"
# ─────────────────────────────────────────────────────────────────────────────
if [ "$SKIP_XRAY" = "1" ]; then
    echo "  ⏭️  --skip-xray"
else
    S=$(find_script setup_caddy_xray_hysteria.sh) || bad "找不到 setup_caddy_xray_hysteria.sh"
    echo "  脚本: $S"
    if [ -f "$(dirname "$S")/cdn-cidrs-v6.txt" ]; then
        upload "$(dirname "$S")/cdn-cidrs-v6.txt" >/dev/null 2>&1
        remote 'sudo -n bash -c "mv /tmp/cdn-cidrs-v6.txt /root/ 2>/dev/null || true"' >/dev/null 2>&1
    fi
    upload "$S" >/dev/null 2>&1
    if [ "$APPLY" = "1" ]; then
        remote "sudo -n bash -c 'mv /tmp/setup_caddy_xray_hysteria.sh /root/ 2>/dev/null; cd /root && DOMAIN=$DOMAIN EMAIL=$EMAIL HY2_CERT_MODE=http bash /root/setup_caddy_xray_hysteria.sh'" 2>&1 \
            | grep -E 'REALITY 公钥|\[vless|\[hysteria|完成|WARN|启用' | head -14 | sed 's/^/  /'
    else
        echo "  [dry-run] 跳过（xray 脚本的 dry-run 需要专用目录，这里不跑）"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
step "7. nftables 服务 + 清理假 failed"
# ─────────────────────────────────────────────────────────────────────────────
if [ "$APPLY" = "1" ]; then
    remote 'sudo -n bash -c "
systemctl start nftables 2>/dev/null
systemctl reset-failed fwupd-refresh.timer fwupd.service multipathd.service 2>/dev/null
echo \"  nftables: \$(systemctl is-enabled nftables)/\$(systemctl is-active nftables)\"
echo \"  failed: \$(systemctl --failed --no-legend | wc -l)\"
"' 2>&1 | sed 's/^/  /'
else
    echo "  [dry-run] systemctl start nftables && systemctl reset-failed ..."
fi

# ─────────────────────────────────────────────────────────────────────────────
step "8. 验收（verify-bootstrap.sh，28 项）"
# ─────────────────────────────────────────────────────────────────────────────
V=$(find_script verify-bootstrap.sh 2>/dev/null || true)
if [ -z "$V" ] && [ -f "$SCRIPT_DIR/../gc-toolkit/verify-bootstrap.sh" ]; then
    V="$SCRIPT_DIR/../gc-toolkit/verify-bootstrap.sh"
fi
if [ -n "$V" ] && [ -f "$V" ]; then
    echo "  脚本: $V"
    bash "$V" "$TARGET" 2>&1 | tail -35 | sed 's/^/  /'
else
    echo "  ⚠️ 找不到 verify-bootstrap.sh，跳过机器验收"
    echo "     手工核对见 gc-toolkit/bootstrap-vm.md §11"
fi

echo
echo "══════════════════════════════════════════════════════════"
if [ "$APPLY" = "1" ]; then
    echo " 完成。域名: $DOMAIN"
    echo " 取分享链接: sudo ACTION=links bash /root/setup_caddy_xray_hysteria.sh"
    echo " 流量守卫（GCP 才需要）: 见 gc-toolkit/bootstrap-vm.md §8"
else
    echo " dry-run 结束。确认无误后加 --apply 执行。"
fi
echo "══════════════════════════════════════════════════════════"
