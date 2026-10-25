#!/usr/bin/env bash
#
# setup-vcn.sh — 在 OCI 租户上补齐 default VCN 的互联网出口与安全规则（幂等）
#
# 前提：租户注册自带 default VCN（双栈）。本脚本只补缺，重复跑无副作用：
#   1. Internet Gateway — 不存在则创建
#   2. 默认路由表 — 追加 0.0.0.0/0 与 ::/0 指向 IGW（已存在则跳过）
#   3. 默认安全列表 — 合并追加自定义入站规则（默认规则原样保留，不重复）
#
# 用法: ./setup-vcn.sh [--dry-run] [env文件路径]

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=0
ENV_FILE="$SCRIPT_DIR/.env"
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
        *)         ENV_FILE="$1" ;;
    esac
    shift
done

[ -f "$ENV_FILE" ] || { echo "错误: 配置文件不存在: $ENV_FILE" >&2; exit 1; }
# shellcheck source=/dev/null
source "$ENV_FILE"

if [ -n "${OCI_BIN:-}" ]; then OCI_BIN=$(eval echo "$OCI_BIN"); fi
OCI_BIN="${OCI_BIN:-oci}"
# 若 OCI_BIN 为裸命令名（如 "oci"），先解析到真实二进制路径，避免与下方 oci() 函数同名递归
if [ "$OCI_BIN" = "oci" ]; then OCI_BIN="$(command -v oci || true)"; fi
PROFILE="${OCI_PROFILE:-DEFAULT}"
[ -n "${COMPARTMENT_ID:-}" ] || { echo "错误: COMPARTMENT_ID 未配置" >&2; exit 1; }
if [ "$DRY_RUN" -eq 0 ]; then
    command -v "$OCI_BIN" >/dev/null 2>&1 || { echo "错误: 找不到 OCI CLI: $OCI_BIN" >&2; exit 1; }
fi
command -v python3 >/dev/null 2>&1 || { echo "错误: 需要 python3" >&2; exit 1; }

oci() { "$OCI_BIN" --profile "$PROFILE" --auth api_key "$@"; }
say() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ─── 发现或创建 default VCN / RT / SL ────────────────────────────────────────
VCN_ID="${VCN_ID:-}"
if [ -z "$VCN_ID" ]; then
    VCN_ID=$(oci network vcn list --compartment-id "$COMPARTMENT_ID" --output json --all 2>/dev/null | python3 -c '
import sys, json
raw = sys.stdin.read().strip()
if not raw:
    sys.exit(0)
d = json.loads(raw).get("data") or []
pref = [v for v in d if "default" in (v.get("display-name") or "").lower()]
print((pref or d)[0]["id"] if d else "")
' 2>/dev/null || echo "")
fi

if [ -z "$VCN_ID" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        say "[dry-run] 未找到任何 VCN，将创建双栈 VCN: default-vcn (10.0.0.0/16 + IPv6 /56)"
        say "[dry-run] 随后将创建 IGW、双栈默认路由、43 条入站安全列表及双栈 default-subnet (10.0.0.0/24 + /64)"
        exit 0
    fi
    say "未找到任何 VCN，正在创建双栈 VCN (default-vcn, 10.0.0.0/16 + IPv6)..."
    VCN_ID=$(oci network vcn create \
        --compartment-id "$COMPARTMENT_ID" \
        --display-name "default-vcn" \
        --dns-label "defaultvcn" \
        --cidr-blocks '["10.0.0.0/16"]' \
        --is-ipv6-enabled true \
        --query 'data.id' --raw-output 2>/dev/null) || { say "❌ VCN 创建失败"; exit 1; }
    [ -n "$VCN_ID" ] && [ "$VCN_ID" != "null" ] || { say "❌ VCN 创建失败"; exit 1; }
    say "✅ VCN 创建成功: $VCN_ID"
fi

VCN_JSON=$(oci network vcn get --vcn-id "$VCN_ID" --output json 2>/dev/null) || { say "❌ 读取 VCN 信息失败"; exit 1; }
RT_ID=$(printf '%s' "$VCN_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["default-route-table-id"])')
SL_ID=$(printf '%s' "$VCN_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["default-security-list-id"])')
VCN_IPV6_CIDR=$(printf '%s' "$VCN_JSON" | python3 -c 'import sys,json; b=json.load(sys.stdin)["data"].get("ipv6-cidr-blocks") or []; print(b[0] if b else "")')
[ -n "$RT_ID" ] && [ -n "$SL_ID" ] || { say "❌ 解析 VCN JSON 失败"; exit 1; }
say "VCN: $VCN_ID (IPv6: ${VCN_IPV6_CIDR:-none})"
say "RT:  $RT_ID"
say "SL:  $SL_ID"

# ─── 1. Internet Gateway ─────────────────────────────────────────────────────
IGW_ID=$(oci network internet-gateway list --compartment-id "$COMPARTMENT_ID" \
    --vcn-id "$VCN_ID" --output json --all 2>/dev/null | python3 -c '
import sys, json
raw = sys.stdin.read().strip()
if not raw:
    sys.exit(0)
d = json.loads(raw).get("data") or []
print(d[0]["id"] if d else "")
' 2>/dev/null || echo "")
if [ -n "$IGW_ID" ]; then
    say "IGW 已存在: $IGW_ID"
elif [ "$DRY_RUN" -eq 1 ]; then
    say "[dry-run] 将创建 Internet Gateway: oci network internet-gateway create (display-name=igw-internet, enabled=true)"
    IGW_ID="(dry-run-igw)"
else
    IGW_ID=$(oci network internet-gateway create \
        --compartment-id "$COMPARTMENT_ID" --vcn-id "$VCN_ID" \
        --display-name "igw-internet" --is-enabled true \
        --query 'data.id' --raw-output) || { say "❌ IGW 创建失败"; exit 1; }
    [ -n "$IGW_ID" ] || { say "❌ IGW 创建失败"; exit 1; }
    say "IGW 创建成功: $IGW_ID"
fi

# ─── 2. 默认路由表：0.0.0.0/0 + ::/0 → IGW ───────────────────────────────────
RT_JSON=$(oci network route-table get --rt-id "$RT_ID" --output json) || { say "❌ 读取路由表信息失败"; exit 1; }
NEW_RULES=$(printf '%s' "$RT_JSON" | python3 -c '
import sys, json
d = json.load(sys.stdin)["data"]
rules = d.get("route-rules") or []
igw = sys.argv[1]
have = {(r.get("destination"), r.get("destination-type")) for r in rules}
for dest in ("0.0.0.0/0", "::/0"):
    if (dest, "CIDR_BLOCK") not in have:
        rules.append({"network-entity-id": igw, "destination": dest, "destination-type": "CIDR_BLOCK"})
json.dump(rules, sys.stdout)
' "$IGW_ID")
[ -n "$NEW_RULES" ] || { say "❌ 解析路由表 JSON 失败"; exit 1; }
if [ "$DRY_RUN" -eq 1 ]; then
    say "[dry-run] 将更新路由表: $(printf '%s' "$NEW_RULES" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))') 条规则（补 0.0.0.0/0 与 ::/0）"
else
    printf '%s' "$NEW_RULES" | python3 -c 'import sys,json; rules=json.load(sys.stdin); print("路由规则:"); [print("  ", r["destination"], "->", r["network-entity-id"][-12:]) for r in rules]' | while IFS= read -r line; do say "$line"; done
    oci network route-table update --rt-id "$RT_ID" \
        --route-rules "$(printf '%s' "$NEW_RULES")" --force >/dev/null \
        || { say "❌ 路由表更新失败"; exit 1; }
    say "✅ 路由表已更新（双栈默认路由 → IGW）"
fi

# ─── 3. 默认安全列表：合并追加自定义入站规则 ─────────────────────────────────
SL_JSON=$(oci network security-list get --security-list-id "$SL_ID" --output json) || { say "❌ 读取安全列表信息失败"; exit 1; }
MERGED_FILE=$(mktemp)
SL_SUMMARY_FILE=$(mktemp)
trap 'rm -f "$MERGED_FILE" "$SL_SUMMARY_FILE"' EXIT
printf '%s' "$SL_JSON" | python3 -c '
import sys, json

d = json.load(sys.stdin)["data"]
ing = d.get("ingress-security-rules") or []
eg  = d.get("egress-security-rules") or []

# 与旧租户安全列表对齐的自定义规则（默认 SL 已含 SSH/ICMP/egress，不重复）。
GROUPS = [
    # (proto, is_udp, min, max, desc_v4, desc_v6)
    (6,  False, 80,    80,    "http,https",      "http,https"),
    (6,  False, 443,   443,   "http,https",      "http,https"),
    (6,  False, 8443,  8443,  "http,https",      "http,https"),
    (6,  False, 8080,  8880,  "http,https",      "http,https"),
    (17, True,  80,    80,    "http,https",      "http,https"),
    (17, True,  443,   443,   "http,https",      "http,https"),
    (17, True,  8443,  8443,  "http,https",      "http,https"),
    (17, True,  8080,  8880,  "http,https",      "http,https"),
    (6,  False, 9000,  65535, "zerotiertcpipv4", "zerotiertcpipv6"),
    (17, True,  9993,  65535, "zerotierudpipv4", "zerotierudpipv6"),
    (6,  False, 3478,  3479,  "coturn-matrix",   "coturn-matrix"),
    (6,  False, 5349,  5350,  "coturn-matrix",   "coturn-matrix"),
    (17, True,  3478,  3479,  "coturn-matrix",   "coturn-matrix"),
    (17, True,  5349,  5350,  "coturn-matrix",   "coturn-matrix"),
    (6,  False, 8448,  8448,  "coturn-matrix",   "coturn-matrix"),
    (6,  False, 5901,  5901,  "VNC",             "vnc v6"),
    (6,  False, 6001,  6001,  "VNC",             "vnc v6"),
    (6,  False, 3333,  3334,  "bitmag-tcp",      "bitmag-ipv6-tcp"),
    (17, True,  3334,  3334,  "bitmag-udp",      "bitmag-ipv6-udp"),
]

def rule(proto, is_udp, pmin, pmax, src, desc):
    r = {"protocol": str(proto), "source": src, "source-type": "CIDR_BLOCK", "description": desc}
    if pmin is not None:
        r["udp-options" if is_udp else "tcp-options"] = {"destination-port-range": {"min": pmin, "max": pmax}}
    return r

want = [
    # 确保双栈基础 SSH 与 ICMPv6 PMTUD 规则存在（CLI 新建 VCN 时默认 SL 可能仅含 IPv4 基础规则）
    rule(6, False, 22, 22, "0.0.0.0/0", None),
    rule(6, False, 22, 22, "::/0", None),
    {"protocol": "1",  "source": "0.0.0.0/0", "source-type": "CIDR_BLOCK", "description": None, "icmp-options": {"type": 3, "code": 4}},
    {"protocol": "58", "source": "::/0",      "source-type": "CIDR_BLOCK", "description": None, "icmp-options": {"type": 2, "code": 0}},
]
for proto, is_udp, pmin, pmax, d4, d6 in GROUPS:
    want.append(rule(proto, is_udp, pmin, pmax, "0.0.0.0/0", d4))
    want.append(rule(proto, is_udp, pmin, pmax, "::/0", d6))

def key(r):
    o = r.get("tcp-options") or r.get("udp-options") or {}
    dp = o.get("destination-port-range") or {}
    ic = r.get("icmp-options") or {}
    return (str(r.get("protocol")), r.get("source"), dp.get("min"), dp.get("max"), ic.get("type"), ic.get("code"))

have = {key(r) for r in ing}
added = [r for r in want if key(r) not in have]
ing.extend(added)

eg_have = {(str(r.get("protocol")), r.get("destination")) for r in eg}
for dest in ("0.0.0.0/0", "::/0"):
    if ("all", dest) not in eg_have:
        eg.append({"protocol": "all", "destination": dest, "destination-type": "CIDR_BLOCK", "is-stateless": False})

json.dump({"ingress-security-rules": ing, "egress-security-rules": eg}, sys.stdout)
print("ADDED=%d TOTAL_INGRESS=%d TOTAL_EGRESS=%d" % (len(added), len(ing), len(eg)), file=sys.stderr)
' > "$MERGED_FILE" 2>"$SL_SUMMARY_FILE" || { say "❌ 规则合并失败"; cat "$SL_SUMMARY_FILE" >&2; exit 1; }
SUMMARY=$(cat "$SL_SUMMARY_FILE")
say "安全列表合并: $SUMMARY"

if [ "$DRY_RUN" -eq 1 ]; then
    say "[dry-run] 将用合并后的完整规则数组执行 oci network security-list update（已存在规则不重复）"
elif [ "$(printf '%s' "$SUMMARY" | sed -n 's/^ADDED=\([0-9]*\).*/\1/p')" = "0" ] && [ "$(printf '%s' "$SUMMARY" | sed -n 's/.*TOTAL_EGRESS=\([0-9]*\).*/\1/p')" -ge 2 ]; then
    say "无新增规则，跳过 update"
else
    oci network security-list update --security-list-id "$SL_ID" \
        --from-json "file://$MERGED_FILE" --force >/dev/null \
        || { say "❌ 安全列表更新失败"; exit 1; }
    say "✅ 安全列表已更新"
fi

# ─── 4. 子网：发现或自动创建双栈 default-subnet ─────────────────────────────
SUBNET_ID="${SUBNET_ID:-}"
if [ -z "$SUBNET_ID" ]; then
    SUBNET_ID=$(oci network subnet list --compartment-id "$COMPARTMENT_ID" \
        --vcn-id "$VCN_ID" --output json --all 2>/dev/null | python3 -c '
import sys, json
raw = sys.stdin.read().strip()
if not raw:
    sys.exit(0)
d = json.loads(raw).get("data") or []
pref = [s for s in d if "default" in (s.get("display-name") or "").lower()]
print((pref or d)[0]["id"] if d else "")
' 2>/dev/null || echo "")
fi

if [ -n "$SUBNET_ID" ]; then
    say "Subnet 已存在: $SUBNET_ID"
elif [ "$DRY_RUN" -eq 1 ]; then
    say "[dry-run] 将创建双栈 Regional 子网: default-subnet (10.0.0.0/24 + IPv6 /64)"
else
    SUBNET_IPV6_CIDR=$(printf '%s' "$VCN_IPV6_CIDR" | python3 -c '
import sys, ipaddress
s = sys.stdin.read().strip()
if s:
    net = ipaddress.IPv6Network(s, strict=False)
    print(str(next(net.subnets(new_prefix=64))))
')
    [ -n "$SUBNET_IPV6_CIDR" ] || { say "❌ 无法从 VCN IPv6 CIDR ($VCN_IPV6_CIDR) 派生 /64 子网"; exit 1; }
    say "正在创建双栈 Regional 子网 (10.0.0.0/24 + $SUBNET_IPV6_CIDR)..."
    SUBNET_ID=$(oci network subnet create \
        --compartment-id "$COMPARTMENT_ID" \
        --vcn-id "$VCN_ID" \
        --display-name "default-subnet" \
        --dns-label "defaultsubnet" \
        --cidr-block "10.0.0.0/24" \
        --ipv6-cidr-block "$SUBNET_IPV6_CIDR" \
        --prohibit-public-ip-on-vnic false \
        --prohibit-internet-ingress false \
        --route-table-id "$RT_ID" \
        --security-list-ids "[\"$SL_ID\"]" \
        --query 'data.id' --raw-output 2>/dev/null) || { say "❌ 子网创建失败"; exit 1; }
    [ -n "$SUBNET_ID" ] && [ "$SUBNET_ID" != "null" ] || { say "❌ 子网创建失败"; exit 1; }
    say "✅ 子网创建成功: $SUBNET_ID"
fi

say "=== 完成。SUBNET_ID=$SUBNET_ID ==="
