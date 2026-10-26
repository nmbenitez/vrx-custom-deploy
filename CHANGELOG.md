# CHANGELOG

## v0.3 en desarrollo (2026-10-24)

- El bootstrap acepta `DownloadOnly` y `Deploy`: la primera fase deja archivos verificados en `Staged`; una segunda ejecución de vRx solicita el despliegue con los mismos archivos.
- El bootstrap registra una tarea SYSTEM persistente antes de iniciar descargas y devuelve `QUEUED` a vRx.
- El trabajador local descarga, verifica y vuelve a intentar después de fallos de red o reinicios.
- Las descargas curl pueden continuar archivos parciales; los archivos completos se reutilizan después de validar SHA-256.
- La aplicación de escritorio para Ubuntu crea, duplica y publica paquetes mediante formularios, genera `deployment.json` y actualiza el manifiesto. También puede probarse en Windows con una carpeta local.
- El editor de escritorio incorpora el logo de vRx y una interfaz oscura con tarjetas, botones y pestañas redondeadas, inspirada en el dashboard del cliente.
- Las pestañas usan números en burbujas de contraste, cambian con una transición breve y la publicación conserva sus tres acciones visibles o desplazables en pantallas bajas.
- Los scripts de descarga vuelven a estar disponibles como fuentes modulares y el generador los exige.
- Validación Python del paquete y de la publicación superada. Integración real de Task Scheduler y PowerShell 5.1 pendiente.


## v0.2.3 — Optimized download transport and speed measurements (2026-10-19)

- Added `windows-client/00-download-helpers.ps1`: configurable `Auto`/`Curl`/`InvokeWebRequest`, trusted Windows curl binary detection, explicit proxy bypass, bounded download retries and timing metrics. The legacy `Invoke-WebRequest` path remains supported.
- Upgraded `02-download-package-folder.ps1` to download the manifest and package files through the shared helper; it logs speed, bytes, cache reuse and SHA-256 verification time. Retains sequential downloads, temporary files and manifest-based integrity checks.
- Updated `02-download-package.ps1` utility to use the same transport helper (still does not verify against manifest).
- `03-verify-package.ps1` now prints total final SHA-256 verification time while retaining its verification behavior.
- Added independent `13-vrx-download-benchmark.ps1` (single vRx execution, no deployment or state changes) to compare curl vs IWR on one package file.
- Exposed download configuration at the top of `09-vrx-bootstrap.ps1` and forwarded it into the embedded modular downloader through local settings; rebuilt the embedded scripts.
- Included previously created **DRAFT** May SCCM case configuration as an example only; no binaries and no approval to run destructive cleanup actions.
- **Unchanged:** no PowerShell `param()`, System32/Sysnative paths, vRx output visibility, one-shot queuing, SYSTEM background worker, manifest format, Ubuntu scripts, install/reboot engine.
- Validation: project Bash/Python/static packaging tests passed. **PowerShell execution on an actual Windows endpoint has not been tested in this build environment.**


## v0.2.2 — Visible staging output (2026-10-18)

- `09-vrx-bootstrap.ps1` runs folder download and SHA-256 verification in the foreground and prints the original messages to vRx output.
- Does not wait for installation, reboot or state changes; registers a background SYSTEM task after successful staging.
- Added `12-start-staged-deployment.ps1` so the background job does not download a second time.
- `11-deployment-launch-worker.ps1` delays installation launch by 15 seconds to let the vRx response finish before a reboot.
- Preserved PowerShell 5.1, no `param()`, modular scripts, and the same Ubuntu repository and manifest format.
- Note: synchronous staging can exceed vRx execution timeout for large packages or slow endpoints.

## v0.2.1 - One-shot vRx deployment dispatch (2026-10-18)

- `09-vrx-bootstrap.ps1` no longer waits for downloads or any deployment step. It registers and starts a separate local SYSTEM task `vRxDeploy-Launch`, records dispatch in `launch-receipt.json`, and returns control to vRx.
- New `11-deployment-launch-worker.ps1` runs `deploy.ps1` independently, logs startup to `launch-worker.log` and reports errors that occur before the engine creates a state file.
- New `10-vrx-check-status.ps1` is an independent one-shot status script, with no `param()`. Queued/running/waiting => exit 2, completed => 0, failed => 1.
- Fixed duplicated/stale deployment log messages on managed-reboot requests.
- All prior Windows utility and Ubuntu scripts remain included; bootstrap embedding rebuilt from the current modular sources.

## v0.2 - Consistency refactor (2026-10-18)

### Preserved
- Original 8 Ubuntu script names and 6 Windows utility script names.
- Dedicated Nginx/Squid services and package hosting in `/srv/packages/`.
- `Invoke-WebRequest` for Windows downloads and variables at script start, no PowerShell `param()`.
- `C:\Infrastructure\Packages` for downloaded package content.

### Changed intentionally
- Ubuntu manifest now recursively indexes packages and is published atomically (instead of only top-level files).
- Folder download now uses manifest instead of parsing Nginx autoindex HTML (directory listing disabled).
- `03-verify-package.ps1` now validates every selected package file; `04-install-package.ps1` remains a standalone MSI utility.
- All Windows scripts load shared variables from `00-config.ps1`; the one-script vRx bootstrap writes an optional local settings file.
- `C:\ProgramData\vRxDeploy` is reserved for engine state and startup resume tasks, not downloaded binaries.
- Added orchestrator, deployment engine, reboot manager, status reader and single-script vRx bootstrap.
- Squid restricted to configured LAN subnet; Nginx default site is backed up before modification.

### Known gaps
- Windows PowerShell scripts need on-machine integration testing.
- HTTP manifest authenticity not implemented; not production-safe for SYSTEM execution.
- No native application-installed detection, user session notification, full dependency graph, or server-side reporting.
- Existing packages may require conversion from older manifests or folder listings.
