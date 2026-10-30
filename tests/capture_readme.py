"""Capture the real desktop editor with a harmless example package."""

from pathlib import Path
from tempfile import TemporaryDirectory
import os
import sys
import time

from PIL import ImageGrab

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from dashboard.desktop import BG, CARD, StepDialog, VrxDesktop
from dashboard.service import PackageService


OUTPUT = Path(__file__).resolve().parents[1] / "docs" / "screenshots"


def capture(window, filename):
    window.attributes("-topmost", True)
    window.lift()
    window.update_idletasks()
    window.update()
    time.sleep(0.25)
    window.update()
    left = window.winfo_rootx()
    top = window.winfo_rooty()
    right = left + window.winfo_width()
    bottom = top + window.winfo_height()
    image = ImageGrab.grab(bbox=(left, top, right, bottom))
    expected = CARD if isinstance(window, StepDialog) else BG
    if image.convert("RGB").getpixel((50, 100)) != tuple(bytes.fromhex(expected[1:])):
        raise RuntimeError("La ventana del dashboard no está visible; se canceló la captura.")
    image.save(OUTPUT / filename, optimize=True)


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory() as temporary:
        data = Path(temporary)
        installer = data / "AplicacionDemo.exe"
        installer.write_bytes(b"example only")
        batch = data / "mensaje-final.bat"
        batch.write_text("@echo off\n", encoding="ascii")
        destination = Path("/srv/packages" if os.name != "nt" else r"C:\vrx-demo\packages")

        app = VrxDesktop()
        try:
            app.geometry("1100x780+25+25")
            app.service = PackageService(data / "drafts", destination)
            app.package_var.set(str(destination))
            name = "demo-oficina-v1"
            app.service.create(name)
            app.service.add_files(name, [installer, batch])
            app.service.set_step(name, {
                "id": "reinicio-inicial", "label": "Reinicio inicial", "type": "reboot",
                "rebootDelaySeconds": 300,
                "rebootMessage": "Actualización de aplicaciones: el equipo se reiniciará en cinco minutos.",
            })
            app.service.set_step(name, {
                "id": "instalar-aplicacion", "label": "Instalar aplicación", "type": "exe",
                "file": installer.name, "arguments": "/S", "successCodes": [0, 3010],
            })
            app.service.set_step(name, {
                "id": "reinicio-final", "label": "Reinicio final", "type": "reboot",
                "rebootDelaySeconds": 300,
                "rebootMessage": "La instalación terminó: el equipo se reiniciará en cinco minutos.",
            })
            app.service.set_step(name, {
                "id": "mensaje-final", "label": "Mensaje final", "type": "bat",
                "file": batch.name, "arguments": "", "successCodes": [0],
            })
            app.selected_name = name
            app.refresh()
            app.lift()

            for tab, filename in (
                ("Archivos", "01-archivos.png"),
                ("Acciones", "02-pasos.png"),
                ("Publicar", "04-publicar.png"),
            ):
                app.show_tab(tab, animate=False)
                capture(app, filename)
                if tab == "Acciones":
                    app.steps_list._parent_canvas.yview_moveto(1.0)
                    capture(app, "02b-pasos-final.png")

            dialog = StepDialog(app, app.service.files(name), app.service.load(name)["steps"][0])
            try:
                dialog.lift()
                capture(dialog, "03-reinicio.png")
            finally:
                dialog.destroy()
        finally:
            app.destroy()

    print(f"Capturas creadas en {OUTPUT}")


if __name__ == "__main__":
    main()
