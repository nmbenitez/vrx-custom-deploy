"""Draft storage and atomic package publication for the desktop editor."""

from contextlib import contextmanager
from pathlib import Path
import hashlib
import json
import os
import re
import shutil
import tempfile


PACKAGE_RE = re.compile(r"[A-Za-z0-9_-][A-Za-z0-9_.-]*\Z")
FILE_RE = re.compile(r"[A-Za-z0-9_. -]+\Z")
TYPES = {"exe", "msi", "bat", "ps1", "vbs", "reboot"}
EXTENSIONS = {"exe": ".exe", "msi": ".msi", "bat": ".bat", "ps1": ".ps1", "vbs": ".vbs"}
RESERVED = re.compile(r"(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)", re.I)


def package_name(value):
    if (not PACKAGE_RE.fullmatch(value) or value in {".", ".."}
            or value.endswith(".") or RESERVED.match(value)):
        raise ValueError("Nombre de paquete inválido. Usá letras, números, guion y punto.")
    return value


def file_name(value):
    if (not FILE_RE.fullmatch(value) or value in {".", ".."}
            or value.endswith((".", " ")) or RESERVED.match(value)):
        raise ValueError("Nombre de archivo inválido para Windows.")
    return value


def validate_definition(definition, available_files):
    name = package_name(definition.get("name", ""))
    steps = definition.get("steps", [])
    if not steps:
        raise ValueError("Agregá al menos un paso antes de publicar.")
    seen = set()
    for step in steps:
        identifier = step.get("id", "")
        if not PACKAGE_RE.fullmatch(identifier) or identifier in seen:
            raise ValueError("Cada paso necesita un ID único y válido.")
        seen.add(identifier)
        if step.get("type") not in TYPES:
            raise ValueError(f"Tipo de paso inválido: {identifier}")
        if step["type"] != "reboot":
            selected = file_name(step.get("file", ""))
            if selected not in available_files:
                raise ValueError(f"Falta el archivo {selected} del paso {identifier}.")
            if not selected.lower().endswith(EXTENSIONS[step["type"]]):
                raise ValueError(f"El archivo {selected} no corresponde al tipo {step['type']}.")
        codes = step.get("successCodes", [0, 3010])
        if not isinstance(codes, list) or not codes or any(
            type(code) is not int or code < 0 or code > 65535 for code in codes
        ):
            raise ValueError(f"Códigos de éxito inválidos en {identifier}.")
    return name


def draft_path(data_root, name):
    return Path(data_root) / "drafts" / package_name(name)


def load_draft(data_root, name):
    return json.loads((draft_path(data_root, name) / "definition.json").read_text(encoding="utf-8"))


def save_draft(data_root, definition):
    target = draft_path(data_root, definition["name"])
    target.mkdir(parents=True, exist_ok=True)
    temporary = target / "definition.json.tmp"
    temporary.write_text(json.dumps(definition, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, target / "definition.json")


@contextmanager
def publication_lock(package_root):
    lock_path = Path(package_root) / ".vrx-publication.lock"
    with lock_path.open("a+b") as handle:
        if os.name == "nt":
            import msvcrt
            handle.write(b"0")
            handle.flush()
            handle.seek(0)
            msvcrt.locking(handle.fileno(), msvcrt.LK_LOCK, 1)
        else:
            import fcntl
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            if os.name == "nt":
                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def generate_manifest(package_root):
    """Replace the global manifest only after every record was calculated."""
    root = Path(package_root)
    lines = []
    for package in sorted(root.iterdir()):
        if not package.is_dir() or package.name.startswith("."):
            continue
        package_name(package.name)
        for path in sorted(package.rglob("*")):
            if path.is_symlink():
                raise ValueError(f"Enlace simbólico no permitido: {path}")
            if not path.is_file() or path.name == "manifest.txt" or path.name.endswith(".download"):
                continue
            relative = path.relative_to(root).as_posix()
            for part in relative.split("/"):
                file_name(part)
            digest = hashlib.sha256()
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
            lines.append(f"{relative}|{path.stat().st_size}|{digest.hexdigest()}\n")
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=root, prefix=".manifest.", delete=False) as stream:
        temporary = Path(stream.name)
        stream.writelines(lines)
    try:
        os.chmod(temporary, 0o644)
        os.replace(temporary, root / "manifest.txt")
    finally:
        temporary.unlink(missing_ok=True)


def publish(data_root, package_root, name):
    definition = load_draft(data_root, name)
    draft = draft_path(data_root, name)
    files = draft / "files"
    files.mkdir(exist_ok=True)
    available = {path.name for path in files.iterdir() if path.is_file()} if files.exists() else set()
    if len({name.lower() for name in available}) != len(available):
        raise ValueError("Hay archivos con nombres que Windows considera iguales.")
    validate_definition(definition, available)
    root = Path(package_root)
    root.mkdir(parents=True, exist_ok=True)
    with publication_lock(root):
        destination = root / name
        if destination.exists():
            raise ValueError("Ese paquete ya está publicado. Duplicá el borrador con un nombre de versión nuevo.")
        with tempfile.TemporaryDirectory(prefix=".vrx-staging-", dir=root) as temporary:
            staging = Path(temporary) / name
            staging.mkdir()
            for path in files.iterdir():
                if path.is_file():
                    if path.is_symlink():
                        raise ValueError(f"Enlace simbólico no permitido: {path.name}")
                    file_name(path.name)
                    shutil.copy2(path, staging / path.name)
            (staging / "deployment.json").write_text(
                json.dumps(definition, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
            )
            os.chmod(staging, 0o755)
            for path in staging.iterdir():
                os.chmod(path, 0o644)
            os.replace(staging, destination)
        try:
            generate_manifest(root)
        except Exception:
            # Preserve the files for inspection without exposing an unlisted package.
            quarantine = root / f".failed-{name}-{os.urandom(4).hex()}"
            os.replace(destination, quarantine)
            raise
    return destination
