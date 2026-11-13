# Continuous integration

All workflows use contents: read and SHA-pinned actions. Only the trusted-main
tracking job additionally has issues: write to maintain the availability issue. No workflow publishes
images, releases, signatures or Git tags. No workflow writes branches or PRs.

CI jobs:

- `lint`: complete hash-pinned pre-commit tools, shellcheck, hadolint, actionlint,
  repository checks, lock and extension-pruning negative tests, scanner gate
  negative tests, committed lock validation and zizmor.
- `configuration security`: blocking High/Critical Trivy configuration scan.
- `image (amd64)` and `image (arm64)`: native ubuntu-24.04 and ubuntu-24.04-arm,
  with uname and built-image architecture checks; no QEMU. Offline locked build,
  acquisition-material checks, hardened smoke/extension tests, auth/configuration,
  storage/recovery/backup, resource limits, preserved-data minor update and TLS.
- `image`: aggregate requires both native jobs to succeed.

Each native job emits an SPDX SBOM with Syft and full Trivy/Grype JSON, including
unfixed and lower-severity findings. `vulnerability-gate.py` is the mandatory
blocking gate: fixed High/Critical findings block unless a successful native
UBI query proves an RPM fix unavailable, under [the security rule](../SECURITY.md).
Non-RPM fixes and query uncertainty always block. There are no exemption lists. Report generation is followed by enforcement; exit-zero
collection is not the acceptance decision. Missing or malformed reports fail.
The complete evidence is uploaded even if the gate fails and retained 14 days.
Review both JSON reports, summaries, logs and every job/step; green alone is
insufficient evidence. Retain exact commit/run IDs when downloading artifacts.

Daily CI rechecks availability at 07:23 UTC. Scheduled/manual runs of main update
one tracking issue and comment only on state changes. Missing native evidence
is reported as unknown and blocking, never as resolved. PRs cannot write issues.

Lock updates run separate native resolver jobs and retain candidate artifacts
for seven days. They cannot modify GitHub contents, settings or permissions.

## Local checks

```sh
# Install the system python3-rpm package for native RPM comparison tests.
python3 -m venv .venv
.venv/bin/pip install --require-hashes --only-binary=:all: \
  --requirement .github/requirements/pre-commit.txt
.venv/bin/pre-commit run --all-files --show-diff-on-failure
.venv/bin/python -m unittest discover -s tests -p 'test_*.py' -v
CONTAINER_RUNTIME=podman IMAGE=localhost/postgresql-lakekeeper-ubi:development \
  bash scripts/build-offline.sh
```

Run each tests/*.sh against that image with CONTAINER_RUNTIME and IMAGE set.
If container namespaces are unavailable locally, report the restriction and
use the native CI evidence; do not skip tests in CI. The requirements .in lists
all pinned transitive tool inputs; .txt carries wheel hashes, including filelock
4.2.9 and current virtualenv 21.15.6. Regenerate with the command in the input.

## Phase A PostgreSQL TLS evidence

Both native image jobs run `tests/tls.sh` without exemptions. Each invocation
issues an RSA-3072/SHA-256 root (24 hours), serverAuth leaves (6 hours, five-minute
clock skew), an unrelated root, wrong-SAN/correct-CN and other-service leaves,
and backdated expired/future leaves. PKI lives only under ignored `.runtime/`;
CA keys are removed before containers start, and all fixture material is deleted
on exit. The real image receives only read-only per-role material. No dependency
or pre-generated certificate is added.

The harness checks fresh libpq verify-full URL connections before and after
negatives: plaintext over DNS/IPv4/IPv6, wrong client CA, wrong server issuer,
wrong SAN despite correct CN, another service certificate, an uncertified DNS
alias, expiry, future validity, and missing/malformed client CA. Server
missing/malformed certificates and keys must fail startup without a usable
plaintext listener. It also checks both TLS 1.2 and 1.3, valid certificate reload
and restoration, runtime `pg_settings`/`pg_hba_file_rules`, actual listening
sockets, mount permissions, secret isolation and hardened container settings.
A source deny scan and URL parser reject verification downgrades; only the
explicit plaintext-negative builder is excluded. Legacy non-TLS authentication
and lifecycle tests remain independent of this TLS profile qualification.

`tls-coverage-<architecture>.json` is uploaded with the existing security
artifacts: image ID, architecture, client version, public certificate metadata,
listener inventory, exact sanitized libpq errors/exit codes, positive controls,
and completion status. No PKI directory, PEM bytes, password or raw container
logs are uploaded. A failed or incomplete manifest is not acceptance. Review
both manifests and both scanners' complete reports; the blocking vulnerability
gate is unchanged. This scope does not qualify Lakekeeper SQLx or cross-service
Phase A. The local sandbox may prohibit container namespaces; native CI is then
the runtime source of evidence, with that limitation reported explicitly.
