#!/bin/bash
set -euo pipefail

OPENWRT_ROOT="$(pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="aoxijy/J-box"
ASSET_ARCH="${JBOX_ARCH:-x64}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [ ! -x "$OPENWRT_ROOT/scripts/feeds" ]; then
    echo "错误: 请从 OpenWrt 源码根目录运行 J-Box 集成脚本" >&2
    exit 1
fi

# 解析要集成进固件的版本:默认取 aoxijy/J-box 的最新 release,所以每次编译都会自动
# 拉到当时最新的 J-Box。JBOX_VERSION 可显式钉一个 tag(回滚 / 复现构建用)。
resolve_latest_tag() {
    if [ -n "${JBOX_VERSION:-}" ]; then
        printf '%s\n' "$JBOX_VERSION"
        return 0
    fi
    curl -fsSI --connect-timeout 20 --retry 3 --retry-all-errors \
        "https://github.com/$REPO/releases/latest" 2>/dev/null \
        | tr -d '\r' \
        | sed -n 's/^[Ll]ocation: .*\/releases\/tag\/\(v[0-9][0-9A-Za-z._-]*\).*/\1/p' \
        | head -n 1
}

# 本地夹具模式(测试用,不联网):直接读 JBOX_ASSET_DIR 里的资产。
if [ -n "${JBOX_ASSET_DIR:-}" ]; then
    ASSET="${JBOX_ASSET:-j-box-linux-${ASSET_ARCH}.tar.gz}"
    echo "使用本地 J-Box 资产目录: $JBOX_ASSET_DIR/$ASSET"
else
    LATEST_TAG="$(resolve_latest_tag || true)"
    case "$LATEST_TAG" in
        *[!A-Za-z0-9._-]*) LATEST_TAG="" ;;
    esac
    if [ -n "$LATEST_TAG" ]; then
        ASSET="j-box-${LATEST_TAG}-linux-${ASSET_ARCH}.tar.gz"
        ASSET_URL="https://github.com/$REPO/releases/download/${LATEST_TAG}/$ASSET"
        echo "J-Box 最新版本: $LATEST_TAG"
    else
        # 解析不到 tag(网络受限 / releases/latest 不返回 Location)时退回稳定资产名:
        # releases/latest/download/<name> 由 GitHub 自己 302 到最新 release 的同名资产。
        ASSET="j-box-linux-${ASSET_ARCH}.tar.gz"
        ASSET_URL="https://github.com/$REPO/releases/latest/download/$ASSET"
        echo "警告: 未能解析 J-Box 最新 tag,改用稳定资产名 $ASSET" >&2
    fi
    SHA_URL="$ASSET_URL.sha256"
fi

fetch_asset() {
    local url="$1"
    local output="$2"
    local prefix
    for prefix in "" "${JBOX_MIRROR:-https://ghfast.top/}"; do
        rm -f "$output"
        if curl -fL --retry 3 --retry-all-errors --connect-timeout 20 \
            --speed-limit 1024 --speed-time 60 --max-time 900 \
            "${prefix}${url}" -o "$output"; then
            return 0
        fi
        echo "警告: 下载失败,切换 J-Box 下载通道: ${prefix}${url}" >&2
    done

    echo "错误: 无法下载 J-Box 资产 $url" >&2
    return 1
}

if [ -n "${JBOX_ASSET_DIR:-}" ]; then
    cp "$JBOX_ASSET_DIR/$ASSET" "$TMP_DIR/$ASSET"
    if [ -n "${JBOX_TEST_SHA256:-}" ]; then
        printf '%s  %s\n' "$JBOX_TEST_SHA256" "$TMP_DIR/$ASSET" | sha256sum -c -
    elif [ -f "$JBOX_ASSET_DIR/$ASSET.sha256" ]; then
        cp "$JBOX_ASSET_DIR/$ASSET.sha256" "$TMP_DIR/$ASSET.sha256"
        (cd "$TMP_DIR" && sha256sum -c "$ASSET.sha256")
    else
        echo "错误: 本地资产目录缺少 $ASSET.sha256,请同时提供 JBOX_TEST_SHA256" >&2
        exit 1
    fi
else
    fetch_asset "$ASSET_URL" "$TMP_DIR/$ASSET"
    # 摘要来自该 release 自己发布的 .sha256:版本每次自动取最新,不能把哈希写死在仓库里
    # (写死的话每次 J-Box 发版都得改这个仓库)。供应链信任根仍是同一个 GitHub 仓库。
    fetch_asset "$SHA_URL" "$TMP_DIR/$ASSET.sha256"
    (cd "$TMP_DIR" && sha256sum -c "$ASSET.sha256")
fi

echo "J-Box 资产校验通过: $ASSET"

DEST="$OPENWRT_ROOT/files/opt/j-box"
rm -rf "$DEST"
python3 "$SCRIPT_DIR/validate_archive.py" --extract "$DEST" "$TMP_DIR/$ASSET"

for required in \
    node/bin/node \
    bin/sing-box \
    panel/server/index.mjs \
    openwrt/initd/jbox \
    openwrt/initd/jbox-panel \
    openwrt/luci/htdocs/luci-static/resources/view/jbox/status.js \
    openwrt/luci/root/usr/share/luci/menu.d/luci-app-jbox.json \
    openwrt/luci/root/usr/share/rpcd/acl.d/luci-app-jbox.json; do
    if [ ! -e "$DEST/$required" ]; then
        echo "错误: J-Box 发布包缺少 $required" >&2
        exit 1
    fi
done

# 与官方在线安装保持一致，避免后续更新时提示缺少下载通道记录。
mkdir -p "$DEST/data"
printf 'direct\n' > "$DEST/data/channel"

mkdir -p \
    "$OPENWRT_ROOT/files/etc/init.d" \
    "$OPENWRT_ROOT/files/etc/uci-defaults" \
    "$OPENWRT_ROOT/files/www/luci-static/resources/view/jbox" \
    "$OPENWRT_ROOT/files/usr/share/luci/menu.d" \
    "$OPENWRT_ROOT/files/usr/share/rpcd/acl.d"

cp "$DEST/openwrt/initd/jbox" "$OPENWRT_ROOT/files/etc/init.d/jbox"
cp "$DEST/openwrt/initd/jbox-panel" "$OPENWRT_ROOT/files/etc/init.d/jbox-panel"
cp "$DEST/openwrt/luci/htdocs/luci-static/resources/view/jbox/status.js" \
    "$OPENWRT_ROOT/files/www/luci-static/resources/view/jbox/status.js"
cp "$DEST/openwrt/luci/root/usr/share/luci/menu.d/luci-app-jbox.json" \
    "$OPENWRT_ROOT/files/usr/share/luci/menu.d/luci-app-jbox.json"
cp "$DEST/openwrt/luci/root/usr/share/rpcd/acl.d/luci-app-jbox.json" \
    "$OPENWRT_ROOT/files/usr/share/rpcd/acl.d/luci-app-jbox.json"

chmod 0755 \
    "$DEST/node/bin/node" \
    "$DEST/bin/sing-box" \
    "$OPENWRT_ROOT/files/etc/init.d/jbox" \
    "$OPENWRT_ROOT/files/etc/init.d/jbox-panel"

cat > "$OPENWRT_ROOT/files/etc/uci-defaults/96-jbox" <<'EOF'
#!/bin/sh
rm -rf /tmp/luci-*cache* 2>/dev/null || true
[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/jbox-panel enable
/etc/init.d/jbox-panel start
exit 0
EOF
chmod 0755 "$OPENWRT_ROOT/files/etc/uci-defaults/96-jbox"

echo "J-Box 已校验并集成到固件(版本资产: $ASSET)"
