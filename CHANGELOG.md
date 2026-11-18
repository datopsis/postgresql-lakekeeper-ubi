# Changelog

## Unreleased

- Update PostgreSQL to **18.7** with native PGDG RHEL 9.9 locks (amd64
  `18.7-1PGDG.rhel9.9`, arm64 `18.7-2PGDG.rhel9.9`) and refreshed UBI closure.
- PostgreSQL [18.7 release notes](https://www.postgresql.org/docs/release/18.7/)
  list the following security fixes:
  CVE-2026-6460, CVE-2026-116306, CVE-2026-116329,
  CVE-2026-16237, CVE-2026-120146, CVE-2026-116310,
  CVE-2026-116332, CVE-2026-120143, CVE-2026-116304,
  CVE-2026-120152, CVE-2026-120150, CVE-2026-116328,
  CVE-2026-116315, CVE-2026-116317, CVE-2026-116321,
  CVE-2026-116327, CVE-2026-116331, CVE-2026-116322,
  CVE-2026-116312, CVE-2026-116335, CVE-2026-116336,
  CVE-2026-6467, CVE-2026-120153, CVE-2026-116303,
  CVE-2026-116311, CVE-2026-116316, CVE-2026-120149,
  CVE-2026-116333, CVE-2026-120144, CVE-2026-120148,
  CVE-2026-120145, CVE-2026-120154, CVE-2026-14661,
  CVE-2026-120142, CVE-2026-18447, CVE-2026-120139,
  CVE-2026-120141, CVE-2026-120151, CVE-2026-116326,
  CVE-2026-116309, CVE-2026-116320, CVE-2026-116319,
  CVE-2026-116307, CVE-2026-116323, CVE-2026-120147,
  CVE-2026-116308, CVE-2026-116325, CVE-2026-116313,
  CVE-2026-116318, CVE-2026-116330, CVE-2026-116314,
  CVE-2026-16240, CVE-2026-6464.

- Fix fresh initialization to create `POSTGRES_DB` (default `POSTGRES_USER`)
  even when it equals the bootstrap user; reuse `postgres` and reject template
  database names. Add native database/ownership/connection and restart coverage.

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
