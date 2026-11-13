# Changelog

## Unreleased

- Refresh both native RPM locks and UBI 9.9 Minimal/Micro base pins now that the
  util-linux family and other vendor security fixes are available in UBI.

- Apply the owner-approved UBI availability rule to fixed High/Critical RPM
  findings: defer only when a fresh native query proves no qualifying fix is
  available; keep available fixes, non-RPM fixes and query uncertainty blocking.
- Report deferred vendor versions and repository evidence in native CI; recheck
  daily and maintain one tracking issue with comments on availability changes.

- Exclude Python 3.9 libraries, pip/setuptools wheels, SQLite and libxslt from
  locks and runtime installation; restrict --nodeps to the pruned contrib RPM.
- Fail builds on forbidden RPM records, unsatisfied dependencies in any other
  package, or missing final-root server/extension libraries. Exercise functions
  and integer GIN/GiST indexes from all five retained add-ons in native tests.

- Add standalone, rootless PGDG PostgreSQL 18.6 on digest-pinned UBI 9.8 Micro
  for Lakekeeper metadata, using the postgresql-ubi design.
- Lock signed contrib RPMs and retain only five add-ons plus core PL/pgSQL.
- Provide explicit database-scoped extension initialization, with no automatic hooks.
- Preserve SCRAM, TLS, strict secrets, durable storage and hardened runtime tests.
- Add native AMD64/ARM64 builds, complete scanner evidence and blocking fixed
  High/Critical gates without exemptions.
- Add read-only artifact lock updates and hash-pinned CI tools, including
  filelock 4.2.9 and virtualenv 21.15.6. No release or publication automation.
