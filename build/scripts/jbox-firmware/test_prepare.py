import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import tarfile
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('prepare', HERE / 'prepare.py')
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class FirmwareTests(unittest.TestCase):
    def test_plugin_parity(self):
        build = HERE.parents[1]
        for base, target in [('Lean_x86_64', 'Lean_x86_64_Jox'),
                             ('Lean_x86_64_Docker', 'Lean_x86_64_Jox_Docker')]:
            packages = lambda text: set(re.findall(r'^CONFIG_PACKAGE_(.+)=y$', text, re.M))
            original = packages((build / base / 'custom.sh').read_text(encoding='utf-8'))
            changed = packages((build / target / 'custom.sh').read_text(encoding='utf-8'))
            self.assertEqual(original - changed, {'luci-app-openclash'})
            self.assertEqual(changed - original, {'ca-bundle', 'ip-full', 'kmod-inet-diag',
                                                  'kmod-nft-tproxy', 'kmod-nft-socket'} - original)
            for relative in ['files', 'sources']:
                for source in (build / base / relative).rglob('*'):
                    if source.is_file() and 'openclash' not in str(source.relative_to(build / base)).lower():
                        self.assertEqual(source.read_bytes(),
                                         (build / target / source.relative_to(build / base)).read_bytes())

    def test_full_embed_and_openclash_removal(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = root / 'release.tar.gz'
            entries = {'meta.json': json.dumps({'version': 'v0.1.209', 'arch': 'x64',
                                                 'singboxVersion': '1.14.4-jbox-tcp2'})}
            for path in ['node/bin/node', 'bin/sing-box', 'update.sh', 'uninstall.sh',
                         'openwrt/initd/jbox', 'openwrt/initd/jbox-panel',
                         'openwrt/luci/htdocs/luci-static/resources/view/jbox/status.js',
                         'openwrt/luci/root/usr/share/luci/menu.d/luci-app-jbox.json',
                         'openwrt/luci/root/usr/share/rpcd/acl.d/luci-app-jbox.json',
                         'panel/server/index.mjs']:
                entries[path] = 'fixture'
            with tarfile.open(package, 'w:gz') as archive:
                for name, content in entries.items():
                    info = tarfile.TarInfo(name)
                    encoded = content.encode()
                    info.size, info.mode = len(encoded), 0o700
                    archive.addfile(info, io.BytesIO(encoded))
            checksum = hashlib.sha256(package.read_bytes()).hexdigest()
            def download(url, destination):
                if url.endswith('.sha256'):
                    destination.write_text(checksum + '  release.tar.gz\n')
                else:
                    shutil.copyfile(package, destination)
            (root / '.config').write_text('CONFIG_PACKAGE_luci-app-openclash=y\nCONFIG_PACKAGE_luci-app-passwall=y\n')
            for path in ['files/etc/openclash/config.yaml', 'files/etc/config/openclash',
                         'files/etc/uci-defaults/custom', 'package/luci-app-openclash/Makefile']:
                file = root / path
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text('keep this\ncp /rom/etc/openclash/core/* /etc/openclash/core\n')
            with patch.object(prepare, 'download', download):
                prepare.prepare(root, 'v0.1.209')
            self.assertNotIn('openclash=y', (root / '.config').read_text())
            self.assertIn('luci-app-passwall=y', (root / '.config').read_text())
            self.assertFalse(any('openclash' in p.name for p in (root / 'files').rglob('*')))
            self.assertFalse((root / 'package/luci-app-openclash').exists())
            self.assertEqual((root / 'files/etc/uci-defaults/custom').read_text(), 'keep this\n')
            self.assertIn('jbox-panel enable', (root / 'files/etc/uci-defaults/97-jbox').read_text())
            if os.name != 'nt':
                self.assertEqual((root / 'files/www/luci-static/resources/view/jbox/status.js').stat().st_mode & 0o777, 0o644)
            self.assertEqual(json.loads((root / 'jbox-firmware.json').read_text())['release'], 'v0.1.209')

    def test_reject_archive_escape(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / 'bad.tar.gz'
            with tarfile.open(archive, 'w:gz') as package:
                info = tarfile.TarInfo('../escape')
                info.size = 1
                package.addfile(info, io.BytesIO(b'x'))
            with self.assertRaises(ValueError):
                prepare.extract_verified(archive, root / 'destination')


if __name__ == '__main__':
    unittest.main()
