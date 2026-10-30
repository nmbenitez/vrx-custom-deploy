# Pruebas del piloto v0.3

Estas pruebas requieren una VM Windows descartable con PowerShell 5.1 y acceso al Ubuntu. Usar `lab-no-reboot` o un paquete de prueba sin instaladores reales.

## Preparación

1. Publicar desde el panel una versión nueva del paquete de laboratorio.
2. Cargar el bootstrap actualizado una sola vez en vRx. Configurar `$Server` allí. Para cada ejecución, editar `$RemoteFolder` y `$BootstrapMode` en esa misma acción.
3. Confirmar que `/srv/packages/<paquete>/deployment.json` y `/srv/packages/manifest.txt` incluyen la versión.
4. Guardar el tamaño y SHA-256 de los archivos del paquete en Ubuntu.

## Casos esenciales

| Caso | Acción | Resultado esperado |
| --- | --- | --- |
| Ejecución directa | Lanzar **Descargar e instalar** desde vRx | Devuelve `QUEUED_DEPLOY`; tarea `vRxDeploy-Launch` registrada antes de descargar. |
| Primera fase | Lanzar **Solo descargar** desde vRx | Devuelve `QUEUED_DOWNLOAD`; al terminar, recibo `Staged`, archivos verificados y sin `deployment-state.json`. |
| Segunda fase | Lanzar **Descargar e instalar** para el mismo paquete | Devuelve `DEPLOY_QUEUED`; reutiliza archivos válidos, crea estado de motor y ejecuta pasos. |
| Segunda fase temprana | Lanzar **Descargar e instalar** cuando la descarga sigue pendiente | Continúa o retoma la descarga; instala solo después de verificar todo el paquete. |
| Cambio durante descarga | Lanzar **Descargar e instalar** mientras el trabajador está descargando | Termina la descarga y pasa a instalar; si la tarea ya estaba finalizando, el disparador periódico retoma la solicitud. |
| Sin acceso al repositorio | Cortar la conexión a Ubuntu antes de lanzar | El bootstrap devuelve `QUEUED_DOWNLOAD` o `QUEUED_DEPLOY`; el recibo local pasa a `RetryScheduled`. |
| Regreso de conexión | Restaurar acceso a Ubuntu | La tarea periódica descarga y verifica sin otra llamada de vRx. |
| Apagado durante transferencia | Apagar la VM mientras existe un archivo `.download` | Tras encender, intenta continuar ese archivo; archivos completos válidos se reutilizan. |
| Doble lanzamiento | Ejecutar otra vez el mismo bootstrap | Informa que el paquete ya está en cola o activo; no crea dos instalaciones. |
| Integridad | Alterar un archivo descargado en la VM antes de reintentar | El archivo se descarga de nuevo y solo se acepta después de verificar tamaño y SHA-256. |
| Consulta de estado | Ejecutar `10-vrx-check-status.ps1` durante y después | Código `2` mientras está pendiente o `Staged`; `0` al completar el despliegue; `1` si falla. |
| Aviso después de reiniciar sin usuario | Configurar `Reiniciar Windows` seguido de `Mostrar mensaje`, reiniciar y demorar el inicio de sesión | El estado queda en `WaitingForUser` y la consulta muestra `PendingStep` con el nombre del aviso. Al iniciar sesión, aparece el aviso y el estado pasa a `Completed` si era el último paso. |
| Falla de un paso | Ejecutar un paso de laboratorio que devuelva un código no permitido | La consulta desde vRx devuelve código `1`, `FailedStep` con el nombre del paso y `LastError` con la causa. |

Revisar en la VM `C:\ProgramData\vRxDeploy\<paquete>\launch-receipt.json`, `launch-worker.log`, `deployment-state.json` y `deployment.log`. Confirmar también los disparadores y el historial de `vRxDeploy-Launch` en Task Scheduler.

Probar por separado un apagado durante un instalador: la versión actual no garantiza que ese paso se ejecute exactamente una vez. Registrar el resultado antes de decidir la política de recuperación de instalación.

## Escalado gradual

Después de validar una VM, probar con un grupo pequeño de equipos, luego un grupo mediano, y medir bytes servidos por Nginx, duración de descargas, número de reintentos y equipos pendientes. Ajustar el intervalo y la dispersión de reintentos antes de un despliegue grande.
