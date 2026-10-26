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
assert "if ($BootstrapMode -eq 'DownloadOnly')" in bootstrap
assert "DEPLOY_QUEUED:" in bootstrap
assert "$ModePath = Join-Path $StateDir 'requested-mode.txt'" in bootstrap
assert "$ReceiptCreatedThisRun" in bootstrap
assert bootstrap.index('Write-Host "DEPLOY_QUEUED:') < bootstrap.index('Remove-Item -LiteralPath $Extracted -Recurse -Force')
assert "foreach ($ScriptName in @('02-download-package-folder.ps1'" not in bootstrap
worker = read_text(windows / '11-deployment-launch-worker.ps1')
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
