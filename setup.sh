#!/usr/bin/env bash
#
# setup.sh — oci-toolkit 一键安装 / 服务管理
#
# 用法：
#   ./setup.sh              # 安装：venv + oci-cli + systemd user 单元
#   ./setup.sh enable       # 启用并启动轮询服务
#   ./setup.sh disable      # 停止服务
#   ./setup.sh status       # 查看服务状态与最近日志
#   ./setup.sh linger       # 开机自启保活（不登录也运行；可能需要 sudo）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$SCRIPT_DIR/venv"
SERVICE_NAME="oci-arm-relaunch"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT_FILE="$UNIT_DIR/$SERVICE_NAME.service"

die() { echo "错误: $*" >&2; exit 1; }

install_venv() {
    echo "==> 检查 Python venv..."
    if [ ! -x "$VENV_DIR/bin/oci" ]; then
        python3 -m venv "$VENV_DIR" || die "无法创建 venv（需要 python3-venv）"
        "$VENV_DIR/bin/pip" install --upgrade pip -q
        echo "==> 安装 oci-cli（约 1-2 分钟）..."
        "$VENV_DIR/bin/pip" install -q --timeout 120 oci-cli
    fi
    echo "    OCI CLI: $("$VENV_DIR/bin/oci" --version)"
}

write_unit() {
    echo "==> 写入 systemd user 单元..."
    mkdir -p "$UNIT_DIR"
    cat > "$UNIT_FILE" <<EOF
[Unit]
Description=OCI ARM instance relaunch poller (oci-toolkit)
After=network-online.target

[Service]
Type=simple
WorkingDirectory=%h/oci-arm-relaunch
ExecStart=%h/oci-arm-relaunch/launch-from-bv.sh
Restart=on-failure
RestartSec=60
StandardOutput=append:%h/oci-arm-relaunch/logs/launch.log
StandardError=inherit

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    echo "    $UNIT_FILE"
}

install_flag() {
    # 同步当前仓库的脚本到运行目录 ~/oci-arm-relaunch（运行时路径固定，便于 systemd 引用）
    echo "==> 部署脚本到 ~/oci-arm-relaunch ..."
    mkdir -p "$HOME/oci-arm-relaunch/logs"
    cp -f "$SCRIPT_DIR/launch-from-bv.sh" "$HOME/oci-arm-relaunch/"
    chmod +x "$HOME/oci-arm-relaunch/launch-from-bv.sh"
    # .env：不存在才复制（避免覆盖线上配置）
    if [ ! -f "$HOME/oci-arm-relaunch/.env" ] && [ -f "$SCRIPT_DIR/.env" ]; then
        cp -f "$SCRIPT_DIR/.env" "$HOME/oci-arm-relaunch/.env"
        chmod 600 "$HOME/oci-arm-relaunch/.env"
        echo "    .env 已部署"
    elif [ ! -f "$HOME/oci-arm-relaunch/.env" ]; then
        echo "    ⚠️ 未找到 .env——部署 .env.example 需手工填写后重跑"
        cp -f "$SCRIPT_DIR/.env.example" "$HOME/oci-arm-relaunch/.env"
    else
        echo "    线上 .env 已存在，保持不变"
    fi
}

case "${1:-install}" in
    install)
        install_venv
        install_flag
        write_unit
        echo "✅ 安装完成。下一步："
        echo "   ./setup.sh enable   # 启用服务"
        echo "   ./setup.sh linger   # 不登录也运行（可能需要 sudo）"
        ;;
    enable)
        [ -f "$UNIT_FILE" ] || die "尚未安装，先运行 ./setup.sh"
        systemctl --user enable --now "$SERVICE_NAME"
        echo "✅ 服务已启用。观察日志:"
        echo "   journalctl --user -u $SERVICE_NAME -f"
        echo "   tail -f $HOME/oci-arm-relaunch/logs/launch.log"
        ;;
    disable)
        systemctl --user disable --now "$SERVICE_NAME" || true
        echo "已停止"
        ;;
    status)
        systemctl --user status "$SERVICE_NAME" --no-pager || true
        echo "--- 最近 20 行日志 ---"
        tail -20 "$HOME/oci-arm-relaunch/logs/launch.log" 2>/dev/null || true
        ;;
    linger)
        if loginctl show-user "$USER" --value --property=Linger 2>/dev/null | grep -q yes; then
            echo "linger 已开启 ✅"
        elif loginctl enable-linger 2>/dev/null; then
            echo "linger 已开启 ✅"
        else
            echo "⚠️ 需要 sudo 开启 linger（输入你的密码）："
            echo "   sudo loginctl enable-linger $USER"
        fi
        ;;
    *)
        echo "用法: ./setup.sh [install|enable|disable|status|linger]"
        exit 1
        ;;
esac
