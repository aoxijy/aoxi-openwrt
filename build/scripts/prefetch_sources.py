#!/usr/bin/env python3
"""Repair the unavailable Xray release and verify it before expensive builds."""
import hashlib
import json
from pathlib import Path
import re
import time
import urllib.request

REPAIRED_VERSION = '26.10.31'
REPAIRED_HASH = 'be44f95d497ad4ba6e9d1dcfbbd71e8e51f812aff077d4c15c9947eff5e3046a'


def repair(recipe):
    text = recipe.read_text()
    if re.search(r'^PKG_VERSION:=26\.10\.29$', text, re.M):
        text = re.sub(r'^PKG_VERSION:=.*$', f'PKG_VERSION:={REPAIRED_VERSION}', text, flags=re.M)
        text = re.sub(r'^PKG_HASH:=.*$', f'PKG_HASH:={REPAIRED_HASH}', text, flags=re.M)
        recipe.write_text(text)
        print('Replaced unavailable Xray 26.10.29 with verified 26.10.31')
    version = re.search(r'^PKG_VERSION:=([0-9.]+)$', text, re.M).group(1)
    expected = re.search(r'^PKG_HASH:=([a-f0-9]{64})$', text, re.M).group(1)
    return version, expected


def prefetch(root):
    if 'CONFIG_PACKAGE_xray-core=y' not in (root / '.config').read_text().splitlines():
        return
    recipe = root / 'feeds/packages/net/xray-core/Makefile'
    version, expected = repair(recipe)
    url = f'https://codeload.github.com/XTLS/Xray-core/tar.gz/v{version}'
    target = root / 'dl' / f'xray-core-{version}.tar.gz'
    target.parent.mkdir(exist_ok=True)
    if not target.exists() or hashlib.sha256(target.read_bytes()).hexdigest() != expected:
        temporary = target.with_suffix('.download')
        for attempt in range(3):
            try:
                request = urllib.request.Request(url, headers={'User-Agent': 'aoxi-openwrt'})
                with urllib.request.urlopen(request, timeout=120) as response:
                    data = response.read()
                if hashlib.sha256(data).hexdigest() != expected:
                    raise ValueError('Xray source SHA-256 mismatch; refusing unverified source')
                temporary.write_bytes(data)
                temporary.replace(target)
                break
            except Exception:
                if attempt == 2:
                    raise
                time.sleep(5 * (attempt + 1))
    info = {'package': 'xray-core', 'version': version, 'url': url, 'sha256': expected}
    (root / 'source-preflight.json').write_text(json.dumps(info, indent=2) + '\n')
    print(f'Verified Xray source: {version}, SHA-256 {expected}')


if __name__ == '__main__':
    prefetch(Path.cwd())
