"""TLS client policy and real ephemeral certificate validity regression tests."""
import ast
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

from urllib.parse import unquote

import yaml

from tls_pki import generate
from tls_profile import ROOT, url, validate_url


# Only rule definitions and their mutation tests are excluded from the deny scan.
DENY = re.compile(
    r'verify\s*[:=]\s*false|--insecure\b|curl\b[^\n]*\s-[a-z]*k[a-z]*(?=\s|$)|cert_none|'
    r'check_hostname\s*[:=]\s*false|insecure_?skip_?verify\s*[:=]\s*true|'
    r'danger_accept_invalid_(?:certs|hostnames)|aws_allow_invalid_certificates\s*[:=]\s*true|'
    r'(?:proxy|grpc)_ssl_verify\s+off|aws_allow_http\s*[:=]\s*true|'
    r'(?:sslmode|pgsslmode)\s*[:=]\s*[\"\']?(?:require|allow|prefer|disable|verify-ca)\b', re.I)


class TLSPolicyTests(unittest.TestCase):
    def test_static_no_verification_downgrades(self):
        paths = subprocess.check_output(['git', 'ls-files'], cwd=ROOT, text=True).splitlines()
        for filename in paths:
            path = ROOT / filename
            if path.suffix not in ('.py', '.sh', '.yaml', '.yml') or path.name == 'test_tls_policy.py':
                continue
            source = path.read_text()
            if path.name == 'tls_profile.py':
                # Exclude only the single deliberate plaintext URL builder, not its callers.
                tree = ast.parse(source)
                lines = source.splitlines()
                for node in ast.walk(tree):
                    if isinstance(node, ast.FunctionDef) and node.name == 'plaintext_connection':
                        lines[node.lineno - 1:node.end_lineno] = [''] * (node.end_lineno - node.lineno + 1)
                source = '\n'.join(lines)
            self.assertIsNone(DENY.search(unquote(source).replace('"', '').replace("'", '')), filename)

    def test_compose_selects_read_only_service_tls(self):
        config = yaml.safe_load((ROOT / 'compose.yaml').read_text())
        service = config['services']['postgresql']
        self.assertEqual(service['environment']['POSTGRESQL_TLS_CERT_FILE'], '/run/tls/server.crt')
        self.assertEqual(service['environment']['POSTGRESQL_TLS_KEY_FILE'], '/run/tls/server.key')
        for name in ('crt', 'key'):
            mounts = [v for v in service['volumes'] if f':/run/tls/server.{name}:' in v]
            self.assertEqual(len(mounts), 1)
            self.assertTrue(mounts[0].endswith(':ro'))
            self.assertIn(':?supply', mounts[0])
        self.assertIn('postgres', service['networks']['default']['aliases'])
        self.assertTrue(service['read_only'])
        self.assertEqual(service['cap_drop'], ['ALL'])
        self.assertEqual(service['security_opt'], ['no-new-privileges:true'])

    def test_url_parser_rejects_downgrades_and_duplicate_options(self):
        valid = url()
        self.assertEqual(validate_url(valid), valid)
        for mode in ('require', 'allow', 'prefer', 'disable', 'verify-ca'):
            with self.subTest(mode=mode), self.assertRaises(AssertionError):
                validate_url(valid.replace('verify-full', mode))
        for suffix in ('&sslmode=verify-full', '&sslmode=disable', '&sslmode=', '&sslcert=/other/key'):
            with self.assertRaises(AssertionError):
                validate_url(valid + suffix)
        for bad in ('verify=False', 'VERIFY=false', 'InsecureSkipVerify=true',
                    'PGSSLMODE=require', 'sslmode%3Dprefer', 'curl -s -k https://postgres',
                    'curl -k https://postgres', 'curl -ks https://postgres'):
            self.assertIsNotNone(DENY.search(unquote(bad)))

    def test_real_pki_dates_identity_and_issuers(self):
        with tempfile.TemporaryDirectory() as directory:
            inventory = generate(directory)
            root = Path(directory)
            self.assertFalse(list((root / 'authority').glob('*.key')))
            for name, reason in (('valid', None), ('rotated', None),
                                 ('wrong-root', 'unable to get local issuer certificate'),
                                 ('wrong-san', 'hostname mismatch'),
                                 ('other-service', 'hostname mismatch'),
                                 ('expired', 'certificate has expired'),
                                 ('future', 'certificate is not yet valid')):
                result = subprocess.run(['openssl', 'verify', '-CAfile', str(root / 'client/trusted.crt'),
                                         '-purpose', 'sslserver', '-verify_hostname', 'postgres',
                                         str(root / name / 'server.crt')], capture_output=True, text=True)
                with self.subTest(name=name):
                    self.assertIn('sha256 fingerprint=', inventory[name].lower())
                    if reason:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn(reason, result.stderr)
                    else:
                        self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('subject=CN = postgres', inventory['wrong-san'])
            self.assertIn('DNS:wrong.invalid', inventory['wrong-san'])


if __name__ == '__main__':
    unittest.main()
