"""Package publication checks shared by the native desktop editor."""

from pathlib import Path
from tempfile import TemporaryDirectory
import hashlib
import json
import unittest
import zipfile
from unittest.mock import patch

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

    def test_delete_draft_and_published_package(self):
        self.service.create("draft-only")
        self.service.delete("draft-only")
        self.assertNotIn("draft-only", self.service.drafts())

        for name in ("remove-me", "keep-me"):
            self.service.create(name)
            self.service.set_step(name, {"id": "reboot", "type": "reboot"})
            self.service.publish(name)
        self.service.delete("remove-me")

        self.assertNotIn("remove-me", self.service.drafts())
        self.assertFalse((self.packages / "remove-me").exists())
        self.assertEqual(self.service.published(), ["keep-me"])
        manifest = (self.packages / "manifest.txt").read_text(encoding="utf-8")
        self.assertNotIn("remove-me/", manifest)
        self.assertIn("keep-me/deployment.json|", manifest)
        with self.assertRaises(ValueError):
            self.service.delete("../outside")

    def test_delete_restores_publication_if_manifest_fails(self):
        self.service.create("demo")
        self.service.set_step("demo", {"id": "reboot", "type": "reboot"})
        self.service.publish("demo")
        original = (self.packages / "manifest.txt").read_text(encoding="utf-8")

        with patch("dashboard.service.generate_manifest", side_effect=OSError("manifest unavailable")):
            with self.assertRaises(OSError):
                self.service.delete("demo")

        self.assertIn("demo", self.service.drafts())
        self.assertTrue((self.packages / "demo" / "deployment.json").is_file())
        self.assertEqual((self.packages / "manifest.txt").read_text(encoding="utf-8"), original)

    def test_delete_preserves_unrelated_folder_with_same_name(self):
        self.service.create("demo")
        unrelated = self.packages / "demo"
        unrelated.mkdir(parents=True)
        (unrelated / "notes.txt").write_text("keep", encoding="utf-8")

        with self.assertRaises(ValueError):
            self.service.delete("demo")

        self.assertIn("demo", self.service.drafts())
        self.assertEqual((unrelated / "notes.txt").read_text(encoding="utf-8"), "keep")

    def test_reboot_warning_is_published_and_validated(self):
        self.service.create("reboot-demo")
        self.service.set_step("reboot-demo", {
            "id": "initial-reboot", "type": "reboot", "label": "Reinicio inicial",
            "rebootDelaySeconds": 300,
            "rebootMessage": "Actualización de aplicaciones: este equipo se reiniciará en cinco minutos.",
        })
        self.service.publish("reboot-demo")
        definition = json.loads((self.packages / "reboot-demo" / "deployment.json").read_text(encoding="utf-8"))
        self.assertEqual(definition["steps"][0]["rebootDelaySeconds"], 300)
        self.assertIn("cinco minutos", definition["steps"][0]["rebootMessage"])

        self.service.create("invalid-reboot")
        for delay, message in ((-1, ""), (0, "Aviso"), (300, 'Aviso "con comillas"')):
            with self.assertRaises(ValueError):
                self.service.set_step("invalid-reboot", {
                    "id": "reboot", "type": "reboot",
                    "rebootDelaySeconds": delay, "rebootMessage": message,
                })

    def test_message_step_needs_no_file_and_validates_text_and_duration(self):
        self.service.create("notice-demo")
        self.service.set_step("notice-demo", {
            "id": "notice", "type": "message", "label": "Avisar al usuario",
            "messageText": "La actualización comenzará en breve.\nGuardá tu trabajo.",
            "messageDurationSeconds": 90,
        })
        self.service.publish("notice-demo")
        definition = json.loads((self.packages / "notice-demo" / "deployment.json").read_text(encoding="utf-8"))
        step = definition["steps"][0]
        self.assertEqual(step["messageText"], "La actualización comenzará en breve.\nGuardá tu trabajo.")
        self.assertEqual(step["messageDurationSeconds"], 90)
        self.assertNotIn("file", step)

        self.service.create("invalid-notice")
        for message, duration in (("", 60), ("Aviso", 0), ("Aviso", 3601), ("Hola\t", 60)):
            with self.assertRaises(ValueError):
                self.service.set_step("invalid-notice", {
                    "id": "notice", "type": "message",
                    "messageText": message, "messageDurationSeconds": duration,
                })


if __name__ == "__main__":
    unittest.main()
