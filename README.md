# vRx Deployment System (desarrollo v0.3)

Sistema piloto para publicar paquetes desde Ubuntu y desplegarlos en Windows mediante ejecuciones breves de vRx. Incluye una aplicación de escritorio para crear `deployment.json` mediante formularios y un trabajador local que recupera descargas interrumpidas.

**Estado:** la publicación y las verificaciones automáticas funcionan en el entorno de desarrollo. Las tareas programadas, la descarga recuperable y los reinicios todavía requieren pruebas en una VM Windows con PowerShell 5.1 antes de distribuirse al cliente. El transporte actual usa HTTP y no autentica el manifiesto.

## Cómo funciona

1. En Ubuntu con escritorio gráfico, el operador abre la aplicación ([instalación](dashboard/README.md)), crea un borrador, carga archivos, configura los pasos y publica. La aplicación escribe `/srv/packages/<paquete>/deployment.json` y actualiza `/srv/packages/manifest.txt`.
2. El bootstrap se carga una vez en vRx. Allí se configura `$Server` una vez. Antes de cada lanzamiento, el operador edita en esa misma acción `$RemoteFolder` con el nombre publicado y `$BootstrapMode` con `DownloadOnly` o `Deploy`. No se genera un script por paquete.
3. Cada ejecución de vRx devuelve el control enseguida. En la primera fase el bootstrap registra una tarea SYSTEM al inicio de Windows y cada 15 minutos; descarga, verifica y queda en estado `Staged` sin iniciar el motor. En la segunda cambia la solicitud local a `Deploy` y despierta la misma tarea. También puede usarse `Deploy` directamente, sin fase previa.
4. La tarea descarga y verifica archivos. Conserva archivos completos válidos y descargas parciales. Después de un apagado o una pérdida de conectividad vuelve a intentarlo. Una demora aleatoria de hasta dos minutos distribuye los intentos entre equipos. Una copia del manifiesto queda asociada a la solicitud.
5. Cuando se solicita `Deploy`, la tarea reutiliza los archivos completos válidos y termina cualquier descarga pendiente antes de ejecutar los pasos de `deployment.json`. Sus reinicios se retoman con otra tarea SYSTEM.
6. `10-vrx-check-status.ps1` consulta el estado en una ejecución independiente de vRx. Código `0`: despliegue completado; `1`: falló; `2`: pendiente, descargando, `Staged` o despliegue en curso. `Staged` significa descarga verificada, aún sin instalación.

Si se programan grupos en horarios distintos con la misma acción de vRx, mantener `$RemoteFolder` y `$BootstrapMode` en `DownloadOnly` hasta que salgan todos los lanzamientos de descarga. La programación podría leer el contenido actualizado de la acción al ejecutarse; este comportamiento debe comprobarse en el entorno de vRx antes del piloto.

## Componentes

| Ruta | Función |
| --- | --- |
| `dashboard/` | Aplicación de escritorio para crear y publicar paquetes. [Uso](dashboard/README.md). |
| `ubuntu-server/` | Nginx, Squid y repositorio de paquetes. |
| `windows-client/09-vrx-bootstrap.ps1` | Entrada reutilizable para vRx; el operador edita el paquete y el modo en la misma acción antes de lanzarla. Archivo generado desde los scripts modulares. |
| `windows-client/11-deployment-launch-worker.ps1` | Descarga persistente, verificación y entrega al motor. |
| `windows-client/06-deployment-engine.ps1` | Ejecución de pasos y estado entre reinicios. |
| `windows-client/10-vrx-check-status.ps1` | Consulta de estado desde vRx. |

El editor inicial permite archivos en la raíz del paquete, pasos `reboot`, `exe`, `msi`, `bat`, `ps1` y `vbs`, reordenamiento, duplicación y publicación de versiones con nombres distintos. También se puede probar en Windows con `python -m dashboard.desktop`; allí publica en una carpeta local de prueba. La integración con la API de vRx y el tablero de estado por equipo están pendientes.

## Desarrollo y validación

```text
python tests/build-bootstrap.py
python tests/test-package.py
python -m unittest discover -s tests -p test_dashboard.py
```

El generador se detiene si faltan fuentes de descarga. La prueba de paquete ejecuta las comprobaciones Bash únicamente cuando Bash está instalado. Las pruebas del editor cubren creación, carga de archivos, publicación, manifiesto, generación del bootstrap y validaciones de datos.

## Limitaciones del piloto

- El inicio y la continuación de tareas programadas todavía no fueron validados en una VM Windows. Las pruebas Python no sustituyen esa validación.
- El estado `Completed` indica que terminaron los pasos configurados; no comprueba que el producto quedó instalado.
- Una interrupción durante un instalador necesita evaluación antes de repetir el paso. No hay garantía de ejecución exactamente una vez.
- El manifiesto usa SHA-256 para detectar daños, pero HTTP no autentica su origen. Los paquetes y scripts se ejecutan como SYSTEM.
- Hay un despliegue activo por equipo. La aplicación todavía no ofrece vista de equipos ni invoca la API de vRx.

Ver el [plan de pruebas](documentation/PLAN_PRUEBAS_V03.md) para validar el piloto en Windows.

Esta edicion publica omite capturas del tenant y borradores de despliegue especificos del cliente.
