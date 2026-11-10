from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from artifacts import LockError  # noqa: E402

spec = importlib.util.spec_from_file_location("refresh_bases", ROOT / "scripts/refresh-bases.py")
refresh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(refresh)


class BaseIndexTests(unittest.TestCase):
    def setUp(self):
        self.index = {
            "schemaVersion": 2,
            "mediaType": refresh.INDEX_TYPES[0],
            "manifests": [
                {"platform": {"os": "linux", "architecture": arch}, "digest": "sha256:" + "a" * 64}
                for arch in ("amd64", "arm64")
            ],
        }

    def verify(self, index):
        raw = json.dumps(index).encode()
        return refresh.verify_index(raw, "sha256:" + hashlib.sha256(raw).hexdigest())

    def test_accepts_both_index_formats(self):
        for media_type in refresh.INDEX_TYPES:
            self.index["mediaType"] = media_type
            self.verify(self.index)

    def test_rejects_missing_duplicate_or_non_linux_platform(self):
        for change in ("missing", "duplicate", "windows", "invalid_digest"):
            with self.subTest(change=change):
                index = copy.deepcopy(self.index)
                if change == "missing":
                    index["manifests"].pop()
                elif change == "duplicate":
                    index["manifests"].append(index["manifests"][0])
                elif change == "windows":
                    index["manifests"][1]["platform"]["os"] = "windows"
                else:
                    index["manifests"][1]["digest"] = "latest"
                with self.assertRaises(LockError):
                    self.verify(index)

    def test_rejects_tampered_bytes_and_single_arch_manifest(self):
        with self.assertRaises(LockError):
            refresh.verify_index(json.dumps(self.index).encode(), "sha256:" + "0" * 64)
        self.index["mediaType"] = "application/vnd.oci.image.manifest.v1+json"
        with self.assertRaises(LockError):
            self.verify(self.index)


class RenderUpdateTests(unittest.TestCase):
    def test_noop_is_byte_identical_but_base_change_gets_new_timestamp(self):
        # Replay actual native inventory metadata through the production renderer.
        for arch in ("amd64", "arm64"):
            with self.subTest(arch=arch), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                original = (ROOT / f"artifacts/locks/{arch}.json").read_bytes()
                lock = json.loads(original)
                inputs = json.loads((ROOT / "artifacts/lock-inputs.json").read_text())
                inputs["base_images"] = {role: value["reference"] for role, value in lock["base_images"].items()}
                (root / "inputs.json").write_text(json.dumps(inputs))
                (root / "lock.json").write_bytes(original)
                binary = []
                for p in lock["packages"]:
                    binary.append("\t".join(str(value) for value in (
                        p["filename"], p["name"], p["epoch"], p["version"], p["release"],
                        p["architecture"], p["source_rpm"], p["signing_key_fingerprint"][-16:],
                        p["repository"], p["url"], p["size"], p["sha256"],
                    )))
                (root / "binary.tsv").write_text("\n".join(binary) + "\n")
                source = ["\t".join(str(p[k]) for k in ("filename", "repository", "url", "size", "sha256"))
                          for p in lock["source_packages"]]
                (root / "source.tsv").write_text("\n".join(source) + "\n")
                command = [sys.executable, str(ROOT / "scripts/render-lock.py"),
                           "--inputs", str(root / "inputs.json"), "--architecture", arch,
                           "--binary-inventory", str(root / "binary.tsv"),
                           "--source-inventory", str(root / "source.tsv"),
                           "--output", str(root / "lock.json")]
                subprocess.run(command, check=True)
                self.assertEqual((root / "lock.json").read_bytes(), original)
                inputs["base_images"]["runtime"] = inputs["base_images"]["runtime"].split("@")[0] + "@sha256:" + "c" * 64
                (root / "inputs.json").write_text(json.dumps(inputs))
                lock["generated_at"] = "2000-01-01T00:00:00Z"
                (root / "lock.json").write_text(json.dumps(lock))
                subprocess.run(command, check=True)
                result = json.loads((root / "lock.json").read_text())
                self.assertNotEqual(result["generated_at"], lock["generated_at"])
                self.assertEqual(result["base_images"]["runtime"]["reference"], inputs["base_images"]["runtime"])


if __name__ == "__main__":
    unittest.main()
