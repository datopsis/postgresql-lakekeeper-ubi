#!/usr/bin/env bash
set -Eeuo pipefail

runtime=${CONTAINER_RUNTIME:-podman}
image=${IMAGE:-localhost/postgresql-lakekeeper-ubi:development}
prefix="postgresql-lakekeeper-ubi-resources-${RANDOM}-$$"
password="resources-${RANDOM}-OnlyForTesting"
application_password="application-${RANDOM}-OnlyForTesting"
data_volume="${prefix}-data"
containers=()
no_new_privileges=no-new-privileges:true

if grep -qi podman <<<"$("${runtime}" --version 2>&1)"; then
    no_new_privileges=no-new-privileges
fi

cleanup() {
    if test "${#containers[@]}" -gt 0; then
        "${runtime}" rm --force --volumes "${containers[@]}" >/dev/null 2>&1 || true
    fi
    "${runtime}" volume rm --force "${data_volume}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

report_error() {
    local status=$?
    printf 'resource-limits failed at line %s\n' "${BASH_LINENO[0]}" >&2
    exit "${status}"
}
trap report_error ERR

remember() {
    containers+=("$1")
}

run_limited() {
    local name=$1
    shift
    remember "${name}"
    "${runtime}" run --detach --name "${name}" \
        --read-only \
        --tmpfs /tmp:rw,noexec,nosuid,nodev,size=768m,mode=1777 \
        --shm-size=256m \
        --memory=384m --memory-swap=384m \
        --ulimit nofile=256:256 --pids-limit=128 \
        --mount "type=volume,src=${data_volume},dst=/var/lib/pgsql" \
        --cap-drop ALL --security-opt "${no_new_privileges}" \
        "$@" "${image}" postgres \
        -c max_connections=12 -c superuser_reserved_connections=3 >/dev/null
}

wait_ready() {
    local name=$1
    local _
    for _ in {1..120}; do
        if "${runtime}" exec --env "PGPASSWORD=${password}" "${name}" \
            psql -qAt --host=127.0.0.1 --username=postgres --dbname=postgres \
            --command='SELECT 1' >/dev/null 2>&1; then
            return
        fi
        sleep 1
    done
    "${runtime}" inspect --format '{{json .State}}' "${name}" >&2 || true
    "${runtime}" logs "${name}" >&2 || true
    return 1
}

"${runtime}" volume create "${data_volume}" >/dev/null
database="${prefix}-database"
run_limited "${database}" --env "POSTGRES_PASSWORD=${password}"
wait_ready "${database}"
test "$("${runtime}" exec "${database}" sh -c 'ulimit -n')" = 256
test "$("${runtime}" exec "${database}" cat /sys/fs/cgroup/pids.max)" = 128
test "$("${runtime}" exec "${database}" cat /sys/fs/cgroup/memory.max)" = 402653184

"${runtime}" exec "${database}" psql --host=/tmp --username=postgres \
    --set=ON_ERROR_STOP=1 \
    --command='CREATE TABLE resource_probe(value integer PRIMARY KEY);' \
    --command='INSERT INTO resource_probe VALUES (1);' \
    --command="CREATE ROLE application LOGIN PASSWORD '${application_password}' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;" >/dev/null

# Fill every non-reserved connection slot with a low-privilege role. The next
# application connection must fail while a local superuser diagnostic remains
# available through the explicitly reserved slots.
for _ in {1..9}; do
    "${runtime}" exec --detach --env "PGPASSWORD=${application_password}" "${database}" \
        psql --host=127.0.0.1 --username=application --dbname=postgres \
        --command='SELECT pg_sleep(120);'
done
for _ in {1..30}; do
    connection_count=$("${runtime}" exec "${database}" psql -qAt \
        --host=/tmp --username=postgres \
        --command="SELECT count(*) FROM pg_stat_activity WHERE usename='application';")
    test "${connection_count}" -eq 9 && break
    sleep 1
done
test "${connection_count}" -eq 9
if "${runtime}" exec --env "PGPASSWORD=${application_password}" "${database}" \
    psql --host=127.0.0.1 --username=application --dbname=postgres \
    --command='SELECT 1' >/dev/null 2>&1; then
    echo 'application connection was accepted after non-reserved slots were exhausted' >&2
    exit 1
fi
test "$("${runtime}" exec "${database}" psql -qAt --host=/tmp --username=postgres \
    --command='SELECT value FROM resource_probe;')" = 1
"${runtime}" exec "${database}" psql -qAt --host=/tmp --username=postgres \
    --command="SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename='application';" >/dev/null

# Exhaust the deliberately bounded shared-memory filesystem without touching
# durable storage. PostgreSQL must remain available after the failed write.
if "${runtime}" exec "${database}" dd if=/dev/zero of=/dev/shm/exhaustion \
    bs=1M count=320 status=none 2>/dev/null; then
    echo 'bounded shared memory unexpectedly accepted a 320 MiB write' >&2
    exit 1
fi
"${runtime}" exec "${database}" rm -f /dev/shm/exhaustion
wait_ready "${database}"

# Force a cgroup-contained OOM with a disposable tmpfs write. The database may
# survive or be killed; either outcome must preserve and recover durable data.
# The awk fields expand inside the database container.
# shellcheck disable=SC2016
oom_before=$("${runtime}" exec "${database}" awk '$1 == "oom" { print $2 }' \
    /sys/fs/cgroup/memory.events)
"${runtime}" exec "${database}" dd if=/dev/zero of=/tmp/memory-pressure \
    bs=1M count=640 status=none >/dev/null 2>&1 || true
sleep 2
# The postmaster can begin its safety shutdown between an inspect and exec, so
# collect in-cgroup evidence opportunistically and use stopped-state/log
# evidence when the cgroup has already gone away.
# shellcheck disable=SC2016
oom_after=$("${runtime}" exec "${database}" awk '$1 == "oom" { print $2 }' \
    /sys/fs/cgroup/memory.events 2>/dev/null || true)
if [[ "${oom_after}" =~ ^[0-9]+$ ]]; then
    test "${oom_after}" -gt "${oom_before}"
else
    if test "$("${runtime}" inspect --format '{{.State.OOMKilled}}' "${database}")" != true; then
        database_logs=$("${runtime}" logs "${database}" 2>&1)
        grep -Eq 'terminated by signal 9|out of memory|oom-kill' <<<"${database_logs}"
    fi
fi
if test "$("${runtime}" inspect --format '{{.State.Running}}' "${database}")" = true; then
    "${runtime}" exec "${database}" rm -f /tmp/memory-pressure || true
    wait_ready "${database}"
fi
"${runtime}" stop --time 30 "${database}" >/dev/null 2>&1 || true
"${runtime}" rm "${database}" >/dev/null

recovered="${prefix}-recovered"
run_limited "${recovered}"
wait_ready "${recovered}"
test "$("${runtime}" exec "${recovered}" psql -qAt --host=/tmp --username=postgres \
    --command='SELECT value FROM resource_probe;')" = 1

# A first initialization with too few inodes must fail closed with no fallback
# to another data path.
inode_limited="${prefix}-inode-limited"
remember "${inode_limited}"
"${runtime}" run --detach --name "${inode_limited}" \
    --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m,mode=1777 \
    --tmpfs /var/lib/pgsql:rw,nosuid,nodev,size=256m,nr_inodes=64,uid=26,gid=0,mode=0770 \
    --cap-drop ALL --security-opt "${no_new_privileges}" \
    --env "POSTGRES_PASSWORD=${password}" "${image}" >/dev/null
for _ in {1..60}; do
    test "$("${runtime}" inspect --format '{{.State.Running}}' "${inode_limited}")" = false && break
    sleep 1
done
test "$("${runtime}" inspect --format '{{.State.ExitCode}}' "${inode_limited}")" != 0
inode_logs=$("${runtime}" logs "${inode_limited}" 2>&1)
grep -Fq 'No space left on device' <<<"${inode_logs}"

echo "PostgreSQL resource-limit and recovery contract passed for ${image}"
