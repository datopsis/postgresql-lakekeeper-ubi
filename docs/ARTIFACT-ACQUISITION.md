# Locked artifacts and updates

Sources match the sibling: PGDG PostgreSQL 18 RPMs/SRPMs and signing keys, plus
Red Hat UBI runtime dependencies and source RPMs. Each architecture lock records
NEVRA, size, SHA-256, publisher fingerprint, source mapping and base index digests.
Input URLs are restricted to approved HTTPS supplier hosts. Keys are pinned by
hash and full fingerprint. All four PGDG seeds must use the selected version:
postgresql18, postgresql18-libs, postgresql18-server and postgresql18-contrib.

`build-offline.sh` acquires the native architecture bundle into a fresh
.artifact-bundle directory and verifies hashes, exact inventory, metadata and
key fingerprints. The builder verifies RPM signatures in an isolated RPM DB,
then installs the complete locked closure without repository resolution. The
final build disables network access and further pulls. No acquisition keys,
repository configuration, cache or package manager survives in the final image.
Source records and third-party terms remain reviewable in Git.

`refresh-bases.py` resolves the live UBI 9.9 Minimal/Micro tags once, verifies
manifest bytes against their digest and requires one Linux amd64 and one Linux
arm64 manifest in each index. Both native resolver jobs consume those same pins.
New bases were checked on 2026-11-13; full digests are in lock-inputs.json.

The scheduled/manual/lock-PR `update-locks.yml` has **contents: read** only and
SHA-pinned actions. It uploads candidate Containerfile, inputs, architecture
locks and RPM/source inventories. It never commits, pushes, opens PRs, changes
settings or publishes. No token or repository permission change is needed.
Review/download candidate artifacts and apply them on a development branch.
Compare both architectures, source/license changes, base indices and signing
identities, then rerun native CI. PostgreSQL seeds and signing keys only change
through explicit input edits; the updater does not silently adopt new keys.

The resolver computes the normal server/client dependency closure and adds the
verified contrib seed without resolving dependencies of its discarded modules.
Only postgresql18-contrib is installed separately with --nodeps. The five excluded
packages (python3-libs, python3-pip-wheel, python3-setuptools-wheel, sqlite-libs,
libxslt) and their otherwise-unreferenced source records are absent from each
lock. No other lock entries, versions, hashes or signatures change for this
reduction. Native resolver candidates must reproduce the selected closure.
The lock validator rejects those five packages, and the final build checks RPM
absence, every other package's dependencies and actual server/extension linkage.
See [the bounded exception](EXTENSIONS.md#narrow-contrib-dependency-exception).
Never falsify supplier RPM metadata or suppress scanner findings.

Changed supplier bytes, missing sources, wrong architecture, unapproved signers,
invalid hashes and signature failures block acquisition/build. Never substitute
an unsigned package or weaken verification when a locked artifact disappears.
