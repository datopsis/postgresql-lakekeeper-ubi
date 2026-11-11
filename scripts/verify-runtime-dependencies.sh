#!/usr/bin/env bash
# Run with the builder's RPM tooling against the assembled final root.
set -Eeuo pipefail
root=${1:?usage: verify-runtime-dependencies.sh ROOT}
inventory=$(rpm --root "${root}" --query --all --queryformat '%{NAME}\n')
test -n "${inventory}"
normal=()
contrib_count=0
while IFS= read -r name; do
    case "${name}" in
        python3-libs|python3-pip-wheel|python3-setuptools-wheel|sqlite-libs|libxslt)
            printf 'forbidden runtime package: %s\n' "${name}" >&2
            exit 1
            ;;
        postgresql18-contrib) contrib_count=$((contrib_count + 1)) ;;
        *) normal+=("${name}") ;;
    esac
done <<<"${inventory}"
test "${contrib_count}" -eq 1
test "${#normal[@]}" -gt 0
# Verify RPM dependency satisfaction for EVERY other package. Do not suppress
# dependency checks here. File verification is separate from dependency checks;
# the image intentionally prunes files and removes package-manager configuration.
rpm --root "${root}" --verify --nofiles --noscript "${normal[@]}"

# Resolve dependencies in the final userspace, never against builder libraries.
# Include the five add-ons, core PL/pgSQL and the server executable explicitly.
for path in /usr/pgsql-18/bin/postgres \
    /usr/pgsql-18/lib/{uuid-ossp,pgcrypto,pg_trgm,btree_gin,btree_gist,plpgsql}.so; do
    test -f "${root}${path}"
    linkage=$(chroot "${root}" /usr/bin/ldd "${path}")
    printf '%s\n%s\n' "${path}" "${linkage}"
    test -n "${linkage}"
    if grep -Fq 'not found' <<<"${linkage}"; then
        printf 'unresolved runtime linkage: %s\n' "${path}" >&2
        exit 1
    fi
done
