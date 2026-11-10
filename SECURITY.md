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

The maintainer triages supplier advisories and both scanner reports. Every fixed
High/Critical Trivy or Grype finding blocks CI with **no exemptions**. Unfixed
findings remain in complete reports and require assessment; passing the gate
is not a claim that there are no vulnerabilities. Failed tools, missing reports
or invalid report formats fail closed. Dependency changes require fresh native
evidence on both architectures.

The image owns verified userspace, authentication defaults, strict credential
handling and extension pruning. Operators own host isolation, enforced runtime
flags, TLS PKI, network boundaries, roles, encryption at rest, storage, backups,
monitoring and patch rollout. Local socket trust assumes exclusive control of
the container and its bounded /tmp. Anyone able to exec as the runtime UID can
administer the database. This is not a multi-tenant security boundary.

No FIPS validation, STIG certification, Red Hat PostgreSQL support or production
qualification is claimed. See [support](docs/SUPPORT.md).
