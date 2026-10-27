#!/usr/bin/env python3
"""Fail before publishing when the assembled image lacks J-Box or retains OpenClash."""
import json
from pathlib import Path
import stat


def verify(root):
    manifests = list((root / 'bin/targets').rglob('*.manifest'))
    assert manifests, 'No firmware package manifest was generated'
    for manifest in manifests:
        assert 'openclash' not in manifest.read_text().lower(), f'OpenClash in {manifest}'
    images = list((root / 'build_dir').glob('target-*/root-x86'))
    assert images, 'Assembled root-x86 filesystem not found'
    expected = json.loads((root / 'jbox-firmware.json').read_text())
    for image in images:
        assert not any('openclash' in p.name.lower() for p in image.rglob('*')), 'OpenClash file remains'
        meta = json.loads((image / 'opt/j-box/meta.json').read_text())
        assert meta['version'] == expected['release'], 'Embedded J-Box version mismatch'
        for path in ('www/luci-static/resources/view/jbox/status.js',
                     'usr/share/luci/menu.d/luci-app-jbox.json',
                     'usr/share/rpcd/acl.d/luci-app-jbox.json'):
            file = image / path
            assert stat.S_IMODE(file.stat().st_mode) == 0o644, f'Unreadable LuCI file: {path}'
            for parent in file.parents:
                if parent == image:
                    break
                assert parent.stat().st_mode & 0o005 == 0o005, f'Inaccessible directory: {parent}'
        for path in ('opt/j-box/node/bin/node', 'opt/j-box/bin/sing-box',
                     'etc/init.d/jbox', 'etc/init.d/jbox-panel', 'etc/uci-defaults/97-jbox'):
            assert (image / path).stat().st_mode & 0o111, f'Missing executable: {path}'
        assert (image / 'opt/j-box/panel/server/index.mjs').is_file(), 'Missing panel entry'
        print(f'Verified {image}: J-Box {meta["version"]}, LuCI permissions, no OpenClash')


if __name__ == '__main__':
    verify(Path.cwd())
