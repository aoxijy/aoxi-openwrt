#!/usr/bin/env python3
"""Embed an already published, checksummed J-Box release into an OpenWrt image."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tarfile
import tempfile
import urllib.request


def download(url, target):
    request = urllib.request.Request(url, headers={'User-Agent': 'aoxi-openwrt-J-Box'})
    with urllib.request.urlopen(request, timeout=120) as response, target.open('wb') as output:
        shutil.copyfileobj(response, output)


def clean_overlay(overlay):
    # Remove copied settings, rules, binaries, init files and stale LuCI assets.
    for item in sorted(overlay.rglob('*'), key=lambda p: len(p.parts), reverse=True):
        if 'openclash' in item.name.lower() or item.name in ('clash_meta', 'clash_tun'):
            if item.is_dir() and not item.is_symlink():
                shutil.rmtree(item)
            else:
                item.unlink()
    for directory in ('etc/uci-defaults', 'etc/init.d'):
        for item in (overlay / directory).glob('*'):
            if item.is_file():
                text = item.read_text(encoding='utf-8')
                if 'openclash' in text.lower():
                    item.write_text(''.join(line for line in text.splitlines(True)
                                            if 'openclash' not in line.lower()), encoding='utf-8')


def extract_verified(archive, destination):
    with tarfile.open(archive) as package:
        for member in package.getmembers():
            target = (destination / member.name).resolve()
            if not target.is_relative_to(destination.resolve()):
                raise ValueError('Archive path escapes installation directory')
            if member.issym() or member.islnk():
                link = ((target.parent if member.issym() else destination) / member.linkname).resolve()
                if not link.is_relative_to(destination.resolve()):
                    raise ValueError('Archive link escapes installation directory')
            if member.isdev():
                raise ValueError('Device node in release archive')
        if hasattr(tarfile, 'data_filter'):
            package.extractall(destination, filter='data')
        else:
            package.extractall(destination)


def prepare(root, version):
    if not re.fullmatch(r'v\d+\.\d+\.\d+', version):
        raise ValueError('Expected a frozen J-Box stable release tag')
    overlay = root / 'files'
    overlay.mkdir(parents=True, exist_ok=True)
    clean_overlay(overlay)
    config = root / '.config'
    text = config.read_text()
    text = re.sub(r'^CONFIG_PACKAGE_([^=\n]*[Oo]pen[Cc]lash[^=\n]*)=[ym]$',
                  r'# CONFIG_PACKAGE_\1 is not set', text, flags=re.M)
    config.write_text(text)
    for directory in ('package', 'feeds'):
        for item in sorted((root / directory).rglob('*'), key=lambda p: len(p.parts), reverse=True):
            if 'openclash' in item.name.lower():
                if item.is_dir() and not item.is_symlink():
                    shutil.rmtree(item)
                elif item.exists() or item.is_symlink():
                    item.unlink()
    asset = f'j-box-{version}-linux-x64.tar.gz'
    url = f'https://github.com/aoxijy/J-box/releases/download/{version}/{asset}'
    with tempfile.TemporaryDirectory(prefix='jbox-firmware-') as temporary:
        temporary = Path(temporary)
        archive, checksum = temporary / asset, temporary / 'checksum'
        download(url + '.sha256', checksum)
        expected = checksum.read_text().split()[0]
        if not re.fullmatch(r'[a-f0-9]{64}', expected):
            raise ValueError('Invalid release checksum')
        download(url, archive)
        digest = hashlib.sha256()
        with archive.open('rb') as stream:
            while block := stream.read(1024 * 1024):
                digest.update(block)
        if digest.hexdigest() != expected:
            raise ValueError('J-Box release checksum mismatch')
        install = overlay / 'opt/j-box'
        install.mkdir(parents=True, exist_ok=True)
        extract_verified(archive, install)
    meta = json.loads((install / 'meta.json').read_text())
    if meta['version'] != version or meta['arch'] != 'x64':
        raise ValueError('J-Box release version or architecture mismatch')
    for name in ('jbox', 'jbox-panel'):
        target = overlay / 'etc/init.d' / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(install / 'openwrt/initd' / name, target)
        target.chmod(0o755)
    for source, target in (
        ('htdocs/luci-static/resources/view/jbox/status.js', 'www/luci-static/resources/view/jbox/status.js'),
        ('root/usr/share/luci/menu.d/luci-app-jbox.json', 'usr/share/luci/menu.d/luci-app-jbox.json'),
        ('root/usr/share/rpcd/acl.d/luci-app-jbox.json', 'usr/share/rpcd/acl.d/luci-app-jbox.json'),
    ):
        destination = overlay / target
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(install / 'openwrt/luci' / source, destination)
        destination.chmod(0o644)
    for directory in (overlay / 'www/luci-static/resources/view/jbox',
                      overlay / 'usr/share/luci/menu.d', overlay / 'usr/share/rpcd/acl.d'):
        directory.chmod(0o755)
    for binary in ('node/bin/node', 'bin/sing-box', 'update.sh', 'uninstall.sh'):
        (install / binary).chmod(0o755)
    for directory in ('data', 'etc', 'logs'):
        (install / directory).mkdir(exist_ok=True)
    (install / 'data/channel').write_text('direct\n')
    startup = overlay / 'etc/uci-defaults/97-jbox'
    startup.parent.mkdir(parents=True, exist_ok=True)
    startup.write_text('''#!/bin/sh
# Offline first boot: enable the management panel; proxy core waits for user configuration.
mkdir -p /opt/j-box/data
/etc/init.d/jbox disable
/etc/init.d/jbox-panel enable
/etc/init.d/jbox-panel start
exit 0
''')
    startup.chmod(0o755)
    record = {'release': version, 'kernel': meta['singboxVersion'], 'sha256': expected,
              'source': url, 'openclash': 'removed'}
    (root / 'jbox-firmware.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record, indent=2))


if __name__ == '__main__':
    prepare(Path.cwd(), os.environ['JBOX_RELEASE_VERSION'])
