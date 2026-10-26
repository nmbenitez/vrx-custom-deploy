"""Package publication checks shared by the native desktop editor."""

from pathlib import Path
from tempfile import TemporaryDirectory
import hashlib
import json
import unittest
import zipfile

from dashboard.publisher import validate_definition
from dashboard.service import PackageService


class DesktopPublicationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.packages = root / "packages"
        self.service = PackageService(root / "data", self.packages)
        self.source = root / "setup.msi"
        self.source.write_bytes(b"installer bytes")

    def test_publish_and_duplicate(self):
        self.service.create("demo-v1")
        self.service.add_files("demo-v1", [self.source])
        self.service.set_step("demo-v1", {
            "id": "install", "label": "Instalar aplicación", "type": "msi",
            "file": "setup.msi", "arguments": "/qn", "successCodes": [0, 3010],
        })
        self.service.publish("demo-v1")
        definition = json.loads((self.packages / "demo-v1" / "deployment.json").read_text(encoding="utf-8"))
        self.assertEqual(definition["steps"][0]["label"], "Instalar aplicación")
        self.assertEqual(definition["steps"][0]["arguments"], "/qn")
        digest = hashlib.sha256(b"installer bytes").hexdigest()
        self.assertIn(f"demo-v1/setup.msi|15|{digest}",
                      (self.packages / "manifest.txt").read_text(encoding="utf-8"))

        self.service.duplicate("demo-v1", "demo-v2")
        self.service.publish("demo-v2")
        self.assertIn("demo-v2/setup.msi|15|",
                      (self.packages / "manifest.txt").read_text(encoding="utf-8"))
        self.assertEqual((self.packages / "demo-v1" / "setup.msi").read_bytes(), b"installer bytes")

    def test_invalid_names_missing_files_and_immutable_publication(self):
        with self.assertRaises(ValueError):
            self.service.create("../outside")
        self.service.create("demo")
        with self.assertRaises(ValueError):
            self.service.set_step("demo", {"id": "run", "type": "msi", "file": "missing.msi"})
        self.service.add_files("demo", [self.source])
        self.service.set_step("demo", {"id": "run", "type": "msi", "file": "setup.msi"})
        with self.assertRaises(ValueError):
            self.service.remove_file("demo", "setup.msi")
        self.service.publish("demo")
        with self.assertRaises(ValueError):
            self.service.publish("demo")
        with self.assertRaises(ValueError):
            self.service.add_files("demo", [self.source])
        with self.assertRaises(ValueError):
            validate_definition({"name": "../outside", "steps": []}, set())

    def test_zip_export_can_be_inspected_before_publication(self):
        self.service.create("portable")
        self.service.add_files("portable", [self.source])
        self.service.set_step("portable", {"id": "install", "type": "msi", "file": "setup.msi"})
        target = self.packages.parent / "portable.zip"
        self.service.export_zip("portable", target)
        with zipfile.ZipFile(target) as archive:
            self.assertEqual(archive.read("portable/setup.msi"), b"installer bytes")
            definition = json.loads(archive.read("portable/deployment.json"))
            self.assertEqual(definition["name"], "portable")


if __name__ == "__main__":
    unittest.main()
