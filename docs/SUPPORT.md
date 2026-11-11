# Support boundary

The intended supported use is **Lakekeeper Iceberg catalog metadata only**, on
PostgreSQL 18 with uuid-ossp, pgcrypto, pg_trgm, btree_gin and btree_gist.
General-purpose use belongs in
[datopsis/postgresql-ubi](https://github.com/datopsis/postgresql-ubi), whose v1
contract intentionally excludes additional extensions. That repository remains
unchanged. Lakekeeper application data files live in object storage, not here.

No supported release exists. Source builds and passing PR CI are development
evidence, not a production support commitment. Native AMD64 and ARM64 are equal
image targets. Docker CI evidence does not qualify a rootless Podman/RHEL/SELinux
host or OpenShift restricted SCC. Arbitrary UID behavior is tested independently.

Supported-scope behavior to qualify: one instance and one durable volume;
SCRAM-SHA-256 network authentication; operator-mounted TLS 1.2/1.3; strict
operator-provided initialization credentials; explicit creation of the five
add-ons in the Lakekeeper database; logical dump/restore and minor-update
procedures inherited from the sibling design.

Out of scope: general-purpose databases, other extensions, HA/replication/pooling
products, major upgrades, physical backup/PITR product qualification, publication,
signing, tags, FIPS validation and STIG certification. PostgreSQL's built-in
PL/pgSQL is retained; it is not a sixth optional add-on. The image does not
provide Lakekeeper, migrate its schema, manage its roles, or store Iceberg data.

Operators own the host/runtime, network and certificate policy, durable storage,
secrets, role privileges, backup destinations, restore validation, capacity,
monitoring and incident response. Persistent storage alone is not a backup.
