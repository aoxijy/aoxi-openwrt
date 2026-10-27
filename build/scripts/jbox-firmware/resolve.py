#!/usr/bin/env python3
"""Resolve one published J-Box version for both firmware jobs."""
import json
import os
import re
import urllib.request

request = urllib.request.Request('https://api.github.com/repos/aoxijy/J-box/releases/latest',
                                 headers={'User-Agent': 'aoxi-openwrt-J-Box'})
with urllib.request.urlopen(request, timeout=60) as response:
    release = json.load(response)
version = release['tag_name']
assert not release['draft'] and not release['prerelease'], 'Expected a stable release'
assert re.fullmatch(r'v\d+\.\d+\.\d+', version), 'Invalid release tag'
assert tuple(map(int, version[1:].split('.'))) >= (0, 1, 209), 'Requires the LuCI permission fix in v0.1.209 or newer'
assets = {asset['name'] for asset in release['assets']}
for suffix in ('.tar.gz', '.tar.gz.sha256'):
    assert f'j-box-{version}-linux-x64{suffix}' in assets, 'Missing x64 release assets'
with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
    output.write(f'version={version}\n')
print(f'Both Jox firmware builds will embed J-Box {version}')
