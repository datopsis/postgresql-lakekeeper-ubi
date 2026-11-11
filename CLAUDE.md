# Repository guidance

This repository packages PostgreSQL 18 on UBI 9 for Lakekeeper metadata only.
Read README.md, docs/SUPPORT.md and docs/SHARED-DESIGN.md before changing it.

Preserve digest-pinned native AMD64/ARM64 bases, complete per-architecture RPM
locks, hashes, full key fingerprints, signatures and offline assembly. Retain
exactly five add-ons: uuid-ossp, pgcrypto, pg_trgm, btree_gin and btree_gist.
Core plpgsql is required by initdb. Remove every other contrib payload and fail
builds when the installed allowlist differs. Never auto-create add-ons.

Preserve non-root execution without privilege transition; no package manager;
SCRAM network authentication; operator-provided credentials only; strict secret
file handling; TLS behavior; durable volume checks; read-only-root operation;
zero capabilities; no-new-privileges; secret-free logs; and graceful shutdown.
Keep the shared implementation in step with datopsis/postgresql-ubi without
introducing a runtime dependency or extending that repository's support scope.

Run lint/unit tests and native image tests, including extension creation and
rejection, auth, TLS, persistence, shutdown and initialization failure. Read
both scanners' reports on both architectures. Fixed High/Critical findings
block; no exemptions, report-only replacement or weakened checks. Report limits
honestly. Never commit databases, secrets, private keys or generated scan output.

CI requirements must be completely hash-pinned with .in inputs. update-locks.yml
has contents: read, SHA-pinned actions and artifact-only candidates; it must
never commit, push or open PRs. No publication, signing, tags or release workflow
is in scope. Do not modify repository/org settings, secrets or permissions.

Use feature branches, pull requests and Conventional Commit subjects. Do not
force-push or merge. Never add AI, assistant, tool-attribution or Co-Authored-By
trailers. Do not assert human sign-off, production support, FIPS or STIG claims.
