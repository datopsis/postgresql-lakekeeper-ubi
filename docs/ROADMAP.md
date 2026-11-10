# Roadmap

1. First increment: standalone pinned PostgreSQL 18/UBI 9 build, signed locked
   contrib inputs, five-add-on pruning, explicit init SQL, inherited hardening,
   native AMD64/ARM64 runtime tests and blocking vulnerability gates.
2. Qualify Lakekeeper integration: migration and catalog API behavior with a
   least-privilege database role, using this image's explicit extension setup.
3. Qualify exact rootless Podman/RHEL/SELinux storage and deployment profiles;
   document the evidence before making platform support claims.
4. Track sibling fixes and supplier updates with fresh locks, runtime tests and
   scanner evidence for both architectures.

Publication/signing, tags, HA and backup expansion are not part of this increment.
No release workflow is present. Future scope changes need an explicit decision.
