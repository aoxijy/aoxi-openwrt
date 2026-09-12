#!/bin/bash
set -euo pipefail

OPENWRT_ROOT="$(pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENBOX_VERSION="v0.1.169"
EXPECTED_SHA256="4f13efc39f50fcd520a2fd638cb6fb5737a5540afa6b9013bc0e35ff5a0e3ee8"
ASSET="open-box-${OPENBOX_VERSION}-linux-x64.tar.gz"
BASE_URL="https://github.com/liandu2024/Open-Box/releases/download/${OPENBOX_VERSION}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [ ! -x "$OPENWRT_ROOT/scripts/feeds" ]; then
    echo "错误: 请从 OpenWrt 源码根目录运行 Open-Box 集成脚本" >&2
    exit 1
fi

fetch_asset() {
    local name="$1"
    local output="$2"
    if [ -n "${OPENBOX_ASSET_DIR:-}" ]; then
        cp "$OPENBOX_ASSET_DIR/$name" "$output"
        return
    fi

    local url prefix
    for prefix in "" "${OPENBOX_MIRROR:-https://ghfast.top/}"; do
        rm -f "$output"
        url="${prefix}${BASE_URL}/$name"
        if curl -fL --retry 3 --retry-all-errors --connect-timeout 20 \
            --speed-limit 1024 --speed-time 60 --max-time 900 \
            "$url" -o "$output"; then
            return
        fi
        echo "警告: 下载失败，切换 Open-Box 下载通道: $url" >&2
    done

    echo "错误: 无法下载 Open-Box 资产 $name" >&2
    return 1
}

fetch_asset "$ASSET" "$TMP_DIR/$ASSET"

# 生产构建只信任仓库中固定的版本与摘要。测试夹具可在使用本地资产目录时
# 显式提供测试摘要，但网络下载永远不能覆盖固定摘要。
if [ -n "${OPENBOX_ASSET_DIR:-}" ]; then
    VERIFY_SHA256="${OPENBOX_TEST_SHA256:-$EXPECTED_SHA256}"
else
    VERIFY_SHA256="$EXPECTED_SHA256"
fi
printf '%s  %s\n' "$VERIFY_SHA256" "$TMP_DIR/$ASSET" | sha256sum -c -

DEST="$OPENWRT_ROOT/files/opt/open-box"
rm -rf "$DEST"
python3 "$SCRIPT_DIR/validate_archive.py" --extract "$DEST" "$TMP_DIR/$ASSET"

for required in \
    node/bin/node \
    bin/sing-box \
    panel/server/index.mjs \
    openwrt/initd/openbox \
    openwrt/initd/openbox-panel \
    openwrt/luci/htdocs/luci-static/resources/view/openbox/status.js \
    openwrt/luci/root/usr/share/luci/menu.d/luci-app-openbox.json \
    openwrt/luci/root/usr/share/rpcd/acl.d/luci-app-openbox.json; do
    if [ ! -e "$DEST/$required" ]; then
        echo "错误: Open-Box 发布包缺少 $required" >&2
        exit 1
    fi
done

# 与官方在线安装保持一致，避免后续更新时提示缺少下载通道记录。
mkdir -p "$DEST/data"
printf 'direct\n' > "$DEST/data/channel"

mkdir -p \
    "$OPENWRT_ROOT/files/etc/init.d" \
    "$OPENWRT_ROOT/files/etc/uci-defaults" \
    "$OPENWRT_ROOT/files/www/luci-static/resources/view/openbox" \
    "$OPENWRT_ROOT/files/usr/share/luci/menu.d" \
    "$OPENWRT_ROOT/files/usr/share/rpcd/acl.d"

cp "$DEST/openwrt/initd/openbox" "$OPENWRT_ROOT/files/etc/init.d/openbox"
cp "$DEST/openwrt/initd/openbox-panel" "$OPENWRT_ROOT/files/etc/init.d/openbox-panel"
cp "$DEST/openwrt/luci/htdocs/luci-static/resources/view/openbox/status.js" \
    "$OPENWRT_ROOT/files/www/luci-static/resources/view/openbox/status.js"
cp "$DEST/openwrt/luci/root/usr/share/luci/menu.d/luci-app-openbox.json" \
    "$OPENWRT_ROOT/files/usr/share/luci/menu.d/luci-app-openbox.json"
cp "$DEST/openwrt/luci/root/usr/share/rpcd/acl.d/luci-app-openbox.json" \
    "$OPENWRT_ROOT/files/usr/share/rpcd/acl.d/luci-app-openbox.json"

chmod 0755 \
    "$DEST/node/bin/node" \
    "$DEST/bin/sing-box" \
    "$OPENWRT_ROOT/files/etc/init.d/openbox" \
    "$OPENWRT_ROOT/files/etc/init.d/openbox-panel"

cat > "$OPENWRT_ROOT/files/etc/uci-defaults/96-openbox" <<'EOF'
#!/bin/sh
rm -rf /tmp/luci-*cache* 2>/dev/null || true
[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/openbox-panel enable
/etc/init.d/openbox-panel start
exit 0
EOF
chmod 0755 "$OPENWRT_ROOT/files/etc/uci-defaults/96-openbox"

echo "Open-Box 已校验并集成到固件"
