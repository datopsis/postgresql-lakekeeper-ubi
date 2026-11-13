# UBI availability gate evaluation

The owner approved repository availability as the definition of a fixable RPM.
This evaluation records live evidence, separate from synthetic policy tests.
No image is deployed by this change.

## Assumptions and implementation evidence

- The RPM must be available to the native UBI resolver, not merely listed in a
  RHEL advisory. The gate copies repo files from the exact locked builder before
  installing query tools, uses releasever=9, and requires all three expected UBI
  binary repositories. The image itself still assembles offline.
- DNF must not silently skip a repository or accept an expired metadata snapshot.
  Each query uses --refresh, metadata_expire=0, skip_if_unavailable=False, a fresh
  per-process cache and bounded timeouts. Query failures block. See the
  [DNF configuration reference](https://dnf.readthedocs.io/en/latest/conf_ref.html).
- Comparison must use RPM ordering, not semantic-version or lexical ordering.
  The system RPM Python binding performs labelCompare on epoch/version/release
  tuples. See [the RPM binding](https://github.com/rpm-software-management/rpm/blob/master/python/rpmmodule.c).
  Tests cover implicit epoch zero, an overriding epoch, numeric releases, tilde,
  caret, and a maintenance release following an initial vendor fix.
- Raw scanner findings remain untouched. Only the gate decision changes. A
  matching RPM PURL, package name and architecture are required before querying;
  ambiguous identities and every fixed non-RPM High/Critical finding block.
- The sibling repository was assessed separately as recorded in SHARED-DESIGN.md.
  Its existing scanner actions block vendor-fixed findings directly. This policy
  change is scoped to this repository.

## First live measurement

[CI run 43366069459](https://github.com/datopsis/postgresql-lakekeeper-ubi/actions/runs/43366069459)
tested gate commit e49b051149caa86fd63a13823301bfd37ce4c410 with the original RPM
locks. Both native image builds and all runtime checks passed. Both vulnerability
gates failed, correctly: UBI had published the previously unavailable fixes.

| Architecture | Scanner | High | Critical | Vendor-fixed High | Blocked | Deferred |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| amd64 | Trivy | 35 | 0 | 19 | 19 | 0 |
| arm64 | Trivy | 35 | 0 | 19 | 19 | 0 |
| amd64 | Grype | 34 | 0 | 14 | 14 | 0 |
| arm64 | Grype | 34 | 0 | 14 | 14 | 0 |

These are 66 live finding decisions across both scanners and native runners,
covering nine distinct RPM names per architecture. All queries succeeded. The
retained JSON includes vendor versions, candidate RPMs, native architecture,
builder reference, and repository-file hashes. Both copies of ubi.repo hashed
to f59e1e4c2f20048ef3204f5c81d23b04aac53a7d789b1f4d055a937867109f13.

The util-linux family candidates were 0:2.37.4-28.el9_9.1, satisfying both the
initial and subsequent vendor-fixed releases. Trivy also found available expat
2.5.0-9.el9_9.4 and libxml2 2.9.13-18.el9_9.1 fixes. Therefore the current util-linux
findings cannot honestly be demonstrated as deferred. The lock refresh closes
out the earlier stalled attempt using native resolver artifacts instead.

## Native lock refresh

[Resolver run 43366679846](https://github.com/datopsis/postgresql-lakekeeper-ubi/actions/runs/43366679846)
produced both architecture locks and common base pins using the existing updater.
The amd64 lock updates 41 of 163 packages; arm64 updates 42 of 164. No package is
added or removed, no signing identity changes, and all PostgreSQL seed records
are byte-equivalent. The existing arm64-only libatomic package accounts for the
inventory difference; every shared package has the same new epoch/version/release.

UBI Minimal moves from index f26ef64172ea61f5ac5ba4be8c5c738bf8760b22b3e5148ce7b40f7308ab32db
to baafce2d34783a28b4a472779f304e97e00f9d35c99553bc53b068b14344d9a9.
UBI Micro moves from d3499a0896e2d6a1642f922615831bc5c2fd513bbb34f3446cabba530d9d54a2
to dbd325b96bcd432dd42816d31412bdf1dc0fb973b79ed310344bc23c76c068db.
Both indexes have verified Linux amd64 and arm64 manifests. The latest full UBI
index was also inspected: 1e9f0ed9fceafb40878bc1705ff124aa150e3fed873f18c42cdc2dded319e0a8;
this image does not use that base.

## Negative and transition coverage

Unit tests require available fixes to block and successful negative queries to
report. They also require timeouts, command failures, missing/disabled/foreign
repositories, malformed RPM versions, wrong architectures and non-RPM findings
to block. Tracker tests cover create/update, comments only on state changes,
missing native evidence, and refusal to update ambiguous duplicate issues.

Native CI additionally probes ten locked UBI packages on each architecture in
both scanner formats. A currently available candidate must block; a deliberately
synthetic epoch above every available candidate must defer. These 20 cases per
architecture use live DNF metadata and native librpm. They are explicitly marked
synthetic in ubi-gate-probes-<architecture>.json and never modify the real Trivy
or Grype reports. The final PR run supplies their execution evidence.

The daily issue-writing job cannot execute from a PR: it is restricted to main
on schedule/workflow_dispatch. Its future scheduling and GITHUB_TOKEN permission
behavior must be checked after merge; this PR neither merges nor changes settings.
The issue updater can be exercised separately with actual native CI artifacts.
