#!/usr/bin/env bash
# The caller verifies the complete locked bundle before invoking this script.
set -Eeuo pipefail
root=${1:?usage: install-runtime-rpms.sh ROOT RPM_DIR}
rpm_dir=${2:?usage: install-runtime-rpms.sh ROOT RPM_DIR}
normal=()
contrib=()
for path in "${rpm_dir}"/*.rpm; do
    name=$(rpm --query --package --queryformat '%{NAME}' "${path}")
    if test "${name}" = postgresql18-contrib; then
        contrib+=("${path}")
    else
        normal+=("${path}")
    fi
done
test "${#contrib[@]}" -eq 1
test "${#normal[@]}" -gt 0
rpm --root "${root}" --install "${normal[@]}"
# Only contrib gets this exception: its discarded modules require Python/XSLT.
# prune-extensions and verify-runtime-dependencies must follow before final use.
rpm --root "${root}" --install --nodeps "${contrib[0]}"
