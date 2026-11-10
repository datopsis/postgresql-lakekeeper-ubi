# Version identity

Current PostgreSQL: **18.6**, PGDG RPM release **18.6-1PGDG.rhel9.8**.
Base line: **Red Hat UBI 9.8**, Minimal builder and Micro runtime, pinned to
multi-architecture manifest digests in artifacts/lock-inputs.json and both locks.

No container release version or Git tag has been created. Development images
have version `development`; exact source commit, lock hashes and local image
IDs identify evidence. No workflow publishes or signs anything.

An image-affecting change requires new native AMD64 and ARM64 build/runtime/
scanner evidence. PostgreSQL minor updates must preserve data in tests and
exercise logical restoration. Major upgrades are outside this support scope;
never modify PG_VERSION to bypass the entrypoint's check. Tooling and docs
commits use Conventional Commits and do not create releases.
