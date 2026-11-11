#!/bin/sh
set -eu

postgres_major=18
initialization_lock=
password_file=

fatal() {
    printf 'postgresql-entrypoint: %s\n' "$*" >&2
    exit 1
}

cleanup_initialization() {
    test -z "${password_file}" || rm -f -- "${password_file}"
    test -z "${initialization_lock}" || rmdir -- "${initialization_lock}" 2>/dev/null || true
}

on_initialization_signal() {
    cleanup_initialization
    trap - EXIT HUP INT TERM
    exit 1
}

reject_line_breaks() {
    value=$1
    label=$2
    newline='
'
    carriage_return=$(printf '\r')
    case "${value}" in
        *"${newline}"*|*"${carriage_return}"*) fatal "${label} must not contain line breaks" ;;
    esac
}

require_regular_file() {
    path=$1
    label=$2
    test ! -L "${path}" || fatal "${label} must not be a symbolic link"
    test -f "${path}" || fatal "${label} must be a regular file"
    test -r "${path}" || fatal "${label} is not readable"
}

require_secret_permissions() {
    path=$1
    label=$2
    permissions=$(stat -c '%a' "${path}")
    owner=$(stat -c '%u' "${path}")
    group=$(stat -c '%g' "${path}")

    case "${permissions}" in
        400|440|600|640) ;;
        *) fatal "${label} permissions must be 0400, 0440, 0600, or 0640" ;;
    esac
    current_uid=$(id -u)
    test "${owner}" = 0 || test "${owner}" = "${current_uid}" || \
        fatal "${label} must be owned by UID 0 or the runtime UID"
    case "${permissions}" in
        440|640)
            test "${group}" = 0 || \
                fatal "${label} group-readable files must be owned by GID 0"
            ;;
    esac
}

require_public_file_permissions() {
    path=$1
    label=$2
    permissions=$(stat -c '%a' "${path}")
    test $((0${permissions} & 07022)) -eq 0 || \
        fatal "${label} must not be group/other writable or have special permission bits"
}

configure_arbitrary_uid() {
    if id -un >/dev/null 2>&1; then
        return
    fi

    wrapper=/usr/lib64/libnss_wrapper.so
    test -r "${wrapper}" || fatal "current UID is unknown and nss_wrapper is unavailable"

    passwd_file=/tmp/postgresql-passwd
    cp /etc/passwd "${passwd_file}"
    printf 'postgres:x:%s:0:PostgreSQL Server:%s:/sbin/nologin\n' \
        "$(id -u)" "${PGDATA}" >>"${passwd_file}"
    export NSS_WRAPPER_PASSWD="${passwd_file}"
    export NSS_WRAPPER_GROUP=/etc/group
    export LD_PRELOAD="${wrapper}${LD_PRELOAD:+:${LD_PRELOAD}}"
}

read_initial_password() {
    if test -n "${POSTGRES_PASSWORD:-}" && test -n "${POSTGRES_PASSWORD_FILE:-}"; then
        fatal "set only one of POSTGRES_PASSWORD or POSTGRES_PASSWORD_FILE"
    fi

    if test -n "${POSTGRES_PASSWORD_FILE:-}"; then
        require_regular_file "${POSTGRES_PASSWORD_FILE}" POSTGRES_PASSWORD_FILE
        require_secret_permissions "${POSTGRES_PASSWORD_FILE}" POSTGRES_PASSWORD_FILE
        password_lines=$(wc -l <"${POSTGRES_PASSWORD_FILE}")
        test "${password_lines}" -eq 0 || \
            fatal "POSTGRES_PASSWORD_FILE must contain exactly one value without a line break"
        POSTGRES_PASSWORD=$(cat -- "${POSTGRES_PASSWORD_FILE}")
    fi

    test -n "${POSTGRES_PASSWORD:-}" || \
        fatal "initialization requires POSTGRES_PASSWORD or POSTGRES_PASSWORD_FILE"
    reject_line_breaks "${POSTGRES_PASSWORD}" POSTGRES_PASSWORD
}

write_host_authentication() {
    umask 077
    {
        printf '# Managed by postgresql-lakekeeper-ubi; replaced on every start.\n'
        printf 'local all all trust\n'
        if test -n "${POSTGRESQL_TLS_CERT_FILE:-}"; then
            printf 'hostssl all all 0.0.0.0/0 scram-sha-256\n'
            printf 'hostssl all all ::/0 scram-sha-256\n'
        else
            printf 'host all all 0.0.0.0/0 scram-sha-256\n'
            printf 'host all all ::/0 scram-sha-256\n'
        fi
    } >"${PGDATA}/pg_hba.conf"
}

initialize_database() {
    read_initial_password
    initialization_lock="${PGDATA}.postgresql-lakekeeper-ubi.init.lock"
    mkdir -- "${initialization_lock}" 2>/dev/null || \
        fatal "initialization is already running or a stale initialization lock exists: ${initialization_lock}"
    umask 077
    password_file="/tmp/postgresql-password.$$"
    printf '%s' "${POSTGRES_PASSWORD}" >"${password_file}"
    trap cleanup_initialization EXIT
    trap on_initialization_signal HUP INT TERM

    initdb \
        --pgdata="${PGDATA}" \
        --username="${POSTGRES_USER}" \
        --pwfile="${password_file}" \
        --auth-host=scram-sha-256 \
        --auth-local=trust \
        --data-checksums \
        --encoding=UTF8

    write_host_authentication

    pg_ctl --pgdata="${PGDATA}" \
        --options="-c listen_addresses='' -c unix_socket_directories=/tmp -c password_encryption=scram-sha-256 -c hba_file=${PGDATA}/pg_hba.conf -c logging_collector=off" \
        --wait start

    database=${POSTGRES_DB:-${POSTGRES_USER}}
    reject_line_breaks "${database}" POSTGRES_DB
    if test "${database}" != "${POSTGRES_USER}"; then
        createdb --host=/tmp --username="${POSTGRES_USER}" -- "${database}"
    fi

    pg_ctl --pgdata="${PGDATA}" --mode=fast --wait stop
    cleanup_initialization
    initialization_lock=
    password_file=
    trap - EXIT HUP INT TERM
    unset POSTGRES_PASSWORD
}

validate_runtime_files() {
    if test -n "${POSTGRESQL_CONFIG_FILE:-}"; then
        require_regular_file "${POSTGRESQL_CONFIG_FILE}" POSTGRESQL_CONFIG_FILE
        require_public_file_permissions "${POSTGRESQL_CONFIG_FILE}" POSTGRESQL_CONFIG_FILE
    fi

    if test -n "${POSTGRESQL_TLS_CERT_FILE:-}" || test -n "${POSTGRESQL_TLS_KEY_FILE:-}"; then
        test -n "${POSTGRESQL_TLS_CERT_FILE:-}" && test -n "${POSTGRESQL_TLS_KEY_FILE:-}" || \
            fatal "set both POSTGRESQL_TLS_CERT_FILE and POSTGRESQL_TLS_KEY_FILE"
        require_regular_file "${POSTGRESQL_TLS_CERT_FILE}" POSTGRESQL_TLS_CERT_FILE
        require_public_file_permissions "${POSTGRESQL_TLS_CERT_FILE}" POSTGRESQL_TLS_CERT_FILE
        require_regular_file "${POSTGRESQL_TLS_KEY_FILE}" POSTGRESQL_TLS_KEY_FILE
        require_secret_permissions "${POSTGRESQL_TLS_KEY_FILE}" POSTGRESQL_TLS_KEY_FILE
    fi
}

if test "${1:-}" = postgres; then
    # Supported by the UBI /bin/sh; POSIX leaves ulimit options unspecified.
    # shellcheck disable=SC3045
    ulimit -c 0 || fatal "cannot disable core dumps"
    reject_line_breaks "${POSTGRES_USER}" POSTGRES_USER
    configure_arbitrary_uid
    test ! -L "${PGDATA}" || fatal "PGDATA must not be a symbolic link"
    mkdir -p -- "${PGDATA}" 2>/dev/null || fatal "cannot create PGDATA: ${PGDATA}"
    test -d "${PGDATA}" || fatal "PGDATA is not a directory: ${PGDATA}"
    test -w "${PGDATA}" || fatal "PGDATA is not writable: ${PGDATA}"
    writability_probe="${PGDATA}/.postgresql-lakekeeper-ubi-write-test.$$"
    (umask 077 && : >"${writability_probe}") 2>/dev/null || \
        fatal "PGDATA cannot accept a validation write: ${PGDATA}"
    rm -f -- "${writability_probe}" || \
        fatal "PGDATA validation file cannot be removed: ${PGDATA}"

    if test ! -s "${PGDATA}/PG_VERSION"; then
        if test -n "$(find "${PGDATA}" -mindepth 1 -maxdepth 1 -print -quit)"; then
            fatal "PGDATA is non-empty but has no PG_VERSION file; refusing automatic recovery or reinitialization"
        fi
        initialize_database
    else
        installed_major=$(cat "${PGDATA}/PG_VERSION")
        test "${installed_major}" = "${postgres_major}" || \
            fatal "PGDATA major ${installed_major} is incompatible with PostgreSQL ${postgres_major}"
        write_host_authentication
    fi

    unset POSTGRES_PASSWORD POSTGRES_PASSWORD_FILE
    validate_runtime_files

    if test -n "${POSTGRESQL_CONFIG_FILE:-}"; then
        set -- "$@" -c "config_file=${POSTGRESQL_CONFIG_FILE}"
    fi
    if test -n "${POSTGRESQL_TLS_CERT_FILE:-}"; then
        set -- "$@" \
            -c ssl=on \
            -c "ssl_cert_file=${POSTGRESQL_TLS_CERT_FILE}" \
            -c "ssl_key_file=${POSTGRESQL_TLS_KEY_FILE}" \
            -c ssl_min_protocol_version=TLSv1.2 \
            -c ssl_max_protocol_version=TLSv1.3
    else
        set -- "$@" -c ssl=off
    fi
    set -- "$@" \
        -c "data_directory=${PGDATA}" \
        -c listen_addresses='*' \
        -c port=5432 \
        -c password_encryption=scram-sha-256 \
        -c "hba_file=${PGDATA}/pg_hba.conf" \
        -c unix_socket_directories=/tmp \
        -c logging_collector=off \
        -c log_destination=stderr \
        -c log_statement=none \
        -c log_min_duration_statement=-1 \
        -c log_parameter_max_length=0 \
        -c log_parameter_max_length_on_error=0 \
        -c log_connections=on \
        -c log_disconnections=on \
        -c log_checkpoints=on
fi

exec "$@"
