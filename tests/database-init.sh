#!/usr/bin/env bash
set -Eeuo pipefail

runtime=${CONTAINER_RUNTIME:-podman}
image=${IMAGE:-localhost/postgresql-lakekeeper-ubi:development}
prefix="postgresql-lakekeeper-ubi-database-${RANDOM}-$$"
password='Database init !@#$%^&*() test'
containers=()
volumes=()
no_new_privileges=no-new-privileges:true
if grep -qi podman <<<"$("${runtime}" --version 2>&1)"; then
    no_new_privileges=no-new-privileges
fi

cleanup() {
    if test "${#containers[@]}" -gt 0; then
        "${runtime}" rm --force --volumes "${containers[@]}" >/dev/null 2>&1 || true
    fi
    if test "${#volumes[@]}" -gt 0; then
        "${runtime}" volume rm --force "${volumes[@]}" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT
trap 'printf "database-init failed at line %s\n" "${LINENO}" >&2' ERR

start() {
    local name=$1 volume=$2
    shift 2
    containers+=("${name}")
    "${runtime}" run --detach --name "${name}" \
        --read-only --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m,mode=1777 \
        --mount "type=volume,src=${volume},dst=/var/lib/pgsql" \
        --cap-drop ALL --security-opt "${no_new_privileges}" \
        "$@" "${image}" >/dev/null
}

sql() {
    local database=$1 command=$2
    "${runtime}" exec --env "PGPASSWORD=${password}" "${name}" \
        psql -XqAt --set=ON_ERROR_STOP=1 --host=127.0.0.1 \
        --username="${user}" --dbname="${database}" --command="${command}"
}

wait_ready() {
    local attempt
    for attempt in {1..90}; do
        if test "$(sql postgres 'SELECT 1' 2>/dev/null)" = 1; then
            return
        fi
        if test "$("${runtime}" inspect --format '{{.State.Running}}' "${name}")" != true; then
            break
        fi
        sleep 1
    done
    "${runtime}" logs "${name}" >&2
    return 1
}

for scenario in unset equal different postgres quoted; do
    name="${prefix}-${scenario}"
    volume="${name}-data"
    volumes+=("${volume}")
    "${runtime}" volume create "${volume}" >/dev/null
    user=rauthy
    options=()
    case "${scenario}" in
        unset) database=${user} ;;
        equal) database=${user}; options+=(--env "POSTGRES_DB=${database}") ;;
        different) database=lakekeeper; options+=(--env "POSTGRES_DB=${database}") ;;
        postgres) database=postgres; options+=(--env "POSTGRES_DB=${database}") ;;
        quoted)
            user='role " with spaces'
            database='database " with spaces'
            options+=(--env "POSTGRES_DB=${database}")
            ;;
    esac
    start "${name}" "${volume}" --env "POSTGRES_USER=${user}" \
        --env "POSTGRES_PASSWORD=${password}" "${options[@]}"
    wait_ready
    test "$(sql "${database}" 'SELECT current_database()')" = "${database}"
    test "$(sql "${database}" 'SELECT current_user')" = "${user}"
    test "$(sql "${database}" 'SELECT pg_get_userbyid(datdba) = current_user FROM pg_database WHERE datname = current_database()')" = t
    expected_count=4
    if test "${scenario}" = postgres; then expected_count=3; fi
    test "$(sql postgres 'SELECT count(*) FROM pg_database')" = "${expected_count}"
    sql "${database}" 'CREATE TABLE restart_probe AS SELECT 42 AS value' >/dev/null
    "${runtime}" stop --time 30 "${name}" >/dev/null
    "${runtime}" rm "${name}" >/dev/null
    name="${name}-restart"
    # Existing data must need no bootstrap credential and must ignore POSTGRES_DB.
    start "${name}" "${volume}" --env "POSTGRES_USER=${user}" \
        --env POSTGRES_DB=restart_must_not_be_created
    wait_ready
    test "$(sql "${database}" 'SELECT value FROM restart_probe')" = 42
    test "$(sql postgres 'SELECT count(*) FROM pg_database')" = "${expected_count}"
    "${runtime}" stop --time 30 "${name}" >/dev/null
    echo "database-init: ${scenario} fresh init, owner, authenticated connection and existing-data restart passed"
done

echo "PostgreSQL database initialization contract passed for ${image}"
