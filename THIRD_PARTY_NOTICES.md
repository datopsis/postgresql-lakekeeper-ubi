# Third-party software and terms

This repository's Apache-2.0 license covers Datopsis-authored packaging and
documentation only. The image also contains separately licensed software.

| Component | Supplier | License and terms |
| --- | --- | --- |
| PostgreSQL | PostgreSQL Global Development Group, packaged by PGDG | [PostgreSQL License](https://www.postgresql.org/about/licence/); exact binary and source RPMs are recorded in each architecture lock |
| Red Hat Universal Base Image and UBI RPM closure | Red Hat | [UBI terms](https://www.redhat.com/en/about/red-hat-end-user-license-agreements#UBI); exact base digests, binary RPMs, source RPMs, and per-package license files are preserved by the locked build |

Release SBOMs must identify the exact installed package inventory. Before a
release, review bundled license material, source availability, redistribution
terms, and notices for PostgreSQL and every runtime dependency.

PostgreSQL and Red Hat names and marks belong to their respective owners. This
independent image does not claim their endorsement, certification, or support.
The accountable maintainer owns source-availability and redistribution review
for each lock change; a missing source record or unresolved term blocks release.
