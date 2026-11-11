# Extension boundary

The PGDG postgresql18-contrib RPM is locked by NEVRA, SHA-256 and full signing
fingerprint on both architectures. The builder verifies its signature before
installation and removes every non-allowlisted contrib file before final copy.
The RPM database still records the supplier package for SBOM/advisory attribution;
it does not imply that its removed features can be used.

## Retained

Exactly five add-ons: `uuid-ossp`, `pgcrypto`, `pg_trgm`, `btree_gin`, `btree_gist`.
Their control files, install/upgrade SQL and shared libraries are retained.
Core `plpgsql` is a separate server component required by initdb and remains
installed in template databases. Thus pg_available_extensions has exactly six
rows: five add-ons plus the core language. PL/pgSQL is not removed or recreated.

The build asserts this exact control-file set, allowed SQL prefixes, required
libraries and absence of every other contrib file, including build-ID links,
examples, command-line tools and modules without controls. A missing allowlisted
extension or unexpected server extension fails the build.

## Narrow contrib dependency exception

`postgresql18-contrib` is the only RPM installed with `--nodeps`, in a separate
transaction after the normally resolved and dependency-checked server/client
closure. The resolver excludes only this exact package name from dependency
resolution, while retaining its pinned RPM and source record. Every RPM,
including contrib, still undergoes hash, NEVRA and signature verification against
the approved full signing-key fingerprint before installation.

`python3-libs`, `python3-pip-wheel`, `python3-setuptools-wheel`, `sqlite-libs`
and `libxslt` are **not installed** and are absent from both architecture locks
and the final RPM database. They serve removed Python transforms, xml2 and their
transitive dependencies; none serves the retained five add-ons. This is not
post-install deletion of Python/wheel files or removal of RPM records.

The exception does not rewrite contrib's supplier metadata: its original RPM
requirements still describe the full upstream payload. Only that package is
excluded from the final RPM dependency verification. Every other installed
package must pass `rpm --verify --nofiles --noscript` with dependency checking
enabled, proving no other RPM requires an unavailable package/capability.

After pruning and final assembly, `verify-runtime-dependencies.sh` rejects any
of the five unwanted package names in the final RPM database. It runs `ldd`
inside the final root on `postgres`, the five retained extension libraries and
core `plpgsql.so`, rejecting command errors, empty output or `not found`.
Builder libraries cannot satisfy this check. The lock validator independently
rejects reintroduction of any of the five packages. Changes to the extension
allowlist or supplier dependencies require renewed native linkage and runtime
evidence; this exception must never expand silently to another package.

Native tests call uuid_generate_v4, pgcrypto digest and trigram similarity,
and build/write/query integer GIN and GiST indexes. These checks supplement
CREATE EXTENSION, hstore rejection and the full hardened runtime suite.

## Removed extensions

The following control/SQL extensions from PGDG 18.6 contrib are removed:

`amcheck`, `autoinc`, `bloom`, `citext`, `cube`, `dblink`, `dict_int`, `dict_xsyn`, `earthdistance`, `file_fdw`, `fuzzystrmatch`, `hstore`, `hstore_plperl`, `hstore_plperlu`, `insert_username`, `intagg`, `intarray`, `isn`, `jsonb_plperl`, `jsonb_plperlu`, `lo`, `ltree`, `moddatetime`, `pageinspect`, `pg_buffercache`, `pg_freespacemap`, `pg_logicalinspect`, `pg_prewarm`, `pg_stat_statements`, `pg_surgery`, `pg_visibility`, `pg_walinspect`, `pgrowlocks`, `pgstattuple`, `postgres_fdw`, `refint`, `seg`, `sslinfo`, `tablefunc`, `tcn`, `tsm_system_rows`, `tsm_system_time`, `unaccent`, `xml2`.

All non-allowlisted contrib libraries are also removed (some have different names
from their extension, or are loadable modules with no extension control):

`_int.so`, `amcheck.so`, `auth_delay.so`, `auto_explain.so`, `autoinc.so`, `basebackup_to_shell.so`, `basic_archive.so`, `bloom.so`, `citext.so`, `cube.so`, `dblink.so`, `earthdistance.so`, `file_fdw.so`, `fuzzystrmatch.so`, `hstore.so`, `hstore_plperl.so`, `hstore_plpython3.so`, `insert_username.so`, `isn.so`, `jsonb_plperl.so`, `jsonb_plpython3.so`, `lo.so`, `ltree.so`, `ltree_plpython3.so`, `moddatetime.so`, `pageinspect.so`, `passwordcheck.so`, `pg_buffercache.so`, `pg_freespacemap.so`, `pg_logicalinspect.so`, `pg_overexplain.so`, `pg_prewarm.so`, `pg_stat_statements.so`, `pg_surgery.so`, `pg_visibility.so`, `pg_walinspect.so`, `pgrowlocks.so`, `pgstattuple.so`, `pgxml.so`, `postgres_fdw.so`, `refint.so`, `seg.so`, `sepgsql.so`, `sslinfo.so`, `tablefunc.so`, `tcn.so`, `test_decoding.so`, `tsm_system_rows.so`, `tsm_system_time.so`, `unaccent.so`.

No extension installed from outside this image is supported. Do not restore a
general-purpose database that depends on removed extensions into this image.

## Explicit initialization

`init/lakekeeper-extensions.sql`, packaged as `/usr/share/lakekeeper/init.sql`,
creates the five in the selected database in one transaction, with
ON_ERROR_STOP and IF NOT EXISTS. Run it explicitly using the README command
against the Lakekeeper database. It does not create a database or role, grant
privileges, mutate templates, or migrate Lakekeeper's schema. The entrypoint
never calls it. Newly created databases receive only core PL/pgSQL until an
operator opts in. Native tests verify opt-in, idempotence, hstore rejection and
extension persistence after container replacement.

PGDG's [additional modules documentation](https://www.postgresql.org/docs/18/contrib.html)
describes the upstream features; their presence upstream is not support here.
