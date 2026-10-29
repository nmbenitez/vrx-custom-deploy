"""Open the real desktop widgets and exercise the package views on a display."""

from pathlib import Path
from tempfile import TemporaryDirectory
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from dashboard.desktop import VrxDesktop
from dashboard.service import PackageService


def main():
    with TemporaryDirectory() as temporary:
        root = Path(temporary)
        installer = root / "setup.msi"
        installer.write_bytes(b"desktop smoke test")
        app = VrxDesktop()
        try:
            app.service = PackageService(root / "data", root / "packages")
            app.service.create("demo")
            app.service.add_files("demo", [installer])
            app.service.set_step("demo", {
                "id": "install", "label": "Instalar demo", "type": "msi", "file": "setup.msi",
            })
            app.service.set_step("demo", {
                "id": "notice", "label": "Avisar al usuario", "type": "message",
                "messageText": "Actualización en curso", "messageDurationSeconds": 60,
            })
            app.refresh()
            for section in ("Archivos", "Pasos", "Publicar", "Archivos", "Publicar"):
                app.show_tab(section)
                app.update()
            app.geometry("1000x660+0+0")
            app.update()
            canvas = app.publish_scroll._parent_canvas
            canvas.yview_moveto(1.0)
            app.update()
            assert app.active_tab == "Publicar"
            assert canvas.yview()[1] == 1.0, "La sección Publicar no llega al final."
        finally:
            app.destroy()
    print("PASS: ventana, archivos, pasos, pestañas y publicación en tamaño mínimo")


if __name__ == "__main__":
    main()
