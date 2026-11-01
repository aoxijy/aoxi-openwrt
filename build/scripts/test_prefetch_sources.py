from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import hashlib
import io
import prefetch_sources as sources


class SourceTests(unittest.TestCase):
    def test_repairs_removed_release_with_fixed_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            recipe = Path(directory) / 'Makefile'
            recipe.write_text('PKG_VERSION:=26.10.29\nPKG_HASH:=' + 'a' * 64 + '\n')
            self.assertEqual(sources.repair(recipe), (sources.REPAIRED_VERSION, sources.REPAIRED_HASH))
            once = recipe.read_text()
            sources.repair(recipe)
            self.assertEqual(once, recipe.read_text())

    def test_rejects_bad_archive_instead_of_disabling_hash_check(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            recipe = root / 'feeds/packages/net/xray-core/Makefile'
            recipe.parent.mkdir(parents=True)
            recipe.write_text('PKG_VERSION:=26.10.31\nPKG_HASH:=' + 'a' * 64 + '\n')
            (root / '.config').write_text('CONFIG_PACKAGE_xray-core=y\n')
            with patch('urllib.request.urlopen', side_effect=lambda *a, **k: io.BytesIO(b'bad')), patch('time.sleep'):
                with self.assertRaisesRegex(ValueError, 'SHA-256 mismatch'):
                    sources.prefetch(root)
            self.assertFalse((root / 'dl/xray-core-26.10.31.tar.gz').exists())

    def test_download_and_cache_verified_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            recipe = root / 'feeds/packages/net/xray-core/Makefile'
            recipe.parent.mkdir(parents=True)
            data = b'verified fixture'
            expected = hashlib.sha256(data).hexdigest()
            recipe.write_text(f'PKG_VERSION:=26.10.31\nPKG_HASH:={expected}\n')
            (root / '.config').write_text('CONFIG_PACKAGE_xray-core=y\n')
            with patch('urllib.request.urlopen', return_value=io.BytesIO(data)) as fetch:
                sources.prefetch(root)
                sources.prefetch(root)
                fetch.assert_called_once()


if __name__ == '__main__':
    unittest.main()
