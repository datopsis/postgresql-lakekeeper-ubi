# Security policy

No supported image has been published. Development images are for evaluation.
Report suspected vulnerabilities privately through the repository's Security
advisory reporting interface when available, or an established private channel
to the Datopsis maintainers. Do not post sensitive details in public issues.
Private vulnerability reporting is an owner-managed setting; this increment
does not enable or change it.

Include commit/image digest, architecture, runtime/host version, configuration
and a sanitized reproduction. Never include credentials, private keys or data.
Upstream reports follow [PostgreSQL](https://www.postgresql.org/support/security/)
or [Red Hat](https://access.redhat.com/security/team/contact) disclosure procedures.

The maintainer triages supplier advisories and both scanner reports. Under the
owner-approved UBI availability rule, a vendor-fixed High/Critical RPM finding
blocks when a package version at least as new as the vendor fix is available
from the UBI repositories used to resolve this image's locks, on its native
architecture. There are no CVE, package or date exemptions.

CI copies repository files from the exact digest-pinned builder recorded in
each architecture lock before installing query tools. DNF queries fresh metadata
with the same releasever=9 and enabled UBI repositories as the lock resolver;
repository skipping is disabled. RPM's own epoch/version/release comparison
handles vendor fixed versions. Both the native architecture and noarch packages
are considered. Availability is defined by this repository query, not by an
advisory for a different RHEL channel. Offline assembly remains unchanged.

Only a successful query proving no qualifying RPM version exists may defer a
finding. Non-RPM findings, unverified package identities, malformed versions,
missing repositories, query errors and timeouts retain blocking behavior.
Missing or malformed scanner reports fail closed. A deferred vulnerability is
still present: it is printed with its vendor fixed version in the job summary
and retained in complete scanner JSON and gate evidence, including repository
file hashes and candidate versions. Unfixed findings remain reported too.

Daily native CI at 07:23 UTC rechecks availability. On scheduled runs and manual
runs of main, a separate job maintains one tracking issue and comments when
finding state changes, including when an RPM becomes available or evidence is
missing. Only that job has issues: write; PR jobs and the lock updater remain
read-only. The schedule takes effect after this workflow reaches main. The
tracking issue is not an allowlist and cannot affect the gate. Passing CI does
not mean there are no vulnerabilities. Dependency changes require fresh native
evidence on both architectures.

The image owns verified userspace, authentication defaults, strict credential
handling and extension pruning. Operators own host isolation, enforced runtime
flags, TLS PKI, network boundaries, roles, encryption at rest, storage, backups,
monitoring and patch rollout. Local socket trust assumes exclusive control of
the container and its bounded /tmp. Anyone able to exec as the runtime UID can
administer the database. This is not a multi-tenant security boundary. For
Phase A, the owner allows this container-local Unix-socket plaintext exception;
all network connections require verify-full TLS. The socket tmpfs must not be
shared with other containers.

No FIPS validation, STIG certification, Red Hat PostgreSQL support or production
qualification is claimed. See [support](docs/SUPPORT.md).
