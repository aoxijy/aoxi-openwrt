#!/usr/bin/env python3
"""Exercise GNU patch against the real stable header before full builds."""
from pathlib import Path
import subprocess
import tempfile
import urllib.request
from fix_shortcut_patch import fix

with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    for name, url in (
        ('include/linux/skbuff.h', 'https://raw.githubusercontent.com/gregkh/linux/v6.18.58/include/linux/skbuff.h'),
        ('target/linux/generic/hack-6.18/953-net-patch-linux-kernel-to-support-shortcut-fe.patch',
         'https://raw.githubusercontent.com/coolsnowwolf/lede/master/target/linux/generic/hack-6.18/953-net-patch-linux-kernel-to-support-shortcut-fe.patch'),
    ):
        target = root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(url, timeout=60) as response:
            target.write_bytes(response.read())
    fix(root)
    patch = next((root / 'target/linux/generic/hack-6.18').glob('953-*'))
    text = patch.read_text()
    fix(root)
    assert text == patch.read_text(), 'Must be idempotent'
    start = text.index('--- a/include/linux/skbuff.h\n')
    end = text.index('\n--- a/', start + 1)
    diff = text[start:end] + '\n'
    subprocess.run(['patch', '--batch', '--fuzz=0', '-p1'], input=diff, text=True, cwd=root, check=True)
    header = (root / 'include/linux/skbuff.h').read_text()
    assert 'fast_forwarded:1' in header and 'tc_depth:2' in header
    print('GNU patch accepts stable sk_buff header and preserves tc_depth')
