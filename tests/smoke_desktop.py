"""Open the real desktop widgets and exercise the package views on a display."""

from pathlib import Path
from tempfile import TemporaryDirectory
import sys
import time
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from dashboard.desktop import StepDialog, TYPE_NAMES, VrxDesktop
from dashboard.service import PackageService


def main():
    with TemporaryDirectory() as temporary:
        root = Path(temporary)
        files = []
        for extension in ("msi", "exe", "bat", "ps1", "vbs"):
            path = root / f"setup.{extension}"
            path.write_bytes(b"desktop smoke test")
            files.append(path)
        app = VrxDesktop()
        try:
            app.service = PackageService(root / "data", root / "packages")
            app.service.create("demo")
            app.service.add_files("demo", files)
            app.service.set_step("demo", {
                "id": "install", "label": "Instalar demo", "type": "msi", "file": "setup.msi",
            })
            app.service.set_step("demo", {
                "id": "notice", "label": "Avisar al usuario", "type": "message",
                "messageText": "Actualización en curso", "messageDurationSeconds": 60,
            })
            app.refresh()
            assert app.copy_button.cget("state") == "normal"
            with patch.object(app, "clipboard_clear") as clear_clipboard, \
                    patch.object(app, "clipboard_append") as append_clipboard:
                app.copy_button.invoke()
                clear_clipboard.assert_called_once_with()
                append_clipboard.assert_called_once_with("demo")
            assert app.status_var.get() == "Nombre copiado: demo"
            app.show_tab("Archivos", animate=False)
            app.next_files_button.invoke()
            assert app.active_tab == "Acciones"
            app.next_actions_button.invoke()
            assert app.active_tab == "Publicar"
            for section in ("Archivos", "Acciones", "Publicar", "Archivos", "Publicar"):
                app.show_tab(section)
                app.update()

            for kind in ("msi", "exe", "bat", "ps1", "vbs"):
                dialog = StepDialog(app, app.service.files("demo"),
                                    on_save=lambda step: app.service.set_step("demo", step))
                try:
                    time.sleep(0.07)
                    app.update()
                    label = f"Validar {kind.upper()}"
                    arguments = f"/argumento-{kind}"
                    wrong_file = "setup.msi" if kind == "exe" else "setup.exe"
                    dialog.type_var.set(TYPE_NAMES[kind])
                    dialog._toggle_fields()
                    dialog.label_var.set(label)
                    dialog.file_var.set(wrong_file)
                    dialog.arguments_var.set(arguments)
                    with patch("dashboard.desktop.messagebox.showerror") as show_error:
                        dialog._save()
                        assert show_error.call_count == 1
                    assert dialog.winfo_exists(), f"El editor se cerró tras un error de {kind}."
                    assert dialog.label_var.get() == label
                    assert dialog.arguments_var.get() == arguments
                    assert dialog.file_var.get() == wrong_file
                    dialog.file_var.set(f"setup.{kind}")
                    dialog._save()
                    assert not dialog.winfo_exists()
                    assert app.service.load("demo")["steps"][-1]["arguments"] == arguments
                finally:
                    if dialog.winfo_exists():
                        dialog.destroy()

            app.geometry("1000x660+0+0")
            app.update()
            canvas = app.publish_scroll._parent_canvas
            canvas.yview_moveto(1.0)
            app.update()
            assert app.active_tab == "Publicar"
            assert canvas.yview()[1] == 1.0, "La sección Publicar no llega al final."
        finally:
            app.destroy()
    print("PASS: navegación, conservación del formulario y publicación en tamaño mínimo")


if __name__ == "__main__":
    main()
