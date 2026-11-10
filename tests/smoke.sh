#!/usr/bin/env bash
set -Eeuo pipefail

runtime="${CONTAINER_RUNTIME:-podman}"
image="${IMAGE:-localhost/postgresql-lakekeeper-ubi9:development}"
password="smoke-$RANDOM-$$-OnlyForTesting"
prefix="postgresql-lakekeeper-ubi9-smoke-${RANDOM}-$$"
primary="${prefix}-primary"
restart="${prefix}-restart"
arbitrary="${prefix}-arbitrary"
missing_password="${prefix}-missing-password"
wrong_major="${prefix}-wrong-major"
primary_volume="${prefix}-primary-data"
arbitrary_volume="${prefix}-arbitrary-data"
missing_volume="${prefix}-missing-data"
no_new_privileges="no-new-privileges:true"

if grep -qi podman <<<"$("${runtime}" --version 2>&1)"; then
    no_new_privileges="no-new-privileges"
fi

cleanup() {
    "${runtime}" rm --force --volumes \
        "${primary}" "${restart}" "${arbitrary}" \
        "${missing_password}" "${wrong_major}" >/dev/null 2>&1 || true
    "${runtime}" volume rm --force \
        "${primary_volume}" "${arbitrary_volume}" "${missing_volume}" \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT

run_restricted() {
    local name="$1"
    local volume="$2"
    shift 2
    "${runtime}" run --detach --name "${name}" \
        --read-only \
        --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m,mode=1777 \
        --mount "type=volume,src=${volume},dst=/var/lib/pgsql" \
        --cap-drop ALL \
        --security-opt "${no_new_privileges}" \
        "$@" "${image}" >/dev/null
}

wait_for_postgresql() {
    local name="$1"
    local _
    for _ in {1..60}; do
        if "${runtime}" exec --env "PGPASSWORD=${password}" "${name}" \
            /usr/pgsql-18/bin/psql --quiet --host=127.0.0.1 \
            --username=postgres --dbname=postgres --command='SELECT 1' \
            >/dev/null 2>&1; then
            return
        fi
        sleep 1
    done
    "${runtime}" inspect --format '{{json .State}}' "${name}" >&2
    "${runtime}" logs "${name}" >&2
    return 1
}

wait_for_failure() {
    local name="$1"
    local state
    local code
    local _
    for _ in {1..20}; do
        state="$("${runtime}" inspect --format '{{.State.Status}}' "${name}")"
        if test "${state}" != running; then
            code="$("${runtime}" inspect --format '{{.State.ExitCode}}' "${name}")"
            test "${code}" != 0
            return
        fi
        sleep 1
    done
    "${runtime}" logs "${name}" >&2
    return 1
}

assert_process_security() {
    local name="$1"
    # Variables expand inside the container.
    # shellcheck disable=SC2016
    "${runtime}" exec "${name}" sh -eu -c '
        for status in /proc/[0-9]*/status; do
            uid=$(sed -n "s/^Uid:[[:space:]]*\([0-9]*\).*/\1/p" "${status}")
            cap=$(sed -n "s/^CapEff:[[:space:]]*//p" "${status}")
            nnp=$(sed -n "s/^NoNewPrivs:[[:space:]]*//p" "${status}")
            test "${uid}" -ne 0
            test "${cap}" = 0000000000000000
            test "${nnp}" = 1
        done
    '
}

sql() {
    local name="$1"
    local statement="$2"
    "${runtime}" exec --env "PGPASSWORD=${password}" "${name}" \
        psql --host=127.0.0.1 --username=postgres \
        --dbname=postgres --tuples-only --no-align --command="${statement}"
}

test "$("${runtime}" image inspect --format '{{.Config.User}}' "${image}")" = "26:0"

"${runtime}" volume create "${primary_volume}" >/dev/null
run_restricted "${primary}" "${primary_volume}" \
    --env "POSTGRES_PASSWORD=${password}"
wait_for_postgresql "${primary}"
test "$(sql "${primary}" 'SHOW server_version;')" = "18.6"

# The add-ons are available, but neither templates nor databases opt in silently.
expected_extensions='btree_gin,btree_gist,pg_trgm,pgcrypto,plpgsql,uuid-ossp'
test "$(sql "${primary}" "SELECT string_agg(name, ',' ORDER BY name) FROM pg_available_extensions;")" = "${expected_extensions}"
test "$(sql "${primary}" "SELECT string_agg(extname, ',' ORDER BY extname) FROM pg_extension;")" = plpgsql
sql "${primary}" 'CREATE DATABASE lakekeeper;' >/dev/null
"${runtime}" exec --env "PGPASSWORD=${password}" "${primary}" psql -X \
    --host=127.0.0.1 --username=postgres --dbname=lakekeeper \
    --file=/usr/share/lakekeeper/init.sql >/dev/null
# Exercise idempotence of the documented optional path.
"${runtime}" exec --env "PGPASSWORD=${password}" "${primary}" psql -X \
    --host=127.0.0.1 --username=postgres --dbname=lakekeeper \
    --file=/usr/share/lakekeeper/init.sql >/dev/null
test "$("${runtime}" exec --env "PGPASSWORD=${password}" "${primary}" psql -XAt \
    --host=127.0.0.1 --username=postgres --dbname=lakekeeper \
    --command="SELECT string_agg(extname, ',' ORDER BY extname) FROM pg_extension;")" = "${expected_extensions}"
# A removed extension must fail with the unavailable-extension diagnostic.
if output=$(sql "${primary}" 'CREATE EXTENSION hstore;' 2>&1); then
    echo 'removed hstore extension unexpectedly installed' >&2
    exit 1
fi
grep -Fq 'extension "hstore" is not available' <<<"${output}"
test "$(sql "${primary}" "SELECT string_agg(extname, ',' ORDER BY extname) FROM pg_extension;")" = plpgsql
"${runtime}" exec "${primary}" sh -ec \
    'test ! -e /usr/pgsql-18/lib/hstore.so; test ! -e /usr/pgsql-18/lib/auto_explain.so'

test "$(sql "${primary}" 'SHOW password_encryption;')" = "scram-sha-256"
test "$(sql "${primary}" 'SHOW data_checksums;')" = on
test "$(sql "${primary}" 'SHOW logging_collector;')" = off
test "$(sql "${primary}" 'SHOW log_statement;')" = none
test "$(sql "${primary}" 'SHOW log_parameter_max_length;')" = 0
test "$(sql "${primary}" 'SHOW log_parameter_max_length_on_error;')" = 0
test "$(sql "${primary}" 'SHOW ssl;')" = off
# Variables expand inside the container.
# shellcheck disable=SC2016
test "$("${runtime}" exec "${primary}" sh -c \
    'cat "$PGDATA/pg_hba.conf"')" = "# Managed by postgresql-lakekeeper-ubi; replaced on every start.
local all all trust
host all all 0.0.0.0/0 scram-sha-256
host all all ::/0 scram-sha-256"
sql "${primary}" \
    'CREATE TABLE persistence_probe (value text NOT NULL); INSERT INTO persistence_probe VALUES ('"'"'survives'"'"');' \
    >/dev/null
test "$("${runtime}" exec "${primary}" id -u)" = 26
test "$("${runtime}" exec "${primary}" id -g)" = 0
assert_process_security "${primary}"
"${runtime}" exec "${primary}" sh -ec \
    'grep -Eq "^[^ ]+ / [^ ]+ ro(,| )" /proc/mounts'
# Expand the manager name inside the container.
# shellcheck disable=SC2016
"${runtime}" exec "${primary}" sh -ceu '
    for manager in dnf microdnf rpm yum pip pip3; do
        if command -v "${manager}" >/dev/null 2>&1; then
            echo "unexpected runtime package manager: ${manager}" >&2
            exit 1
        fi
    done
    test ! -e /usr/share/python3-wheels
    test ! -e /usr/lib64/python3.9/ensurepip
'
"${runtime}" exec "${primary}" sh -ceu \
    '! (printf probe > /root-filesystem-probe) 2>/dev/null'
if grep -Fq "${password}" <<<"$("${runtime}" logs "${primary}" 2>&1)"; then
    echo "Initialization password was exposed in container logs" >&2
    exit 1
fi
if "${runtime}" exec "${primary}" sh -c \
    'tr "\0" "\n" </proc/1/environ | grep -E "^POSTGRES_PASSWORD(_FILE)?="'; then
    echo "Initialization credential remained in the PostgreSQL process environment" >&2
    exit 1
fi

"${runtime}" stop --time 30 "${primary}" >/dev/null
test "$("${runtime}" inspect --format '{{.State.ExitCode}}' "${primary}")" = 0
"${runtime}" rm "${primary}" >/dev/null

run_restricted "${restart}" "${primary_volume}"
wait_for_postgresql "${restart}"
test "$(sql "${restart}" 'SELECT value FROM persistence_probe;')" = survives

test "$("${runtime}" exec --env "PGPASSWORD=${password}" "${restart}" psql -XAt \
    --host=127.0.0.1 --username=postgres --dbname=lakekeeper \
    --command="SELECT string_agg(extname, ',' ORDER BY extname) FROM pg_extension;")" = "${expected_extensions}"

"${runtime}" stop --time 30 "${restart}" >/dev/null
"${runtime}" rm "${restart}" >/dev/null

"${runtime}" volume create "${arbitrary_volume}" >/dev/null
run_restricted "${arbitrary}" "${arbitrary_volume}" \
    --user 10001:0 --env "POSTGRES_PASSWORD=${password}"
wait_for_postgresql "${arbitrary}"
test "$("${runtime}" exec "${arbitrary}" id -u)" = 10001
assert_process_security "${arbitrary}"
test "$(sql "${arbitrary}" 'SELECT current_user;')" = postgres
"${runtime}" stop --time 30 "${arbitrary}" >/dev/null
"${runtime}" rm "${arbitrary}" >/dev/null

"${runtime}" volume create "${missing_volume}" >/dev/null
run_restricted "${missing_password}" "${missing_volume}"
wait_for_failure "${missing_password}"
grep -Fq 'initialization requires POSTGRES_PASSWORD' \
    <<<"$("${runtime}" logs "${missing_password}" 2>&1)"
"${runtime}" rm "${missing_password}" >/dev/null

"${runtime}" run --detach --name "${wrong_major}" \
    --read-only \
    --mount "type=volume,src=${primary_volume},dst=/var/lib/pgsql" \
    --cap-drop ALL \
    --security-opt "${no_new_privileges}" \
    --entrypoint sh "${image}" \
    -c 'printf 17 > /var/lib/pgsql/data/PG_VERSION' >/dev/null
while test "$("${runtime}" inspect --format '{{.State.Status}}' "${wrong_major}")" = running; do
    sleep 1
done
"${runtime}" rm "${wrong_major}" >/dev/null
run_restricted "${wrong_major}" "${primary_volume}"
wait_for_failure "${wrong_major}"
grep -Fq 'PGDATA major 17 is incompatible with PostgreSQL 18' \
    <<<"$("${runtime}" logs "${wrong_major}" 2>&1)"

echo "PostgreSQL restricted-runtime scenario tests passed for ${image}"
