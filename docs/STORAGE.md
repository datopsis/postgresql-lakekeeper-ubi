# Storage and lifecycle

Provision one writable volume at /var/lib/pgsql; PGDATA defaults to its data
subdirectory. Preserve it across container replacement. The image initializes
only an empty directory, enables data checksums, rejects nonempty partial data,
symlinks, unwritable data and a PG_VERSION other than 18. A sibling initialization
lock prevents concurrent initialization; investigate partial data and any stale
lock before recovery. Never automatically delete or reinitialize it.

Run with a read-only root, bounded noexec/nosuid/nodev /tmp tmpfs, all capabilities
dropped and no-new-privileges. UID 26 or a nonzero arbitrary UID in GID 0 must be
able to write the volume. Prepare bind-mount ownership using the runtime's UID
mapping and appropriate SELinux labels; do not fix failures by running as root.
One server owns the volume. Validate storage fsync, locking and failure semantics.

SIGINT provides fast clean shutdown. Allow at least 30 seconds initially and
measure under load. Stop and remove only the container; recreate it with the
same volume. Existing data needs no bootstrap password. Crash recovery replays
WAL; verify application data after a forced stop or resource failure.

The inherited tests cover logical pg_dump/pg_restore into an isolated target,
row/content checks, crash recovery, capacity failures and an immutable PostgreSQL
18.4-to-18.6 compatibility fixture. This fixture is test-only, not a runtime
dependency or qualification of that image. Preserve compatible locales; the
cross-image fixture uses portable C with UTF-8 encoding.

Operators own backup scheduling, encryption, access, retention, globals/roles,
and restore exercises. Take a protected custom-format pg_dump using verified TLS
and a secret password file; retain its digest separately. Restore with
pg_restore --exit-on-error into an isolated empty database and validate schema,
roles, Lakekeeper migration state and representative transactions. A per-database
dump does not include all cluster globals. Keep Lakekeeper's encryption key
recoverable separately under its own secret policy.

Before minor updates, retain the old image and verified backup, test preserved
data and logical restoration, then replace the container while preserving storage.
Rollback requires a tested restore procedure; do not assume older binaries can
safely open data touched by newer ones. Major upgrades, HA and physical/PITR
products are outside this increment. See PostgreSQL's
[backup documentation](https://www.postgresql.org/docs/18/backup.html).
