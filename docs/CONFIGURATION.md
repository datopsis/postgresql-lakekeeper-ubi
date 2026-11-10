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
