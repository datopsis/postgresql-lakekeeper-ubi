"""Negative checks for the single-RPM exception and final-root dependency gate."""
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from artifacts import LockError, validate_lock


class RuntimeDependencyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / 'tools'
        self.bin.mkdir()
        self.log = self.root / 'calls.jsonl'
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}',
                        CALL_LOG=str(self.log), INVENTORY='glibc\npostgresql18-server\npostgresql18-contrib\n')
        rpm = self.bin / 'rpm'
        rpm.write_text(f'#!{sys.executable}\n' + '''import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ['CALL_LOG'], 'a') as log:
    log.write(json.dumps(args) + '\\n')
if '--package' in args:
    print(pathlib.Path(args[-1]).stem)
elif '--all' in args:
    print(os.environ['INVENTORY'], end='')
elif '--verify' in args:
    sys.exit(int(os.environ.get('RPM_VERIFY_FAILURE', '0')))
''')
        rpm.chmod(0o755)
        chroot = self.bin / 'chroot'
        chroot.write_text('#!/bin/sh\nprintf "%s\\n" "${LINKAGE:-libc.so.6 => /lib64/libc.so.6}"\nexit "${LDD_FAILURE:-0}"\n')
        chroot.chmod(0o755)
        for path in ['bin/postgres'] + [f'lib/{name}.so' for name in
                     ('uuid-ossp', 'pgcrypto', 'pg_trgm', 'btree_gin', 'btree_gist', 'plpgsql')]:
            target = self.root / 'usr/pgsql-18' / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.touch()

    def run_script(self, name, *args):
        return subprocess.run(['bash', str(ROOT / 'scripts' / name), str(self.root), *args],
                              env=self.env, capture_output=True, text=True)

    def test_only_exact_contrib_package_receives_nodeps(self):
        rpms = self.root / 'rpms'
        rpms.mkdir()
        for name in ('postgresql18-server', 'postgresql18-contrib', 'glibc'):
            (rpms / f'{name}.rpm').touch()
        result = self.run_script('install-runtime-rpms.sh', str(rpms))
        self.assertEqual(result.returncode, 0, result.stderr)
        installs = [json.loads(line) for line in self.log.read_text().splitlines() if '--install' in line]
        self.assertEqual(len(installs), 2)
        self.assertNotIn('--nodeps', installs[0])
        self.assertNotIn(str(rpms / 'postgresql18-contrib.rpm'), installs[0])
        self.assertEqual(installs[1], ['--root', str(self.root), '--install', '--nodeps', str(rpms / 'postgresql18-contrib.rpm')])
        (rpms / 'postgresql18-contrib.rpm').unlink()
        self.assertNotEqual(self.run_script('install-runtime-rpms.sh', str(rpms)).returncode, 0)

    def test_every_other_package_is_dependency_verified(self):
        result = self.run_script('verify-runtime-dependencies.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        verify = next(json.loads(line) for line in self.log.read_text().splitlines() if '--verify' in line)
        self.assertNotIn('--nodeps', verify)
        self.assertNotIn('postgresql18-contrib', verify)
        self.assertEqual(verify[-2:], ['glibc', 'postgresql18-server'])
        self.env['RPM_VERIFY_FAILURE'] = '1'
        self.assertNotEqual(self.run_script('verify-runtime-dependencies.sh').returncode, 0)

    def test_forbidden_rpm_missing_linkage_and_ldd_errors_fail(self):
        for name in ('python3-libs', 'python3-pip-wheel', 'python3-setuptools-wheel', 'sqlite-libs', 'libxslt'):
            with self.subTest(package=name):
                self.env['INVENTORY'] += name + '\n'
                result = self.run_script('verify-runtime-dependencies.sh')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('forbidden runtime package', result.stderr)
                self.env['INVENTORY'] = self.env['INVENTORY'].removesuffix(name + '\n')
        self.env['LINKAGE'] = 'libabsent.so => not found'
        self.assertNotEqual(self.run_script('verify-runtime-dependencies.sh').returncode, 0)
        self.env.pop('LINKAGE')
        self.env['LDD_FAILURE'] = '1'
        self.assertNotEqual(self.run_script('verify-runtime-dependencies.sh').returncode, 0)

    def test_lock_rejects_removed_dependencies(self):
        for name in ('python3-libs', 'python3-pip-wheel', 'python3-setuptools-wheel', 'sqlite-libs', 'libxslt'):
            with self.subTest(package=name):
                lock = json.loads((ROOT / 'artifacts/locks/amd64.json').read_text())
                package = next(p.copy() for p in lock['packages'] if p['name'] == 'zlib')
                package['nevra'] = package['nevra'].replace('zlib-', name + '-', 1)
                package['filename'] = package['filename'].replace('zlib-', name + '-', 1)
                package['name'] = name
                lock['packages'].append(package)
                lock['packages'].sort(key=lambda p: p['nevra'])
                path = self.root / 'lock.json'
                path.write_text(json.dumps(lock))
                with self.assertRaisesRegex(LockError, 'dependencies of removed contrib modules'):
                    validate_lock(path)


if __name__ == '__main__':
    unittest.main()
