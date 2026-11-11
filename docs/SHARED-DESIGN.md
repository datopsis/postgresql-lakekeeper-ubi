# Shared design with postgresql-ubi

Initial source baseline:
[datopsis/postgresql-ubi at 9b3190d4d3bccbd54d2f4965252762083f3ebeb7](https://github.com/datopsis/postgresql-ubi/tree/9b3190d4d3bccbd54d2f4965252762083f3ebeb7).
Its Containerfile, entrypoint, artifact lock tooling, runtime tests, CI patterns
and operational guidance were read before adaptation. Copied code is now owned
by this Apache-2.0 repository. There is **no runtime or build dependency on a
postgresql-ubi image**, and no published sibling image is assumed.

The repositories share a design and **must be kept in step**: authentication,
TLS, secret validation, volume layout, lifecycle, hardening, lock verification,
base/package maintenance and runtime fixes must be assessed in both repositories
when either changes. Record the source commit and intentional differences in
changes. Do not change the general-purpose sibling's extension support contract.

Intentional differences here: Lakekeeper-only support; the contrib RPM and its
single-package dependency exception; five allowlisted add-ons; removal of every
other contrib payload; exclusion of dependencies used only by removed modules;
explicit opt-in SQL; complete Trivy and Grype JSON with a common blocking
gate; read-only lock candidates; and no release, signing or publishing workflow.

Core PL/pgSQL and initdb/template semantics remain unchanged. The shared entrypoint
is adapted only in diagnostic/lock-file naming. No startup hook implicitly
creates extensions or migrates Lakekeeper. Keep Lakekeeper's declared database
requirements in view when upgrading either project.

Phase A item 1 retains that baseline entrypoint and server behavior unchanged.
This repository adds Lakekeeper-shaped URL qualification, per-service mount
examples and native TLS evidence. No shared-profile defect or PostgreSQL feature
change is presumed; a defect must be reported before expanding this scope.
The sibling needs no separate PR for this qualification-only work.
