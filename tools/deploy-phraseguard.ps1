<#
.SYNOPSIS
  Install PhraseGuard on the SBC from Windows, with nothing extra installed.

.DESCRIPTION
  A thin wrapper around tools/deploy-phraseguard.sh. It packages this checkout,
  copies it to the box, and runs the real deploy script THERE.

  Windows 10 (1803+) and Windows 11 ship ssh.exe, scp.exe and tar.exe in the
  box, so this needs no WSL, no Git Bash, no PuTTY and no Python. If you have
  Git Bash, prefer it and run the .sh directly -- it is the same code path and
  one less wrapper between you and the result.

  Nothing here restarts or reloads Asterisk, and nothing writes to
  /etc/asterisk. The install runs in SHADOW MODE: it detects and records, and
  it hangs up nothing until you deliberately change one setting.

.PARAMETER Remote
  user@host for the SBC, e.g. root@167.235.206.206

.PARAMETER Action
  DryRun    print every action the deploy would take, change nothing
  Install   do it
  Check     is it working right now? (read-only)
  Uninstall stop it and remove it

.EXAMPLE
  .\tools\deploy-phraseguard.ps1 -Remote root@167.235.206.206 -Action DryRun

.EXAMPLE
  .\tools\deploy-phraseguard.ps1 -Remote root@167.235.206.206 -Action Install

.NOTES
  If PowerShell refuses to run this ("running scripts is disabled"), either:
    powershell -ExecutionPolicy Bypass -File .\tools\deploy-phraseguard.ps1 -Remote ... -Action DryRun
  or unblock it once:
    Unblock-File .\tools\deploy-phraseguard.ps1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Remote,

    [Parameter(Mandatory = $true)]
    [ValidateSet('DryRun', 'Install', 'Check', 'Uninstall')]
    [string]$Action,

    # Passed straight through to the deploy script on the box.
    [string]$SbcDir = '/opt/sbc',
    [string]$Model = ''
)

$ErrorActionPreference = 'Stop'

function Say  ($m) { Write-Host "  $m" }
function Ok   ($m) { Write-Host "   OK   $m" -ForegroundColor Green }
function Bad  ($m) { Write-Host "  FAIL  $m" -ForegroundColor Red }
function Head ($m) { Write-Host ""; Write-Host $m -ForegroundColor White }

Write-Host ""
Write-Host "deploy-phraseguard (Windows)  ->  $Remote" -ForegroundColor White

# ---------------------------------------------------------------------------
# Preflight, on THIS machine
# ---------------------------------------------------------------------------
Head "1. this machine"
foreach ($tool in 'ssh', 'scp', 'tar') {
    $found = Get-Command $tool -ErrorAction SilentlyContinue
    if ($found) {
        Ok "$tool found: $($found.Source)"
    }
    else {
        Bad "$tool is not available"
        Say ""
        Say "  ssh, scp and tar ship with Windows 10 (1803+) and Windows 11."
        Say "  If they are missing, enable the OpenSSH client:"
        Say "    Settings -> System -> Optional features -> Add -> OpenSSH Client"
        Say "  or install Git for Windows and use Git Bash instead, which is"
        Say "  the better option anyway:"
        Say "    ./tools/deploy-phraseguard.sh --remote $Remote --dry-run"
        Say ""
        exit 2
    }
}

# The repo root is the parent of the directory holding this script.
$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
foreach ($need in 'phraseguard', 'tools/deploy-phraseguard.sh') {
    $p = Join-Path $RepoRoot ($need -replace '/', '\')
    if (-not (Test-Path $p)) {
        Bad "cannot find $need under $RepoRoot"
        Say "Run this from inside the repository checkout."
        exit 2
    }
}
Ok "repository checkout: $RepoRoot"

# ---------------------------------------------------------------------------
# Package
# ---------------------------------------------------------------------------
# A temp FILE plus scp, rather than piping a tar through PowerShell into ssh.
# PowerShell's pipeline is text-oriented and mangles binary on the way through;
# a tarball that arrives one byte different is a deploy that fails in a way
# nobody enjoys diagnosing at 2am.
Head "2. packaging"
$Stamp   = Get-Date -Format 'yyyyMMddHHmmss'
$Tarball = Join-Path $env:TEMP "phraseguard-$Stamp.tar.gz"
$RemoteStage = "/tmp/phraseguard-deploy.$Stamp"

Push-Location $RepoRoot
try {
    # Windows tar is bsdtar. --format=gnutar keeps GNU tar on the box happy.
    & tar -czf $Tarball --format=gnutar `
        phraseguard `
        tools/deploy-phraseguard.sh `
        tools/phraseguard-spike.sh `
        tools/phraseguard-lint.py 2>$null
    if ($LASTEXITCODE -ne 0) { throw "tar failed with exit code $LASTEXITCODE" }
}
catch {
    Pop-Location
    Bad "could not package the files: $_"
    exit 2
}
Pop-Location
Ok "packaged $([math]::Round((Get-Item $Tarball).Length / 1KB)) KB -> $Tarball"

# ---------------------------------------------------------------------------
# Ship and run
# ---------------------------------------------------------------------------
Head "3. copying to $Remote"
Say "You may be prompted for a password or key passphrase."
& scp -o ConnectTimeout=15 $Tarball "${Remote}:/tmp/phraseguard-deploy.tar.gz"
if ($LASTEXITCODE -ne 0) {
    Bad "scp failed. Check that this works first:  ssh $Remote echo ok"
    Remove-Item $Tarball -Force -ErrorAction SilentlyContinue
    exit 2
}
Ok "copied"
Remove-Item $Tarball -Force -ErrorAction SilentlyContinue

$ActionFlag = switch ($Action) {
    'DryRun'    { '--dry-run' }
    'Install'   { '--install' }
    'Check'     { '--check' }
    'Uninstall' { '--uninstall' }
}
$Extra = "--sbc-dir '$SbcDir'"
if ($Model) { $Extra += " --model '$Model'" }

Head "4. running the deploy on the box"
Say "Everything below this line is happening on $Remote."
Write-Host ""

# One implementation of the install, and it is the one that runs on the box.
# This wrapper only gets the files there.
$RemoteCmd = @"
set -e
mkdir -p '$RemoteStage'
tar xzf /tmp/phraseguard-deploy.tar.gz -C '$RemoteStage'
rm -f /tmp/phraseguard-deploy.tar.gz
cd '$RemoteStage'
# sudo only when not already root. Connecting as root@ is the normal case on
# this box, and a minimal Hetzner image often has no sudo at all -- hardcoding
# it turns a working login into "sudo: command not found".
if [ "`$(id -u)" = 0 ]; then SUDO=; elif command -v sudo >/dev/null; then SUDO=sudo; else echo 'not root and no sudo on this box' >&2; exit 2; fi
`$SUDO bash ./tools/deploy-phraseguard.sh $ActionFlag $Extra
rc=`$?
rm -rf '$RemoteStage'
exit `$rc
"@

& ssh -t -o ConnectTimeout=15 $Remote $RemoteCmd
$rc = $LASTEXITCODE

Write-Host ""
if ($rc -eq 0) {
    Ok "finished on $Remote"
    if ($Action -eq 'Install') {
        Write-Host ""
        Say "PhraseGuard is running in SHADOW MODE: it records, it hangs up nothing."
        Say ""
        Say "Next:"
        Say "  .\tools\deploy-phraseguard.ps1 -Remote $Remote -Action Check"
        Say "  ssh $Remote 'journalctl -t sbc-phraseguard -f'"
    }
}
else {
    Bad "exited $rc on $Remote"
    Say "Nothing was left running that was not already there."
}
Write-Host ""
exit $rc
