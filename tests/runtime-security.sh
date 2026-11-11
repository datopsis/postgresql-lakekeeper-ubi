#!/usr/bin/env bash
set -Eeuo pipefail

runtime=${CONTAINER_RUNTIME:-podman}
image=${IMAGE:-localhost/postgresql-lakekeeper-ubi:development}
prefix="postgresql-lakekeeper-ubi-security-${RANDOM}-$$"
password='Odd !@#$%^&*()[]{}:;,.?=+_- value'
rotated='Rotated !@#$%^&*()[]{}:;,.?=+_- value'
sensitive_value='person-for-log-test@example.invalid'
data_volume="${prefix}-data"
secret_volume="${prefix}-secrets"
config_volume="${prefix}-config"
containers=()
volumes=("${data_volume}" "${secret_volume}" "${config_volume}")
no_new_privileges=no-new-privileges:true

if grep -qi podman <<<"$("${runtime}" --version 2>&1)"; then
    no_new_privileges=no-new-privileges
fi

cleanup() {
    if test "${#containers[@]}" -gt 0; then
        "${runtime}" rm --force --volumes "${containers[@]}" >/dev/null 2>&1 || true
    fi
    "${runtime}" volume rm --force "${volumes[@]}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
report_error() {
    failure_status=$?
    printf 'runtime-security failed at line %s\n' "${BASH_LINENO[0]}" >&2
    exit "${failure_status}"
}
trap report_error ERR

new_container() {
    containers+=("$1")
}

run_restricted() {
    local name=$1
    local volume=$2
    local options=()
    shift 2
    while test "$#" -gt 0 && test "$1" != --container-command; do
        options+=("$1")
        shift
    done
    if test "${1:-}" = --container-command; then
        shift
    fi
    new_container "${name}"
    "${runtime}" run --detach --name "${name}" \
        --read-only \
        --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m,mode=1777 \
        --mount "type=volume,src=${volume},dst=/var/lib/pgsql" \
        --cap-drop ALL \
        --security-opt "${no_new_privileges}" \
        "${options[@]}" "${image}" "$@" >/dev/null
}

wait_ready() {
    local name=$1
    local credential=$2
    local _
    for _ in {1..90}; do
        if "${runtime}" exec --env "PGPASSWORD=${credential}" "${name}" \
            psql -qAt --host=127.0.0.1 --username=postgres --dbname=postgres \
            --command='SELECT 1' >/dev/null 2>&1; then
            return
        fi
        sleep 1
    done
    "${runtime}" logs "${name}" >&2
    return 1
}

expect_failure() {
    local name=$1
    local expected=$2
    shift 2
    new_container "${name}"
    if "${runtime}" run --name "${name}" "$@" "${image}"; then
        echo "expected ${name} to fail" >&2
        return 1
    fi
    failure_logs=$("${runtime}" logs "${name}" 2>&1)
    grep -Fq "${expected}" <<<"${failure_logs}"
}

seed_file() {
    local volume=$1
    local path=$2
    local mode=$3
    local value=$4
    # Variables expand inside the seed container.
    # shellcheck disable=SC2016
    printf '%s' "${value}" | "${runtime}" run --rm --interactive --user 0 \
        --mount "type=volume,src=${volume},dst=/seed" \
        --entrypoint sh "${image}" -ceu \
        'umask 077; mkdir -p "$(dirname "/seed/$1")"; cat >"/seed/$1"; chmod "$2" "/seed/$1"; chown 0:0 "/seed/$1"' \
        sh "${path}" "${mode}"
}

for volume in "${volumes[@]}"; do
    "${runtime}" volume create "${volume}" >/dev/null
done

seed_file "${secret_volume}" password 440 "${password}"
seed_file "${secret_volume}" empty 440 ''
seed_file "${secret_volume}" newline 440 $'value\nsecond'
seed_file "${secret_volume}" permissive 444 value
"${runtime}" run --rm --user 0 \
    --mount "type=volume,src=${secret_volume},dst=/seed" \
    --entrypoint sh "${image}" -ceu \
    'ln -s password /seed/symlink; : >/seed/unreadable; chmod 000 /seed/unreadable'

common_failure=(--read-only --tmpfs '/tmp:rw,noexec,nosuid,nodev,size=64m,mode=1777'
    --cap-drop ALL --security-opt "${no_new_privileges}")

expect_failure "${prefix}-empty-env" 'initialization requires POSTGRES_PASSWORD' \
    "${common_failure[@]}" --env POSTGRES_PASSWORD=
expect_failure "${prefix}-both" 'set only one of POSTGRES_PASSWORD or POSTGRES_PASSWORD_FILE' \
    "${common_failure[@]}" --env POSTGRES_PASSWORD=value \
    --env POSTGRES_PASSWORD_FILE=/run/secrets/password \
    --mount "type=volume,src=${secret_volume},dst=/run/secrets,readonly"
expect_failure "${prefix}-empty-file" 'initialization requires POSTGRES_PASSWORD' \
    "${common_failure[@]}" --env POSTGRES_PASSWORD_FILE=/run/secrets/empty \
    --mount "type=volume,src=${secret_volume},dst=/run/secrets,readonly"
expect_failure "${prefix}-newline" 'without a line break' \
    "${common_failure[@]}" --env POSTGRES_PASSWORD_FILE=/run/secrets/newline \
    --mount "type=volume,src=${secret_volume},dst=/run/secrets,readonly"
expect_failure "${prefix}-permissive" 'permissions must be' \
    "${common_failure[@]}" --env POSTGRES_PASSWORD_FILE=/run/secrets/permissive \
    --mount "type=volume,src=${secret_volume},dst=/run/secrets,readonly"
expect_failure "${prefix}-symlink" 'must not be a symbolic link' \
    "${common_failure[@]}" --env POSTGRES_PASSWORD_FILE=/run/secrets/symlink \
    --mount "type=volume,src=${secret_volume},dst=/run/secrets,readonly"
expect_failure "${prefix}-unreadable" 'is not readable' \
    "${common_failure[@]}" --env POSTGRES_PASSWORD_FILE=/run/secrets/unreadable \
    --mount "type=volume,src=${secret_volume},dst=/run/secrets,readonly"

primary="${prefix}-primary"
run_restricted "${primary}" "${data_volume}" \
    --env POSTGRES_PASSWORD_FILE=/run/secrets/password \
    --mount "type=volume,src=${secret_volume},dst=/run/secrets,readonly"
wait_ready "${primary}" "${password}"

test "$("${runtime}" exec "${primary}" psql -qAt --host=/tmp --username=postgres \
    --command='SHOW password_encryption;')" = scram-sha-256
# Variables expand inside the database container.
# shellcheck disable=SC2016
"${runtime}" exec "${primary}" sh -ceu '
    grep -Eq "^Max core file size[[:space:]]+0[[:space:]]+" /proc/1/limits || {
        echo "PostgreSQL PID 1 has a nonzero core-file soft limit" >&2
        exit 1
    }
    if find /tmp -maxdepth 1 -name "postgresql-password.*" -print -quit | grep -q .; then
        echo "transient password file persisted after initialization" >&2
        exit 1
    fi
    if tr "\0" "\n" </proc/1/environ | grep -E "^POSTGRES_PASSWORD(_FILE)?="; then
        echo "initialization credential persisted in PID 1 environment" >&2
        exit 1
    fi
'
process_list=$("${runtime}" top "${primary}")
if grep -Fq "${password}" <<<"${process_list}"; then
    echo 'initialization credential exposed in process arguments' >&2
    exit 1
fi
primary_logs=$("${runtime}" logs "${primary}" 2>&1)
if grep -Fq "${password}" <<<"${primary_logs}"; then
    echo 'initialization credential exposed in logs' >&2
    exit 1
fi

"${runtime}" exec "${primary}" psql --host=/tmp --username=postgres \
    --set=ON_ERROR_STOP=1 --command="CREATE ROLE app LOGIN PASSWORD '${rotated}' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;" \
    --command='CREATE TABLE role_probe(value integer);' \
    --command='GRANT SELECT ON role_probe TO app;' >/dev/null
"${runtime}" exec "${primary}" psql --host=/tmp --username=postgres \
    --command="SELECT '${sensitive_value}';" >/dev/null
test "$("${runtime}" exec --env "PGPASSWORD=${rotated}" "${primary}" \
    psql -qAt --host=127.0.0.1 --username=app --dbname=postgres \
    --command='SELECT count(*) FROM role_probe;')" = 0
if "${runtime}" exec --env PGPASSWORD=wrong "${primary}" \
    psql -qAt --host=127.0.0.1 --username=app --dbname=postgres \
    --command='SELECT 1' >/dev/null 2>&1; then
    echo 'wrong application password authenticated' >&2
    exit 1
fi
if "${runtime}" exec --env "PGPASSWORD=${rotated}" "${primary}" \
    psql -qAt --host=127.0.0.1 --username=app --dbname=postgres \
    --command='CREATE TABLE forbidden(value integer)' >/dev/null 2>&1; then
    echo 'least-privilege application role created an unauthorized table' >&2
    exit 1
fi

"${runtime}" exec "${primary}" psql --host=/tmp --username=postgres \
    --set=ON_ERROR_STOP=1 --command="ALTER ROLE app PASSWORD '${password}';" >/dev/null
if "${runtime}" exec --env "PGPASSWORD=${rotated}" "${primary}" \
    psql -qAt --host=127.0.0.1 --username=app --dbname=postgres \
    --command='SELECT 1' >/dev/null 2>&1; then
    echo 'old application password remained valid after rotation' >&2
    exit 1
fi
test "$("${runtime}" exec --env "PGPASSWORD=${password}" "${primary}" \
    psql -qAt --host=127.0.0.1 --username=app --dbname=postgres \
    --command='SELECT 1')" = 1
primary_logs=$("${runtime}" logs "${primary}" 2>&1)
if grep -Fq "${rotated}" <<<"${primary_logs}" || \
    grep -Fq "${sensitive_value}" <<<"${primary_logs}"; then
    echo 'credential or personal-data fixture exposed in database logs' >&2
    exit 1
fi

# Persisted attempts to weaken HBA are replaced at the next start.
# PGDATA expands inside the database container.
# shellcheck disable=SC2016
"${runtime}" exec "${primary}" sh -c 'printf "host all all all trust\n" >"$PGDATA/pg_hba.conf"'
"${runtime}" stop --time 30 "${primary}" >/dev/null
"${runtime}" rm "${primary}" >/dev/null

seed_file "${config_volume}" postgresql.conf 444 $'max_connections = 37\npassword_encryption = md5\nlogging_collector = on\nlog_statement = all\nssl = on\n'
configured="${prefix}-configured"
run_restricted "${configured}" "${data_volume}" \
    --env POSTGRESQL_CONFIG_FILE=/run/config/postgresql.conf \
    --mount "type=volume,src=${config_volume},dst=/run/config,readonly" \
    --container-command postgres -c password_encryption=md5 -c log_statement=all \
    -c hba_file=/tmp/untrusted-hba -c ssl=on
wait_ready "${configured}" "${password}"
"${runtime}" exec "${configured}" psql --host=/tmp --username=postgres \
    --command="SELECT '${sensitive_value}';" >/dev/null
for expectation in \
    'max_connections|37' \
    'password_encryption|scram-sha-256' \
    'logging_collector|off' \
    'log_destination|stderr' \
    'log_statement|none' \
    'ssl|off'; do
    setting=${expectation%%|*}
    value=${expectation#*|}
    test "$("${runtime}" exec "${configured}" psql -qAt --host=/tmp --username=postgres \
        --command="SHOW ${setting};")" = "${value}"
done
# PGDATA expands inside the database container.
# shellcheck disable=SC2016
test "$("${runtime}" exec "${configured}" sh -c 'cat "$PGDATA/pg_hba.conf"')" = \
"# Managed by postgresql-lakekeeper-ubi; replaced on every start.
local all all trust
host all all 0.0.0.0/0 scram-sha-256
host all all ::/0 scram-sha-256"

configured_logs=$("${runtime}" logs "${configured}" 2>&1)
if grep -Fq "${rotated}" <<<"${configured_logs}" || \
    grep -Fq "${sensitive_value}" <<<"${configured_logs}"; then
    echo 'credential or personal-data fixture exposed in database logs' >&2
    exit 1
fi

echo "PostgreSQL authentication and configuration contract passed for ${image}"
