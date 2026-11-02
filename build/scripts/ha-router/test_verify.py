import importlib.util
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('ha_verify', HERE / 'verify.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def fixture(root):
    target = root / 'bin/targets/x86/64'
    (target / 'packages').mkdir(parents=True)
    (target / 'packages/Packages.manifest').write_text('Package: keepalived\nVersion: 2.2.7\n')
    manifest = target / 'openwrt-x86-64-generic.manifest'
    manifest.write_text(''.join(f'{name} - 1\n' for name in
                              ('keepalived', 'flock', 'libcap-bin', 'ip-full', 'kmod-tun')))
    image = root / 'build_dir/target-x86_64_musl/root-x86'
    kit = image / 'usr/share/ha-quick'
    for name, text in (
        ('install.sh', '#!/bin/sh\n'), ('load-identity.sh', '# fixture\n'),
        ('payload/ha-check', '#!/bin/sh\n'), ('payload/ha-role', '#!/bin/sh\n'),
        ('payload/easytier-8.toml', '__HA_ET_SECRET__'), ('payload/npc.uci', '__HA_NPS_VKEY__'),
    ):
        path = kit / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    first = image / 'etc/uci-defaults/99-ha-quick'
    first.parent.mkdir(parents=True)
    first.write_text('#!/bin/sh\n')
    packages = image / 'etc/pre_install'
    packages.mkdir()
    for name in ('easytier_2.ipk', 'luci-app-easytier_2.ipk', 'npc_1.ipk', 'luci-app-npc_1.ipk'):
        (packages / name).write_bytes(b'fixture')
    return manifest


class VerifyTests(unittest.TestCase):
    def test_package_repository_index_does_not_fail_image_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture(root)
            module.verify(root)

    def test_missing_package_in_image_still_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = fixture(root)
            manifest.write_text(manifest.read_text().replace('flock - 1\n', ''))
            with self.assertRaisesRegex(AssertionError, 'flock missing'):
                module.verify(root)

    def test_repository_index_alone_cannot_prove_image_packages(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture(root).unlink()
            with self.assertRaisesRegex(AssertionError, 'No firmware manifest'):
                module.verify(root)


if __name__ == '__main__':
    unittest.main()
