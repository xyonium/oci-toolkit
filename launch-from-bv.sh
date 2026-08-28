#!/usr/bin/env bash
#
# launch-from-bv.sh — 以已有引导卷为启动源，轮询重开 OCI ARM 实例
#
# 场景：实例被终止（如 Oracle 2026-08-18 强制执行免费层新限额），引导卷保留。
# 本脚本反复尝试 launch，容量释放瞬间以原盘开机，数据配置原样恢复。
#
# 用法：
#   ./launch-from-bv.sh [--dry-run] [--once] [env文件路径]
#     --dry-run   只打印将要执行的 launch 命令，不真正调用
#     --once      只尝试一次（用于参数验证），成功或失败都退出
#     env文件     默认为脚本同目录的 .env

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── 参数解析 ─────────────────────────────────────────────────────────────────
DRY_RUN=0
ONCE=0
ENV_FILE="$SCRIPT_DIR/.env"
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --once)    ONCE=1 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *)         ENV_FILE="$1" ;;
    esac
    shift
done

if [ ! -f "$ENV_FILE" ]; then
    echo "错误: 配置文件不存在: $ENV_FILE" >&2
    echo "复制 .env.example 为 .env 并填写后重试。" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$ENV_FILE"

# ─── 配置校验 ─────────────────────────────────────────────────────────────────
# .env 里的 OCI_BIN 支持 $HOME 展开；--dry-run 时允许 CLI 尚未安装
if [ -n "${OCI_BIN:-}" ]; then OCI_BIN=$(eval echo "$OCI_BIN"); fi
OCI_BIN="${OCI_BIN:-oci}"
REQUIRED=(COMPARTMENT_ID TARGET_AD BOOT_VOLUME_ID SUBNET_ID SHAPE OCPUS MEMORY_GB INSTANCE_NAME)
missing=0
for var in "${REQUIRED[@]}"; do
    if [ -z "${!var:-}" ]; then
        echo "错误: 必填配置为空: $var" >&2
        missing=1
    fi
done
if ! command -v "$OCI_BIN" >/dev/null 2>&1 && [ "$DRY_RUN" -eq 0 ]; then
    echo "错误: 找不到 OCI CLI: $OCI_BIN" >&2
    missing=1
fi
[ "$missing" -eq 0 ] || exit 1

RETRY_INTERVAL="${RETRY_INTERVAL:-200}"
# 每次间隔叠加 0~JITTER 秒随机抖动，避免固定周期轮询特征
JITTER="${JITTER:-100}"
ASSIGN_PUBLIC_IP="${ASSIGN_PUBLIC_IP:-true}"
ASSIGN_IPV6="${ASSIGN_IPV6:-true}"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"

# ─── 输出 ─────────────────────────────────────────────────────────────────────
# systemd 单元把 stdout 追加进同一日志文件，交互运行时再由 say() 落一份
LOG_FILE="$LOG_DIR/launch.log"
if [ -t 1 ]; then
    say() {
        local line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
        echo "$line"
        echo "$line" >> "$LOG_FILE"
    }
else
    say() {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    }
fi

# ─── launch 参数组装 ──────────────────────────────────────────────────────────
build_launch_cmd() {
    local ipv6_flag=""
    [ "$ASSIGN_IPV6" = "true" ] && ipv6_flag="--assign-ipv6-ip true"
    cat <<EOF
$OCI_BIN compute instance launch \\
  --compartment-id        "$COMPARTMENT_ID" \\
  --availability-domain   "$TARGET_AD" \\
  --shape                 "$SHAPE" \\
  --shape-config          '{"ocpus": $OCPUS, "memoryInGBs": $MEMORY_GB}' \\
  --source-boot-volume-id "$BOOT_VOLUME_ID" \\
  --subnet-id             "$SUBNET_ID" \\
  --display-name          "$INSTANCE_NAME" \\
  --assign-public-ip      $ASSIGN_PUBLIC_IP \\
  $ipv6_flag \\
  --auth                  api_key \\
  --no-retry \\
  --connection-timeout    60 \\
  --read-timeout          120
EOF
}

# ─── 错误分类：输入为 CLI 的合并输出，输出为 RETRY|STOP|SUCCESS ────────────────
classify_result() {
    local out="$1" code
    # 优先从 JSON 错误体里取 code
    code=$(printf '%s' "$out" | python3 -c '
import sys, json, re
m = re.search(r"\{.*\}", sys.stdin.read(), re.S)
print(json.loads(m.group(0)).get("code", "") if m else "")
' 2>/dev/null)

    if [ "$code" = "TooManyRequests" ]; then echo RETRY429; return; fi
    case "$code" in
        InternalError|ServiceUnavailable) echo RETRY; return ;;
        LimitExceeded|NotAuthorizedOrNotFound|NotAuthenticated|InvalidParameter|Conflict) echo STOP; return ;;
    esac

    # JSON 解析失败时退回原文匹配
    if printf '%s' "$out" | grep -qiE "out of (host )?capacity"; then echo RETRY; return; fi
    if printf '%s' "$out" | grep -qiE "timed out|ServiceUnavailable|InternalError"; then echo RETRY; return; fi
    if printf '%s' "$out" | grep -qiE "TooManyRequests"; then echo RETRY429; return; fi
    if printf '%s' "$out" | grep -qiE "LimitExceeded|NotAuthorized|NotAuthenticated|InvalidParameter|Conflict"; then echo STOP; return; fi

    echo UNKNOWN
}

# ─── 成功后：等 RUNNING（最多10分钟）并抓公网 IP ──────────────────────────────
report_instance() {
    local instance_id="$1"
    say "实例已创建: $instance_id"
    say "等待实例进入 RUNNING 状态（最多 10 分钟）..."
    local i=0
    while [ $i -lt 40 ]; do
        sleep 15
        i=$((i + 1))
        local state
        state=$("$OCI_BIN" compute instance get --instance-id "$instance_id" \
            --auth api_key \
            --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo "?")
        case "$state" in
            RUNNING)
                say "✅ 实例已 RUNNING"
                local ips
                ips=$("$OCI_BIN" compute instance list-vnics --instance-id "$instance_id" \
                    --compartment-id "$COMPARTMENT_ID" \
                    --auth api_key 2>/dev/null | python3 -c '
import sys, json
d = json.load(sys.stdin)["data"]
for v in d:
    print("  公网 IPv4:", v.get("public-ip") or "(无)")
    for ip6 in (v.get("ipv6-addresses") or []):
        print("  公网 IPv6:", ip6.get("address"))
')
                say "网络信息：
$ips"
                say "🎉 完成！可登录: ssh <盘内用户>@<公网IP>"
                return 0
                ;;
            PROVISIONING|STARTING) ;;
            *)
                say "⚠️ 实例状态异常: $state（启动失败时检查控制台）"
                return 1
                ;;
        esac
    done
    say "⚠️ 10 分钟内未到 RUNNING，请到控制台查看"
    return 1
}

# ─── 主循环 ───────────────────────────────────────────────────────────────────
if [ "$DRY_RUN" -eq 1 ]; then
    echo "=== DRY RUN — 以下为将要执行的命令 ==="
    build_launch_cmd
    exit 0
fi

say "=== oci-toolkit: 基于引导卷重开 ARM 实例 ==="
say "引导卷: $BOOT_VOLUME_ID"
say "可用域: $TARGET_AD   规格: $SHAPE ($OCPUS OCPU / ${MEMORY_GB}GB)"
say "轮询间隔: ${RETRY_INTERVAL}s + 0~${JITTER}s 随机抖动"

attempt=0
consecutive_429=0
base=$RETRY_INTERVAL

while true; do
    attempt=$((attempt + 1))
    say "--- 第 $attempt 次尝试 ---"

    out=$("$OCI_BIN" compute instance launch \
        --compartment-id "$COMPARTMENT_ID" \
        --availability-domain "$TARGET_AD" \
        --shape "$SHAPE" \
        --shape-config "{\"ocpus\": $OCPUS, \"memoryInGBs\": $MEMORY_GB}" \
        --source-boot-volume-id "$BOOT_VOLUME_ID" \
        --subnet-id "$SUBNET_ID" \
        --display-name "$INSTANCE_NAME" \
        --assign-public-ip "$ASSIGN_PUBLIC_IP" \
        $([ "$ASSIGN_IPV6" = "true" ] && echo --assign-ipv6-ip true) \
        --auth api_key \
        --no-retry \
        --connection-timeout 60 \
        --read-timeout 120 2>&1)
    rc=$?

    if [ $rc -eq 0 ]; then
        instance_id=$(printf '%s' "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"]["id"])' 2>/dev/null || echo "未知")
        say "🎉 容量到手！"
        report_instance "$instance_id"
        say "=== 脚本结束（服务将转为 inactive）==="
        exit 0
    fi

    verdict=$(classify_result "$out")
    # 从错误里提取简短信息
    brief=$(printf '%s' "$out" | python3 -c '
import sys, json, re
m = re.search(r"\{.*\}", sys.stdin.read(), re.S)
if m:
    d = json.loads(m.group(0))
    print(d.get("code",""), "|", d.get("message","")[:120])
else:
    print(sys.stdin.read()[:120] if False else "非JSON输出")
' 2>/dev/null || printf '%s' "$out" | head -c 120)

    case "$verdict" in
        RETRY)
            consecutive_429=0
            base=$RETRY_INTERVAL
            say "  容量不足/暂时性错误 ($brief)"
            ;;
        RETRY429)
            consecutive_429=$((consecutive_429 + 1))
            if [ $consecutive_429 -ge "${BACKOFF_AFTER_429:-5}" ]; then
                base=$((RETRY_INTERVAL * 2))
                say "  429 限流已连续 $consecutive_429 次，基准间隔翻倍为 ${base}s"
            else
                base=$RETRY_INTERVAL
                say "  429 限流 ($brief)"
            fi
            ;;
        STOP)
            say "❌ 不可重试错误，脚本终止: $brief"
            say "=== 完整输出 ==="
            printf '%s\n' "$out" | tail -20
            exit 1
            ;;
        *)
            say "❓ 未知响应 (rc=$rc): $brief"
            if [ "$ONCE" -eq 1 ]; then
                printf '%s\n' "$out" | tail -20
                exit 2
            fi
            say "  视为暂时性问题，继续轮询（若持续出现请人工检查）"
            consecutive_429=0
            base=$RETRY_INTERVAL
            ;;
    esac

    [ "$ONCE" -eq 1 ] && { say "--once 模式：单次尝试结束"; exit 0; }
    # 基准间隔 + 0~JITTER 秒随机抖动（非固定周期的机器节奏）
    interval=$((base + RANDOM % (JITTER + 1)))
    say "  ${interval}s 后重试（基准 ${base}s + 抖动）"
    sleep "$interval"
done
