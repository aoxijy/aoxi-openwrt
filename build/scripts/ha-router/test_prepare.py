import importlib.util
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('ha_prepare', HERE / 'prepare.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PrepareTests(unittest.TestCase):
    def test_embeds_opt_in_kit_without_activating_vip(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.config').write_text('# CONFIG_PACKAGE_keepalived is not set\nCONFIG_PACKAGE_flock=m\n')
            module.prepare(root)
            once = (root / '.config').read_text()
            module.prepare(root)
            self.assertEqual(once, (root / '.config').read_text())
            for package in module.PACKAGES:
                self.assertEqual(once.count(f'CONFIG_PACKAGE_{package}=y'), 1)
            self.assertFalse((root / 'files/etc/ha-router.enabled').exists())
            self.assertFalse((root / 'files/etc/init.d/keepalived').exists())
            self.assertIn('/usr/share/ha-quick', (root / 'files/etc/init.d/ha-quick').read_text())
            for node in (2, 8):
                text = (root / f'files/usr/share/ha-quick/payload/easytier-{node}.toml').read_text()
                self.assertIn('__HA_ET_SECRET__', text)
            self.assertIn('__HA_NPS_VKEY__', (root / 'files/usr/share/ha-quick/payload/npc.uci').read_text())


if __name__ == '__main__':
    unittest.main()
