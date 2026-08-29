#!/usr/bin/env bash
#
# gather-iptables.sh — 从多台主机收集 iptables 持久化配置，供对比分析
#
# 用法: ./gather-iptables.sh [user@]host ...
#   例: ./gather-iptables.sh ubuntu@oraclejp.henhaoji.site ubuntu@oraclejp-2.henhaoji.site \
#                            ubuntu@84.8.146.223 ubuntu@145.241.242.232
#
# 输出目录: ./iptables-dump/<host>/
#   meta.txt            主机名/系统/文件大小/持久化服务状态
#   rules.v4            磁盘上的持久化配置（重启后生效的那份）
#   rules.v6
#   iptables-live.txt   当前内核里实际生效的规则（可能与 rules.v4 不同）
#   ip6tables-live.txt
#
# 前提：本机 SSH 私钥已授权到目标主机（OCI Ubuntu 默认用户 ubuntu，sudo 免密）

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR/iptables-dump}"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)

if [ $# -eq 0 ]; then
    echo "用法: $0 [user@]host ..." >&2
    echo "示例: $0 ubuntu@oraclejp.henhaoji.site ubuntu@84.8.146.223" >&2
    exit 2
fi

mkdir -p "$OUT_DIR" || { echo "错误: 无法创建输出目录 $OUT_DIR" >&2; exit 1; }

rc_all=0
for target in "$@"; do
    host="${target#*@}"
    safe_host="${host//:/_}"
    dir="$OUT_DIR/$safe_host"
    rm -rf "$dir"
    mkdir -p "$dir"

    printf '=== %s ===\n' "$target"

    if ! ssh "${SSH_OPTS[@]}" "$target" 'true' 2>"$dir/_conn.err"; then
        echo "  ❌ 无法连接（密钥未授权或主机不可达）"
        sed 's/^/     /' "$dir/_conn.err" | head -3
        rc_all=1
        continue
    fi

    # 元数据：文件大小是判断 rules.v6 是否为空的关键
    ssh "${SSH_OPTS[@]}" "$target" 'bash -s' >"$dir/meta.txt" 2>&1 <<'REMOTE'
echo "hostname: $(hostname)"
echo "os: $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo unknown)"
echo "kernel: $(uname -r)"
echo "--- 持久化文件 ---"
for f in /etc/iptables/rules.v4 /etc/iptables/rules.v6; do
    if [ -e "$f" ]; then
        echo "$f: 存在, 字节数=$(stat -c %s "$f"), 行数=$(wc -l < "$f")"
    else
        echo "$f: 不存在"
    fi
done
echo "--- 持久化机制 ---"
echo "iptables-persistent 已安装: $(dpkg -l iptables-persistent 2>/dev/null | grep -c '^ii')"
echo "netfilter-persistent 开机启用: $(systemctl is-enabled netfilter-persistent 2>/dev/null || echo unknown)"
echo "netfilter-persistent 当前状态: $(systemctl is-active netfilter-persistent 2>/dev/null || echo unknown)"
echo "--- 网络接口与地址（用于识别绑定私有 IP 的规则）---"
ip -o addr show scope global 2>/dev/null | awk '{print "  ", $2, $4}'
REMOTE

    # 磁盘上的持久化配置（这才是重启后生效的）
    ssh "${SSH_OPTS[@]}" "$target" 'sudo -n cat /etc/iptables/rules.v4 2>&1' >"$dir/rules.v4" 2>&1
    ssh "${SSH_OPTS[@]}" "$target" 'sudo -n cat /etc/iptables/rules.v6 2>&1' >"$dir/rules.v6" 2>&1

    # 内存中实际生效的规则（对比用：能看出是否有未保存的改动）
    ssh "${SSH_OPTS[@]}" "$target" 'sudo -n iptables-save 2>&1' >"$dir/iptables-live.txt" 2>&1
    ssh "${SSH_OPTS[@]}" "$target" 'sudo -n ip6tables-save 2>&1' >"$dir/ip6tables-live.txt" 2>&1

    echo "  ✅ 已采集 → $dir/"
    echo "     rules.v4: $(wc -c <"$dir/rules.v4") 字节, rules.v6: $(wc -c <"$dir/rules.v6") 字节"
done

echo
echo "输出目录: $OUT_DIR"
echo "把这个目录的内容贴给我，或让我直接读取即可。"
exit "$rc_all"
