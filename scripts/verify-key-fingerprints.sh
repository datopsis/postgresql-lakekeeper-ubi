#!/usr/bin/env bash
set -Eeuo pipefail

bundle=${1:?usage: verify-key-fingerprints.sh BUNDLE_DIR}
manifest=${bundle}/key-manifest.tsv

test -f "${manifest}"
while IFS=$'\t' read -r filename expected_fingerprint expected_sha256; do
    key=${bundle}/keys/${filename}
    test -f "${key}"
    test "$(sha256sum "${key}" | cut -d' ' -f1)" = "${expected_sha256}"
    mapfile -t fingerprints < <(
        gpg --batch --quiet --with-colons --show-keys "${key}" \
            | awk -F: '$1 == "fpr" { print $10 }'
    )
    test "${#fingerprints[@]}" -ge 1
    test "${fingerprints[0]}" = "${expected_fingerprint}"
done <"${manifest}"
