# PostgreSQL for Lakekeeper on UBI 9

A security-oriented PostgreSQL **18.6** container on Red Hat UBI **9.8 Micro**,
for **Lakekeeper's Iceberg catalog metadata only**. Native Linux AMD64 and ARM64.
No image has been published; this is a development increment, not a supported
production release. General-purpose PostgreSQL belongs in
[datopsis/postgresql-ubi](https://github.com/datopsis/postgresql-ubi).

The five add-on extensions are `uuid-ossp`, `pgcrypto`, `pg_trgm`, `btree_gin`,
and `btree_gist`. All other PGDG contrib payload is removed at build time.
Core `plpgsql`, which `initdb` installs in the template databases, remains.
The five add-ons are **not created automatically**. See [extensions](docs/EXTENSIONS.md)
for the explicit opt-in and complete removal inventory.

## Build and run

Requires Python 3, GnuPG and rootless Podman. The build acquires exact locked
RPMs, verifies hashes, NEVRAs, signatures and full signing-key fingerprints,
then assembles without network access or package resolution. No sibling image
is needed. Run from this checkout on the image's native architecture:

```sh
CONTAINER_RUNTIME=podman IMAGE=localhost/postgresql-lakekeeper-ubi:development \
  bash scripts/build-offline.sh
```

Provision an operator-supplied password as a regular file without a trailing
newline. Inside the container it must be owned by UID 0 or the runtime UID,
mode 0400/0600, or mode 0440/0640 with GID 0. Account for rootless UID mappings.
No passwords are generated, defaulted or logged by the image. Alternatively,
set `POSTGRES_PASSWORD` in the operator's environment and pass it by name;
container inspect APIs can retain environment secrets, so prefer a mounted file.

Example for an isolated local development network, using a pre-provisioned
`secrets/postgres-password` file with those permissions:

```sh
podman volume create lakekeeper-postgres-data
podman run --detach --name lakekeeper-postgres \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m,mode=1777 \
  --mount type=volume,src=lakekeeper-postgres-data,dst=/var/lib/pgsql \
  --volume "$PWD/secrets/postgres-password:/run/secrets/postgres-password:ro,Z" \
  --env POSTGRES_PASSWORD_FILE=/run/secrets/postgres-password \
  --env POSTGRES_DB=lakekeeper \
  --publish 127.0.0.1:5432:5432 \
  --cap-drop ALL --security-opt no-new-privileges \
  localhost/postgresql-lakekeeper-ubi:development
```

Network authentication is SCRAM-SHA-256. The example has no transport encryption;
use the [TLS profile](docs/CONFIGURATION.md) outside a separately enforced isolated
network. PostgreSQL runs as `26:0`, with no privilege transition, package manager,
or writable root requirement. Arbitrary nonzero UIDs in GID 0 use `nss_wrapper`.
The image cannot force runtime flags: the operator must retain the hardening above.

## Enable extensions explicitly

After initializing the `lakekeeper` database, run the packaged idempotent SQL
as an authorized database administrator. This example uses the container-local
socket, which is trusted within the container boundary:

```sh
podman exec lakekeeper-postgres psql -X --host=/tmp \
  --username=postgres --dbname=lakekeeper \
  --file=/usr/share/lakekeeper/init.sql
```

For a remote administrator, run `init/lakekeeper-extensions.sql` with `psql -X`,
`ON_ERROR_STOP` (also set in the file), a protected password file and
`sslmode=verify-full`. Select the Lakekeeper database explicitly. Provision a
separate application role and privileges; do not give Lakekeeper the bootstrap
superuser. Run Lakekeeper's migrations separately using its documented process.
This image never runs migrations or startup SQL hooks.

## Verification and operations

[CI](docs/CI.md) runs lint, negative tests, native builds, hardened runtime/TLS/
storage tests, SBOM generation and blocking Trivy/Grype gates for fixed
High/Critical findings, with no exemptions. It retains complete JSON reports
for both architectures. Nothing publishes an image, tag, signature or release.

- [Configuration and TLS](docs/CONFIGURATION.md)
- [Storage, shutdown and recovery](docs/STORAGE.md)
- [Locked inputs and updates](docs/ARTIFACT-ACQUISITION.md)
- [Shared design and maintenance](docs/SHARED-DESIGN.md)
- [Support boundary](docs/SUPPORT.md), [roadmap](docs/ROADMAP.md), [version](docs/VERSION.md)
- [Security policy](SECURITY.md), [third-party terms](THIRD_PARTY_NOTICES.md)
