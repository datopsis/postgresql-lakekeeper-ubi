#!/usr/bin/env python3
"""Validate locks, acquire exact artifacts, and prepare offline bundles."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


ALLOWED_HOSTS = {
    "cdn-ubi.redhat.com",
    "dnf-srpms.postgresql.org",
    "download.postgresql.org",
    "security.access.redhat.com",
}
SHA256_RE = re.compile(r"^[a-f0-9]{64}$")
DIGEST_RE = re.compile(r"^sha256:[a-f0-9]{64}$")
FINGERPRINT_RE = re.compile(r"^[A-F0-9]{40}$")
FILENAME_RE = re.compile(r"^[A-Za-z0-9+_.-]+$")
ARCHES = {"amd64": "x86_64", "arm64": "aarch64"}
BASE_PREFIXES = {
    "builder": "registry.access.redhat.com/ubi9/ubi-minimal:",
    "runtime": "registry.access.redhat.com/ubi9/ubi-micro:",
}
UBI_BINARY_REPOSITORIES = {
    "ubi-9-baseos-rpms",
    "ubi-9-appstream-rpms",
    "ubi-9-codeready-builder-rpms",
}
UBI_SOURCE_REPOSITORIES = {
    "ubi-9-baseos-source-rpms",
    "ubi-9-appstream-source-rpms",
    "ubi-9-codeready-builder-source-rpms",
}


class LockError(ValueError):
    """A lock or bundle violated the fail-closed contract."""


def fail(message: str) -> None:
    raise LockError(message)


def read_json(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot read valid JSON from {path}: {exc}")
    if not isinstance(data, dict):
        fail(f"{path} must contain one JSON object")
    return data


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def validate_url(url: object, label: str) -> str:
    if not isinstance(url, str):
        fail(f"{label} URL must be a string")
    parsed = urllib.parse.urlsplit(url)
    if (
        parsed.scheme != "https"
        or parsed.hostname not in ALLOWED_HOSTS
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
    ):
        fail(f"{label} has an unapproved URL: {url}")
    return url


def require_keys(value: dict, required: set[str], allowed: set[str], label: str) -> None:
    missing = required - value.keys()
    extra = value.keys() - allowed
    if missing:
        fail(f"{label} is missing fields: {', '.join(sorted(missing))}")
    if extra:
        fail(f"{label} has unexpected fields: {', '.join(sorted(extra))}")


def require_string(value: object, label: str) -> str:
    if not isinstance(value, str) or not value:
        fail(f"{label} must be a non-empty string")
    return value


def require_sha256(value: object, label: str) -> str:
    if not isinstance(value, str) or not SHA256_RE.fullmatch(value):
        fail(f"{label} must be a lowercase SHA-256 value")
    return value


def validate_base_reference(reference: object, role: str) -> str:
    value = require_string(reference, f"base image {role}")
    if not value.startswith(BASE_PREFIXES[role]) or "@sha256:" not in value:
        fail(f"base image {role} is not an approved digest-pinned UBI image")
    if not DIGEST_RE.fullmatch(value.rsplit("@", 1)[1]):
        fail(f"base image {role} has an invalid digest")
    return value


def validate_inputs(path: Path) -> dict:
    data = read_json(path)
    required = {
        "schema_version",
        "bundle_version",
        "postgresql_version",
        "postgresql_rpm_version",
        "ubi_release",
        "base_images",
        "architectures",
        "signing_keys",
    }
    require_keys(data, required, required, "lock inputs")
    if data["schema_version"] != 1 or data["bundle_version"] != 1:
        fail("only lock schema and bundle version 1 are supported")
    for role in ("builder", "runtime"):
        validate_base_reference(data["base_images"].get(role), role)
    if set(data["architectures"]) != set(ARCHES):
        fail("lock inputs must define exactly amd64 and arm64")
    for architecture, rpm_architecture in ARCHES.items():
        entry = data["architectures"][architecture]
        require_keys(
            entry,
            {"rpm_architecture", "postgresql_rpms", "pgdg_key"},
            {"rpm_architecture", "postgresql_rpms", "pgdg_key"},
            f"architecture {architecture}",
        )
        if entry["rpm_architecture"] != rpm_architecture:
            fail(f"architecture {architecture} has the wrong RPM architecture")
        if len(entry["postgresql_rpms"]) != 4:
            fail(f"architecture {architecture} must seed exactly four PostgreSQL RPMs")
        for item in entry["postgresql_rpms"]:
            require_keys(item, {"url", "sha256"}, {"url", "sha256"}, "PostgreSQL seed")
            validate_url(item["url"], "PostgreSQL seed")
            require_sha256(item["sha256"], "PostgreSQL seed")
    validate_keys(data["signing_keys"])
    return data


def validate_keys(keys: object) -> list[dict]:
    if not isinstance(keys, list) or not keys:
        fail("signing_keys must be a non-empty array")
    ids: set[str] = set()
    filenames: set[str] = set()
    fingerprints: set[str] = set()
    for key in keys:
        if not isinstance(key, dict):
            fail("each signing key must be an object")
        required = {"id", "filename", "url", "sha256", "fingerprint"}
        # Input selections omit filename; the rendered lock adds it.
        input_required = required - {"filename"}
        if set(key) == input_required:
            filename = Path(urllib.parse.urlsplit(validate_url(key["url"], "signing key")).path).name
        else:
            require_keys(key, required, required, "signing key")
            filename = require_string(key["filename"], "signing key filename")
        key_id = require_string(key["id"], "signing key id")
        fingerprint = require_string(key["fingerprint"], "signing key fingerprint")
        if not FILENAME_RE.fullmatch(filename):
            fail(f"unsafe signing key filename: {filename}")
        validate_url(key["url"], "signing key")
        require_sha256(key["sha256"], "signing key")
        if not FINGERPRINT_RE.fullmatch(fingerprint):
            fail(f"invalid full signing-key fingerprint: {fingerprint}")
        if key_id in ids or filename in filenames or fingerprint in fingerprints:
            fail("duplicate signing key id, filename, or fingerprint")
        ids.add(key_id)
        filenames.add(filename)
        fingerprints.add(fingerprint)
    return keys


def validate_lock(path: Path) -> dict:
    data = read_json(path)
    required = {
        "schema_version",
        "bundle_version",
        "architecture",
        "rpm_architecture",
        "generated_at",
        "postgresql_version",
        "postgresql_rpm_version",
        "base_images",
        "signing_keys",
        "packages",
        "source_packages",
    }
    require_keys(data, required, required, "artifact lock")
    if data["schema_version"] != 1 or data["bundle_version"] != 1:
        fail("only lock schema and bundle version 1 are supported")
    architecture = data["architecture"]
    if architecture not in ARCHES or data["rpm_architecture"] != ARCHES[architecture]:
        fail("lock architecture and RPM architecture do not match")
    require_string(data["generated_at"], "generated_at")
    require_string(data["postgresql_version"], "postgresql_version")
    require_string(data["postgresql_rpm_version"], "postgresql_rpm_version")
    bases = data["base_images"]
    require_keys(bases, {"builder", "runtime"}, {"builder", "runtime"}, "base_images")
    for role, base in bases.items():
        require_keys(base, {"reference", "digest", "platform"}, {"reference", "digest", "platform"}, f"base {role}")
        reference = validate_base_reference(base["reference"], role)
        digest = require_string(base["digest"], f"base {role} digest")
        if not DIGEST_RE.fullmatch(digest) or not reference.endswith(f"@{digest}"):
            fail(f"base {role} reference and digest do not match")
        if base["platform"] != f"linux/{architecture}":
            fail(f"base {role} platform does not match lock architecture")
    keys = validate_keys(data["signing_keys"])
    fingerprints = {key["fingerprint"] for key in keys}
    packages = data["packages"]
    sources = data["source_packages"]
    if not isinstance(packages, list) or not packages:
        fail("packages must be a non-empty array")
    if not isinstance(sources, list) or not sources:
        fail("source_packages must be a non-empty array")
    package_files: set[str] = set()
    package_nevras: set[str] = set()
    for package in packages:
        validate_package(package, architecture, data, fingerprints)
        if package["filename"] in package_files or package["nevra"] in package_nevras:
            fail("duplicate package filename or NEVRA")
        package_files.add(package["filename"])
        package_nevras.add(package["nevra"])
    if [item["nevra"] for item in packages] != sorted(item["nevra"] for item in packages):
        fail("packages must be sorted by NEVRA")
    source_files: set[str] = set()
    for source in sources:
        validate_source(source)
        if source["filename"] in source_files:
            fail("duplicate source package filename")
        source_files.add(source["filename"])
    if [item["filename"] for item in sources] != sorted(source_files):
        fail("source_packages must be sorted by filename")
    missing_sources = {item["source_rpm"] for item in packages} - source_files
    if missing_sources:
        fail(f"binary packages lack source records: {', '.join(sorted(missing_sources))}")
    forbidden = {"python3-libs", "python3-pip-wheel", "python3-setuptools-wheel", "sqlite-libs", "libxslt"}
    present = forbidden & {item["name"] for item in packages}
    if present:
        fail(f"lock contains dependencies of removed contrib modules: {', '.join(sorted(present))}")
    required_pg = {"postgresql18", "postgresql18-libs", "postgresql18-server", "postgresql18-contrib"}
    if required_pg - {item["name"] for item in packages}:
        fail("lock does not contain all required PostgreSQL packages")
    return data


def validate_package(package: object, architecture: str, lock: dict, fingerprints: set[str]) -> None:
    if not isinstance(package, dict):
        fail("each package must be an object")
    required = {"name", "epoch", "version", "release", "architecture", "nevra", "filename", "url", "repository", "size", "sha256", "signing_key_fingerprint", "source_rpm"}
    require_keys(package, required, required, "package")
    for field in ("name", "version", "release", "architecture", "nevra", "repository", "source_rpm"):
        require_string(package[field], f"package {field}")
    if not isinstance(package["epoch"], int) or package["epoch"] < 0:
        fail("package epoch must be a non-negative integer")
    if package["architecture"] not in {ARCHES[architecture], "noarch"}:
        fail(f"package {package['nevra']} has the wrong architecture")
    expected_nevra = f"{package['name']}-{package['epoch']}:{package['version']}-{package['release']}.{package['architecture']}"
    if package["nevra"] != expected_nevra:
        fail(f"package NEVRA is inconsistent: {package['nevra']}")
    if not FILENAME_RE.fullmatch(package["filename"]) or not package["filename"].endswith(".rpm"):
        fail(f"unsafe package filename: {package['filename']}")
    url = validate_url(package["url"], f"package {package['nevra']}")
    if not isinstance(package["size"], int) or package["size"] < 1:
        fail(f"package {package['nevra']} has an invalid size")
    require_sha256(package["sha256"], f"package {package['nevra']}")
    if package["signing_key_fingerprint"] not in fingerprints:
        fail(f"package {package['nevra']} uses an unapproved signing key")
    if not package["source_rpm"].endswith(".src.rpm"):
        fail(f"package {package['nevra']} has an invalid source RPM")
    if package["name"].startswith("postgresql18") and (
        package["version"] != lock["postgresql_version"]
        or f"{package['version']}-{package['release']}" != lock["postgresql_rpm_version"]
    ):
        fail(f"package {package['nevra']} violates the locked PostgreSQL version")
    host = urllib.parse.urlsplit(url).hostname
    if package["name"].startswith("postgresql18"):
        if package["repository"] != "pgdg-18" or host != "download.postgresql.org":
            fail(f"package {package['nevra']} has an inconsistent PGDG source")
    elif package["repository"] not in UBI_BINARY_REPOSITORIES or host != "cdn-ubi.redhat.com":
        fail(f"package {package['nevra']} has an inconsistent UBI source")


def validate_source(source: object) -> None:
    if not isinstance(source, dict):
        fail("each source package must be an object")
    required = {"filename", "url", "repository", "size", "sha256"}
    require_keys(source, required, required, "source package")
    filename = require_string(source["filename"], "source package filename")
    if not FILENAME_RE.fullmatch(filename) or not filename.endswith(".src.rpm"):
        fail(f"unsafe source package filename: {filename}")
    url = validate_url(source["url"], f"source package {filename}")
    repository = require_string(source["repository"], "source package repository")
    if not isinstance(source["size"], int) or source["size"] < 1:
        fail(f"source package {filename} has an invalid size")
    require_sha256(source["sha256"], f"source package {filename}")
    host = urllib.parse.urlsplit(url).hostname
    if filename.startswith("postgresql18-"):
        if repository != "pgdg-18-source" or host != "dnf-srpms.postgresql.org":
            fail(f"source package {filename} has an inconsistent PGDG source")
    elif repository not in UBI_SOURCE_REPOSITORIES or host != "cdn-ubi.redhat.com":
        fail(f"source package {filename} has an inconsistent UBI source")


class ApprovedRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001
        validate_url(newurl, "redirect")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def download(url: str, output: Path, expected_size: int | None, expected_sha256: str) -> None:
    validate_url(url, output.name)
    opener = urllib.request.build_opener(ApprovedRedirectHandler())
    for attempt in range(3):
        temporary = output.with_suffix(output.suffix + ".partial")
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "postgresql-lakekeeper-ubi-artifact-acquirer/1"})
            digest = hashlib.sha256()
            size = 0
            with opener.open(request, timeout=30) as response, temporary.open("wb") as target:
                validate_url(response.geturl(), "final response")
                for block in iter(lambda: response.read(1024 * 1024), b""):
                    size += len(block)
                    if expected_size is not None and size > expected_size:
                        fail(f"download exceeded locked size for {output.name}")
                    digest.update(block)
                    target.write(block)
            if expected_size is not None and size != expected_size:
                fail(f"size mismatch for {output.name}: expected {expected_size}, got {size}")
            if digest.hexdigest() != expected_sha256:
                fail(f"SHA-256 mismatch for {output.name}")
            os.replace(temporary, output)
            return
        except (OSError, urllib.error.URLError, LockError) as exc:
            temporary.unlink(missing_ok=True)
            if attempt == 2 or isinstance(exc, LockError):
                raise
            time.sleep(2**attempt)


def lock_files(lock: dict, include_sources: bool) -> list[tuple[str, dict]]:
    files = [(f"keys/{item['filename']}", item) for item in lock["signing_keys"]]
    files.extend((f"rpms/{item['filename']}", item) for item in lock["packages"])
    if include_sources:
        files.extend((f"srpms/{item['filename']}", item) for item in lock["source_packages"])
    return files


def verify_bundle(lock_path: Path, bundle: Path, include_sources: bool) -> None:
    lock = validate_lock(lock_path)
    expected = {relative for relative, _ in lock_files(lock, include_sources)}
    expected.update({"LOCK-SHA256", "key-manifest.tsv", "rpm-manifest.tsv"})
    actual = {
        path.relative_to(bundle).as_posix()
        for path in bundle.rglob("*")
        if path.is_file()
    }
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        fail(f"bundle inventory mismatch; missing={missing}; unexpected={extra}")
    for relative, item in lock_files(lock, include_sources):
        path = bundle / relative
        if path.stat().st_size != item.get("size", path.stat().st_size):
            fail(f"size mismatch for bundled {relative}")
        if sha256_file(path) != item["sha256"]:
            fail(f"SHA-256 mismatch for bundled {relative}")
    expected_lock_sha = sha256_file(lock_path)
    if (bundle / "LOCK-SHA256").read_text(encoding="ascii").strip() != expected_lock_sha:
        fail("bundle lock digest does not match the selected lock")
    expected_manifest = rpm_manifest(lock)
    if (bundle / "rpm-manifest.tsv").read_text(encoding="utf-8") != expected_manifest:
        fail("bundle RPM manifest does not match the selected lock")
    if (bundle / "key-manifest.tsv").read_text(encoding="utf-8") != key_manifest(lock):
        fail("bundle key manifest does not match the selected lock")


def key_manifest(lock: dict) -> str:
    rows = []
    for key in lock["signing_keys"]:
        rows.append("\t".join([key["filename"], key["fingerprint"], key["sha256"]]))
    return "\n".join(rows) + "\n"


def rpm_manifest(lock: dict) -> str:
    rows = []
    for package in lock["packages"]:
        rows.append("\t".join([
            package["filename"],
            package["name"],
            str(package["epoch"]),
            package["version"],
            package["release"],
            package["architecture"],
            package["source_rpm"],
            package["signing_key_fingerprint"],
        ]))
    return "\n".join(rows) + "\n"


def acquire(lock_path: Path, output: Path, include_sources: bool) -> None:
    lock = validate_lock(lock_path)
    if output.exists():
        fail(f"refusing to overwrite existing bundle directory: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=f".{output.name}-", dir=output.parent))
    try:
        for relative, item in lock_files(lock, include_sources):
            destination = temporary / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            download(item["url"], destination, item.get("size"), item["sha256"])
        (temporary / "LOCK-SHA256").write_text(sha256_file(lock_path) + "\n", encoding="ascii")
        (temporary / "key-manifest.tsv").write_text(key_manifest(lock), encoding="utf-8", newline="\n")
        (temporary / "rpm-manifest.tsv").write_text(rpm_manifest(lock), encoding="utf-8", newline="\n")
        verify_bundle(lock_path, temporary, include_sources)
        os.replace(temporary, output)
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise


def acquire_inputs(inputs_path: Path, architecture: str, output: Path) -> None:
    inputs = validate_inputs(inputs_path)
    if architecture not in ARCHES:
        fail(f"unsupported architecture: {architecture}")
    if output.exists():
        fail(f"refusing to overwrite existing input directory: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=f".{output.name}-", dir=output.parent))
    try:
        for key in inputs["signing_keys"]:
            filename = Path(urllib.parse.urlsplit(key["url"]).path).name
            destination = temporary / "keys" / filename
            destination.parent.mkdir(parents=True, exist_ok=True)
            download(key["url"], destination, None, key["sha256"])
        for item in inputs["architectures"][architecture]["postgresql_rpms"]:
            filename = Path(urllib.parse.urlsplit(item["url"]).path).name
            destination = temporary / "rpms" / filename
            destination.parent.mkdir(parents=True, exist_ok=True)
            download(item["url"], destination, None, item["sha256"])
        keys = {"signing_keys": [dict(key, filename=Path(urllib.parse.urlsplit(key["url"]).path).name)
                                 for key in inputs["signing_keys"]]}
        (temporary / "key-manifest.tsv").write_text(key_manifest(keys), encoding="utf-8")
        os.replace(temporary, output)
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    inputs_parser = subparsers.add_parser("validate-inputs")
    inputs_parser.add_argument("path", type=Path)
    lock_parser = subparsers.add_parser("validate-lock")
    lock_parser.add_argument("path", type=Path)
    acquire_parser = subparsers.add_parser("acquire")
    acquire_parser.add_argument("--lock", required=True, type=Path)
    acquire_parser.add_argument("--output", required=True, type=Path)
    acquire_parser.add_argument("--include-sources", action="store_true")
    input_acquire_parser = subparsers.add_parser("acquire-inputs")
    input_acquire_parser.add_argument("--inputs", required=True, type=Path)
    input_acquire_parser.add_argument("--architecture", required=True)
    input_acquire_parser.add_argument("--output", required=True, type=Path)
    verify_parser = subparsers.add_parser("verify-bundle")
    verify_parser.add_argument("--lock", required=True, type=Path)
    verify_parser.add_argument("--bundle", required=True, type=Path)
    verify_parser.add_argument("--include-sources", action="store_true")
    arguments = parser.parse_args()
    try:
        if arguments.command == "validate-inputs":
            validate_inputs(arguments.path)
        elif arguments.command == "validate-lock":
            validate_lock(arguments.path)
        elif arguments.command == "acquire":
            acquire(arguments.lock, arguments.output, arguments.include_sources)
        elif arguments.command == "acquire-inputs":
            acquire_inputs(arguments.inputs, arguments.architecture, arguments.output)
        elif arguments.command == "verify-bundle":
            verify_bundle(arguments.lock, arguments.bundle, arguments.include_sources)
    except LockError as exc:
        print(f"artifact verification failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
