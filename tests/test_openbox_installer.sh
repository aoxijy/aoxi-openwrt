#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PAYLOAD="$TMP/payload"
ASSETS="$TMP/assets"
BUILDROOT="$TMP/openwrt"
ASSET_NAME="open-box-v0.1.169-linux-x64.tar.gz"
mkdir -p \
    "$PAYLOAD/node/bin" \
    "$PAYLOAD/bin" \
    "$PAYLOAD/panel/server" \
    "$PAYLOAD/openwrt/initd" \
    "$PAYLOAD/openwrt/luci/htdocs/luci-static/resources/view/openbox" \
    "$PAYLOAD/openwrt/luci/root/usr/share/luci/menu.d" \
    "$PAYLOAD/openwrt/luci/root/usr/share/rpcd/acl.d" \
    "$ASSETS" "$BUILDROOT/scripts"

for f in \
    node/bin/node \
    bin/sing-box \
    panel/server/index.mjs \
    openwrt/initd/openbox \
    openwrt/initd/openbox-panel \
    openwrt/luci/htdocs/luci-static/resources/view/openbox/status.js \
    openwrt/luci/root/usr/share/luci/menu.d/luci-app-openbox.json \
    openwrt/luci/root/usr/share/rpcd/acl.d/luci-app-openbox.json; do
    printf 'fixture:%s\n' "$f" > "$PAYLOAD/$f"
done

tar -czf "$ASSETS/$ASSET_NAME" -C "$PAYLOAD" .
FIXTURE_SHA256="$(sha256sum "$ASSETS/$ASSET_NAME" | cut -d' ' -f1)"
printf '#!/bin/sh\n' > "$BUILDROOT/scripts/feeds"
chmod +x "$BUILDROOT/scripts/feeds"

(
    cd "$BUILDROOT"
    OPENBOX_ASSET_DIR="$ASSETS" OPENBOX_TEST_SHA256="$FIXTURE_SHA256" \
        bash "$REPO_ROOT/build/scripts/openbox/install.sh"
)

for f in \
    files/opt/open-box/node/bin/node \
    files/opt/open-box/bin/sing-box \
    files/etc/init.d/openbox \
    files/etc/init.d/openbox-panel \
    files/etc/uci-defaults/96-openbox \
    files/www/luci-static/resources/view/openbox/status.js \
    files/usr/share/luci/menu.d/luci-app-openbox.json \
    files/usr/share/rpcd/acl.d/luci-app-openbox.json; do
    test -e "$BUILDROOT/$f"
done

test -x "$BUILDROOT/files/etc/init.d/openbox-panel"
grep -q '^direct$' "$BUILDROOT/files/opt/open-box/data/channel"
grep -q '/etc/init.d/openbox-panel enable' "$BUILDROOT/files/etc/uci-defaults/96-openbox"
grep -q '/etc/init.d/openbox-panel start' "$BUILDROOT/files/etc/uci-defaults/96-openbox"

# 损坏发布包必须在 SHA256 校验阶段被拒绝。
printf 'corrupt' >> "$ASSETS/$ASSET_NAME"
BADROOT="$TMP/bad-openwrt"
mkdir -p "$BADROOT/scripts"
printf '#!/bin/sh\n' > "$BADROOT/scripts/feeds"
chmod +x "$BADROOT/scripts/feeds"
if (cd "$BADROOT" && OPENBOX_ASSET_DIR="$ASSETS" OPENBOX_TEST_SHA256="$FIXTURE_SHA256" \
    bash "$REPO_ROOT/build/scripts/openbox/install.sh" >/dev/null 2>&1); then
    echo "损坏的 Open-Box 发布包未被拒绝" >&2
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
if python3 "$REPO_ROOT/build/scripts/openbox/validate_archive.py" "$MALICIOUS" >/dev/null 2>&1; then
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
if python3 "$REPO_ROOT/build/scripts/openbox/validate_archive.py" "$MALICIOUS_LINK" >/dev/null 2>&1; then
    echo "越界符号链接归档未被拒绝" >&2
    exit 1
fi

echo OPENBOX_INSTALLER_FIXTURE_OK
