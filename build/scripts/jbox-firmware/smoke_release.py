#!/usr/bin/env python3
"""Exercise the real release archive before starting expensive firmware builds."""
import os
from pathlib import Path
import subprocess
import tempfile
from prepare import prepare

with tempfile.TemporaryDirectory(prefix='jbox-release-smoke-') as temporary:
    root = Path(temporary)
    (root / '.config').write_text('')
    prepare(root, os.environ['JBOX_RELEASE_VERSION'])
    engine = root / 'files/opt/j-box/panel/server/engine/config.mjs'
    helper = root / 'files/opt/j-box/openwrt/initd/easytier-compat.sh'
    assert helper.is_file(), 'Release must include EasyTier launch isolation'
    assert '--gid=20260' in helper.read_text()
    init = root / 'files/etc/init.d/jbox'
    assert 'meta skgid 20260' in init.read_text(), 'Release must bypass EasyTier sockets'
    subprocess.run(['node', '--input-type=module', '-e', '''
      const {buildConfig}=await import(process.argv[1]);
      const c=buildConfig({nodes:[],userGroups:[],profile:{ipv6:false,dns:{mode:'dnsmasq'},routing:{policies:[]},rulesetDir:'/unused'}});
      if(c.inbounds[0].type!=='tun'||c.inbounds[0].interface_name!=='jbox-tun')throw Error('J-Box must use an independent TUN interface');
      console.log('Real release extraction, dependency imports and independent TUN generation: OK');
    ''', engine.as_uri()], check=True)
