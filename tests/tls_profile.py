"""Qualify the mounted profile with the image's real libpq client, never mocks."""
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import tempfile
import time
from urllib.parse import parse_qs, urlencode, urlsplit

from tls_pki import generate


ROOT = Path(__file__).resolve().parents[1]


def validate_url(url, plaintext_probe=False):
    parsed = urlsplit(url)
    options = parse_qs(parsed.query, strict_parsing=True)
    assert parsed.scheme == 'postgresql' and parsed.port == 5432
    assert parsed.username == 'postgres' and parsed.password is None
    assert parsed.path == '/lakekeeper'
    assert set(options) <= {'sslmode', 'sslrootcert', 'connect_timeout', 'hostaddr',
                            'ssl_min_protocol_version', 'ssl_max_protocol_version'}
    assert all(len(values) == 1 for values in options.values())
    assert options['sslmode'] == [('disable' if plaintext_probe else 'verify-full')]
    assert options['sslrootcert'][0].startswith('/run/tls/')
    return url


def url(host='postgres', ca='trusted', **options):
    return validate_url(f'postgresql://postgres@{host}:5432/lakekeeper?' + urlencode({
        'sslmode': 'verify-full', 'sslrootcert': f'/run/tls/{ca}.crt',
        'connect_timeout': '3', **options}))


class Profile:
    def __init__(self, directory):
        self.directory = Path(directory)
        self.runtime = os.environ.get('CONTAINER_RUNTIME', 'podman')
        self.image = os.environ.get('IMAGE', 'localhost/postgresql-lakekeeper-ubi:development')
        self.prefix = 'pg-tls-' + secrets.token_hex(6)
        self.server = self.prefix + '-server'
        self.client = self.prefix + '-client'
        self.network = self.prefix + '-net'
        self.volumes = [self.prefix + suffix for suffix in ('-data', '-server-tls', '-client-tls')]
        self.password = secrets.token_hex(24)
        self.rows = []
        self.report = {'revision': os.environ.get('GITHUB_SHA', 'local'), 'scope': 'Phase A item 1; psql/libpq, not Lakekeeper SQLx',
                       'image': self.image, 'coverage': self.rows, 'complete': False}

    def command(self, *args, check=True):
        result = subprocess.run(list(map(str, args)), capture_output=True, text=True, timeout=120)
        if check and result.returncode:
            # Do not print command arguments, environment, PEMs or unfiltered logs.
            raise RuntimeError(f'command failed ({args[0]}), exit {result.returncode}')
        return result

    def run(self, *args, **kwargs):
        return self.command(self.runtime, *args, **kwargs)

    def hardened(self):
        option = 'no-new-privileges' if 'podman' in self.runtime else 'no-new-privileges:true'
        return ['--read-only', '--tmpfs', '/tmp:rw,noexec,nosuid,nodev,size=64m,mode=1777',
                '--cap-drop', 'ALL', '--security-opt', option]

    def stage(self, source, volume):
        # Only this role's files are mounted; no signing key or sibling key directory.
        self.run('run', '--rm', '--network', 'none', '--user', '0',
                 '--mount', f'type=bind,src={source},dst=/source,readonly',
                 '--mount', f'type=volume,src={volume},dst=/target',
                 '--entrypoint', 'sh', self.image, '-ceu',
                 'rm -f /target/*; cp /source/* /target/; chown 0:0 /target/*; '
                 'chmod 0444 /target/*; '
                 'for f in /target/*.key /target/password /target/pgpass; do '
                 'test ! -f "$f" || chmod 0440 "$f"; done; '
                 'if test -f /target/pgpass; then chown 26:0 /target/pgpass; chmod 0400 /target/pgpass; fi')

    def select(self, leaf):
        self.stage(self.directory / leaf, self.volumes[1])

    def start(self):
        self.run('rm', '-f', self.server, check=False)
        self.run('run', '-d', '--name', self.server, '--network', self.network,
                 '--network-alias', 'postgres', '--network-alias', 'alias', *self.hardened(),
                 '--mount', f'type=volume,src={self.volumes[0]},dst=/var/lib/pgsql',
                 '--mount', f'type=volume,src={self.volumes[1]},dst=/run/tls,readonly',
                 '--env', 'POSTGRES_DB=lakekeeper',
                 '--env', 'POSTGRES_PASSWORD_FILE=/run/tls/password',
                 '--env', 'POSTGRESQL_TLS_CERT_FILE=/run/tls/server.crt',
                 '--env', 'POSTGRESQL_TLS_KEY_FILE=/run/tls/server.key', self.image)

    def ready(self):
        for _ in range(90):
            process = self.run('exec', self.server, 'cat', '/proc/1/comm', check=False)
            if process.stdout.strip() == 'postgres' and self.run('exec', self.server, 'pg_isready', '-h', '/tmp', check=False).returncode == 0:
                return
            time.sleep(1)
        raise RuntimeError('server readiness timeout')

    def query(self, connection=None, sql='SELECT 1', plaintext_probe=False):
        connection = validate_url(connection or url(), plaintext_probe)
        return self.run('exec', self.client, 'psql', '-XwqAt', connection,
                        '-v', 'ON_ERROR_STOP=1', '-c', sql, check=False)

    def control(self, connection=None):
        result = self.query(connection, "SELECT ssl || '|' || version FROM pg_stat_ssl WHERE pid=pg_backend_pid()")
        assert result.returncode == 0 and result.stdout.strip() in ('true|TLSv1.2', 'true|TLSv1.3'), 'verified SQL control failed: ' + result.stderr.replace(self.password, '[REDACTED]')
        return result.stdout.strip()

    def record(self, case, result, oracle, before, after, listener='postgres:5432'):
        assert result.returncode != 0 and re.search(oracle, result.stderr, re.I), f'{case}: missing expected rejection'
        assert 'password authentication failed' not in result.stderr.lower()
        # Only error lines, with no supplied credentials or PEM data, enter evidence.
        error = result.stderr.strip().replace(self.password, '[REDACTED]')
        assert 'PRIVATE KEY' not in error
        self.rows.append({'client': 'image psql/libpq', 'listener': listener, 'case': case,
                          'exit': result.returncode, 'error': error,
                          'control_before': before, 'control_after': after, 'result': 'rejected'})
        print(f'TLS PASS {case}: exit={result.returncode}, oracle={oracle}', flush=True)

    def client_negative(self, case, connection, oracle, plaintext_probe=False):
        before = self.control()
        result = self.query(connection, plaintext_probe=plaintext_probe)
        after = self.control()
        self.record(case, result, oracle, before, after)

    def plaintext_connection(self, address=None):
        # The sole intentional plaintext probe. Never used for a positive operation.
        options = {'sslmode': 'disable', 'sslrootcert': '/run/tls/trusted.crt', 'connect_timeout': '3'}
        if address:
            options['hostaddr'] = address
        connection = 'postgresql://postgres@postgres:5432/lakekeeper?' + urlencode(options)
        return connection

    def plaintext(self, address=None):
        self.client_negative('plaintext-' + (address or 'DNS'), self.plaintext_connection(address),
                             r'no pg_hba.conf entry.*no encryption', plaintext_probe=True)

    def server_negative(self, leaf, oracle):
        before = self.control()
        self.run('stop', self.server)
        self.select(leaf)
        self.start()
        self.ready()
        result = self.query()
        cleartext = self.query(self.plaintext_connection(), plaintext_probe=True)
        self.run('stop', self.server)
        self.select('valid')
        self.start()
        self.ready()
        after = self.control()
        self.record(leaf, result, oracle, before, after)
        self.record(leaf + '-plaintext', cleartext, r'no pg_hba.conf entry.*no encryption', before, after)

    def inspect(self):
        server = json.loads(self.run('inspect', self.server).stdout)[0]
        client = json.loads(self.run('inspect', self.client).stdout)[0]
        for obj, expected in ((server, self.volumes[1]), (client, self.volumes[2])):
            tls = [m for m in obj['Mounts'] if m['Destination'] == '/run/tls']
            assert len(tls) == 1 and tls[0]['Name'] == expected and not tls[0]['RW']
            assert obj['HostConfig']['ReadonlyRootfs']
            assert obj['Config']['User'] == '26:0'
            assert 'ALL' in [c.upper() for c in obj['HostConfig']['CapDrop']]
            assert any(x.startswith('no-new-privileges') for x in obj['HostConfig']['SecurityOpt'])
            assert not obj['HostConfig'].get('PortBindings')
            assert not any(e.startswith(('PGPASSWORD=', 'POSTGRES_PASSWORD=')) for e in obj['Config']['Env'])
        for container, paths in ((self.server, ['/run/tls/pgpass', '/authority/trusted.key', '/run/tls/catalog.key']),
                                 (self.client, ['/run/tls/server.key', '/run/tls/password', '/authority/trusted.key'])):
            for path in paths:
                assert self.run('exec', container, 'test', '-r', path, check=False).returncode != 0
        assert self.run('exec', self.server, 'stat', '-c', '%u:%g:%a', '/run/tls/server.key').stdout.strip() == '0:0:440'
        # A separate client namespace must not have access to the server's local socket.
        assert self.run('exec', self.client, 'test', '-S', '/tmp/.s.PGSQL.5432', check=False).returncode != 0
        settings = self.query(sql="SELECT name,setting FROM pg_settings WHERE name IN ('ssl','ssl_min_protocol_version','ssl_max_protocol_version','ssl_cert_file','ssl_key_file','port','unix_socket_directories') ORDER BY name")
        parsed = dict(line.split('|', 1) for line in settings.stdout.splitlines())
        assert parsed == {'ssl': 'on', 'ssl_min_protocol_version': 'TLSv1.2', 'ssl_max_protocol_version': 'TLSv1.3',
                          'ssl_cert_file': '/run/tls/server.crt', 'ssl_key_file': '/run/tls/server.key',
                          'port': '5432', 'unix_socket_directories': '/tmp'}
        hba = self.query(sql="SELECT type,address,auth_method FROM pg_hba_file_rules ORDER BY rule_number")
        assert hba.stdout.splitlines() == ['local||trust', 'hostssl|0.0.0.0|scram-sha-256', 'hostssl|::|scram-sha-256']
        sockets = {}
        for family in ('tcp', 'tcp6'):
            rows = self.run('exec', self.server, 'cat', '/proc/net/' + family).stdout.splitlines()[1:]
            listeners = [r.split()[1] for r in rows if r.split()[3] == '0A']
            # Docker's embedded DNS is the runtime's loopback resolver, not an image listener.
            app = [r for r in listeners if r.split(':')[0] != '0B00007F']
            assert app == [('00000000' if family == 'tcp' else '0' * 32) + ':1538'], app
            sockets[family] = app
        self.report.update(settings=parsed, sockets=sockets, mounts_and_secret_isolation='passed',
                           unix_socket='container-local /tmp only; cross-service policy remains owner decision')
        network = server['NetworkSettings']['Networks'][self.network]
        for address in (network['IPAddress'], network['GlobalIPv6Address']):
            assert address
            self.control(url(hostaddr=address))
            self.plaintext(address)

    def execute(self):
        self.report['certificates'] = generate(self.directory)
        for name in self.report['certificates']:
            (self.directory / name / 'password').write_text(self.password)
        (self.directory / 'client' / 'pgpass').write_text(f'*:5432:lakekeeper:postgres:{self.password}\n')
        self.run('network', 'create', '--ipv6', self.network)
        for volume in self.volumes:
            self.run('volume', 'create', volume)
        self.select('valid')
        self.stage(self.directory / 'client', self.volumes[2])
        self.run('run', '-d', '--name', self.client, '--network', self.network, *self.hardened(),
                 '--mount', f'type=volume,src={self.volumes[2]},dst=/run/tls,readonly',
                 '--env', 'PGPASSFILE=/run/tls/pgpass', '--entrypoint', 'sleep', self.image, 'infinity')
        self.start()
        self.ready()
        self.control()
        self.report['architecture'] = json.loads(self.run('image', 'inspect', self.image).stdout)[0]['Architecture']
        self.report['image_id'] = json.loads(self.run('image', 'inspect', self.image).stdout)[0]['Id']
        self.report['client_version'] = self.run('exec', self.client, 'psql', '--version').stdout.strip()
        self.inspect()
        for version in ('TLSv1.2', 'TLSv1.3'):
            assert self.control(url(ssl_min_protocol_version=version, ssl_max_protocol_version=version)) == 'true|' + version
        self.plaintext()
        for case, connection, oracle in (
            ('wrong-client-ca', url(ca='unrelated'), r'certificate verify failed'),
            ('alias-not-in-san', url(host='alias'), r'does not match host name'),
            ('missing-ca', url(ca='missing'), r'root certificate file.*does not exist'),
            ('malformed-ca', url(ca='malformed'), r'could not read root certificate file')):
            self.client_negative(case, connection, oracle)
        for leaf, oracle in (('wrong-root', r'certificate verify failed'),
                             ('wrong-san', r'does not match host name'),
                             ('other-service', r'does not match host name'),
                             ('expired', r'certificate verify failed'),
                             ('future', r'certificate verify failed')):
            self.server_negative(leaf, oracle)
        self.rotate()
        self.fail_closed()
        self.inspect()
        self.report['complete'] = True

    def fingerprint(self):
        # Strict verification even for inspection: never a verification-off diagnostic.
        result = self.run('exec', self.client, 'sh', '-c',
                          'openssl s_client -starttls postgres -connect postgres:5432 '
                          '-CAfile /run/tls/trusted.crt -verify_hostname postgres '
                          '-verify_return_error </dev/null', check=False)
        assert result.returncode == 0
        cert = subprocess.run(['openssl', 'x509', '-noout', '-fingerprint', '-sha256'],
                              input=result.stdout, text=True, capture_output=True, check=True)
        return cert.stdout.strip()

    def rotate(self):
        for leaf in ('rotated', 'valid'):
            before = self.control()
            self.select(leaf)
            self.run('kill', '--signal', 'HUP', self.server)
            expected = self.report['certificates'][leaf].splitlines()[0]
            for _ in range(30):
                if self.fingerprint().lower() == expected.lower():
                    break
                time.sleep(0.2)
            else:
                raise AssertionError('reload did not present the new certificate')
            after = self.control()
            self.rows.append({'client': 'image psql/libpq and verified OpenSSL',
                              'listener': 'postgres:5432', 'case': 'reload-' + leaf,
                              'control_before': before, 'control_after': after, 'result': 'passed'})

    def fail_closed(self):
        for filename, mutation, oracle in (
            ('server.crt', 'missing', 'POSTGRESQL_TLS_CERT_FILE must be a regular file'),
            ('server.key', 'missing', 'POSTGRESQL_TLS_KEY_FILE must be a regular file'),
            ('server.crt', 'malformed', 'could not load server certificate file'),
            ('server.key', 'malformed', 'could not load private key file')):
            before = self.control()
            source = self.directory / 'broken'
            shutil.copytree(self.directory / 'valid', source)
            target = source / filename
            if mutation == 'missing':
                target.unlink()
            else:
                target.write_text('malformed TLS material\n')
            self.run('stop', self.server)
            self.stage(source, self.volumes[1])
            self.start()
            for _ in range(30):
                state = json.loads(self.run('inspect', self.server).stdout)[0]['State']
                if not state['Running']:
                    break
                time.sleep(1)
            assert not state['Running'] and state['ExitCode'] != 0
            logs = self.run('logs', self.server).stdout + self.run('logs', self.server).stderr
            assert oracle in logs and self.password not in logs and 'PRIVATE KEY' not in logs
            # No usable old/default TCP listener after the failed restart.
            assert self.query(self.plaintext_connection(), plaintext_probe=True).returncode != 0
            self.select('valid')
            self.start()
            self.ready()
            after = self.control()
            self.plaintext()
            self.rows.append({'client': 'image startup and psql/libpq', 'listener': 'postgres:5432',
                              'case': mutation + '-' + filename, 'result': 'refused startup',
                              'error': oracle, 'exit': state['ExitCode'],
                              'control_before': before, 'control_after': after})
            shutil.rmtree(source)

    def cleanup(self):
        for name in (self.server, self.client):
            self.run('rm', '-fv', name, check=False)
        for volume in self.volumes:
            self.run('volume', 'rm', '-f', volume, check=False)
        self.run('network', 'rm', self.network, check=False)


def main():
    os.umask(0o077)
    runtime = ROOT / '.runtime'
    runtime.mkdir(exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix='tls-', dir=runtime))
    profile = Profile(directory)
    try:
        profile.execute()
    finally:
        output = Path(os.environ.get('TLS_REPORT', runtime / 'tls-coverage.json'))
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(profile.report, indent=2) + '\n')
        try:
            profile.cleanup()
        finally:
            shutil.rmtree(directory)


if __name__ == '__main__':
    main()
