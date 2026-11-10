# Continuous integration

All workflows use contents: read and SHA-pinned actions. No workflow publishes
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
blocking gate: either scanner's fixed High/Critical finding returns failure,
without exemptions. Report generation is followed by enforcement; exit-zero
collection is not the acceptance decision. Missing or malformed reports fail.
The complete evidence is uploaded even if the gate fails and retained 14 days.
Review both JSON reports, summaries, logs and every job/step; green alone is
insufficient evidence. Retain exact commit/run IDs when downloading artifacts.

Lock updates run separate native resolver jobs and retain candidate artifacts
for seven days. They cannot modify GitHub contents, settings or permissions.

## Local checks

```sh
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
