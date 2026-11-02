#!/usr/bin/env python3
"""Check assembled images before publishing the four firmware variants."""
from pathlib import Path


def verify(root):
    targets = root / 'bin/targets'
    # packages/Packages.manifest is a package repository index (RFC822), not
    # the opkg list-installed manifest emitted for a firmware image.
    manifests = [path for path in targets.rglob('*.manifest')
                 if 'packages' not in path.relative_to(targets).parts[:-1]
                 and path.name != 'Packages.manifest']
    assert manifests, 'No firmware manifest'
    for manifest in manifests:
        names = {line.split(' - ')[0] for line in manifest.read_text().splitlines()}
        for package in ('keepalived', 'flock', 'libcap-bin', 'ip-full', 'kmod-tun'):
            assert package in names, f'{package} missing from {manifest}'
    images = list((root / 'build_dir').glob('target-*/root-x86'))
    assert images, 'No assembled root filesystem'
    for image in images:
        kit = image / 'usr/share/ha-quick'
        for name in ('install.sh', 'load-identity.sh', 'payload/ha-check', 'payload/ha-role'):
            assert (kit / name).is_file(), f'Missing HA file: {name}'
        assert '__HA_ET_SECRET__' in (kit / 'payload/easytier-8.toml').read_text()
        assert '__HA_NPS_VKEY__' in (kit / 'payload/npc.uci').read_text()
        assert not (image / 'etc/ha-router.enabled').exists(), 'HA enabled before node selection'
        assert not (image / 'etc/ha-quick/identity.conf').exists(), 'Private identity embedded'
        assert (image / 'etc/uci-defaults/99-ha-quick').is_file()
        # Existing EasyTier/NPC packages are installed on first boot by 98-pre_install.
        packages = image / 'etc/pre_install'
        for pattern in ('easytier_*.ipk', 'luci-app-easytier_*.ipk', 'npc_*.ipk', 'luci-app-npc_*.ipk'):
            matches = list(packages.glob(pattern))
            assert matches and all(p.stat().st_size > 0 for p in matches), f'Missing/empty {pattern}'
        print(f'Verified {image}: HA dependencies, opt-in kit, bundled EasyTier/NPC')


if __name__ == '__main__':
    verify(Path.cwd())
