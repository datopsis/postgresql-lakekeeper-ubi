# Version identity

Current PostgreSQL: **18.7**, PGDG RPM releases **18.7-1PGDG.rhel9.9** (AMD64)
and **18.7-2PGDG.rhel9.9** (ARM64).
Base line: **Red Hat UBI 9.9**, Minimal builder and Micro runtime, pinned to
multi-architecture manifest digests in artifacts/lock-inputs.json and both locks.

No container release version or Git tag has been created. Development images
have version `development`; exact source commit, lock hashes and local image
IDs identify evidence. No workflow publishes or signs anything.

An image-affecting change requires new native AMD64 and ARM64 build/runtime/
scanner evidence. PostgreSQL minor updates must preserve data in tests and
exercise logical restoration. Major upgrades are outside this support scope;
never modify PG_VERSION to bypass the entrypoint's check. Tooling and docs
commits use Conventional Commits and do not create releases.

PGDG metadata selects the standard `postgresql18` package family. The visible
`babelfish_postgresql18` 18.7 `-10PGDG` build is a separate Babelfish package,
not a newer release of `postgresql18`. All four seeds follow the native
standard-package metadata selection; the ARM64 rebuild is release 2.
