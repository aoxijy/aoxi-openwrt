#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENWRT_ROOT="$(pwd)"

if [ ! -x "$OPENWRT_ROOT/scripts/feeds" ]; then
    echo "错误: 请从 OpenWrt 源码根目录运行服务菜单开关安装脚本" >&2
    exit 1
fi

python3 "$SCRIPT_DIR/patch_luci_status.py"
cp -a "$SCRIPT_DIR/files/." "$OPENWRT_ROOT/files/"
chmod 0755 "$OPENWRT_ROOT/files/etc/uci-defaults/97-luci-service-menu-toggle"
chmod 0644 \
    "$OPENWRT_ROOT/files/etc/config/luci_service_menu" \
    "$OPENWRT_ROOT/files/usr/lib/lua/luci/controller/service_menu_toggle.lua" \
    "$OPENWRT_ROOT/files/usr/share/luci/menu.d/luci-service-menu-toggle.json"

echo "服务菜单显示/隐藏功能已加入固件（默认隐藏）"
