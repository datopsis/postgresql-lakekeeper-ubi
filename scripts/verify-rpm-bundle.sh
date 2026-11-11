#!/usr/bin/env bash
set -Eeuo pipefail

bundle=${1:?usage: verify-rpm-bundle.sh BUNDLE_DIR}
manifest=${bundle}/rpm-manifest.tsv
rpmdb=$(mktemp -d)
trap 'rm -rf "${rpmdb}"' EXIT

test -f "${manifest}"
rpm --dbpath "${rpmdb}" --initdb
rpm --dbpath "${rpmdb}" --import "${bundle}"/keys/*

expected_count=0
while IFS=$'\t' read -r filename name epoch version release architecture source_rpm fingerprint; do
    artifact=${bundle}/rpms/${filename}
    test -f "${artifact}"
    rpm --dbpath "${rpmdb}" --checksig "${artifact}"
    actual=$(rpm --dbpath "${rpmdb}" -qp \
        --qf '%{NAME}|%{EPOCHNUM}|%{VERSION}|%{RELEASE}|%{ARCH}|%{SOURCERPM}' \
        "${artifact}")
    expected="${name}|${epoch}|${version}|${release}|${architecture}|${source_rpm}"
    test "${actual}" = "${expected}"
    signature=$(rpm --dbpath "${rpmdb}" -qp --qf \
        '%{SIGPGP:pgpsig}|%{SIGGPG:pgpsig}|%{RSAHEADER:pgpsig}|%{DSAHEADER:pgpsig}' \
        "${artifact}")
    key_id=$(sed -n 's/.*[Kk]ey ID \([0-9A-Fa-f]*\).*/\1/p' <<<"${signature}" | head -n1)
    test -n "${key_id}"
    [[ ${fingerprint} == *${key_id^^} ]]
    expected_count=$((expected_count + 1))
done <"${manifest}"

actual_count=$(find "${bundle}/rpms" -maxdepth 1 -type f -name '*.rpm' | wc -l)
test "${actual_count}" -eq "${expected_count}"
