#!/usr/bin/env bash
set -Eeuo pipefail

runtime=${CONTAINER_RUNTIME:-podman}
image=${IMAGE:-localhost/postgresql-lakekeeper-ubi:development}
prefix="postgresql-lakekeeper-ubi-storage-${RANDOM}-$$"
password="storage-${RANDOM}-OnlyForTesting"
data_volume="${prefix}-data"
restore_volume="${prefix}-restore"
backup_volume="${prefix}-backup"
partial_volume="${prefix}-partial"
locked_volume="${prefix}-locked"
hook_volume="${prefix}-hook"
ownership_volume="${prefix}-ownership"
containers=()
volumes=("${data_volume}" "${restore_volume}" "${backup_volume}" \
    "${partial_volume}" "${locked_volume}" "${hook_volume}" "${ownership_volume}")
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
    printf 'storage-lifecycle failed at line %s\n' "${BASH_LINENO[0]}" >&2
    exit "${failure_status}"
}
trap report_error ERR

remember() {
    containers+=("$1")
}

run_database() {
    local name=$1
    local volume=$2
    shift 2
    remember "${name}"
    "${runtime}" run --detach --name "${name}" \
        --read-only \
        --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m,mode=1777 \
        --mount "type=volume,src=${volume},dst=/var/lib/pgsql" \
        --cap-drop ALL \
        --security-opt "${no_new_privileges}" \
        "$@" "${image}" >/dev/null
}

wait_ready() {
    local name=$1
    local database=${2:-postgres}
    local _
    for _ in {1..120}; do
        if "${runtime}" exec --env "PGPASSWORD=${password}" "${name}" \
            psql -qAt --host=127.0.0.1 --username=postgres --dbname="${database}" \
            --command='SELECT 1' >/dev/null 2>&1; then
            return
        fi
        sleep 1
    done
    "${runtime}" logs "${name}" >&2
    return 1
}

wait_failed() {
    local name=$1
    local expected=$2
    local _
    for _ in {1..60}; do
        if test "$("${runtime}" inspect --format '{{.State.Status}}' "${name}")" != running; then
            test "$("${runtime}" inspect --format '{{.State.ExitCode}}' "${name}")" != 0
            failure_logs=$("${runtime}" logs "${name}" 2>&1)
            if ! grep -Fq "${expected}" <<<"${failure_logs}"; then
                printf 'expected failure text not found: %s\n' "${expected}" >&2
                "${runtime}" logs "${name}" >&2
                return 1
            fi
            return
        fi
        sleep 1
    done
    "${runtime}" logs "${name}" >&2
    return 1
}

for volume in "${volumes[@]}"; do
    "${runtime}" volume create "${volume}" >/dev/null
done

primary="${prefix}-primary"
run_database "${primary}" "${data_volume}" --env "POSTGRES_PASSWORD=${password}"
wait_ready "${primary}"
"${runtime}" exec "${primary}" psql --host=/tmp --username=postgres \
    --set=ON_ERROR_STOP=1 \
    --command='CREATE TABLE durable(id bigint PRIMARY KEY, payload text NOT NULL);' \
    --command="INSERT INTO durable SELECT i, repeat(md5(i::text), 64) FROM generate_series(1, 30000) AS i;" \
    --command='CHECKPOINT;' >/dev/null
test "$("${runtime}" exec "${primary}" psql -qAt --host=/tmp --username=postgres \
    --command='SELECT count(*) FROM durable;')" = 30000
test "$("${runtime}" exec "${primary}" pg_controldata /var/lib/pgsql/data \
    | sed -n 's/^Data page checksum version:[[:space:]]*//p')" = 1

# Bounded temporary storage fails without affecting durable data.
if "${runtime}" exec "${primary}" dd if=/dev/zero of=/tmp/space-probe \
    bs=1M count=80 status=none 2>/dev/null; then
    echo 'bounded /tmp unexpectedly accepted an 80 MiB write' >&2
    exit 1
fi
"${runtime}" exec "${primary}" rm -f /tmp/space-probe

# A normal stop must checkpoint cleanly and remove transient PID/socket state.
"${runtime}" stop --time 30 "${primary}" >/dev/null
test "$("${runtime}" inspect --format '{{.State.ExitCode}}' "${primary}")" = 0
"${runtime}" rm "${primary}" >/dev/null

clean_restart="${prefix}-clean-restart"
run_database "${clean_restart}" "${data_volume}"
wait_ready "${clean_restart}"
test "$("${runtime}" exec "${clean_restart}" psql -qAt --host=/tmp --username=postgres \
    --command='SELECT count(*) FROM durable;')" = 30000
# PGDATA expands inside the database container.
# shellcheck disable=SC2016
"${runtime}" exec "${clean_restart}" sh -ceu 'test -s "$PGDATA/postmaster.pid"; test -S /tmp/.s.PGSQL.5432'

# Force termination during writes. Committed rows must survive crash recovery.
"${runtime}" exec --detach "${clean_restart}" psql --host=/tmp --username=postgres \
    --command="INSERT INTO durable SELECT i, repeat(md5(i::text), 64) FROM generate_series(30001, 90000) AS i; SELECT pg_sleep(30);"
sleep 2
"${runtime}" kill --signal KILL "${clean_restart}" >/dev/null
"${runtime}" rm "${clean_restart}" >/dev/null

recovered="${prefix}-recovered"
run_database "${recovered}" "${data_volume}"
wait_ready "${recovered}"
row_count=$("${runtime}" exec "${recovered}" psql -qAt --host=/tmp --username=postgres \
    --command='SELECT count(*) FROM durable;')
test "${row_count}" -eq 30000 || test "${row_count}" -eq 90000
test "$("${runtime}" exec "${recovered}" psql -qAt --host=/tmp --username=postgres \
    --command='SELECT pg_is_in_recovery();')" = f
recovery_logs=$("${runtime}" logs "${recovered}" 2>&1)
grep -Eq 'database system was interrupted|database system was not properly shut down|redo starts at' \
    <<<"${recovery_logs}"

# Logical backup and isolated restore validate schema, row count, and content.
"${runtime}" run --rm --user 0 \
    --mount "type=volume,src=${backup_volume},dst=/backup" \
    --entrypoint sh "${image}" -c 'chown 26:0 /backup; chmod 0770 /backup'
"${runtime}" exec "${recovered}" true
"${runtime}" stop --time 30 "${recovered}" >/dev/null
"${runtime}" rm "${recovered}" >/dev/null

backup_source="${prefix}-backup-source"
run_database "${backup_source}" "${data_volume}" \
    --mount "type=volume,src=${backup_volume},dst=/backup"
wait_ready "${backup_source}"
source_digest=$("${runtime}" exec "${backup_source}" psql -qAt --host=/tmp --username=postgres \
    --command="SELECT md5(string_agg(id || ':' || payload, ',' ORDER BY id)) FROM durable;")
"${runtime}" exec "${backup_source}" pg_dump --host=/tmp --username=postgres \
    --format=custom --file=/backup/postgres.dump postgres
"${runtime}" exec "${backup_source}" sh -ceu 'test -s /backup/postgres.dump; chmod 0400 /backup/postgres.dump'
"${runtime}" stop --time 30 "${backup_source}" >/dev/null

restore="${prefix}-restore"
run_database "${restore}" "${restore_volume}" \
    --env "POSTGRES_PASSWORD=${password}" \
    --mount "type=volume,src=${backup_volume},dst=/backup,readonly"
wait_ready "${restore}"
"${runtime}" exec "${restore}" pg_restore --host=/tmp --username=postgres \
    --dbname=postgres --clean --if-exists --exit-on-error /backup/postgres.dump
test "$("${runtime}" exec "${restore}" psql -qAt --host=/tmp --username=postgres \
    --command='SELECT count(*) FROM durable;')" = "${row_count}"
restore_digest=$("${runtime}" exec "${restore}" psql -qAt --host=/tmp --username=postgres \
    --command="SELECT md5(string_agg(id || ':' || payload, ',' ORDER BY id)) FROM durable;")
test "${source_digest}" = "${restore_digest}"

# Partial initialization and stale/concurrent locks always fail closed.
"${runtime}" run --rm --user 26:0 \
    --mount "type=volume,src=${partial_volume},dst=/var/lib/pgsql" \
    --entrypoint sh "${image}" -c 'mkdir -p /var/lib/pgsql/data; : >/var/lib/pgsql/data/partial'
partial="${prefix}-partial"
run_database "${partial}" "${partial_volume}" --env "POSTGRES_PASSWORD=${password}"
wait_failed "${partial}" 'refusing automatic recovery or reinitialization'

"${runtime}" run --rm --user 26:0 \
    --mount "type=volume,src=${locked_volume},dst=/var/lib/pgsql" \
    --entrypoint sh "${image}" -c 'mkdir /var/lib/pgsql/data.postgresql-lakekeeper-ubi.init.lock'
locked="${prefix}-locked"
run_database "${locked}" "${locked_volume}" --env "POSTGRES_PASSWORD=${password}"
wait_failed "${locked}" 'stale initialization lock exists'

"${runtime}" run --rm --user 0 \
    --mount "type=volume,src=${ownership_volume},dst=/var/lib/pgsql" \
    --entrypoint sh "${image}" -c 'chmod 0700 /var/lib/pgsql; chown 0:0 /var/lib/pgsql'
wrong_owner="${prefix}-wrong-owner"
run_database "${wrong_owner}" "${ownership_volume}" --env "POSTGRES_PASSWORD=${password}"
wait_failed "${wrong_owner}" 'cannot create PGDATA'

readonly_data="${prefix}-readonly"
remember "${readonly_data}"
"${runtime}" run --detach --name "${readonly_data}" \
    --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m,mode=1777 \
    --mount "type=volume,src=${data_volume},dst=/var/lib/pgsql,readonly" \
    --cap-drop ALL --security-opt "${no_new_privileges}" "${image}" >/dev/null
wait_failed "${readonly_data}" 'PGDATA is not writable'

full="${prefix}-full"
remember "${full}"
"${runtime}" run --detach --name "${full}" \
    --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m,mode=1777 \
    --tmpfs /var/lib/pgsql:rw,nosuid,nodev,size=4m,uid=26,gid=0,mode=0770 \
    --cap-drop ALL --security-opt "${no_new_privileges}" \
    --env "POSTGRES_PASSWORD=${password}" "${image}" >/dev/null
wait_failed "${full}" 'No space left on device'

# An intentionally delayed initdb makes interruption and concurrency deterministic.
"${runtime}" run --rm --user 0 \
    --mount "type=volume,src=${hook_volume},dst=/hook" \
    --entrypoint sh "${image}" -ceu '
        printf "%s\n" "#!/bin/sh" "sleep 30" "exec /usr/pgsql-18/bin/initdb \"\$@\"" >/hook/initdb
        chmod 0755 /hook/initdb
        chown 26:0 /hook/initdb
    '
concurrent_volume="${prefix}-concurrent"
volumes+=("${concurrent_volume}")
"${runtime}" volume create "${concurrent_volume}" >/dev/null
first="${prefix}-concurrent-one"
second="${prefix}-concurrent-two"
run_database "${first}" "${concurrent_volume}" \
    --env "POSTGRES_PASSWORD=${password}" --env PATH=/hook:/usr/local/bin:/usr/pgsql-18/bin:/usr/bin:/bin \
    --mount "type=volume,src=${hook_volume},dst=/hook,readonly"
sleep 1
run_database "${second}" "${concurrent_volume}" \
    --env "POSTGRES_PASSWORD=${password}" --env PATH=/hook:/usr/local/bin:/usr/pgsql-18/bin:/usr/bin:/bin \
    --mount "type=volume,src=${hook_volume},dst=/hook,readonly"
wait_failed "${second}" 'initialization is already running'
"${runtime}" stop --time 5 "${first}" >/dev/null || true
"${runtime}" rm "${first}" >/dev/null

interrupted_restart="${prefix}-interrupted-restart"
run_database "${interrupted_restart}" "${concurrent_volume}" --env "POSTGRES_PASSWORD=${password}"
wait_failed "${interrupted_restart}" 'stale initialization lock exists'
"${runtime}" rm "${interrupted_restart}" >/dev/null

# Recovery is an explicit operator decision after confirming that initdb never
# began and the database directory is empty. The entrypoint never guesses.
# Command substitution expands inside the inspection container.
# shellcheck disable=SC2016
"${runtime}" run --rm --user 26:0 \
    --mount "type=volume,src=${concurrent_volume},dst=/var/lib/pgsql" \
    --entrypoint sh "${image}" -ceu \
    'test -d /var/lib/pgsql/data; test -z "$(find /var/lib/pgsql/data -mindepth 1 -print -quit)"; rmdir /var/lib/pgsql/data.postgresql-lakekeeper-ubi.init.lock'
recovered_initialization="${prefix}-recovered-initialization"
run_database "${recovered_initialization}" "${concurrent_volume}" \
    --env "POSTGRES_PASSWORD=${password}"
wait_ready "${recovered_initialization}"

echo "PostgreSQL durable-storage and lifecycle contract passed for ${image}"
