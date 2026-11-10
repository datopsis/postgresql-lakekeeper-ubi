#!/usr/bin/env bash
set -Eeuo pipefail

case "$(uname -m)" in
    x86_64) architecture=amd64 ;;
    aarch64|arm64) architecture=arm64 ;;
    *) printf 'unsupported native architecture: %s\n' "$(uname -m)" >&2; exit 1 ;;
esac

runtime=${CONTAINER_RUNTIME:-podman}
image=${IMAGE:-localhost/postgresql-lakekeeper-ubi:test}
lock=artifacts/locks/${architecture}.json
bundle=.artifact-bundle/${architecture}

command -v "${runtime}" >/dev/null
command -v gpg >/dev/null
test -f "${lock}"
test ! -e "${bundle}"

python3 scripts/artifacts.py acquire --lock "${lock}" --output "${bundle}"
bash scripts/verify-key-fingerprints.sh "${bundle}"
lock_sha=$(sha256sum "${lock}" | cut -d' ' -f1)
postgresql_signer=$(python3 -c '
import json, sys
lock = json.load(open(sys.argv[1]))
values = {item["signing_key_fingerprint"] for item in lock["packages"]
          if item["name"].startswith("postgresql")}
assert len(values) == 1
print(values.pop())
' "${lock}")
builder=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["base_images"]["builder"]["reference"])' "${lock}")
runtime_base=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["base_images"]["runtime"]["reference"])' "${lock}")

"${runtime}" pull "${builder}"
"${runtime}" pull "${runtime_base}"
"${runtime}" tag "${builder}" localhost/postgresql-lakekeeper-ubi-builder:locked
"${runtime}" tag "${runtime_base}" localhost/postgresql-lakekeeper-ubi-runtime:locked
test "$("${runtime}" image inspect --format '{{.Architecture}}' localhost/postgresql-lakekeeper-ubi-builder:locked)" = "${architecture}"
test "$("${runtime}" image inspect --format '{{.Architecture}}' localhost/postgresql-lakekeeper-ubi-runtime:locked)" = "${architecture}"

if test "${runtime}" = docker; then
    pull_flag=false
else
    pull_flag=never
fi
build_arguments=(--file Containerfile --tag "${image}" --network=none \
    --pull="${pull_flag}" --no-cache \
    --label "io.datopsis.ubi.builder=${builder}" \
    --label "io.datopsis.ubi.runtime=${runtime_base}" \
    --build-arg UBI_MINIMAL_IMAGE=localhost/postgresql-lakekeeper-ubi-builder:locked \
    --build-arg UBI_MICRO_IMAGE=localhost/postgresql-lakekeeper-ubi-runtime:locked \
    --build-arg POSTGRESQL_SIGNER_FINGERPRINT="${postgresql_signer}" \
    --build-arg ARTIFACT_LOCK_SHA256="${lock_sha}" .)
for release_argument in RELEASE_VERSION RELEASE_REVISION RELEASE_CREATED RELEASE_SOURCE; do
    if test -n "${!release_argument:-}"; then
        build_arguments=(--build-arg "${release_argument}=${!release_argument}" "${build_arguments[@]}")
    fi
done
if test "${runtime}" = docker && test -n "${BUILD_METADATA_FILE:-}"; then
    build_arguments=(--metadata-file "${BUILD_METADATA_FILE}" "${build_arguments[@]}")
fi

"${runtime}" build "${build_arguments[@]}"
