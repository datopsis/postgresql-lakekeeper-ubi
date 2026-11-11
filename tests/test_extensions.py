from pathlib import Path
import os
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/prune-extensions.sh'


class ExtensionPruningTests(unittest.TestCase):
    def fixture(self, directory):
        root = Path(directory)
        pg = root / 'usr/pgsql-18'
        ext = pg / 'share/extension'
        lib = pg / 'lib'
        ext.mkdir(parents=True)
        lib.mkdir()
        files = []
        for name in ('btree_gin', 'btree_gist', 'pg_trgm', 'pgcrypto', 'uuid-ossp', 'plpgsql', 'hstore'):
            for path in (ext / f'{name}.control', ext / f'{name}--1.0.sql', lib / f'{name}.so'):
                path.touch()
                if name != 'plpgsql':
                    files.append('/' + str(path.relative_to(root)))
        # Non-extension modules must also be removed, even without controls.
        (lib / 'auto_explain.so').touch()
        files.append('/usr/pgsql-18/lib/auto_explain.so')
        bin_dir = root / 'bin'
        bin_dir.mkdir()
        rpm = bin_dir / 'rpm'
        rpm.write_text('#!/bin/sh\ncat <<\'FILES\'\n' + '\n'.join(files) + '\nFILES\n')
        rpm.chmod(0o755)
        return root, pg, dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}")

    def test_removed_sql_libraries_and_controls_are_absent(self):
        with tempfile.TemporaryDirectory() as directory:
            root, pg, env = self.fixture(directory)
            subprocess.run(['bash', str(SCRIPT), str(root)], env=env, check=True)
            self.assertFalse(list(pg.rglob('hstore*')))
            self.assertFalse((pg / 'lib/auto_explain.so').exists())
            self.assertEqual(len(list((pg / 'share/extension').glob('*.control'))), 6)

    def test_unexpected_server_extension_or_missing_required_library_fails(self):
        for mutation in ('extra', 'missing'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                root, pg, env = self.fixture(directory)
                if mutation == 'extra':
                    (pg / 'share/extension/surprise.control').touch()
                else:
                    (pg / 'lib/pgcrypto.so').unlink()
                result = subprocess.run(['bash', str(SCRIPT), str(root)], env=env, capture_output=True)
                self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
