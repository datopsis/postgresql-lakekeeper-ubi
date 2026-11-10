# Changelog

## Unreleased

- Add standalone, rootless PGDG PostgreSQL 18.6 on digest-pinned UBI 9.8 Micro
  for Lakekeeper metadata, using the postgresql-ubi design.
- Lock signed contrib RPMs and retain only five add-ons plus core PL/pgSQL.
- Provide explicit database-scoped extension initialization, with no automatic hooks.
- Preserve SCRAM, TLS, strict secrets, durable storage and hardened runtime tests.
- Add native AMD64/ARM64 builds, complete scanner evidence and blocking fixed
  High/Critical gates without exemptions.
- Add read-only artifact lock updates and hash-pinned CI tools, including
  filelock 4.2.9 and virtualenv 21.15.6. No release or publication automation.
