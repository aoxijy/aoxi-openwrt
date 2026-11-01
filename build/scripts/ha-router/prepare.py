#!/usr/bin/env python3
"""Install the opt-in HA kit after proxy overlays have been prepared."""
from pathlib import Path
import re
import shutil

PACKAGES = ('keepalived', 'flock', 'libcap-bin', 'ip-full', 'kmod-tun')
HERE = Path(__file__).resolve().parent


def prepare(root):
    config = root / '.config'
    text = config.read_text()
    for package in PACKAGES:
        pattern = rf'^(?:CONFIG_PACKAGE_{re.escape(package)}=.*|# CONFIG_PACKAGE_{re.escape(package)} is not set)\n?'
        text = re.sub(pattern, '', text, flags=re.M)
    text = text.rstrip() + '\n' + ''.join(f'CONFIG_PACKAGE_{package}=y\n' for package in PACKAGES)
    config.write_text(text)
    overlay = root / 'files'
    kit = overlay / 'usr/share/ha-quick'
    kit.mkdir(parents=True, exist_ok=True)
    for name in ('install.sh', 'load-identity.sh', 'README.md'):
        shutil.copyfile(HERE / name, kit / name)
        (kit / name).chmod(0o644)
    shutil.copytree(HERE / 'payload', kit / 'payload', dirs_exist_ok=True)
    for path in (kit / 'payload').iterdir():
        path.chmod(0o644)
    init = overlay / 'etc/init.d/ha-quick'
    init.parent.mkdir(parents=True, exist_ok=True)
    init.write_text('''#!/bin/sh /etc/rc.common
START=10
start() {
    [ -e /tmp/ha-quick ] || ln -s /usr/share/ha-quick /tmp/ha-quick
}
''')
    init.chmod(0o755)
    first = overlay / 'etc/uci-defaults/99-ha-quick'
    first.parent.mkdir(parents=True, exist_ok=True)
    first.write_text('''#!/bin/sh
/etc/init.d/ha-quick enable
/etc/init.d/ha-quick start
exit 0
''')
    first.chmod(0o755)
    command = overlay / 'usr/sbin/ha-quick'
    command.parent.mkdir(parents=True, exist_ok=True)
    command.write_text('#!/bin/sh\nexec sh /usr/share/ha-quick/install.sh "$@"\n')
    command.chmod(0o755)
    # No HA init/enabled marker is installed here: generic images must never
    # advertise a user's VIP until that user explicitly selects a node.
    print('Embedded opt-in VRRP kit; no private identities included')


if __name__ == '__main__':
    prepare(Path.cwd())
