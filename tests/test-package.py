#!/usr/bin/env python3
"""Static contract checks and optional Ubuntu manifest integration test."""
from pathlib import Path
import base64
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import tempfile
import zipfile


def read_text(path):
    return path.read_text(encoding='utf-8')

root = Path(__file__).resolve().parents[1]
ubuntu = root / 'ubuntu-server'
windows = root / 'windows-client'

for source in list(windows.glob('*.ps1')) + list(windows.glob('*.psm1')):
    content = read_text(source)
    assert not re.search(r'(?m)^param\s*\(', content, re.I), source.name
    assert content.startswith('#Requires') or content.startswith('# ============================================'), source.name

required = ('02-package-download.psm1',)
for name in required:
    assert (windows / name).is_file(), name
for path in (root / 'example-package').rglob('*.json'):
    deployment = json.loads(path.read_text(encoding='utf-8'))
    assert deployment['name'] and deployment['steps']
    ids = [step['id'] for step in deployment['steps']]
    assert len(ids) == len(set(ids))

bootstrap = read_text(windows / '09-vrx-bootstrap.ps1')
archive = bootstrap.split("$Encoded = @'\n", 1)[1].split("\n'@", 1)[0]
with zipfile.ZipFile(io.BytesIO(base64.b64decode(''.join(archive.split())))) as bundle:
    for source in list(windows.glob('*.ps1')) + list(windows.glob('*.psm1')):
        if source.name == '09-vrx-bootstrap.ps1':
            continue
        assert bundle.read(source.name) == source.read_bytes(), source.name

assert bootstrap.index('Register-ScheduledTask -TaskName $TaskName') < bootstrap.rindex('Start-ScheduledTask -TaskName $TaskName')
assert "New-ScheduledTaskTrigger -AtStartup" in bootstrap
assert "-RepetitionInterval (New-TimeSpan -Minutes 15)" in bootstrap
assert '$Server = ""' in bootstrap
assert '$RemoteFolder = ""' in bootstrap
assert '$BootstrapMode = "DownloadOnly"' in bootstrap
assert '$DownloadRoot = "C:\\Infrastructure\\Packages"' in bootstrap
assert "('$DownloadRoot = ''{0}''' -f $DownloadRoot.Replace(\"'\", \"''\"))" in bootstrap
assert "if ($ExistingReceipt.DownloadRoot)" in bootstrap
assert 'DownloadRoot = $DownloadRoot' in bootstrap
operator_section = bootstrap.split('# Queue persistent download or installation', 1)[0]
for internal_setting in ('DownloadMethod', 'CurlBypassProxy', 'CurlRetryCount',
                         'CurlConnectTimeoutSeconds', 'CurlMaxTimeSeconds', 'DownloadAttempts'):
    assert '$' + internal_setting + ' =' not in operator_section
assert "if ($BootstrapMode -eq 'DownloadOnly')" in bootstrap
assert "function Remove-TerminalTasks" in bootstrap
assert "Unregister-ScheduledTask -TaskName $Name" in bootstrap
assert "DEPLOY_QUEUED:" in bootstrap
assert "$ModePath = Join-Path $StateDir 'requested-mode.txt'" in bootstrap
assert "$ReceiptCreatedThisRun" in bootstrap
assert bootstrap.index('Write-Host "DEPLOY_QUEUED:') < bootstrap.index('Remove-Item -LiteralPath $Extracted -Recurse -Force')
assert "foreach ($ScriptName in @('02-download-package-folder.ps1'" not in bootstrap
worker = read_text(windows / '11-deployment-launch-worker.ps1')
assert "if ($FinalState.Status -in @('Completed','Failed')) { Remove-TerminalTasks }" in worker
assert "if ($null -ne $Receipt -and $Receipt.Status -eq 'Failed')" in worker
assert "'RetryScheduled'" in worker and "'ReadyToInstall'" in worker
assert "'Staged'" in worker and "Get-RequestedMode" in worker
assert worker.index("$Receipt.Status = 'Staged'") < worker.index("'12-start-staged-deployment.ps1'")
assert "if ((Get-RequestedMode) -eq 'DownloadOnly') { exit 0 }" in worker
assert 'Invoke-PackageDownload' in worker
assert "'12-start-staged-deployment.ps1'" in worker
helper = read_text(windows / '02-package-download.psm1')
assert "'--continue-at', '-'" in helper
assert 'if (-not $ResumePartialDownload)' in helper
folder = read_text(windows / '02-package-download.psm1')
assert 'ManifestSnapshot' in folder and 'ResumePartialDownload = $true' in folder

engine = read_text(windows / '06-deployment-engine.ps1')
assert engine.count('Remove-LaunchTask') >= 3
assert "if ($State.Status -eq 'Completed')" in engine
assert "if ($Step.type -eq 'message')" in engine
assert "Send-UserMessage -Message ([string]$Step.messageText)" in engine
assert "if ($Step.type -notin @('reboot','message'))" in engine
assert 'WTSQuerySessionInformationW' in engine
assert 'if (active == 0) return 0;' in engine
assert "$State.Status = 'WaitingForUser'" in engine
assert 'Install-ResumeTask' in engine.split("if ($Step.type -eq 'message')", 1)[1].split('$ExecutableFile = Resolve-StepFile', 1)[0]
assert 'CurrentStepLabel' in engine and 'LastError' in engine
if shutil.which('powershell'):
    source = engine.split("Add-Type -TypeDefinition @'\n", 1)[1].split("\n'@", 1)[0]
    encoded = base64.b64encode(source.encode('utf-8')).decode('ascii')
    compile_command = (
        "$source = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + encoded + "')); "
        "Add-Type -TypeDefinition $source -ErrorAction Stop"
    )
    subprocess.run(['powershell', '-NoProfile', '-NonInteractive', '-Command', compile_command], check=True)
    message_branch = "if ($Step.type -eq 'message') {" + engine.split(
        "if ($Step.type -eq 'message') {", 1
    )[1].split('$ExecutableFile = Resolve-StepFile', 1)[0]
    with tempfile.TemporaryDirectory() as directory:
        probe = Path(directory) / 'probe.ps1'
        for initial_status, delivered, expected in (
            ('Running', 0, ('TASK_REGISTERED', 'SAVED:WaitingForUser:0')),
            ('WaitingForUser', 1, ('SAVED:Running:1',)),
        ):
            probe.write_text(
                "$Step = [pscustomobject]@{type='message'; id='notice'; messageText='Test'; messageDurationSeconds=1}\n"
                f"$State = [pscustomobject]@{{Status='{initial_status}'; NextStep=0; LastExitCode=$null; UpdatedAt=''}}\n"
                "$Index = 0; $TaskName = 'test'\n"
                f"function Send-UserMessage {{ param([string]$Message, [int]$DurationSeconds) return {delivered} }}\n"
                "function Install-ResumeTask { Write-Host 'TASK_REGISTERED' }\n"
                "function Get-ScheduledTask { return $null }\n"
                'function Save-DeploymentState { Write-Host "SAVED:$($State.Status):$($State.NextStep)" }\n'
                'function Write-DeploymentLog { Write-Host "LOG:$LogMessage" }\n'
                "foreach ($item in @(1)) {\n" + message_branch + "\n}\n",
                encoding='utf-8',
            )
            result = subprocess.run(
                ['powershell', '-NoProfile', '-NonInteractive', '-File', str(probe)],
                capture_output=True, text=True, errors='replace',
            )
            assert result.returncode == 0, result.stderr
            for marker in expected:
                assert marker in result.stdout, result.stdout

        status_script = read_text(windows / '10-vrx-check-status.ps1')
        status_script = status_script.replace('$RemoteFolder = "example-package"', '$RemoteFolder = "probe"')
        status_script = status_script.replace(
            '$EngineRoot = "C:\\ProgramData\\vRxDeploy"', f'$EngineRoot = "{Path(directory).as_posix()}"'
        )
        probe.write_text(status_script, encoding='utf-8')
        state_dir = Path(directory) / 'probe'
        state_dir.mkdir()
        state_file = state_dir / 'deployment-state.json'
        for status, code, marker in (
            ('WaitingForUser', 2, 'PendingStep: Mostrar resumen (id: notice, type: message)'),
            ('Failed', 1, 'FailedStep: Mostrar resumen (id: notice, type: message)'),
            ('Completed', 0, 'Status: Completed'),
        ):
            state_file.write_text(json.dumps({
                'Package': 'probe', 'Status': status, 'NextStep': 0,
                'CurrentStepId': 'notice', 'CurrentStepLabel': 'Mostrar resumen',
                'CurrentStepType': 'message', 'LastError': 'Test failure',
            }), encoding='utf-8')
            result = subprocess.run(
                ['powershell', '-NoProfile', '-NonInteractive', '-File', str(probe)],
                capture_output=True, text=True, errors='replace',
            )
            assert result.returncode == code, result.stderr
            assert marker in result.stdout, result.stdout
            if status == 'Failed':
                assert 'LastError: Test failure' in result.stdout, result.stdout
reboot_manager = read_text(windows / '07-reboot-manager.ps1')
assert 'New-ScheduledTaskTrigger -AtLogOn' in reboot_manager
assert "$LogonTrigger.Delay = 'PT20S'" in reboot_manager
assert 'Unregister-ScheduledTask -TaskName $TaskName' in reboot_manager
assert 'Unregister-ScheduledTask -TaskName $LaunchTaskName' in reboot_manager

if shutil.which('bash'):
    for source in ubuntu.glob('*.sh'):
        subprocess.run(['bash', '-n', str(source)], check=True)
    with tempfile.TemporaryDirectory() as directory:
        repo = Path(directory)
        (repo / 'app').mkdir()
        (repo / 'app' / 'payload.exe').write_bytes(b'package')
        env = dict(os.environ, PACKAGE_DIR=str(repo))
        subprocess.run(['bash', str(ubuntu / '06-generate-manifest.sh')], env=env, check=True, capture_output=True)
        line = (repo / 'manifest.txt').read_text().strip()
        assert line == f"app/payload.exe|7|{hashlib.sha256(b'package').hexdigest()}"
    print('PASS: Bash syntax and manifest integration')
else:
    print('SKIP: Bash checks (bash is unavailable)')
print('PASS: package JSON, bootstrap bundle, persistent worker and resumable download contract')
