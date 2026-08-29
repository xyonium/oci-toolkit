#!/usr/bin/env bash
#
# launch-vm.sh — 用最新 Ubuntu 24.04 镜像在 OCI 上启动实例
#
# 用法: ./launch-vm.sh <--x86|--arm> [--once] [--dry-run] [env文件路径]
#   --x86     启动 $X86_NAMES 全部实例（E2.1.Micro，47GB 引导卷），幂等、不轮询
#   --arm     A1.Flex (2 OCPU/12GB, 106GB)，在 $ADS 各可用域间轮换抢容量并轮询
#   --once    只尝试一次（成功或失败都退出）
#   --dry-run 只打印将要执行的命令，不真正调用；env文件默认为同目录 .env
#
# 退出码: 0=成功, 1=不可重试错误, 2=未知响应, 3=单次尝试未获得容量

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── 参数解析 ─────────────────────────────────────────────────────────────────
MODE=""
DRY_RUN=0
ONCE=0
ENV_FILE="$SCRIPT_DIR/.env"
while [ $# -gt 0 ]; do
    case "$1" in
        --x86)     MODE="x86" ;;
        --arm)     MODE="arm" ;;
        --dry-run) DRY_RUN=1 ;;
        --once)    ONCE=1 ;;
        -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
        *)         ENV_FILE="$1" ;;
    esac
    shift
done

if [ -z "$MODE" ]; then
    echo "错误: 必须指定模式 --x86 或 --arm" >&2
    sed -n '2,11p' "$0" >&2
    exit 1
fi

[ -f "$ENV_FILE" ] || { echo "错误: 配置文件不存在: $ENV_FILE" >&2; exit 1; }
# shellcheck source=/dev/null
source "$ENV_FILE"

# ─── 配置校验 ─────────────────────────────────────────────────────────────────
# .env 里的 OCI_BIN 支持 $HOME 展开；--dry-run 时允许 CLI 尚未安装
if [ -n "${OCI_BIN:-}" ]; then OCI_BIN=$(eval echo "$OCI_BIN"); fi
OCI_BIN="${OCI_BIN:-oci}"
# 若 OCI_BIN 为裸命令名（如 "oci"），先解析到真实二进制路径，避免与下方 oci() 函数同名递归
if [ "$OCI_BIN" = "oci" ]; then OCI_BIN="$(command -v oci || true)"; fi
PROFILE="${OCI_PROFILE:-DEFAULT}"
for var in COMPARTMENT_ID SUBNET_ID; do
    [ -n "${!var:-}" ] || { echo "错误: 必填配置为空: $var（请检查 .env）" >&2; exit 1; }
done
if [ "$DRY_RUN" -eq 0 ]; then
    command -v "$OCI_BIN" >/dev/null 2>&1 || { echo "错误: 找不到 OCI CLI: $OCI_BIN" >&2; exit 1; }
fi
command -v python3 >/dev/null 2>&1 || { echo "错误: 需要 python3" >&2; exit 1; }

# ─── oci() 包装：统一 profile 与认证方式 ──────────────────────────────────────
oci() { "$OCI_BIN" --profile "$PROFILE" --auth api_key "$@"; }

# ─── 输出 ─────────────────────────────────────────────────────────────────────
# systemd 单元把 stdout 追加进同一日志文件，交互运行时再由 say() 落一份
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR" || { echo "错误: 无法创建日志目录 $LOG_DIR" >&2; exit 1; }
LOG_FILE="$LOG_DIR/launch-$MODE.log"
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
# 成功标记：ARM 抢到容量后落盘，重跑直接退出
# 独立文件名（.success-vm-arm），避免与 launch-from-bv.sh 的 .success 冲突
SUCCESS_FLAG="$LOG_DIR/.success-vm-arm"

# ─── SSH 公钥校验（两种模式都需要） ───────────────────────────────────────────
require_ssh_key() {
    SSH_KEY_FILE="${SSH_KEY_FILE:-}"
    if [ -z "$SSH_KEY_FILE" ]; then
        say "❌ SSH_KEY_FILE 未配置（.env 中指向 SSH 公钥文件）"
        exit 1
    fi
    # 支持 ~ 开头：展开为 $HOME
    case "$SSH_KEY_FILE" in
        \~*) SSH_KEY_FILE="${HOME:-}${SSH_KEY_FILE#\~}" ;;
    esac
    [ -f "$SSH_KEY_FILE" ] || { say "❌ SSH 公钥文件不存在: $SSH_KEY_FILE"; exit 1; }
}

# ─── 查找最新 Ubuntu 24.04 镜像 ────────────────────────────────────────────────
# 注意：本机 OCI CLI 为旧版本，compute image list 必须带 --compartment-id，否则报错
find_image() {
    local shape="$1" id rc
    # 注意：绝不能用 2>&1 合并 stderr —— 旧版 CLI 会往 stderr 打印分页 WARNING，
    # 混入结果后 OCID 前缀校验会失败（曾导致镜像查询误报失败）。stderr 单独丢弃。
    id=$(oci compute image list \
        --compartment-id "$COMPARTMENT_ID" \
        --operating-system "Canonical Ubuntu" \
        --operating-system-version "24.04" \
        --shape "$shape" \
        --sort-by TIMECREATED --sort-order DESC \
        --limit 1 \
        --query 'data[0].id' --raw-output 2>/dev/null)
    rc=$?
    if [ $rc -ne 0 ] || [ -z "$id" ] || [ "$id" = "null" ]; then
        say "❌ 找不到 Ubuntu 24.04 $shape 镜像（rc=$rc）"
        return 1
    fi
    case "$id" in
        ocid1.image.*) echo "$id" ;;
        *) say "❌ 镜像查询结果异常: $id"; return 1 ;;
    esac
}

# ─── 错误分类：输入为 CLI 的合并输出，输出为 RETRY|RETRY429|STOP|UNKNOWN ──────
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

# ─── 从错误输出里提取简短信息 ─────────────────────────────────────────────────
brief_of() {
    local out="$1"
    printf '%s' "$out" | python3 -c '
import sys, json, re
m = re.search(r"\{.*\}", sys.stdin.read(), re.S)
if m:
    d = json.loads(m.group(0))
    print(d.get("code",""), "|", d.get("message","")[:120])
else:
    print("非JSON输出")
' 2>/dev/null || printf '%s' "$out" | head -c 120
}

# ─── 成功后：等 RUNNING（最多10分钟）并抓公网 IP ──────────────────────────────
report_instance() {
    local instance_id="$1"
    local interval="${POLL_INTERVAL:-15}"   # 测试可调小；默认 15s，最多 40 次
    say "实例已创建: $instance_id"
    say "等待实例进入 RUNNING 状态（最多 10 分钟）..."
    local i=0
    while [ $i -lt 40 ]; do
        sleep "$interval"
        i=$((i + 1))
        local state
        state=$(oci compute instance get --instance-id "$instance_id" \
            --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo "?")
        case "$state" in
            RUNNING)
                say "✅ 实例已 RUNNING"
                local ips
                ips=$(oci compute instance list-vnics --instance-id "$instance_id" \
                    --compartment-id "$COMPARTMENT_ID" --output json 2>/dev/null | python3 -c '
import sys, json
raw = sys.stdin.read().strip()
if not raw:
    sys.exit(1)
try:
    d = json.loads(raw)
    d = d["data"] if isinstance(d, dict) and "data" in d else d
    if not isinstance(d, list):
        sys.exit(1)
except Exception:
    sys.exit(1)
for v in d:
    if not isinstance(v, dict):
        continue
    print("  公网 IPv4:", v.get("public-ip") or "(无)")
    print("  私网 IPv4:", v.get("private-ip") or "(无)")
    # 注意：不同 CLI 版本返回结构不同 —— 有的是 ["2603:..."] 字符串列表，
    # 有的是 [{"address": "2603:..."}] 字典列表，两种都要兼容
    for ip6 in (v.get("ipv6-addresses") or []):
        if isinstance(ip6, dict):
            addr = ip6.get("address") or ip6.get("ip-address")
        else:
            addr = ip6
        if addr:
            print("  公网 IPv6:", addr)
') || { say "⚠️ 获取网络信息失败"; return 0; }
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

# ─── x86 模式：逐个幂等启动 $X86_NAMES ───────────────────────────────────────
# 启动一台 x86 实例；$3 为附加的 IPv6 标志（空字符串或 "--assign-ipv6-ip true"）
x86_launch() {
    local img="$1" nm="$2" ipv6_extra="$3"
    oci compute instance launch \
        --compartment-id "$COMPARTMENT_ID" \
        --availability-domain "$X86_AD" \
        --shape "VM.Standard.E2.1.Micro" \
        --image-id "$img" \
        --subnet-id "$SUBNET_ID" \
        --display-name "$nm" \
        --assign-public-ip true \
        $ipv6_extra \
        --boot-volume-size-in-gbs "$X86_BV_GB" \
        --ssh-authorized-keys-file "$SSH_KEY_FILE" \
        --no-retry \
        --connection-timeout 60 \
        --read-timeout 120 2>&1
}

run_x86() {
    X86_NAMES="${X86_NAMES:-}"
    # 去空白后再校验：纯空格值会变成零次循环，静默无事发生
    X86_NAMES="$(printf '%s' "$X86_NAMES" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//')"
    [ -n "$X86_NAMES" ] || { say "❌ X86_NAMES 未配置（.env 中空格分隔的实例名列表）"; exit 1; }
    X86_AD="${X86_AD:-}"
    X86_AD="$(printf '%s' "$X86_AD" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//')"
    [ -n "$X86_AD" ] || { say "❌ X86_AD 未配置（.env 中目标可用域）"; exit 1; }
    X86_BV_GB="${X86_BV_GB:-47}"
    X86_IPV6="${X86_IPV6:-true}"
    require_ssh_key

    local image_id
    if [ "$DRY_RUN" -eq 1 ]; then
        image_id="<最新 Ubuntu 24.04 x86 镜像>"
    else
        image_id=$(find_image "VM.Standard.E2.1.Micro") || { say "❌ 获取镜像失败，终止"; exit 1; }
        say "✅ 使用镜像: $image_id"
    fi

    local n failures=0
    for n in $X86_NAMES; do
        say "--- $n ---"
        if [ "$DRY_RUN" -eq 0 ]; then
            # 幂等：已有同名非终止实例则跳过。
            # 注意：本机旧版 OCI CLI 在 list 结果为空时输出**零字节**（不是 {"data":[]}），
            # 因此"输出为空"≠"查询失败"——必须区分：命令 rc 非 0 才算真失败（此时终止，
            # 避免免费层上打出重复实例）；输出为空但命令成功 = 没有同名实例，正常继续。
            local existing listrc
            listout=$(oci compute instance list --compartment-id "$COMPARTMENT_ID" \
                --display-name "$n" --all --output json 2>/dev/null)
            listrc=$?
            if [ $listrc -ne 0 ]; then
                say "❌ 查询 $n 同名实例失败（oci rc=$listrc），终止以避免重复启动"
                exit 1
            fi
            existing=$(printf '%s' "$listout" | python3 -c '
import sys
raw = sys.stdin.read().strip()
# 旧版 CLI 空结果返回空字符串 → 视为无实例
if not raw:
    sys.exit(0)
try:
    d = json.loads(raw)
    while isinstance(d, dict) and "data" in d:
        d = d["data"]
except Exception:
    sys.exit(1)
alive = [v["id"] for v in d if (v.get("lifecycle-state") or "") not in ("TERMINATED", "TERMINATING")]
print(alive[0] if alive else "")
' 2>/dev/null) || { say "❌ 解析 $n 同名实例列表失败，终止以避免重复启动"; exit 1; }
            if [ -n "$existing" ]; then
                say "⚠️ 已存在同名非终止实例 ($existing)，跳过 $n"
                continue
            fi
        fi

        local ipv6_extra=""
        [ "$X86_IPV6" = "true" ] && ipv6_extra="--assign-ipv6-ip true"

        if [ "$DRY_RUN" -eq 1 ]; then
            say "[dry-run] 将执行: $OCI_BIN --profile $PROFILE --auth api_key compute instance launch --compartment-id \"$COMPARTMENT_ID\" --availability-domain \"$X86_AD\" --shape \"VM.Standard.E2.1.Micro\" --image-id \"$image_id\" --subnet-id \"$SUBNET_ID\" --display-name \"$n\" --assign-public-ip true $ipv6_extra --boot-volume-size-in-gbs \"$X86_BV_GB\" --ssh-authorized-keys-file \"$SSH_KEY_FILE\" --no-retry --connection-timeout 60 --read-timeout 120"
            continue
        fi

        local out rc instance_id
        out=$(x86_launch "$image_id" "$n" "$ipv6_extra"); rc=$?
        if [ $rc -ne 0 ] && [ -n "$ipv6_extra" ] && printf '%s' "$out" | grep -qi "ipv6"; then
            # E2.1.Micro 对 IPv6 支持不确定：报错提到 ipv6 时去掉该标志重试一次
            say "⚠️ $n 启动失败且错误提到 ipv6，去掉 --assign-ipv6-ip 重试一次: $(brief_of "$out")"
            ipv6_extra=""
            out=$(x86_launch "$image_id" "$n" "$ipv6_extra"); rc=$?
        fi
        if [ $rc -eq 0 ]; then
            instance_id=$(printf '%s' "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"]["id"])' 2>/dev/null || echo "未知")
            if [ -n "$ipv6_extra" ]; then
                say "✅ $n 启动成功: $instance_id"
            else
                say "✅ $n 启动成功（无 IPv6，已降级）: $instance_id"
            fi
            report_instance "$instance_id"
        else
            failures=$((failures + 1))
            say "❌ $n 启动失败 (rc=$rc): $(brief_of "$out")"
            printf '%s\n' "$out" | tail -20
        fi
    done
    if [ "$failures" -gt 0 ]; then
        say "❌ x86 模式完成，$failures 个实例启动失败"
        exit 1
    fi
    say "=== x86 模式完成 ==="
}

# ─── ARM 模式：多 AD 轮换轮询抢容量 ───────────────────────────────────────────
run_arm() {
    SHAPE="${SHAPE:-VM.Standard.A1.Flex}"
    OCPUS="${OCPUS:-2}"
    MEMORY_GB="${MEMORY_GB:-12}"
    ARM_BV_GB="${ARM_BV_GB:-106}"
    INSTANCE_ARM_NAME="${INSTANCE_ARM_NAME:-arm-instance}"
    ADS="${ADS:-}"
    [ -n "$ADS" ] || { say "❌ ADS 未配置（.env 中空格分隔的可用域列表）"; exit 1; }
    RETRY_INTERVAL="${RETRY_INTERVAL:-200}"
    JITTER="${JITTER:-100}"
    BACKOFF_AFTER_429="${BACKOFF_AFTER_429:-5}"
    ASSIGN_PUBLIC_IP="${ASSIGN_PUBLIC_IP:-true}"
    ASSIGN_IPV6="${ASSIGN_IPV6:-true}"
    require_ssh_key

    # 成功标记：已抢到容量并创建过实例后，不再重复启动
    if [ -f "$SUCCESS_FLAG" ]; then
        say "检测到成功标记 $SUCCESS_FLAG，实例已创建过，跳过轮询。"
        say "（如需重新抢容量: rm $SUCCESS_FLAG）"
        exit 0
    fi
    # 去空白后再校验：纯空格值会让循环零次或模除归零
    ADS="$(printf '%s' "$ADS" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//')"
    [ -n "$ADS" ] || { say "❌ ADS 未配置（.env 中空格分隔的可用域列表）"; exit 1; }
    local -a ad_list
    read -ra ad_list <<< "$ADS"

    local image_id
    if [ "$DRY_RUN" -eq 1 ]; then
        image_id="<最新 Ubuntu 24.04 ARM 镜像>"
    else
        image_id=$(find_image "$SHAPE") || { say "❌ 获取镜像失败，终止"; exit 1; }
        say "✅ 使用镜像: $image_id"
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        # dry-run：每个 AD 打印一次计划命令后退出（避免无限循环）
        local ad
        local ipv6_extra=""
        [ "$ASSIGN_IPV6" = "true" ] && ipv6_extra="--assign-ipv6-ip true"
        for ad in "${ad_list[@]}"; do
            say "[dry-run] (AD: $ad) 将执行: $OCI_BIN --profile $PROFILE --auth api_key compute instance launch --compartment-id \"$COMPARTMENT_ID\" --availability-domain \"$ad\" --shape \"$SHAPE\" --shape-config '{\"ocpus\": $OCPUS, \"memoryInGBs\": $MEMORY_GB}' --image-id \"$image_id\" --subnet-id \"$SUBNET_ID\" --display-name \"$INSTANCE_ARM_NAME\" --assign-public-ip \"$ASSIGN_PUBLIC_IP\" $ipv6_extra --boot-volume-size-in-gbs \"$ARM_BV_GB\" --ssh-authorized-keys-file \"$SSH_KEY_FILE\" --no-retry --connection-timeout 60 --read-timeout 120"
        done
        exit 0
    fi

    say "=== launch-vm --arm: 多 AD 轮换抢容量 ==="
    say "规格: $SHAPE ($OCPUS OCPU / ${MEMORY_GB}GB)   引导卷: ${ARM_BV_GB}GB"
    say "可用域轮换: $ADS"
    say "轮询间隔: ${RETRY_INTERVAL}s + 0~${JITTER}s 随机抖动"

    local attempt=0 consecutive_429=0 base="$RETRY_INTERVAL" ad_idx=0 interval
    # 记录每个 AD 是否曾返回「不提供此 shape」的 404。
    # 注意：NotAuthorizedOrNotFound 在 launch_instance 上有两义——
    #   1) 该 AD 不提供此 shape（常见，如 E2.1.Micro 只在部分 AD 有）
    #   2) 真的权限/资源问题（key 失效、compartment 错）
    # 只有部分 AD 404 → 跳过该 AD 继续轮换；全部 AD 都 404 → 才真正终止。
    # 曾因把单个 AD 的 404 当成全局错误，导致整个轮询退出、服务停摆 2 小时。
    local total_ads=${#ad_list[@]}
    while true; do
        attempt=$((attempt + 1))
        local ad="${ad_list[ad_idx]}"
        ad_idx=$(((ad_idx + 1) % ${#ad_list[@]}))
        say "--- 第 $attempt 次尝试（AD: $ad）---"

        local out rc
        local ipv6_extra=""
        [ "$ASSIGN_IPV6" = "true" ] && ipv6_extra="--assign-ipv6-ip true"
        out=$(oci compute instance launch \
            --compartment-id "$COMPARTMENT_ID" \
            --availability-domain "$ad" \
            --shape "$SHAPE" \
            --shape-config "{\"ocpus\": $OCPUS, \"memoryInGBs\": $MEMORY_GB}" \
            --image-id "$image_id" \
            --subnet-id "$SUBNET_ID" \
            --display-name "$INSTANCE_ARM_NAME" \
            --assign-public-ip "$ASSIGN_PUBLIC_IP" \
            $ipv6_extra \
            --boot-volume-size-in-gbs "$ARM_BV_GB" \
            --ssh-authorized-keys-file "$SSH_KEY_FILE" \
            --no-retry \
            --connection-timeout 60 \
            --read-timeout 120 2>&1)
        rc=$?

        if [ $rc -eq 0 ]; then
            local instance_id
            instance_id=$(printf '%s' "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"]["id"])' 2>/dev/null || echo "未知")
            say "🎉 容量到手！实例: $instance_id"
            report_instance "$instance_id"
            printf '%s\n' "$instance_id" > "$SUCCESS_FLAG" || { say "❌ 写入成功标记失败: $SUCCESS_FLAG"; exit 1; }
            say "=== 脚本结束（删除 $SUCCESS_FLAG 可重新抢容量）==="
            exit 0
        fi

        local verdict brief
        verdict=$(classify_result "$out")
        brief=$(brief_of "$out")
        case "$verdict" in
            RETRY)
                consecutive_429=0
                base=$RETRY_INTERVAL
                say "  容量不足/暂时性错误 ($brief)"
                ;;
            RETRY429)
                consecutive_429=$((consecutive_429 + 1))
                if [ $consecutive_429 -ge "$BACKOFF_AFTER_429" ]; then
                    base=$((RETRY_INTERVAL * 2))
                    say "  429 限流已连续 $consecutive_429 次，基准间隔翻倍为 ${base}s"
                else
                    base=$RETRY_INTERVAL
                    say "  429 限流 ($brief)"
                fi
                ;;
            STOP)
                # 单 AD 的 NotAuthorizedOrNotFound 通常是「该 AD 不提供此 shape」，
                # 而不是真的权限问题 → 移出轮换继续抢其他 AD。
                # 仅当这是最后一个 AD 时，才认定是真的权限/配置问题并终止。
                if printf '%s' "$out" | grep -q "NotAuthorizedOrNotFound" && [ ${#ad_list[@]} -gt 1 ]; then
                    say "  ⚠️ 该 AD 不提供 $SHAPE，移出轮换: $ad（剩余 $((${#ad_list[@]} - 1))/$total_ads 个 AD）"
                    local new_list=() a
                    for a in "${ad_list[@]}"; do
                        [ "$a" = "$ad" ] || new_list+=("$a")
                    done
                    ad_list=("${new_list[@]}")
                    # 移除元素后其右侧全部左移一格，而 ad_idx 此前已自增指向下一个 AD，
                    # 若不回退一格就会跳过一个 AD（ad_idx=1、list=[AD2,AD3] 时会跳过 AD2）。
                    ad_idx=$((ad_idx - 1))
                    [ "$ad_idx" -lt 0 ] && ad_idx=0
                    ad_idx=$((ad_idx % ${#ad_list[@]}))
                    [ "$ONCE" -eq 1 ] && { say "--once 模式：单次尝试结束（未获得容量）"; exit 3; }
                    continue
                fi
                say "❌ 不可重试错误，脚本终止: $brief"
                say "（若这是 NotAuthorizedOrNotFound：请检查 API key、compartment，或该区域是否提供 $SHAPE）"
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

        [ "$ONCE" -eq 1 ] && { say "--once 模式：单次尝试结束（未获得容量）"; exit 3; }
        interval=$((base + RANDOM % (JITTER + 1)))
        say "  ${interval}s 后重试（基准 ${base}s + 抖动）"
        sleep "$interval"
    done
}

# ─── 入口 ─────────────────────────────────────────────────────────────────────
run_"$MODE"
