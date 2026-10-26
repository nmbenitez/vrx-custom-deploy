"""Application operations shared by the desktop UI and tests."""

from pathlib import Path
import json
import os
import shutil
import tempfile
import zipfile

from .publisher import (
    EXTENSIONS, TYPES, draft_path, file_name, load_draft, package_name,
    publish, save_draft, validate_definition, validate_reboot_options,
)


class PackageService:
    def __init__(self, data_root, package_root):
        self.data_root = Path(data_root).expanduser().resolve()
        self.package_root = Path(package_root).expanduser().resolve()
        (self.data_root / "drafts").mkdir(parents=True, exist_ok=True)

    def drafts(self):
        return sorted(path.name for path in (self.data_root / "drafts").iterdir()
                      if path.is_dir() and (path / "definition.json").is_file())

    def published(self):
        if not self.package_root.exists():
            return []
        return sorted(path.name for path in self.package_root.iterdir()
                      if path.is_dir() and not path.name.startswith(".")
                      and (path / "deployment.json").is_file())

    def create(self, name):
        package_name(name)
        if draft_path(self.data_root, name).exists() or (self.package_root / name).exists():
            raise ValueError("Ya existe un borrador o paquete publicado con ese nombre.")
        save_draft(self.data_root, {"name": name, "steps": []})

    def load(self, name):
        return load_draft(self.data_root, package_name(name))

    def files(self, name):
        folder = draft_path(self.data_root, name) / "files"
        return sorted(path.name for path in folder.iterdir() if path.is_file()) if folder.exists() else []

    def _editable(self, name):
        self.load(name)
        if (self.package_root / name).exists():
            raise ValueError("El paquete ya está publicado. Duplicalo con un nombre nuevo.")

    def add_files(self, name, paths):
        self._editable(name)
        folder = draft_path(self.data_root, name) / "files"
        folder.mkdir(exist_ok=True)
        candidates = []
        existing = {path.name.lower() for path in folder.iterdir()}
        for source in map(Path, paths):
            filename = file_name(source.name)
            if filename.lower() == "deployment.json":
                raise ValueError("deployment.json se genera al publicar.")
            if filename.lower() in existing:
                raise ValueError(f"El archivo ya existe: {filename}")
            if not source.is_file() or source.is_symlink():
                raise ValueError(f"No es un archivo regular: {source}")
            existing.add(filename.lower())
            candidates.append((source, filename))
        for source, filename in candidates:
            with tempfile.NamedTemporaryFile(dir=folder, prefix=".upload-", delete=False) as stream:
                temporary = Path(stream.name)
                with source.open("rb") as input_file:
                    shutil.copyfileobj(input_file, stream, length=1024 * 1024)
            try:
                os.replace(temporary, folder / filename)
            finally:
                temporary.unlink(missing_ok=True)
        return len(candidates)

    def remove_file(self, name, filename):
        self._editable(name)
        file_name(filename)
        definition = self.load(name)
        if any(step.get("file") == filename for step in definition["steps"]):
            raise ValueError("El archivo está usado por un paso. Quitá el paso primero.")
        (draft_path(self.data_root, name) / "files" / filename).unlink()

    def set_step(self, name, step, index=None):
        self._editable(name)
        definition = self.load(name)
        steps = definition["steps"]
        identifier = package_name(step.get("id", ""))
        kind = step.get("type", "")
        if kind not in TYPES:
            raise ValueError("Tipo de paso inválido.")
        if any(existing["id"] == identifier for position, existing in enumerate(steps) if position != index):
            raise ValueError("Ya existe un paso con ese identificador.")
        clean = {"id": identifier, "type": kind, "label": str(step.get("label", identifier)).strip() or identifier}
        if kind == "reboot":
            delay, message = validate_reboot_options(step)
            clean.update(rebootDelaySeconds=delay, rebootMessage=message)
        else:
            filename = file_name(step.get("file", ""))
            if filename not in self.files(name):
                raise ValueError("Primero cargá el archivo del paso.")
            if not filename.lower().endswith(EXTENSIONS[kind]):
                raise ValueError(f"El tipo {kind} requiere un archivo {EXTENSIONS[kind]}.")
            raw_codes = step.get("successCodes", [0, 3010])
            codes = [int(code) for code in raw_codes]
            if not codes or any(code < 0 or code > 65535 for code in codes):
                raise ValueError("Códigos de éxito inválidos.")
            clean.update(file=filename, arguments=str(step.get("arguments", "")),
                         successCodes=codes, windowStyle="Hidden")
        if index is None:
            steps.append(clean)
        elif 0 <= index < len(steps):
            steps[index] = clean
        else:
            raise IndexError("El paso no existe.")
        save_draft(self.data_root, definition)

    def move_step(self, name, index, direction):
        self._editable(name)
        definition = self.load(name)
        steps = definition["steps"]
        other = index + direction
        if not (0 <= index < len(steps) and 0 <= other < len(steps)):
            return
        steps[index], steps[other] = steps[other], steps[index]
        save_draft(self.data_root, definition)

    def remove_step(self, name, index):
        self._editable(name)
        definition = self.load(name)
        definition["steps"].pop(index)
        save_draft(self.data_root, definition)

    def duplicate(self, name, new_name):
        definition = self.load(name)
        package_name(new_name)
        target = draft_path(self.data_root, new_name)
        if target.exists() or (self.package_root / new_name).exists():
            raise ValueError("El nombre nuevo ya existe.")
        source_files = draft_path(self.data_root, name) / "files"
        target.mkdir(parents=True)
        if source_files.exists():
            shutil.copytree(source_files, target / "files")
        definition["name"] = new_name
        save_draft(self.data_root, definition)

    def publish(self, name):
        definition = self.load(name)
        validate_definition(definition, set(self.files(name)))
        return publish(self.data_root, self.package_root, name)

    def export_zip(self, name, destination):
        """Create a portable package for manual transfer to a remote Ubuntu host."""
        definition = self.load(name)
        files = self.files(name)
        validate_definition(definition, set(files))
        with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr(f"{name}/deployment.json", json.dumps(definition, ensure_ascii=False, indent=2) + "\n")
            for filename in files:
                archive.write(draft_path(self.data_root, name) / "files" / filename,
                              arcname=f"{name}/{filename}")
