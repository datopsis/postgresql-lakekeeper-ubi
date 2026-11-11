#!/usr/bin/env python3
"""Render a deterministic artifact lock from native resolver inventories."""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

from artifacts import LockError, validate_inputs, validate_lock


def read_tsv(path: Path, fields: list[str]) -> list[dict[str, str]]:
    rows = []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        values = line.split("\t")
        if len(values) != len(fields):
            raise LockError(f"{path}:{number} has {len(values)} fields; expected {len(fields)}")
        rows.append(dict(zip(fields, values, strict=True)))
    if not rows:
        raise LockError(f"{path} is empty")
    return rows


def fingerprint_for_key_id(keys: list[dict], key_id: str) -> str:
    normalized = key_id.upper()
    matches = [key["fingerprint"] for key in keys if key["fingerprint"].endswith(normalized)]
    if len(matches) != 1:
        raise LockError(f"RPM key ID {key_id} does not select exactly one approved fingerprint")
    return matches[0]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inputs", required=True, type=Path)
    parser.add_argument("--architecture", required=True, choices=("amd64", "arm64"))
    parser.add_argument("--binary-inventory", required=True, type=Path)
    parser.add_argument("--source-inventory", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()

    inputs = validate_inputs(arguments.inputs)
    keys = []
    for key in inputs["signing_keys"]:
        rendered = dict(key)
        rendered["filename"] = Path(key["url"]).name
        keys.append(rendered)
    keys.sort(key=lambda item: item["id"])

    binary_fields = [
        "filename",
        "name",
        "epoch",
        "version",
        "release",
        "architecture",
        "source_rpm",
        "key_id",
        "repository",
        "url",
        "size",
        "sha256",
    ]
    packages = []
    for row in read_tsv(arguments.binary_inventory, binary_fields):
        package = {
            "name": row["name"],
            "epoch": int(row["epoch"]),
            "version": row["version"],
            "release": row["release"],
            "architecture": row["architecture"],
            "nevra": f"{row['name']}-{row['epoch']}:{row['version']}-{row['release']}.{row['architecture']}",
            "filename": row["filename"],
            "url": row["url"],
            "repository": row["repository"],
            "size": int(row["size"]),
            "sha256": row["sha256"],
            "signing_key_fingerprint": fingerprint_for_key_id(keys, row["key_id"]),
            "source_rpm": row["source_rpm"],
        }
        packages.append(package)
    packages.sort(key=lambda item: item["nevra"])

    source_fields = ["filename", "repository", "url", "size", "sha256"]
    sources = []
    for row in read_tsv(arguments.source_inventory, source_fields):
        sources.append({
            "filename": row["filename"],
            "url": row["url"],
            "repository": row["repository"],
            "size": int(row["size"]),
            "sha256": row["sha256"],
        })
    sources.sort(key=lambda item: item["filename"])

    architecture = arguments.architecture
    bases = {}
    for role, reference in inputs["base_images"].items():
        bases[role] = {
            "reference": reference,
            "digest": reference.rsplit("@", 1)[1],
            "platform": f"linux/{architecture}",
        }
    lock = {
        "schema_version": inputs["schema_version"],
        "bundle_version": inputs["bundle_version"],
        "architecture": architecture,
        "rpm_architecture": inputs["architectures"][architecture]["rpm_architecture"],
        "generated_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "postgresql_version": inputs["postgresql_version"],
        "postgresql_rpm_version": inputs["postgresql_rpm_version"],
        "base_images": bases,
        "signing_keys": keys,
        "packages": packages,
        "source_packages": sources,
    }
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    # A successful weekly resolution with identical inputs must not create a PR
    # just because the wall clock changed. Changed subjects get fresh evidence.
    if arguments.output.exists():
        previous = validate_lock(arguments.output)
        comparison = dict(lock, generated_at=previous["generated_at"])
        if comparison == previous:
            lock = previous
    arguments.output.write_text(json.dumps(lock, indent=2) + "\n", encoding="utf-8", newline="\n")
    validate_lock(arguments.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
