# syntax=docker/dockerfile:1.7

ARG UBI_MINIMAL_IMAGE="registry.access.redhat.com/ubi9/ubi-minimal:9.9@sha256:baafce2d34783a28b4a472779f304e97e00f9d35c99553bc53b068b14344d9a9"
ARG UBI_MICRO_IMAGE="registry.access.redhat.com/ubi9/ubi-micro:9.9@sha256:dbd325b96bcd432dd42816d31412bdf1dc0fb973b79ed310344bc23c76c068db"

FROM ${UBI_MICRO_IMAGE} AS runtime-base

FROM ${UBI_MINIMAL_IMAGE} AS builder

ARG TARGETARCH
ARG ARTIFACT_LOCK_SHA256
COPY .artifact-bundle/${TARGETARCH}/ /tmp/artifacts/
COPY --chmod=0755 scripts/verify-rpm-bundle.sh /usr/local/bin/verify-rpm-bundle
COPY --chmod=0755 scripts/prune-extensions.sh /usr/local/bin/prune-extensions
COPY --chmod=0755 scripts/install-runtime-rpms.sh /usr/local/bin/install-runtime-rpms
COPY --chmod=0755 scripts/verify-runtime-dependencies.sh /usr/local/bin/verify-runtime-dependencies
COPY --from=runtime-base / /final/
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# The bundle is acquired and hash/fingerprint verified before this build. The
# build rechecks its selected lock, exact RPM metadata, and signatures without
# contacting repositories or resolving dependencies.
RUN test -n "${ARTIFACT_LOCK_SHA256}" \
    && test "$(cat /tmp/artifacts/LOCK-SHA256)" = "${ARTIFACT_LOCK_SHA256}" \
    && verify-rpm-bundle /tmp/artifacts \
    && mkdir -p /runtime \
    && rpm --root /runtime --initdb \
    && rpm --root /runtime --import /tmp/artifacts/keys/* \
    && install-runtime-rpms /runtime /tmp/artifacts/rpms \
    && rpm --root /runtime --query --all \
        --qf '%{NAME}-%{VERSION}-%{RELEASE}\n' \
        | sed -n '/^gpg-pubkey-/p' > /tmp/imported-keys \
    && while IFS= read -r key; do \
        rpm --root /runtime --erase "${key}"; \
    done < /tmp/imported-keys \
    && prune-extensions /runtime \
    && cp -a /runtime/. /final/ \
    && rm -rf \
        /final/etc/dnf \
        /final/etc/pki/entitlement \
        /final/etc/pki/rpm-gpg \
        /final/etc/rhsm \
        /final/etc/yum.repos.d \
        /final/run/* \
        /final/tmp/* \
        /final/var/cache/dnf \
        /final/var/cache/yum \
        /final/var/lib/rhsm \
        /final/var/log/* \
        /final/var/tmp/* \
    && find /final -xdev -type f -perm /6000 -exec chmod a-s {} + \
    && ! find /final -xdev -type f -perm -0002 -print -quit | grep -q . \
    && mkdir -p /final/var/lib/pgsql \
    && chown -R 26:0 /final/var/lib/pgsql \
    && chmod 2775 /final/var/lib/pgsql \
    && verify-runtime-dependencies /final

FROM scratch

ARG UBI_MINIMAL_IMAGE
ARG UBI_MICRO_IMAGE
ARG POSTGRESQL_VERSION="18.6"
ARG POSTGRESQL_RPM_VERSION="18.6-1PGDG.rhel9.8"
ARG POSTGRESQL_PUBLISHER="PostgreSQL Global Development Group (PGDG)"
ARG POSTGRESQL_SIGNER_FINGERPRINT="unknown"
ARG ARTIFACT_LOCK_SHA256
ARG RELEASE_VERSION="development"
ARG RELEASE_REVISION="unknown"
ARG RELEASE_CREATED="1970-01-01T00:00:00Z"
ARG RELEASE_SOURCE="https://github.com/datopsis/postgresql-lakekeeper-ubi"

LABEL org.opencontainers.image.title="PostgreSQL for Lakekeeper on Red Hat UBI 9" \
      org.opencontainers.image.description="Rootless PostgreSQL for Lakekeeper metadata with five allowlisted extensions on UBI 9 Micro" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.vendor="Datopsis" \
      org.opencontainers.image.version="${RELEASE_VERSION}" \
      org.opencontainers.image.revision="${RELEASE_REVISION}" \
      org.opencontainers.image.created="${RELEASE_CREATED}" \
      org.opencontainers.image.source="${RELEASE_SOURCE}" \
      org.opencontainers.image.url="${RELEASE_SOURCE}" \
      org.opencontainers.image.documentation="${RELEASE_SOURCE}/blob/${RELEASE_REVISION}/README.md" \
      io.datopsis.postgresql.rpm-version="${POSTGRESQL_RPM_VERSION}" \
      io.datopsis.postgresql.version="${POSTGRESQL_VERSION}" \
      io.datopsis.postgresql.publisher="${POSTGRESQL_PUBLISHER}" \
      io.datopsis.postgresql.signing-key-fingerprint="${POSTGRESQL_SIGNER_FINGERPRINT}" \
      io.datopsis.ubi.builder="${UBI_MINIMAL_IMAGE}" \
      io.datopsis.ubi.runtime="${UBI_MICRO_IMAGE}" \
      io.datopsis.artifact-lock.sha256="${ARTIFACT_LOCK_SHA256}"

COPY --from=builder /final/ /
COPY --chown=0:0 --chmod=0755 container/entrypoint.sh /usr/local/bin/postgresql-entrypoint

COPY --chown=0:0 --chmod=0644 init/lakekeeper-extensions.sql /usr/share/lakekeeper/init.sql

ENV LANG="C.UTF-8" \
    TZ="UTC" \
    PATH="/usr/pgsql-18/bin:${PATH}" \
    PGDATA="/var/lib/pgsql/data" \
    POSTGRES_USER="postgres"

VOLUME ["/var/lib/pgsql"]

USER 26:0
WORKDIR /var/lib/pgsql

EXPOSE 5432

HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=5 \
  CMD ["/usr/pgsql-18/bin/pg_isready", "--quiet", "--host=/tmp", "--timeout=3"]

STOPSIGNAL SIGINT

ENTRYPOINT ["postgresql-entrypoint"]
CMD ["postgres"]
