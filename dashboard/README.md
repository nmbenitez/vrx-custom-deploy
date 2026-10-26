# Editor de automatizaciones vRx

Aplicación de escritorio para Ubuntu con entorno gráfico. Usa Python, CustomTkinter y Pillow; no necesita navegador ni servidor web. El operador crea un borrador, agrega instaladores y pasos, y pulsa **Publicar paquete**. La aplicación genera `deployment.json` dentro de `/srv/packages/<nombre>/` y actualiza `/srv/packages/manifest.txt` automáticamente.

## Ejecutar en Ubuntu Desktop

1. Instalar Python 3, Tkinter y soporte para entornos virtuales: `sudo apt install python3 python3-tk python3-venv`.
2. Crear el repositorio con `ubuntu-server/05-create-package-repository.sh`, ejecutado por el mismo usuario de escritorio que publicará paquetes. Si ya existe, asegurar que ese usuario pueda escribir en `/srv/packages` y que Nginx pueda leerlo.
3. Desde la raíz de este proyecto, crear el entorno e instalar las dependencias: `python3 -m venv .venv` y `.venv/bin/python -m pip install -r dashboard/requirements.txt`.
4. Abrir la ventana con `.venv/bin/python -m dashboard.desktop`. Para agregarla al menú de aplicaciones, ejecutar una vez `.venv/bin/python -m dashboard.install_launcher`; el proyecto debe permanecer en esa ubicación.
5. En **Directorio de paquetes**, dejar `/srv/packages` y guardar la configuración.

Los borradores se guardan en `~/.vrx-deployment/drafts/`; la configuración, en `~/.vrx-deployment/settings.json`. Una publicación es inmutable: para cambiarla, usar **Duplicar** y poner un nombre nuevo. El dashboard publica `deployment.json`, los archivos del paquete y `manifest.txt`; el bootstrap operativo se mantiene cargado en vRx.

En vRx se carga una sola vez `windows-client/09-vrx-bootstrap.ps1`. Allí se configura `$Server` una vez. Para cada conjunto publicado, el operador cambia `$RemoteFolder` al nombre del paquete y ejecuta con `$BootstrapMode = "DownloadOnly"` en los grupos y horarios deseados. Cuando corresponda instalar, cambia únicamente `$BootstrapMode = "Deploy"` y vuelve a ejecutar la misma acción. No cambiar el modo de una acción que todavía tenga lanzamientos de descarga pendientes, salvo que vRx confirme que cada programación conserva una copia de sus variables.

El directorio `/srv/packages` debe ser local al equipo donde se usa la aplicación. Si el Ubuntu con escritorio es distinto del servidor que aloja Nginx, montar allí el repositorio de paquetes o transferir el ZIP exportado y regenerar el manifiesto en el servidor.

## Probar en Windows

Desde la raíz del proyecto, instalar las dependencias con `python -m pip install -r dashboard/requirements.txt` y ejecutar `python -m dashboard.desktop`. La aplicación usa `~/vrx-packages-test` como destino inicial para no tocar el servidor Ubuntu. Se puede crear y publicar un paquete de prueba y revisar su `deployment.json` y `manifest.txt` en esa carpeta. Esta prueba no publica en Ubuntu.

Pruebas automatizadas: `python -m unittest discover -s tests -p test_dashboard.py`.

Prueba visual del programa completo: `python tests/smoke_desktop.py` en una sesión gráfica. En Ubuntu también puede ejecutarse sin pantalla con `xvfb-run -a .venv/bin/python tests/smoke_desktop.py` si está instalado `xvfb`. La sección **Publicar** permite desplazarse cuando la ventana es baja; los números de las secciones se muestran en burbujas y el cambio de sección tiene una transición breve.

La consulta de estados de equipos mediante la API de vRx queda para una etapa posterior.
