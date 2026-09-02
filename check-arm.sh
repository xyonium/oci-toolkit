#!/usr/bin/env bash
#
# check-arm.sh — 查看两台 ARM 容量轮询的当前状态（JP 与 UK，均运行在 gpu 上）
#
# 用法: ./check-arm.sh              # 一次性查看
#       ./check-arm.sh --follow     # 持续跟踪 UK 日志（Ctrl-C 退出）
#
# 两台轮询都跑在 gpu (ssh eli@gpu) 上，是不同的 systemd user 服务：
#   oci-arm-relaunch  → JP(ap-osaka-1)，基于 106GB 保留引导卷重开 A1.Flex
#   oci-uk-arm        → UK(uk-london-1)，用最新 Ubuntu 24.04 镜像新建 A1.Flex
#
# 退出码: 0=至少一台已成功拿到实例 / 1=都还在轮询 / 2=服务异常或无法连接

set -uo pipefail

GPU_HOST="${GPU_HOST:-eli@gpu}"

if [ "${1:-}" = "--follow" ]; then
    echo "跟踪 UK ARM 日志（Ctrl-C 退出）..."
    exec ssh -o BatchMode=yes "$GPU_HOST" \
        'tail -f ~/oci-uk/logs/launch-arm.log'
fi

ssh -o BatchMode=yes -o ConnectTimeout=15 "$GPU_HOST" 'bash -s' <<'REMOTE'
rc_bad=0
for pair in "oci-arm-relaunch:JP(ap-osaka-1):~/oci-arm-relaunch" "oci-uk-arm:UK(uk-london-1):~/oci-uk"; do
    svc="${pair%%:*}"; rest="${pair#*:}"; label="${rest%%:*}"; dir="${rest#*:}"
    dir="${dir/#\~/$HOME}"

    echo "════════ $label — 服务 $svc ════════"

    state=$(systemctl --user is-active "$svc" 2>/dev/null)
    enabled=$(systemctl --user is-enabled "$svc" 2>/dev/null)
    case "$state" in
        active)   echo "  状态: ✅ active（$enabled）" ;;
        failed)   echo "  状态: ❌ FAILED ← 需要人工介入"; rc_bad=1 ;;
        inactive) echo "  状态: ⚠️  inactive（未运行）"; rc_bad=1 ;;
        *)        echo "  状态: ❓ $state"; rc_bad=1 ;;
    esac

    # 已启动的实例 PID 与主进程运行时长
    if [ "$state" = "active" ]; then
        since=$(systemctl --user show "$svc" -p ExecMainStartTimestamp --value 2>/dev/null)
        [ -n "$since" ] && echo "  启动于: $since"
    fi

    # 成功标记
    flag=""
    for f in "$dir/logs/.success-vm-arm" "$dir/logs/.success" "$dir/.success"; do
        [ -f "$f" ] && { flag="$f"; break; }
    done
    if [ -n "$flag" ]; then
        echo "  🎉 已抢到容量！实例 OCID: $(cat "$flag")"
        rc_ok=1
    else
        echo "  尚未抢到容量（无成功标记）"
    fi

    # 日志尾部：尝试次数、最近一次错误
    log="$dir/logs/launch-arm.log"
    [ -f "$log" ] || log="$dir/logs/launch.log"
    if [ -f "$log" ]; then
        echo "  ── 最近进展 ──"
        grep -E "第 [0-9]+ 次尝试|容量不足|🎉|移出轮换|不可重试" "$log" 2>/dev/null \
            | tail -4 | sed 's/^/    /'
        echo "  日志: $log（$(wc -l < "$log") 行）"
    fi
    echo
done

if [ "$rc_bad" -ne 0 ]; then
    echo "⚠️  有服务不在运行，查看失败原因："
    echo "    ssh eli@gpu 'systemctl --user status <服务名> --no-pager | head -20'"
    exit 2
fi
REMOTE

exit $?
