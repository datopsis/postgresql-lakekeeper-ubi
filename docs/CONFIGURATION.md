# Configuration and TLS

| Variable | Meaning |
| --- | --- |
| POSTGRES_USER | Initial superuser, default postgres; reject line breaks |
| POSTGRES_DB | Initial database, defaults to POSTGRES_USER |
| POSTGRES_PASSWORD / POSTGRES_PASSWORD_FILE | Exactly one operator-supplied bootstrap credential; required for empty data only |
| PGDATA | Default /var/lib/pgsql/data, inside the explicit writable volume |
| POSTGRESQL_CONFIG_FILE | Optional protected regular configuration file |
| POSTGRESQL_TLS_CERT_FILE / POSTGRESQL_TLS_KEY_FILE | Both required together; protected regular PEM files mounted read-only |

The entrypoint accepts only a nonempty single-line password. Secret files must
have no trailing newline, cannot be symlinks, must be owned by root or the runtime
UID, and use 0400/0600 or 0440/0640 (group-readable requires GID 0). Credentials
are unset before exec. Environment bootstrap values can remain in runtime
inspection metadata. Restarting existing data does not change role passwords.
Public certificate/config files must not be group/other writable or have special
mode bits. Config overrides cannot disable the command-line security settings.

Without TLS, TCP is SCRAM-authenticated but unencrypted; confine it to an enforced
isolated network. To enable TLS, mount a PKI-issued certificate chain with the
server DNS name in SAN and its private key read-only, and set both TLS variables:

```sh
--volume "$PWD/server-chain.crt:/run/tls/server.crt:ro,Z" \
--volume "$PWD/server.key:/run/tls/server.key:ro,Z" \
--env POSTGRESQL_TLS_CERT_FILE=/run/tls/server.crt \
--env POSTGRESQL_TLS_KEY_FILE=/run/tls/server.key
```

Add these options to the hardened run command in README. Set the key ownership
and modes to the secret rules above and the certificate to 0444. Clients must
use `sslmode=verify-full`, a trusted CA and the certificate's DNS name. The server
enforces TLS 1.2 through 1.3 and hostssl SCRAM rules; plaintext TCP is rejected.
Rotate mounted files and reload PostgreSQL with pg_reload_conf(), validating
clients before retiring the old certificate. Client-certificate mapping is not
part of this profile.

Local sockets in /tmp use trust, as in the sibling; control exec access and do
not share that tmpfs. Logging goes to stderr with statement, duration and bind
parameter logging disabled. Core dumps are disabled. `pg_isready` is only a
readiness probe; authenticated application SQL remains a separate health check.

## Lakehouse Phase A contract (plan item 1)

Use the existing mounted profile for `postgres:5432`, SAN `DNS:postgres`.
Mount only `tls/postgres/server.crt` and `tls/postgres/server.key` into PostgreSQL
at the paths above, read-only. The key is root-owned `0440`, GID 0 (or one of
the stricter accepted secret modes); the public certificate is `0444`.
Never mount the parent TLS directory or a CA signing key. Sharing GID 0 is not
isolation: each service must receive only its own private files. No certificates
or keys are built into the image or committed. Compose requires the host paths
`POSTGRES_TLS_CERT_FILE` and `POSTGRES_TLS_KEY_FILE`; it does not issue material.

Give each Lakekeeper **serving and migration** container only the public CA at
`/run/tls/ca.crt`, read-only, alongside its existing application secrets. The
URL shape (credentials supplied separately here) is:

```text
postgresql://lakekeeper@postgres:5432/lakekeeper?sslmode=verify-full&sslrootcert=/run/tls/ca.crt
```

Set the options on the actual Lakekeeper database URL, including a read URL if
configured. Lakekeeper's URL branch takes precedence over separate SSL-mode
settings. Password/SCRAM auth remains required; client-certificate mapping and
PostgreSQL mTLS are **outside this profile**. The fixture uses the bootstrap role
only for image qualification; applications need a separately provisioned role.

`tests/tls.sh` uses the real image's `psql`/libpq in a separate container with
this URL shape. It is not evidence for Lakekeeper's SQLx migration/serving pools;
those belong to plan item 4 and the integration gate. See [CI](CI.md) for the
per-architecture evidence contract. No PostgreSQL binary, entrypoint default,
extension allowance or sibling repository is changed by this qualification.

For Phase A, the owner explicitly allows plaintext on the inherited
container-local `/tmp` Unix socket. Keep its tmpfs private and control exec access;
tests prove the client container cannot access the server socket. This exception
applies only to local Unix sockets: every Phase A network connection must use
`sslmode=verify-full` with the trusted CA and matching server DNS identity.
This repository's qualification does not claim all of Phase A complete.
The optional legacy non-TLS image profile remains unchanged; the example and
Compose configuration select TLS explicitly. Omitting both variables deliberately
selects that legacy profile, so deployment must require both mounts/settings.
