#!/usr/bin/env python3
"""Resolve the selected UBI release once, verifying both native platforms."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import urllib.request
from pathlib import Path

from artifacts import ARCHES, BASE_PREFIXES, DIGEST_RE, LockError, validate_inputs


INDEX_TYPES = (
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.index.v1+json",
)


def verify_index(raw: bytes, expected_digest: str) -> str:
    digest = "sha256:" + hashlib.sha256(raw).hexdigest()
    if digest != expected_digest:
        raise LockError("registry manifest digest does not match its bytes")
    index = json.loads(raw)
    if index.get("schemaVersion") != 2 or index.get("mediaType") not in INDEX_TYPES:
        raise LockError("base must be a multi-architecture manifest index")
    for architecture in ARCHES:
        matches = [entry for entry in index.get("manifests", [])
                   if entry.get("platform", {}).get("os") == "linux"
                   and entry["platform"].get("architecture") == architecture]
        if len(matches) != 1 or not DIGEST_RE.fullmatch(matches[0].get("digest", "")):
            raise LockError(f"base must contain exactly one linux/{architecture} manifest")
    return digest


def resolve(role: str, release: str) -> str:
    reference = BASE_PREFIXES[role] + release
    repository = reference.split("/", 1)[1].rsplit(":", 1)[0]
    request = urllib.request.Request(
        f"https://registry.access.redhat.com/v2/{repository}/manifests/{release}",
        headers={"Accept": ", ".join(INDEX_TYPES)},
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        digest = verify_index(response.read(), response.headers["Docker-Content-Digest"])
    return f"{reference}@{digest}"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inputs", type=Path, default=Path("artifacts/lock-inputs.json"))
    parser.add_argument("--containerfile", type=Path, default=Path("Containerfile"))
    args = parser.parse_args()
    inputs = validate_inputs(args.inputs)
    release = inputs["ubi_release"]
    if not re.fullmatch(r"9\.[0-9]+", release):
        raise LockError("expected an explicit UBI 9 minor release")
    # Resolve both before changing any files; never mix independently moving tags
    # between architecture jobs.
    bases = {role: resolve(role, release) for role in BASE_PREFIXES}
    containerfile = args.containerfile.read_text(encoding="utf-8")
    for role, variable in (("builder", "UBI_MINIMAL_IMAGE"), ("runtime", "UBI_MICRO_IMAGE")):
        containerfile, count = re.subn(
            rf'^ARG {variable}="[^"]+"$', f'ARG {variable}="{bases[role]}"',
            containerfile, flags=re.MULTILINE,
        )
        if count != 1:
            raise LockError(f"expected one pinned {variable} default")
        print(f"{role}: {inputs['base_images'][role]} -> {bases[role]}")
    inputs["base_images"] = bases
    args.inputs.write_text(json.dumps(inputs, indent=2) + "\n", encoding="utf-8")
    args.containerfile.write_text(containerfile, encoding="utf-8")
    validate_inputs(args.inputs)


if __name__ == "__main__":
    main()
