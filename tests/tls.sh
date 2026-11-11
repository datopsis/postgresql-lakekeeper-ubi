#!/usr/bin/env bash
set -Eeuo pipefail

runtime=${CONTAINER_RUNTIME:-podman}
image=${IMAGE:-localhost/postgresql-lakekeeper-ubi:development}
prefix="postgresql-lakekeeper-ubi-tls-${RANDOM}-$$"
password="tls-${RANDOM}-OnlyForTesting"
data_volume="${prefix}-data"
tls_volume="${prefix}-material"
container="${prefix}-server"
fixture=$(mktemp -d)
no_new_privileges=no-new-privileges:true

if grep -qi podman <<<"$("${runtime}" --version 2>&1)"; then
    no_new_privileges=no-new-privileges
fi

cleanup() {
    "${runtime}" rm --force --volumes "${container}" >/dev/null 2>&1 || true
    "${runtime}" volume rm --force "${data_volume}" "${tls_volume}" >/dev/null 2>&1 || true
    rm -rf -- "${fixture}"
}
trap cleanup EXIT
report_error() {
    failure_status=$?
    printf 'tls test failed at line %s\n' "${BASH_LINENO[0]}" >&2
    exit "${failure_status}"
}
trap report_error ERR

make_ca() {
    local stem=$1
    openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 2 \
        -subj "/CN=${stem} test CA" \
        -keyout "${fixture}/${stem}-ca.key" \
        -out "${fixture}/${stem}-ca.crt" >/dev/null 2>&1
}

make_server() {
    local stem=$1
    local ca=$2
    local serial=$3
    openssl req -newkey rsa:3072 -nodes -sha256 \
        -subj '/CN=localhost' \
        -addext 'subjectAltName=DNS:localhost' \
        -keyout "${fixture}/${stem}.key" \
        -out "${fixture}/${stem}.csr" >/dev/null 2>&1
    printf 'subjectAltName=DNS:localhost\nextendedKeyUsage=serverAuth\n' >"${fixture}/${stem}.ext"
    openssl x509 -req -sha256 -days 2 -set_serial "${serial}" \
        -in "${fixture}/${stem}.csr" \
        -CA "${fixture}/${ca}-ca.crt" \
        -CAkey "${fixture}/${ca}-ca.key" \
        -out "${fixture}/${stem}.crt" \
        -extfile "${fixture}/${stem}.ext" >/dev/null 2>&1
}

copy_material() {
    local stem=$1
    # Positional parameters expand inside the copy container.
    # shellcheck disable=SC2016
    "${runtime}" run --rm --user 0 \
        --mount "type=bind,src=${fixture},dst=/source,readonly" \
        --mount "type=volume,src=${tls_volume},dst=/tls" \
        --entrypoint sh "${image}" -ceu '
            cp "/source/$1.crt" /tls/server.crt
            cp "/source/$1.key" /tls/server.key
            cp /source/trusted-ca.crt /tls/ca.crt
            cp /source/untrusted-ca.crt /tls/untrusted-ca.crt
            chown 0:0 /tls/*
            chmod 0444 /tls/*.crt
            chmod 0440 /tls/server.key
        ' sh "${stem}"
}

wait_tls() {
    local _
    for _ in {1..90}; do
        if "${runtime}" exec --env "PGPASSWORD=${password}" "${container}" \
            psql -qAt 'host=localhost user=postgres dbname=postgres sslmode=verify-full sslrootcert=/run/tls/ca.crt connect_timeout=2' \
            --command='SELECT 1' >/dev/null 2>&1; then
            return
        fi
        sleep 1
    done
    "${runtime}" logs "${container}" >&2
    return 1
}

served_serial() {
    "${runtime}" exec "${container}" sh -c \
        "openssl s_client -starttls postgres -connect localhost:5432 </dev/null 2>/dev/null | openssl x509 -noout -serial" \
        | tr -d '\r'
}

make_ca trusted
make_ca untrusted
make_server server-one trusted 1001
make_server server-two trusted 1002

cp "${fixture}/trusted-ca.crt" "${fixture}/trusted-ca-copy.crt"
cp "${fixture}/untrusted-ca.crt" "${fixture}/untrusted-ca-copy.crt"
mv "${fixture}/trusted-ca-copy.crt" "${fixture}/trusted-ca.crt"
mv "${fixture}/untrusted-ca-copy.crt" "${fixture}/untrusted-ca.crt"

# The same valid fixture is rejected outside its validity interval.
not_before=$(date -u -d '1 day ago' +%s)
after_expiry=$(date -u -d '4 days' +%s)
if openssl verify -attime "${not_before}" -CAfile "${fixture}/trusted-ca.crt" \
    "${fixture}/server-one.crt" >/dev/null 2>&1; then
    echo 'not-yet-valid certificate fixture was accepted' >&2
    exit 1
fi
if openssl verify -attime "${after_expiry}" -CAfile "${fixture}/trusted-ca.crt" \
    "${fixture}/server-one.crt" >/dev/null 2>&1; then
    echo 'expired certificate fixture was accepted' >&2
    exit 1
fi

"${runtime}" volume create "${data_volume}" >/dev/null
"${runtime}" volume create "${tls_volume}" >/dev/null
copy_material server-one

"${runtime}" run --detach --name "${container}" \
    --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m,mode=1777 \
    --mount "type=volume,src=${data_volume},dst=/var/lib/pgsql" \
    --mount "type=volume,src=${tls_volume},dst=/run/tls,readonly" \
    --cap-drop ALL \
    --security-opt "${no_new_privileges}" \
    --env "POSTGRES_PASSWORD=${password}" \
    --env POSTGRESQL_TLS_CERT_FILE=/run/tls/server.crt \
    --env POSTGRESQL_TLS_KEY_FILE=/run/tls/server.key \
    "${image}" >/dev/null
wait_tls

test "$("${runtime}" exec --env "PGPASSWORD=${password}" "${container}" \
    psql -qAt 'host=localhost user=postgres dbname=postgres sslmode=verify-full sslrootcert=/run/tls/ca.crt' \
    --command="SELECT ssl || '|' || version FROM pg_stat_ssl WHERE pid=pg_backend_pid();")" = 'true|TLSv1.3' || \
test "$("${runtime}" exec --env "PGPASSWORD=${password}" "${container}" \
    psql -qAt 'host=localhost user=postgres dbname=postgres sslmode=verify-full sslrootcert=/run/tls/ca.crt' \
    --command="SELECT ssl || '|' || version FROM pg_stat_ssl WHERE pid=pg_backend_pid();")" = 'true|TLSv1.2'

if "${runtime}" exec --env "PGPASSWORD=${password}" "${container}" \
    psql -qAt 'host=localhost user=postgres dbname=postgres sslmode=disable connect_timeout=2' \
    --command='SELECT 1' >/dev/null 2>&1; then
    echo 'clear-text network connection was accepted by the TLS profile' >&2
    exit 1
fi
if "${runtime}" exec --env "PGPASSWORD=${password}" "${container}" \
    psql -qAt 'host=127.0.0.1 user=postgres dbname=postgres sslmode=verify-full sslrootcert=/run/tls/ca.crt connect_timeout=2' \
    --command='SELECT 1' >/dev/null 2>&1; then
    echo 'certificate hostname mismatch was accepted' >&2
    exit 1
fi
if "${runtime}" exec --env "PGPASSWORD=${password}" "${container}" \
    psql -qAt 'host=localhost user=postgres dbname=postgres sslmode=verify-full sslrootcert=/run/tls/untrusted-ca.crt connect_timeout=2' \
    --command='SELECT 1' >/dev/null 2>&1; then
    echo 'untrusted certificate chain was accepted' >&2
    exit 1
fi

test "$(served_serial)" = serial=03E9
copy_material server-two
"${runtime}" kill --signal HUP "${container}" >/dev/null
sleep 2
test "$(served_serial)" = serial=03EA
wait_tls
copy_material server-one
"${runtime}" kill --signal HUP "${container}" >/dev/null
sleep 2
test "$(served_serial)" = serial=03E9
wait_tls

# PGDATA expands inside the database container.
# shellcheck disable=SC2016
test "$("${runtime}" exec "${container}" sh -c 'cat "$PGDATA/pg_hba.conf"')" = \
"# Managed by postgresql-lakekeeper-ubi; replaced on every start.
local all all trust
hostssl all all 0.0.0.0/0 scram-sha-256
hostssl all all ::/0 scram-sha-256"

echo "PostgreSQL TLS 1.2/1.3 server profile passed for ${image}"
