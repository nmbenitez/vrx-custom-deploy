"""Install a per-user Ubuntu application-menu launcher for the desktop editor."""

from pathlib import Path
import os
import sys


def main():
    if sys.platform != "linux":
        raise SystemExit("Este acceso directo está pensado para Ubuntu con escritorio gráfico.")
    project_root = Path(__file__).resolve().parents[1]
    python = project_root / ".venv" / "bin" / "python"
    if not python.is_file():
        raise SystemExit("Falta .venv. Instalá las dependencias como indica dashboard/README.md.")
    if any(character in str(project_root) for character in "\n\r"):
        raise SystemExit("La ruta del proyecto contiene caracteres no admitidos.")
    destination = Path.home() / ".local" / "share" / "applications" / "vrx-deployment.desktop"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(
        "[Desktop Entry]\n"
        "Type=Application\n"
        "Name=vRx - Editor de automatizaciones\n"
        "Comment=Crear y publicar paquetes de despliegue vRx\n"
        f'Exec="{python}" -m dashboard.desktop\n'
        f"Path={project_root}\n"
        "Terminal=false\n"
        "Categories=Utility;\n",
        encoding="utf-8",
    )
    os.chmod(destination, 0o644)
    print(f"Acceso directo instalado: {destination}")


if __name__ == "__main__":
    main()
