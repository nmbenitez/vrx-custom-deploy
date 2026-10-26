"""Rounded desktop editor for vRx deployment packages on Ubuntu and Windows."""

from pathlib import Path
import json
import os
import re
import threading
import tkinter as tk
from tkinter import filedialog, messagebox
import unicodedata

import customtkinter as ctk
from PIL import Image

from .service import PackageService


APP_HOME = Path.home() / ".vrx-deployment"
SETTINGS = APP_HOME / "settings.json"
BG = "#202333"
NAV = "#292d3e"
CARD = "#111322"
SURFACE = "#1b1e2e"
SURFACE_HOVER = "#272b40"
BORDER = "#343a53"
TEXT = "#f5f6fc"
MUTED = "#a2aac1"
ACCENT = "#6f71ff"
ACCENT_HOVER = "#8587ff"
TAB_NUMBER = "#45c7cf"
TAB_NUMBER_TEXT = "#10242b"
FONT = "Segoe UI" if os.name == "nt" else "DejaVu Sans"
TYPE_NAMES = {
    "msi": "Instalar MSI", "exe": "Ejecutar EXE", "bat": "Ejecutar BAT",
    "ps1": "Ejecutar PowerShell", "vbs": "Ejecutar VBS", "reboot": "Reiniciar Windows",
}
TYPE_CODES = {label: code for code, label in TYPE_NAMES.items()}


def slug(value):
    ascii_text = unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode("ascii")
    return re.sub(r"[^a-z0-9]+", "-", ascii_text.lower()).strip("-")


def default_settings():
    root = "/srv/packages" if os.name != "nt" else str(Path.home() / "vrx-packages-test")
    return {"package_root": root}


def load_settings():
    if SETTINGS.is_file():
        saved = json.loads(SETTINGS.read_text(encoding="utf-8"))
        return {"package_root": saved.get("package_root", default_settings()["package_root"])}
    return default_settings()


def action_button(parent, text, command, primary=False, width=120, height=36):
    return ctk.CTkButton(
        parent, text=text, command=command, width=width, height=height,
        corner_radius=10, border_width=0, fg_color=ACCENT if primary else SURFACE_HOVER,
        hover_color=ACCENT_HOVER if primary else BORDER, text_color=TEXT,
        font=(FONT, 12, "bold"),
    )


class StepDialog(ctk.CTkToplevel):
    def __init__(self, parent, files, existing=None):
        super().__init__(parent, fg_color=BG)
        self.title("Editar paso" if existing else "Agregar paso")
        self.geometry("560x495")
        self.resizable(False, False)
        self.transient(parent)
        self.result = None
        existing = existing or {}
        self.label_var = tk.StringVar(value=existing.get("label", existing.get("id", "")))
        self.type_var = tk.StringVar(value=TYPE_NAMES.get(existing.get("type", "msi"), "Instalar MSI"))
        self.file_var = tk.StringVar(value=existing.get("file") or (files[0] if files else "Sin archivos"))
        self.arguments_var = tk.StringVar(value=existing.get("arguments", ""))
        self.codes_var = tk.StringVar(value=",".join(map(str, existing.get("successCodes", [0, 3010]))))
        self.reboot_delay_var = tk.StringVar(value=str(existing.get("rebootDelaySeconds", 0)))
        self.reboot_message_var = tk.StringVar(value=existing.get("rebootMessage", ""))

        card = ctk.CTkFrame(self, fg_color=CARD, corner_radius=18)
        card.pack(fill="both", expand=True, padx=18, pady=18)
        card.grid_columnconfigure(0, weight=1)
        ctk.CTkLabel(card, text="CONFIGURAR PASO", text_color=ACCENT,
                     font=(FONT, 11, "bold")).grid(row=0, column=0, sticky="w", padx=24, pady=(20, 2))
        ctk.CTkLabel(card, text="Definí qué ejecutará Windows", text_color=TEXT,
                     font=(FONT, 18, "bold")).grid(row=1, column=0, sticky="w", padx=24, pady=(0, 12))
        self.label_entry = self._entry(card, 2, "Descripción", self.label_var)
        self.type_menu = self._menu(card, 4, "Acción", self.type_var, list(TYPE_NAMES.values()),
                                    command=lambda _value: self._toggle_fields())
        self.file_menu = self._menu(card, 6, "Archivo cargado", self.file_var,
                                    files or ["Sin archivos"])
        self.arguments_entry = self._entry(card, 8, "Argumentos", self.arguments_var)
        self.codes_entry = self._entry(card, 10, "Códigos de éxito", self.codes_var)
        self.reboot_fields = ctk.CTkFrame(card, fg_color="transparent")
        self.reboot_fields.grid(row=12, column=0, sticky="ew", padx=24)
        self.reboot_fields.grid_columnconfigure(0, weight=1)
        self._entry(self.reboot_fields, 0, "Cuenta regresiva antes de reiniciar (segundos)", self.reboot_delay_var)
        self._entry(self.reboot_fields, 2, "Mensaje de reinicio para Windows", self.reboot_message_var)
        ctk.CTkLabel(card, text="Ejemplo: 0,3010. MSI agrega /i y /norestart.",
                     text_color=MUTED, font=(FONT, 10)).grid(row=13, column=0, sticky="w", padx=24, pady=(5, 12))
        buttons = ctk.CTkFrame(card, fg_color="transparent")
        buttons.grid(row=14, column=0, sticky="e", padx=24, pady=(0, 20))
        action_button(buttons, "Cancelar", self.destroy, width=104).pack(side="left", padx=(0, 8))
        action_button(buttons, "Guardar paso", self._save, primary=True, width=130).pack(side="left")
        self._toggle_fields()
        self.after(30, self.grab_set)
        self.after(50, self.label_entry.focus_set)

    def _entry(self, parent, row, caption, variable):
        ctk.CTkLabel(parent, text=caption, text_color=MUTED, font=(FONT, 11)).grid(
            row=row, column=0, sticky="w", padx=24)
        widget = ctk.CTkEntry(parent, textvariable=variable, height=34, corner_radius=9,
                              fg_color=SURFACE, border_color=BORDER, text_color=TEXT,
                              font=(FONT, 12))
        widget.grid(row=row + 1, column=0, sticky="ew", padx=24, pady=(2, 9))
        return widget

    def _menu(self, parent, row, caption, variable, values, command=None):
        ctk.CTkLabel(parent, text=caption, text_color=MUTED, font=(FONT, 11)).grid(
            row=row, column=0, sticky="w", padx=24)
        widget = ctk.CTkOptionMenu(parent, variable=variable, values=values, command=command,
                                   height=34, corner_radius=9, fg_color=SURFACE,
                                   button_color=SURFACE_HOVER, button_hover_color=BORDER,
                                   text_color=TEXT, font=(FONT, 12))
        widget.grid(row=row + 1, column=0, sticky="ew", padx=24, pady=(2, 9))
        return widget

    def _toggle_fields(self):
        reboot = TYPE_CODES[self.type_var.get()] == "reboot"
        state = "disabled" if reboot else "normal"
        for widget in (self.file_menu, self.arguments_entry, self.codes_entry):
            widget.configure(state=state)
        if reboot:
            self.reboot_fields.grid()
            self.geometry("560x615")
        else:
            self.reboot_fields.grid_remove()
            self.geometry("560x495")

    def _save(self):
        label = self.label_var.get().strip()
        identifier = slug(label)
        if not label or not identifier:
            messagebox.showerror("Paso incompleto", "Escribí una descripción para el paso.", parent=self)
            return
        step = {"id": identifier, "label": label, "type": TYPE_CODES[self.type_var.get()]}
        if step["type"] == "reboot":
            try:
                delay = int(self.reboot_delay_var.get().strip())
            except ValueError:
                messagebox.showerror("Demora inválida", "Usá un número entero de segundos.", parent=self)
                return
            message = self.reboot_message_var.get().strip()
            if delay < 0 or delay > 315360000 or len(message) > 512 or '"' in message or '\n' in message or '\r' in message:
                messagebox.showerror("Reinicio inválido", "La demora debe estar entre 0 y 315360000 segundos; el mensaje admite hasta 512 caracteres, sin comillas.", parent=self)
                return
            if message and delay == 0:
                messagebox.showerror("Reinicio inválido", "Usá una cuenta regresiva mayor que cero para mostrar el mensaje.", parent=self)
                return
            step.update(rebootDelaySeconds=delay, rebootMessage=message)
        else:
            if self.file_var.get() == "Sin archivos":
                messagebox.showerror("Paso incompleto", "Primero cargá un archivo.", parent=self)
                return
            try:
                codes = [int(value.strip()) for value in self.codes_var.get().split(",")]
            except ValueError:
                messagebox.showerror("Códigos inválidos", "Usá números separados por comas.", parent=self)
                return
            step.update(file=self.file_var.get(), arguments=self.arguments_var.get(), successCodes=codes)
        self.result = step
        self.destroy()


class VrxDesktop(ctk.CTk):
    def __init__(self):
        ctk.set_appearance_mode("dark")
        super().__init__(fg_color=BG)
        self.title("vRx · Editor de automatizaciones")
        width = min(1220, max(1000, self.winfo_screenwidth() - 80))
        height = min(790, max(660, self.winfo_screenheight() - 100))
        left = max(0, (self.winfo_screenwidth() - width) // 2)
        top = max(0, (self.winfo_screenheight() - height - 50) // 2)
        self.geometry(f"{width}x{height}+{left}+{top}")
        self.minsize(1000, 660)
        logo_file = Path(__file__).with_name("logo.png")
        logo_image = Image.open(logo_file)
        self.logo = ctk.CTkImage(light_image=logo_image, dark_image=logo_image, size=(84, 42))
        if os.name == "nt":
            self.iconbitmap(str(Path(__file__).with_name("icon.ico")))
        else:
            self.window_icon = tk.PhotoImage(file=str(logo_file))
            self.iconphoto(True, self.window_icon)

        self.settings = load_settings()
        self.package_var = tk.StringVar(value=self.settings["package_root"])
        self.status_var = tk.StringVar(value="Listo")
        self.selected_name = None
        self.busy = False
        self.active_tab = None
        self.tab_pages = {}
        self.tab_buttons = {}
        self._tab_animation_job = None
        self.service = PackageService(APP_HOME, self.settings["package_root"])
        self._build()
        self.refresh()

    def _build(self):
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(1, weight=1)
        header = ctk.CTkFrame(self, fg_color=NAV, corner_radius=0, height=72)
        header.grid(row=0, column=0, sticky="ew")
        header.grid_propagate(False)
        header.grid_columnconfigure(1, weight=1)
        ctk.CTkLabel(header, image=self.logo, text="").grid(row=0, column=0, padx=(26, 14), pady=12)
        title = ctk.CTkFrame(header, fg_color="transparent")
        title.grid(row=0, column=1, sticky="w")
        ctk.CTkLabel(title, text="Deployment Studio", text_color=TEXT,
                     font=(FONT, 17, "bold")).pack(anchor="w")
        ctk.CTkLabel(title, text="Editor de automatizaciones", text_color=MUTED,
                     font=(FONT, 11)).pack(anchor="w")

        body = ctk.CTkFrame(self, fg_color="transparent")
        body.grid(row=1, column=0, sticky="nsew", padx=20, pady=(18, 10))
        body.grid_columnconfigure(1, weight=1)
        body.grid_rowconfigure(1, weight=1)
        self._build_settings(body)
        self._build_sidebar(body)
        self._build_workspace(body)

        footer = ctk.CTkFrame(self, fg_color="transparent", height=34)
        footer.grid(row=2, column=0, sticky="ew", padx=24, pady=(0, 12))
        footer.grid_columnconfigure(2, weight=1)
        ctk.CTkLabel(footer, text="ESTADO", text_color=ACCENT,
                     font=(FONT, 10, "bold")).grid(row=0, column=0, sticky="w")
        ctk.CTkLabel(footer, textvariable=self.status_var, text_color=MUTED,
                     font=(FONT, 11)).grid(row=0, column=1, sticky="w", padx=(12, 0))
        self.progress = ctk.CTkProgressBar(footer, width=150, height=5, corner_radius=5,
                                           fg_color=SURFACE, progress_color=ACCENT,
                                           mode="indeterminate")
        self.progress.grid(row=0, column=2, sticky="e")
        self.progress.grid_remove()

    def _build_settings(self, parent):
        card = ctk.CTkFrame(parent, fg_color=CARD, corner_radius=18,
                            border_width=1, border_color=BORDER)
        card.grid(row=0, column=0, columnspan=2, sticky="ew", pady=(0, 16))
        card.grid_columnconfigure(0, weight=1)
        ctk.CTkLabel(card, text="PUBLICACIÓN", text_color=ACCENT,
                     font=(FONT, 11, "bold")).grid(row=0, column=0,
                                                     sticky="w", padx=22, pady=(16, 8))
        package = ctk.CTkFrame(card, fg_color="transparent")
        package.grid(row=1, column=0, sticky="ew", padx=(22, 22), pady=(0, 18))
        package.grid_columnconfigure(0, weight=1)
        ctk.CTkLabel(package, text="Directorio de paquetes", text_color=MUTED,
                     font=(FONT, 11)).grid(row=0, column=0, sticky="w", pady=(0, 4))
        ctk.CTkEntry(package, textvariable=self.package_var, height=37, corner_radius=10,
                     fg_color=SURFACE, border_color=BORDER, text_color=TEXT,
                     font=(FONT, 11)).grid(row=1, column=0, sticky="ew", padx=(0, 8))
        action_button(package, "Elegir…", self.choose_directory, width=86, height=37).grid(
            row=1, column=1)
        action_button(package, "Guardar", self.save_settings, primary=True,
                      width=92, height=37).grid(row=1, column=2, padx=(8, 0))

    def _build_sidebar(self, parent):
        sidebar = ctk.CTkFrame(parent, fg_color=CARD, corner_radius=18,
                               border_width=1, border_color=BORDER, width=270)
        sidebar.grid(row=1, column=0, sticky="nsew", padx=(0, 16))
        sidebar.grid_propagate(False)
        sidebar.grid_columnconfigure(0, weight=1)
        sidebar.grid_rowconfigure(2, weight=1)
        ctk.CTkLabel(sidebar, text="AUTOMATIZACIONES", text_color=ACCENT,
                     font=(FONT, 11, "bold")).grid(row=0, column=0, sticky="w",
                                                     padx=18, pady=(18, 3))
        ctk.CTkLabel(sidebar, text="Paquetes creados", text_color=MUTED,
                     font=(FONT, 10)).grid(row=1, column=0, sticky="w", padx=18)
        self.draft_list = ctk.CTkScrollableFrame(sidebar, fg_color="transparent",
                                                 scrollbar_button_color=BORDER,
                                                 scrollbar_button_hover_color=ACCENT)
        self.draft_list.grid(row=2, column=0, sticky="nsew", padx=10, pady=12)
        self.draft_list.grid_columnconfigure(0, weight=1)
        controls = ctk.CTkFrame(sidebar, fg_color="transparent")
        controls.grid(row=3, column=0, sticky="ew", padx=16, pady=(0, 16))
        controls.grid_columnconfigure((0, 1), weight=1)
        action_button(controls, "+ Nuevo", self.create_draft, primary=True,
                      width=96).grid(row=0, column=0, sticky="ew", padx=(0, 5))
        action_button(controls, "Duplicar", self.duplicate_draft,
                      width=96).grid(row=0, column=1, sticky="ew", padx=(5, 0))

    def _build_workspace(self, parent):
        workspace = ctk.CTkFrame(parent, fg_color=CARD, corner_radius=18,
                                 border_width=1, border_color=BORDER)
        workspace.grid(row=1, column=1, sticky="nsew")
        workspace.grid_columnconfigure(0, weight=1)
        workspace.grid_rowconfigure(2, weight=1)
        heading = ctk.CTkFrame(workspace, fg_color="transparent")
        heading.grid(row=0, column=0, sticky="ew", padx=24, pady=(20, 8))
        heading.grid_columnconfigure(0, weight=1)
        self.title_label = ctk.CTkLabel(heading, text="Seleccioná o creá una automatización",
                                        text_color=TEXT, font=(FONT, 20, "bold"))
        self.title_label.grid(row=0, column=0, sticky="w")
        self.state_badge = ctk.CTkLabel(heading, text="BORRADOR", text_color=ACCENT,
                                        fg_color=SURFACE_HOVER, corner_radius=10,
                                        width=94, height=29, font=(FONT, 10, "bold"))
        self.state_badge.grid(row=0, column=1, sticky="e")
        tab_bar = ctk.CTkFrame(workspace, fg_color=SURFACE, corner_radius=13)
        tab_bar.grid(row=1, column=0, sticky="w", padx=24, pady=(0, 8))
        for index, name in enumerate(("Archivos", "Pasos", "Publicar")):
            item = ctk.CTkFrame(tab_bar, fg_color="transparent", corner_radius=10)
            item.grid(row=0, column=index, padx=4, pady=4)
            number = ctk.CTkLabel(item, text=str(index + 1), fg_color=TAB_NUMBER,
                                  text_color=TAB_NUMBER_TEXT, corner_radius=11,
                                  width=23, height=23, font=(FONT, 11, "bold"))
            number.pack(side="left", padx=(11, 7), pady=7)
            label = ctk.CTkLabel(item, text=name, text_color=MUTED,
                                 font=(FONT, 12, "bold"))
            label.pack(side="left", padx=(0, 13))
            for widget in (item, number, label):
                widget.bind("<Button-1>", lambda _event, tab=name: self.show_tab(tab))
            self.tab_buttons[name] = (item, label)

        self.page_host = ctk.CTkFrame(workspace, fg_color=CARD, corner_radius=0)
        self.page_host.grid(row=2, column=0, sticky="nsew", padx=16, pady=(0, 16))
        for name, build in (("Archivos", self._build_files),
                            ("Pasos", self._build_steps),
                            ("Publicar", self._build_publish)):
            page = ctk.CTkFrame(self.page_host, fg_color=CARD, corner_radius=0)
            self.tab_pages[name] = page
            build(page)
        self.show_tab("Archivos", animate=False)
        for index, name in enumerate(("Archivos", "Pasos", "Publicar"), start=1):
            self.bind(f"<Control-Key-{index}>", lambda _event, tab=name: self.show_tab(tab))

    def show_tab(self, name, animate=True):
        if name == self.active_tab:
            return
        if self._tab_animation_job is not None:
            self.after_cancel(self._tab_animation_job)
            self._tab_animation_job = None
        for page in self.tab_pages.values():
            page.place_forget()
        self.active_tab = name
        for tab_name, (item, label) in self.tab_buttons.items():
            selected = tab_name == name
            item.configure(fg_color=SURFACE_HOVER if selected else "transparent")
            label.configure(text_color=TEXT if selected else MUTED)
        page = self.tab_pages[name]
        page.place(x=18 if animate else 0, y=0, relwidth=1, relheight=1)
        if not animate:
            return

        def advance(frame=0):
            progress = min(1.0, (frame + 1) / 10)
            eased = 1 - (1 - progress) ** 3
            page.place_configure(x=round(18 * (1 - eased)))
            if progress < 1:
                self._tab_animation_job = self.after(16, lambda: advance(frame + 1))
            else:
                self._tab_animation_job = None

        advance()

    def _build_files(self, tab):
        tab.grid_columnconfigure(0, weight=1)
        tab.grid_rowconfigure(2, weight=1)
        ctk.CTkLabel(tab, text="Archivos del paquete", text_color=TEXT,
                     font=(FONT, 16, "bold")).grid(row=0, column=0, sticky="w", padx=10, pady=(18, 0))
        ctk.CTkLabel(tab, text="Instaladores y scripts que descargarán las PC.",
                     text_color=MUTED, font=(FONT, 11)).grid(row=1, column=0, sticky="w", padx=10, pady=(0, 12))
        self.files_list = ctk.CTkScrollableFrame(tab, fg_color=SURFACE, corner_radius=13,
                                                 scrollbar_button_color=BORDER,
                                                 scrollbar_button_hover_color=ACCENT)
        self.files_list.grid(row=2, column=0, sticky="nsew", padx=10)
        self.files_list.grid_columnconfigure(0, weight=1)
        action_button(tab, "+ Agregar archivos", self.add_files, primary=True,
                      width=174).grid(row=3, column=0, sticky="w", padx=10, pady=14)

    def _build_steps(self, tab):
        tab.grid_columnconfigure(0, weight=1)
        tab.grid_rowconfigure(2, weight=1)
        ctk.CTkLabel(tab, text="Secuencia de ejecución", text_color=TEXT,
                     font=(FONT, 16, "bold")).grid(row=0, column=0, sticky="w", padx=10, pady=(18, 0))
        ctk.CTkLabel(tab, text="Los pasos se ejecutan en el orden mostrado.",
                     text_color=MUTED, font=(FONT, 11)).grid(row=1, column=0, sticky="w", padx=10, pady=(0, 12))
        self.steps_list = ctk.CTkScrollableFrame(tab, fg_color=SURFACE, corner_radius=13,
                                                 scrollbar_button_color=BORDER,
                                                 scrollbar_button_hover_color=ACCENT)
        self.steps_list.grid(row=2, column=0, sticky="nsew", padx=10)
        self.steps_list.grid_columnconfigure(0, weight=1)
        action_button(tab, "+ Agregar paso", self.add_step, primary=True,
                      width=148).grid(row=3, column=0, sticky="w", padx=10, pady=14)

    def _build_publish(self, tab):
        tab.grid_columnconfigure(0, weight=1)
        tab.grid_rowconfigure(0, weight=1)
        content = ctk.CTkScrollableFrame(tab, fg_color=CARD, corner_radius=0,
                                         scrollbar_button_color=BORDER,
                                         scrollbar_button_hover_color=ACCENT)
        content.grid(row=0, column=0, sticky="nsew")
        content.grid_columnconfigure(0, weight=1)
        self.publish_scroll = content
        content._parent_canvas.bind("<Configure>", self._update_publish_scrollbar, add="+")
        ctk.CTkLabel(content, text="Publicar automatización", text_color=TEXT,
                     font=(FONT, 18, "bold")).grid(row=0, column=0, sticky="w", padx=14, pady=(26, 5))
        ctk.CTkLabel(content, text="Se genera deployment.json y se actualiza manifest.txt automáticamente.",
                     text_color=MUTED, font=(FONT, 11)).grid(row=1, column=0, sticky="w", padx=14)
        destination = ctk.CTkFrame(content, fg_color=SURFACE, corner_radius=12)
        destination.grid(row=2, column=0, sticky="ew", padx=14, pady=(18, 16))
        ctk.CTkLabel(destination, text="DESTINO DEL PAQUETE", text_color=ACCENT,
                     font=(FONT, 10, "bold")).pack(anchor="w", padx=18, pady=(15, 2))
        self.destination_label = ctk.CTkLabel(destination, text="Seleccioná un paquete",
                                              text_color=TEXT, font=(FONT, 12),
                                              wraplength=590, justify="left")
        self.destination_label.pack(anchor="w", padx=18, pady=(0, 16))
        actions = ctk.CTkFrame(content, fg_color="transparent")
        actions.grid(row=3, column=0, sticky="w", padx=14)
        action_button(actions, "Publicar paquete", self.publish_package, primary=True,
                      width=190, height=42).grid(row=0, column=0, columnspan=2,
                                                 sticky="w", pady=(0, 12))
        action_button(actions, "Exportar paquete ZIP…", self.export_zip,
                      width=218, height=39).grid(row=1, column=0, sticky="w")
        ctk.CTkLabel(content, text="Para cambiar una versión publicada, duplicala con un nombre nuevo.",
                     text_color=MUTED, font=(FONT, 10)).grid(row=4, column=0, sticky="w",
                                                           padx=14, pady=(17, 0))

    def _update_publish_scrollbar(self, _event=None):
        self.after_idle(self._sync_publish_scrollbar)

    def _sync_publish_scrollbar(self):
        if not self.publish_scroll.winfo_exists():
            return
        canvas = self.publish_scroll._parent_canvas
        bounds = canvas.bbox("all")
        overflowing = bool(bounds and bounds[3] - bounds[1] > canvas.winfo_height() + 2)
        self._show_scrollbar(self.publish_scroll, overflowing)

    def _error(self, error):
        messagebox.showerror("vRx", str(error), parent=self)
        self.status_var.set(str(error))

    def _run_background(self, label, operation, success):
        if self.busy:
            return
        self.busy = True
        self.status_var.set(label)
        self.progress.grid()
        self.progress.start()

        def finish(result=None, error=None):
            self.progress.stop()
            self.progress.grid_remove()
            self.busy = False
            if error:
                self._error(error)
            else:
                self.status_var.set(success(result))
                self.refresh()

        def run():
            try:
                result = operation()
            except Exception as error:
                self.after(0, lambda error=error: finish(error=error))
            else:
                self.after(0, lambda result=result: finish(result=result))

        threading.Thread(target=run, daemon=True).start()

    def choose_directory(self):
        selected = filedialog.askdirectory(parent=self, title="Directorio de paquetes")
        if selected:
            self.package_var.set(selected)

    def save_settings(self):
        try:
            package_root = Path(self.package_var.get()).expanduser().resolve()
            service = PackageService(APP_HOME, package_root)
            self.settings = {"package_root": str(package_root)}
            APP_HOME.mkdir(parents=True, exist_ok=True)
            SETTINGS.write_text(json.dumps(self.settings, indent=2), encoding="utf-8")
            self.service = service
            self.refresh()
            self.status_var.set("Configuración guardada")
        except Exception as error:
            self._error(error)

    def refresh(self):
        names = self.service.drafts()
        published = set(self.service.published())
        self._show_scrollbar(self.draft_list, bool(names))
        if self.selected_name not in names:
            self.selected_name = names[0] if names else None
        for child in self.draft_list.winfo_children():
            child.destroy()
        if not names:
            ctk.CTkLabel(self.draft_list, text="Todavía no hay paquetes.\nCreá el primero con + Nuevo.",
                         text_color=MUTED, font=(FONT, 11), justify="left").grid(
                row=0, column=0, sticky="w", padx=8, pady=15)
        for index, name in enumerate(names):
            selected = name == self.selected_name
            label = name + ("  ✓" if name in published else "")
            ctk.CTkButton(self.draft_list, text=label, command=lambda item=name: self.select(item),
                          anchor="w", height=39, corner_radius=10,
                          fg_color=ACCENT if selected else SURFACE,
                          hover_color=ACCENT_HOVER if selected else SURFACE_HOVER,
                          text_color=TEXT, font=(FONT, 11),
                          border_width=0).grid(row=index, column=0, sticky="ew", pady=3, padx=2)
        self._refresh_detail(published)

    def select(self, name):
        self.selected_name = name
        self.refresh()

    def _clear_rows(self, frame):
        for child in frame.winfo_children():
            child.destroy()

    @staticmethod
    def _show_scrollbar(frame, visible):
        if visible:
            frame._scrollbar.grid()
        else:
            frame._scrollbar.grid_remove()

    def _refresh_detail(self, published):
        self._clear_rows(self.files_list)
        self._clear_rows(self.steps_list)
        name = self.selected_name
        if not name:
            self.title_label.configure(text="Seleccioná o creá una automatización")
            self.state_badge.configure(text="SIN PAQUETE")
            self.destination_label.configure(text="Seleccioná un paquete")
            self._show_scrollbar(self.files_list, False)
            self._show_scrollbar(self.steps_list, False)
            self._empty(self.files_list, "Cargá los instaladores y scripts para comenzar.")
            self._empty(self.steps_list, "Agregá los pasos que ejecutará Windows.")
            return
        is_published = name in published
        self.title_label.configure(text=name)
        self.state_badge.configure(text="PUBLICADO" if is_published else "BORRADOR")
        self.destination_label.configure(text=str(self.service.package_root / name / "deployment.json"))
        files = self.service.files(name)
        steps = self.service.load(name)["steps"]
        self._show_scrollbar(self.files_list, bool(files))
        self._show_scrollbar(self.steps_list, bool(steps))
        if not files:
            self._empty(self.files_list, "Todavía no hay archivos en este paquete.")
        for index, filename in enumerate(files):
            row = ctk.CTkFrame(self.files_list, fg_color=SURFACE_HOVER, corner_radius=10)
            row.grid(row=index, column=0, sticky="ew", padx=7, pady=5)
            row.grid_columnconfigure(1, weight=1)
            ctk.CTkLabel(row, text=Path(filename).suffix.upper() or "FILE", text_color=ACCENT,
                         fg_color=SURFACE, corner_radius=8, width=50, height=30,
                         font=(FONT, 10, "bold")).grid(row=0, column=0, padx=(10, 12), pady=10)
            ctk.CTkLabel(row, text=filename, text_color=TEXT, font=(FONT, 12)).grid(
                row=0, column=1, sticky="w")
            action_button(row, "Quitar", lambda file=filename: self.remove_file(file),
                          width=74, height=30).grid(row=0, column=2, padx=10)
        if not steps:
            self._empty(self.steps_list, "Todavía no hay pasos configurados.")
        for index, step in enumerate(steps):
            row = ctk.CTkFrame(self.steps_list, fg_color=SURFACE_HOVER, corner_radius=10)
            row.grid(row=index, column=0, sticky="ew", padx=7, pady=5)
            row.grid_columnconfigure(1, weight=1)
            ctk.CTkLabel(row, text=f"{index + 1:02d}", text_color=ACCENT,
                         fg_color=SURFACE, corner_radius=8, width=40, height=36,
                         font=(FONT, 11, "bold")).grid(row=0, column=0, rowspan=2, padx=(10, 12), pady=10)
            ctk.CTkLabel(row, text=step.get("label", step["id"]), text_color=TEXT,
                         font=(FONT, 12, "bold")).grid(row=0, column=1, sticky="sw", pady=(8, 0))
            detail = TYPE_NAMES[step["type"]] + (f"  ·  {step['file']}" if step.get("file") else "")
            if step["type"] == "reboot" and step.get("rebootDelaySeconds", 0):
                detail += f"  ·  {step['rebootDelaySeconds']} s"
            ctk.CTkLabel(row, text=detail, text_color=MUTED, font=(FONT, 10)).grid(
                row=1, column=1, sticky="nw", pady=(0, 8))
            controls = ctk.CTkFrame(row, fg_color="transparent")
            controls.grid(row=0, column=2, rowspan=2, padx=8)
            for caption, action in (("↑", lambda i=index: self.move_step(i, -1)),
                                    ("↓", lambda i=index: self.move_step(i, 1)),
                                    ("Editar", lambda i=index: self.edit_step(i)),
                                    ("×", lambda i=index: self.remove_step(i))):
                action_button(controls, caption, action, width=32 if len(caption) == 1 else 61,
                              height=30).pack(side="left", padx=2)

    def _empty(self, frame, text):
        ctk.CTkLabel(frame, text=text, text_color=MUTED,
                     font=(FONT, 12)).grid(row=0, column=0, sticky="w", padx=18, pady=22)

    @staticmethod
    def _ask_name(title, prompt):
        return ctk.CTkInputDialog(
            title=title, text=prompt, fg_color=CARD, text_color=TEXT,
            button_fg_color=ACCENT, button_hover_color=ACCENT_HOVER,
            button_text_color=TEXT, entry_fg_color=SURFACE,
            entry_border_color=BORDER, entry_text_color=TEXT,
            font=(FONT, 12),
        ).get_input()

    def create_draft(self):
        name = self._ask_name("Nueva automatización", "Nombre del paquete (ejemplo: agente-v1)")
        if not name:
            return
        try:
            self.service.create(name.strip())
            self.selected_name = name.strip()
            self.refresh()
        except Exception as error:
            self._error(error)

    def duplicate_draft(self):
        if not self.selected_name:
            return
        name = self._ask_name("Duplicar automatización", "Nombre para la versión nueva")
        if not name:
            return
        try:
            self.service.duplicate(self.selected_name, name.strip())
            self.selected_name = name.strip()
            self.refresh()
        except Exception as error:
            self._error(error)

    def add_files(self):
        if not self.selected_name:
            return
        paths = filedialog.askopenfilenames(parent=self, title="Archivos del paquete")
        if paths:
            name = self.selected_name
            self._run_background("Copiando archivos…", lambda: self.service.add_files(name, paths),
                                 lambda count: f"{count} archivo(s) cargado(s)")

    def remove_file(self, filename):
        if not self.selected_name:
            return
        if not messagebox.askyesno("Quitar archivo", f"¿Quitar {filename} del borrador?", parent=self):
            return
        try:
            self.service.remove_file(self.selected_name, filename)
            self.refresh()
        except Exception as error:
            self._error(error)

    def _step_dialog(self, index=None):
        if not self.selected_name:
            message = "Primero creá o seleccioná un paquete con + Nuevo."
            self.status_var.set(message)
            messagebox.showinfo("Sin paquete seleccionado", message, parent=self)
            return
        existing = self.service.load(self.selected_name)["steps"][index] if index is not None else None
        dialog = StepDialog(self, self.service.files(self.selected_name), existing)
        self.wait_window(dialog)
        if dialog.result:
            try:
                self.service.set_step(self.selected_name, dialog.result, index)
                self.refresh()
            except Exception as error:
                self._error(error)

    def add_step(self):
        self._step_dialog()

    def edit_step(self, index):
        self._step_dialog(index)

    def move_step(self, index, direction):
        try:
            self.service.move_step(self.selected_name, index, direction)
            self.refresh()
        except Exception as error:
            self._error(error)

    def remove_step(self, index):
        if not messagebox.askyesno("Quitar paso", "¿Quitar este paso?", parent=self):
            return
        try:
            self.service.remove_step(self.selected_name, index)
            self.refresh()
        except Exception as error:
            self._error(error)

    def publish_package(self):
        if not self.selected_name:
            return
        name = self.selected_name
        self._run_background("Publicando y calculando hashes…", lambda: self.service.publish(name),
                             lambda path: f"Publicado: {path}")

    def export_zip(self):
        if not self.selected_name:
            return
        destination = filedialog.asksaveasfilename(parent=self, title="Exportar paquete",
            initialfile=f"{self.selected_name}.zip", defaultextension=".zip", filetypes=[("ZIP", "*.zip")])
        if destination:
            name = self.selected_name
            self._run_background("Creando ZIP…", lambda: self.service.export_zip(name, destination),
                                 lambda _result: f"ZIP guardado: {destination}")


def main():
    VrxDesktop().mainloop()


if __name__ == "__main__":
    main()
