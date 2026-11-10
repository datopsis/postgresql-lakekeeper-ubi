from __future__ import annotations

import copy
import hashlib
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

import artifacts  # noqa: E402


FINGERPRINT = "A" * 40
SHA = "0" * 64


def package(name: str) -> dict:
    filename = f"{name}-18.6-1PGDG.rhel9.8.x86_64.rpm"
    return {
        "name": name,
        "epoch": 0,
        "version": "18.6",
        "release": "1PGDG.rhel9.8",
        "architecture": "x86_64",
        "nevra": f"{name}-0:18.6-1PGDG.rhel9.8.x86_64",
        "filename": filename,
        "url": f"https://download.postgresql.org/pub/repos/yum/{filename}",
        "repository": "pgdg-18",
        "size": 1,
        "sha256": SHA,
        "signing_key_fingerprint": FINGERPRINT,
        "source_rpm": "postgresql18-18.6-1PGDG.rhel9.8.src.rpm",
    }


def valid_lock() -> dict:
    digest = f"sha256:{'1' * 64}"
    packages = sorted(
        [package("postgresql18"), package("postgresql18-libs"), package("postgresql18-server"), package("postgresql18-contrib")],
        key=lambda item: item["nevra"],
    )
    return {
        "schema_version": 1,
        "bundle_version": 1,
        "architecture": "amd64",
        "rpm_architecture": "x86_64",
        "generated_at": "2026-09-11T00:00:00Z",
        "postgresql_version": "18.6",
        "postgresql_rpm_version": "18.6-1PGDG.rhel9.8",
        "base_images": {
            role: {
                "reference": f"registry.access.redhat.com/ubi9/{image}:9.8@{digest}",
                "digest": digest,
                "platform": "linux/amd64",
            }
            for role, image in (("builder", "ubi-minimal"), ("runtime", "ubi-micro"))
        },
        "signing_keys": [{
            "id": "test-key",
            "filename": "RPM-GPG-KEY-test",
            "url": "https://security.access.redhat.com/data/test-key.txt",
            "sha256": SHA,
            "fingerprint": FINGERPRINT,
        }],
        "packages": packages,
        "source_packages": [{
            "filename": "postgresql18-18.6-1PGDG.rhel9.8.src.rpm",
            "url": "https://dnf-srpms.postgresql.org/srpms/postgresql18.src.rpm",
            "repository": "pgdg-18-source",
            "size": 1,
            "sha256": SHA,
        }],
    }


class ArtifactLockTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_lock(self, value: dict) -> Path:
        path = self.root / "lock.json"
        path.write_text(json.dumps(value), encoding="utf-8")
        return path

    def assert_rejected(self, value: dict) -> None:
        with self.assertRaises(artifacts.LockError):
            artifacts.validate_lock(self.write_lock(value))

    def test_valid_lock_is_accepted(self) -> None:
        artifacts.validate_lock(self.write_lock(valid_lock()))

    def test_malformed_and_unexpected_fields_fail_closed(self) -> None:
        path = self.root / "bad.json"
        path.write_text("{", encoding="utf-8")
        with self.assertRaises(artifacts.LockError):
            artifacts.validate_lock(path)
        value = valid_lock()
        value["unexpected"] = True
        self.assert_rejected(value)

    def test_wrong_arch_version_nevra_source_and_base_are_rejected(self) -> None:
        mutations = []
        value = valid_lock()
        value["packages"][0]["architecture"] = "aarch64"
        mutations.append(value)
        value = valid_lock()
        value["packages"][0]["version"] = "18.5"
        mutations.append(value)
        value = valid_lock()
        value["packages"][0]["nevra"] = "wrong"
        mutations.append(value)
        value = valid_lock()
        value["packages"][0]["source_rpm"] = "missing.src.rpm"
        mutations.append(value)
        value = valid_lock()
        value["base_images"]["runtime"]["platform"] = "linux/arm64"
        mutations.append(value)
        value = valid_lock()
        value["base_images"]["runtime"]["reference"] = f"example.invalid/image@sha256:{'1' * 64}"
        mutations.append(value)
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                self.assert_rejected(mutation)

    def test_duplicate_and_unapproved_signer_or_url_are_rejected(self) -> None:
        value = valid_lock()
        value["packages"].append(copy.deepcopy(value["packages"][0]))
        self.assert_rejected(value)
        value = valid_lock()
        value["packages"][0]["signing_key_fingerprint"] = "B" * 40
        self.assert_rejected(value)
        value = valid_lock()
        value["packages"][0]["url"] = "https://example.invalid/package.rpm"
        self.assert_rejected(value)

    def test_bundle_rejects_tamper_missing_extra_and_wrong_lock(self) -> None:
        value = valid_lock()
        key_bytes = b"k"
        rpm_bytes = b"r"
        value["signing_keys"][0]["sha256"] = hashlib.sha256(key_bytes).hexdigest()
        for item in value["packages"]:
            item["sha256"] = hashlib.sha256(rpm_bytes).hexdigest()
        lock_path = self.write_lock(value)
        bundle = self.root / "bundle"
        (bundle / "keys").mkdir(parents=True)
        (bundle / "rpms").mkdir()
        (bundle / "keys" / value["signing_keys"][0]["filename"]).write_bytes(key_bytes)
        for item in value["packages"]:
            (bundle / "rpms" / item["filename"]).write_bytes(rpm_bytes)
        (bundle / "LOCK-SHA256").write_text(artifacts.sha256_file(lock_path) + "\n", encoding="ascii")
        (bundle / "key-manifest.tsv").write_text(artifacts.key_manifest(value), encoding="utf-8")
        (bundle / "rpm-manifest.tsv").write_text(artifacts.rpm_manifest(value), encoding="utf-8")
        artifacts.verify_bundle(lock_path, bundle, False)

        cases = {
            "tampered": lambda: (bundle / "rpms" / value["packages"][0]["filename"]).write_bytes(b"x"),
            "missing": lambda: (bundle / "rpms" / value["packages"][0]["filename"]).unlink(),
            "extra": lambda: (bundle / "extra").write_text("x", encoding="utf-8"),
            "wrong-lock": lambda: (bundle / "LOCK-SHA256").write_text(SHA, encoding="ascii"),
        }
        for name, mutate in cases.items():
            with self.subTest(name=name):
                snapshot = self.root / f"bundle-{name}"
                shutil.copytree(bundle, snapshot)
                original = bundle
                bundle = snapshot
                mutate()
                with self.assertRaises(artifacts.LockError):
                    artifacts.verify_bundle(lock_path, bundle, False)
                bundle = original


if __name__ == "__main__":
    unittest.main()
