#!/usr/bin/env bash
set -Eeuo pipefail

runtime=${CONTAINER_RUNTIME:-podman}
image=${IMAGE:-localhost/postgresql-lakekeeper-ubi:development}
prefix="postgresql-lakekeeper-ubi-update-${RANDOM}-$$"
password="update-${RANDOM}-OnlyForTesting"
volume="${prefix}-data"
backup_volume="${prefix}-backup"
old_container="${prefix}-18-4"
new_container="${prefix}-18-6"

case "$(uname -m)" in
    x86_64)
        previous_image='docker.io/library/postgres@sha256:4cc13dede823cab4e05290c7fb3350fb4e599ecabd9b07e6706b5d5e8f5bc929'
        expected_architecture=amd64
        ;;
    aarch64|arm64)
        previous_image='docker.io/library/postgres@sha256:0826e5f2996099babb925e09fb72bf2c6eb5d187cfcae20aa9291af1612307e4'
        expected_architecture=arm64
        ;;
    *)
        echo "unsupported update-fixture architecture: $(uname -m)" >&2
        exit 1
        ;;
esac

cleanup() {
    "${runtime}" rm --force --volumes "${old_container}" "${new_container}" >/dev/null 2>&1 || true
    "${runtime}" volume rm --force "${volume}" "${backup_volume}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
report_error() {
    failure_status=$?
    printf 'minor-update failed at line %s\n' "${BASH_LINENO[0]}" >&2
    exit "${failure_status}"
}
trap report_error ERR

wait_ready() {
    local name=$1
    local version=$2
    local _
    for _ in {1..120}; do
        if test "$("${runtime}" exec --env "PGPASSWORD=${password}" "${name}" \
            psql -qAt --host=127.0.0.1 --username=postgres --dbname=postgres \
            --command='SHOW server_version_num;' 2>/dev/null || true)" = "${version}"; then
            return
        fi
        sleep 1
    done
    "${runtime}" logs "${name}" >&2
    return 1
}

"${runtime}" pull "${previous_image}"
test "$("${runtime}" image inspect --format '{{.Architecture}}' "${previous_image}")" = \
    "${expected_architecture}"
"${runtime}" volume create "${volume}" >/dev/null
"${runtime}" volume create "${backup_volume}" >/dev/null

"${runtime}" run --detach --name "${old_container}" \
    --mount "type=volume,src=${volume},dst=/var/lib/postgresql" \
    --mount "type=volume,src=${backup_volume},dst=/backup" \
    --env "POSTGRES_PASSWORD=${password}" \
    --env 'POSTGRES_INITDB_ARGS=--locale=C --encoding=UTF8 --data-checksums' \
    "${previous_image}" >/dev/null
wait_ready "${old_container}" 180004
# Docker exec defaults to root in the official fixture; inspect PostgreSQL PID
# 1 to verify the actual server identity.
# The awk fields expand inside the fixture container.
# shellcheck disable=SC2016
test "$("${runtime}" exec "${old_container}" awk '/^Uid:/ { print $2 }' \
    /proc/1/status)" = 999
# PGDATA expands inside the compatibility-fixture container.
# shellcheck disable=SC2016
test "$("${runtime}" exec "${old_container}" sh -c 'printf %s "$PGDATA"')" = \
    /var/lib/postgresql/18/docker
"${runtime}" exec "${old_container}" psql --host=/var/run/postgresql \
    --username=postgres --set=ON_ERROR_STOP=1 \
    --command='CREATE TABLE update_fixture(id integer PRIMARY KEY, payload text NOT NULL);' \
    --command="INSERT INTO update_fixture SELECT i, md5(i::text) FROM generate_series(1, 1000) AS i;" >/dev/null
fixture_digest=$("${runtime}" exec "${old_container}" psql -qAt --host=/var/run/postgresql \
    --username=postgres \
    --command="SELECT md5(string_agg(id || ':' || payload, ',' ORDER BY id)) FROM update_fixture;")
"${runtime}" exec --user 0 "${old_container}" sh -c \
    'chown 999:0 /backup; chmod 0770 /backup'
"${runtime}" exec "${old_container}" pg_dump --host=/var/run/postgresql \
    --username=postgres --format=custom --file=/backup/pre-update.dump postgres
"${runtime}" exec --user 0 "${old_container}" sh -c \
    'test -s /backup/pre-update.dump; chown 999:0 /backup/pre-update.dump; chmod 0440 /backup/pre-update.dump'
"${runtime}" stop --time 30 "${old_container}" >/dev/null
"${runtime}" rm "${old_container}" >/dev/null

# Adapt only the official image's versioned mount layout.
# shellcheck disable=SC2016
"${runtime}" run --rm --user 0 \
    --mount "type=volume,src=${volume},dst=/var/lib/pgsql" \
    --entrypoint sh "${image}" -ceu '
        test "$(cat /var/lib/pgsql/18/docker/PG_VERSION)" = 18
        test ! -e /var/lib/pgsql/data
        mv /var/lib/pgsql/18/docker /var/lib/pgsql/data
        rmdir /var/lib/pgsql/18
        chown -R 26:0 /var/lib/pgsql/data
        chmod 0700 /var/lib/pgsql/data
    '

"${runtime}" run --detach --name "${new_container}" \
    --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m,mode=1777 \
    --mount "type=volume,src=${volume},dst=/var/lib/pgsql" \
    --mount "type=volume,src=${backup_volume},dst=/backup,readonly" \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    "${image}" >/dev/null
wait_ready "${new_container}" 180006
test "$("${runtime}" exec "${new_container}" psql -qAt --host=/tmp --username=postgres \
    --command='SELECT count(*) FROM update_fixture;')" = 1000
test "$("${runtime}" exec "${new_container}" psql -qAt --host=/tmp --username=postgres \
    --command="SELECT md5(string_agg(id || ':' || payload, ',' ORDER BY id)) FROM update_fixture;")" = \
    "${fixture_digest}"
"${runtime}" exec "${new_container}" pg_dump --host=/tmp --username=postgres \
    --format=custom --file=/tmp/post-update.dump postgres
"${runtime}" exec "${new_container}" sh -c 'test -s /tmp/post-update.dump; test -s /backup/pre-update.dump'

echo "PostgreSQL 18.4 to 18.6 preserved-data update passed for ${image}"
