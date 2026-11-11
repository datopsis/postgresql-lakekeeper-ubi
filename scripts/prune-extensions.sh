#!/usr/bin/env bash
# Keep five Lakekeeper add-ons and PostgreSQL's core PL/pgSQL language.
set -Eeuo pipefail
root=${1:?usage: prune-extensions.sh ROOT}
prefix=/usr/pgsql-18
extensions=${root}${prefix}/share/extension
libraries=${root}${prefix}/lib
allowed=(btree_gin btree_gist pg_trgm pgcrypto uuid-ossp)

is_allowed() {
    local name=$1 item
    for item in "${allowed[@]}"; do
        test "${name}" != "${item}" || return 0
    done
    return 1
}

# Remove the entire non-allowlisted contrib payload, including modules with no
# control file (auto_explain, test_decoding, etc.), build-ID links and examples.
mapfile -t contrib_files < <(rpm --root "${root}" --query --list postgresql18-contrib)
test "${#contrib_files[@]}" -gt 0
for path in "${contrib_files[@]}"; do
    test ! -f "${root}${path}" && test ! -L "${root}${path}" && continue
    name=${path##*/}
    case "${path}" in
        "${prefix}/share/extension/"*.control) name=${name%.control} ;;
        "${prefix}/share/extension/"*.sql) name=${name%%--*} ;;
        "${prefix}/lib/"*.so) name=${name%.so} ;;
        *) rm -f -- "${root}${path}"; continue ;;
    esac
    if ! is_allowed "${name}"; then
        rm -f -- "${root}${path}"
    fi
done

# Reject unexpected controls, SQL, missing libraries or dangling allowlist
# entries. PL/pgSQL ships with the server and initdb installs it in templates.
expected=$(printf '%s\n' "${allowed[@]}" plpgsql | LC_ALL=C sort)
actual=$(find "${extensions}" -maxdepth 1 -name '*.control' -printf '%f\n' \
    | sed 's/\.control$//' | LC_ALL=C sort)
test "${actual}" = "${expected}" || {
    printf 'extension allowlist mismatch\nexpected:\n%s\nactual:\n%s\n' "${expected}" "${actual}" >&2
    exit 1
}
for name in "${allowed[@]}" plpgsql; do
    test -f "${libraries}/${name}.so"
    test -n "$(find "${extensions}" -maxdepth 1 -name "${name}--*.sql" -print -quit)"
done
while IFS= read -r path; do
    name=${path##*/}
    name=${name%%--*}
    test "${name}" = plpgsql || is_allowed "${name}"
done < <(find "${extensions}" -type f -name '*.sql')
# Independent postcondition over every RPM-owned file: deleting only controls
# must never leave forbidden libraries or SQL hidden in another directory.
for path in "${contrib_files[@]}"; do
    test ! -f "${root}${path}" && test ! -L "${root}${path}" && continue
    case "${path}" in
        "${prefix}/share/extension/"*.control) name=${path##*/}; name=${name%.control} ;;
        "${prefix}/share/extension/"*.sql) name=${path##*/}; name=${name%%--*} ;;
        "${prefix}/lib/"*.so) name=${path##*/}; name=${name%.so} ;;
        *) printf 'unexpected contrib file: %s\n' "${path}" >&2; exit 1 ;;
    esac
    is_allowed "${name}"
done
