#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PAYLOAD="$TMP/payload"
ASSETS="$TMP/assets"
BUILDROOT="$TMP/openwrt"
# 本地夹具模式用不带版本号的稳定资产名(install.sh 在 JBOX_ASSET_DIR 下不联网解析 tag)
ASSET_NAME="j-box-linux-x64.tar.gz"
mkdir -p \
    "$PAYLOAD/node/bin" \
    "$PAYLOAD/bin" \
    "$PAYLOAD/panel/server" \
    "$PAYLOAD/openwrt/initd" \
    "$PAYLOAD/openwrt/luci/htdocs/luci-static/resources/view/jbox" \
    "$PAYLOAD/openwrt/luci/root/usr/share/luci/menu.d" \
    "$PAYLOAD/openwrt/luci/root/usr/share/rpcd/acl.d" \
    "$ASSETS" "$BUILDROOT/scripts"

for f in \
    node/bin/node \
    bin/sing-box \
    panel/server/index.mjs \
    openwrt/initd/jbox \
    openwrt/initd/jbox-panel \
    openwrt/luci/htdocs/luci-static/resources/view/jbox/status.js \
    openwrt/luci/root/usr/share/luci/menu.d/luci-app-jbox.json \
    openwrt/luci/root/usr/share/rpcd/acl.d/luci-app-jbox.json; do
    printf 'fixture:%s\n' "$f" > "$PAYLOAD/$f"
done

tar -czf "$ASSETS/$ASSET_NAME" -C "$PAYLOAD" .
FIXTURE_SHA256="$(sha256sum "$ASSETS/$ASSET_NAME" | cut -d' ' -f1)"
printf '#!/bin/sh\n' > "$BUILDROOT/scripts/feeds"
chmod +x "$BUILDROOT/scripts/feeds"

(
    cd "$BUILDROOT"
    JBOX_ASSET_DIR="$ASSETS" JBOX_TEST_SHA256="$FIXTURE_SHA256" \
        bash "$REPO_ROOT/build/scripts/jbox/install.sh"
)

for f in \
    files/opt/j-box/node/bin/node \
    files/opt/j-box/bin/sing-box \
    files/etc/init.d/jbox \
    files/etc/init.d/jbox-panel \
    files/etc/uci-defaults/96-jbox \
    files/www/luci-static/resources/view/jbox/status.js \
    files/usr/share/luci/menu.d/luci-app-jbox.json \
    files/usr/share/rpcd/acl.d/luci-app-jbox.json; do
    test -e "$BUILDROOT/$f"
done

test -x "$BUILDROOT/files/etc/init.d/jbox-panel"
grep -q '^direct$' "$BUILDROOT/files/opt/j-box/data/channel"
grep -q '/etc/init.d/jbox-panel enable' "$BUILDROOT/files/etc/uci-defaults/96-jbox"
grep -q '/etc/init.d/jbox-panel start' "$BUILDROOT/files/etc/uci-defaults/96-jbox"

# 损坏发布包必须在 SHA256 校验阶段被拒绝。
printf 'corrupt' >> "$ASSETS/$ASSET_NAME"
BADROOT="$TMP/bad-openwrt"
mkdir -p "$BADROOT/scripts"
printf '#!/bin/sh\n' > "$BADROOT/scripts/feeds"
chmod +x "$BADROOT/scripts/feeds"
if (cd "$BADROOT" && JBOX_ASSET_DIR="$ASSETS" JBOX_TEST_SHA256="$FIXTURE_SHA256" \
    bash "$REPO_ROOT/build/scripts/jbox/install.sh" >/dev/null 2>&1); then
    echo "损坏的 J-Box 发布包未被拒绝" >&2
    exit 1
fi

# 即使摘要匹配，包含路径穿越成员的归档也必须被拒绝。
MALICIOUS="$TMP/malicious.tar.gz"
python3 - "$MALICIOUS" <<'PY'
import io
import sys
import tarfile

with tarfile.open(sys.argv[1], "w:gz") as bundle:
    info = tarfile.TarInfo("../escape")
    payload = b"escape"
    info.size = len(payload)
    bundle.addfile(info, io.BytesIO(payload))
PY
if python3 "$REPO_ROOT/build/scripts/jbox/validate_archive.py" "$MALICIOUS" >/dev/null 2>&1; then
    echo "路径穿越归档未被拒绝" >&2
    exit 1
fi

MALICIOUS_LINK="$TMP/malicious-link.tar.gz"
python3 - "$MALICIOUS_LINK" <<'PY'
import sys
import tarfile

with tarfile.open(sys.argv[1], "w:gz") as bundle:
    info = tarfile.TarInfo("safe/link")
    info.type = tarfile.SYMTYPE
    info.linkname = "../../etc/passwd"
    bundle.addfile(info)
PY
if python3 "$REPO_ROOT/build/scripts/jbox/validate_archive.py" "$MALICIOUS_LINK" >/dev/null 2>&1; then
    echo "越界符号链接归档未被拒绝" >&2
    exit 1
fi

echo JBOX_INSTALLER_FIXTURE_OK
