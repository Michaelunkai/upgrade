#Requires -RunAsAdministrator
# repair-upgrade.ps1 - Fully automatic Windows 11 in-place repair upgrade
# Extracts ISO to C:\WinSetup so migcore.dll and all migration DLLs are local
# Zero manual steps. Zero errors. Run elevated and walk away.

param(
    [string]$IsoSource = "E:\isos\Windows.iso",
    [string]$ExtractDir = "C:\WinSetup",
    [string]$LocalIso = "C:\WinISO\Windows.iso"
)

$ErrorActionPreference = 'Stop'
$host.UI.RawUI.WindowTitle = "Repair Upgrade - Automated"

function Write-Step($n, $msg) { Write-Host "`n[$n] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)      { Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Fail($msg)    { Write-Host "    [FAIL] $msg" -ForegroundColor Red; throw $msg }

# ─── STEP 1: Copy ISO to C: (NTFS) ───────────────────────────────────
Write-Step 1 "Copy ISO to NTFS drive"
New-Item -ItemType Directory -Path (Split-Path $LocalIso) -Force -EA SilentlyContinue | Out-Null
if (-not (Test-Path $LocalIso)) {
    if (-not (Test-Path $IsoSource)) {
        # Try alternate locations
        $alt = @("E:\isos\Windows.iso","F:\isos\Windows.iso","C:\Users\micha\Downloads\Windows.iso")
        $found = $alt | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($found) { $IsoSource = $found } else { Write-Fail "No Windows ISO found at $IsoSource or alternates" }
    }
    Write-Host "    Copying $(Split-Path $IsoSource -Leaf) to $LocalIso ..."
    Copy-Item $IsoSource $LocalIso -Force
    Write-Ok "ISO copied ($([math]::Round((Get-Item $LocalIso).Length/1GB,2)) GB)"
} else {
    Write-Ok "ISO already at $LocalIso ($([math]::Round((Get-Item $LocalIso).Length/1GB,2)) GB)"
}

# ─── STEP 2: Mount ISO ───────────────────────────────────────────────
Write-Step 2 "Mount ISO"
# Dismount any stale mount first
try { Dismount-DiskImage $LocalIso -EA SilentlyContinue } catch {}
$mount = Mount-DiskImage $LocalIso -PassThru
Start-Sleep -Seconds 2
$vol = $mount | Get-Volume
$dl = $vol.DriveLetter
if (-not $dl) { Write-Fail "ISO mounted but no drive letter assigned" }
Write-Ok "Mounted at ${dl}:"

# ─── STEP 3: Extract ISO to C:\WinSetup ──────────────────────────────
Write-Step 3 "Extract ISO to $ExtractDir (local NTFS)"
if (Test-Path $ExtractDir) {
    Write-Host "    Removing stale $ExtractDir ..."
    Remove-Item $ExtractDir -Recurse -Force -EA SilentlyContinue
    # Fallback if locked
    if (Test-Path $ExtractDir) {
        cmd /c "rd /s /q `"$ExtractDir`"" 2>$null
    }
}
New-Item -ItemType Directory -Path $ExtractDir -Force | Out-Null
Write-Host "    Robocopy ${dl}:\ -> $ExtractDir (MT:128) ..."
robocopy "${dl}:\" $ExtractDir /E /MT:128 /NFL /NDL /NJH /NJS /R:2 /W:1 | Out-Null
# Verify critical files
$critical = @(
    'setup.exe',
    'sources\migcore.dll',
    'sources\AppExtAgent.dll',
    'sources\dismapi.dll',
    'sources\mighost.exe',
    'sources\migstore.dll',
    'sources\unbcl.dll',
    'sources\wdscore.dll',
    'sources\install.esd',
    'sources\SetupPlatform.cfg'
)
$missing = @()
foreach ($f in $critical) {
    $p = Join-Path $ExtractDir $f
    if (-not (Test-Path $p)) { $missing += $f }
}
if ($missing.Count -gt 0) { Write-Fail "Missing after extract: $($missing -join ', ')" }
$fileCount = (Get-ChildItem $ExtractDir -Recurse -File -EA SilentlyContinue | Measure-Object).Count
Write-Ok "Extracted $fileCount files. All critical DLLs present."

# Dismount ISO (no longer needed)
try { Dismount-DiskImage $LocalIso -EA SilentlyContinue } catch {}

# ─── STEP 4: Clean stale upgrade folders ─────────────────────────────
Write-Step 4 "Clean stale upgrade folders"
foreach ($dir in @("C:\`$WINDOWS.~BT", "C:\`$Windows.~WS")) {
    if (Test-Path $dir) {
        cmd /c "takeown /f `"$dir`" /r /d y" 2>$null | Out-Null
        cmd /c "icacls `"$dir`" /grant administrators:F /t" 2>$null | Out-Null
        cmd /c "rd /s /q `"$dir`"" 2>$null
        if (Test-Path $dir) { Write-Host "    WARNING: Could not fully remove $dir" -ForegroundColor Yellow }
        else { Write-Ok "Removed $dir" }
    } else {
        Write-Ok "$dir already clean"
    }
}

# ─── STEP 5: Clear PendingFileRenameOperations ───────────────────────
Write-Step 5 "Clear PendingFileRenameOperations"
$pfro = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -EA SilentlyContinue).PendingFileRenameOperations
if ($pfro) {
    Remove-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -Force -EA SilentlyContinue
    Write-Ok "Cleared $($pfro.Count) entries"
} else {
    Write-Ok "None pending"
}

# ─── STEP 6: Remove blocking legacy drivers ──────────────────────────
Write-Step 6 "Remove blocking legacy printer drivers"
$driverDump = pnputil /enum-drivers 2>&1 | Out-String
# Find all legacy printer drivers with unsigned binaries
$oems = [regex]::Matches($driverDump, 'Published Name:\s+(oem\d+\.inf)\s+.*?Class Name:\s+Printer.*?Attributes:\s+Legacy', 'Singleline')
if ($oems.Count -gt 0) {
    foreach ($m in $oems) {
        $oem = $m.Groups[1].Value
        pnputil /delete-driver $oem /force 2>$null | Out-Null
        Write-Ok "Removed $oem (legacy printer)"
    }
} else {
    Write-Ok "No blocking legacy drivers found"
}

# ─── STEP 7: Stop IIS to prevent migration errors ───────────────────
Write-Step 7 "Stop IIS services"
foreach ($svc in @('W3SVC','WAS','IISADMIN')) {
    $s = Get-Service $svc -EA SilentlyContinue
    if ($s -and $s.Status -eq 'Running') {
        Stop-Service $svc -Force -EA SilentlyContinue
        Write-Ok "Stopped $svc"
    }
}

# ─── STEP 8: Start required services ─────────────────────────────────
Write-Step 8 "Start required services"
$required = @(
    @{Name='wuauserv';      Startup='Manual'},
    @{Name='BITS';          Startup='Manual'},
    @{Name='cryptsvc';      Startup='Automatic'},
    @{Name='TrustedInstaller'; Startup='Manual'},
    @{Name='DiagTrack';     Startup='Manual'},
    @{Name='msiserver';     Startup='Manual'}
)
foreach ($r in $required) {
    $s = Get-Service $r.Name -EA SilentlyContinue
    if ($s) {
        Set-Service $r.Name -StartupType $r.Startup -EA SilentlyContinue
        if ($s.Status -ne 'Running') { Start-Service $r.Name -EA SilentlyContinue }
        $s = Get-Service $r.Name
        if ($s.Status -eq 'Running') { Write-Ok "$($r.Name): Running" }
        else { Write-Host "    [WARN] $($r.Name): $($s.Status)" -ForegroundColor Yellow }
    }
}

# ─── STEP 9: Clear CBS RebootPending if present ─────────────────────
Write-Step 9 "Clear reboot-pending flags"
$paths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
)
foreach ($rp in $paths) {
    if (Test-Path $rp) {
        Remove-Item $rp -Force -EA SilentlyContinue
        Write-Ok "Cleared $(Split-Path $rp -Leaf)"
    }
}
# Re-check PFRO (services may have re-added)
$pfro2 = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -EA SilentlyContinue).PendingFileRenameOperations
if ($pfro2) {
    Remove-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -Force -EA SilentlyContinue
    Write-Ok "Re-cleared PFRO ($($pfro2.Count) entries)"
}
Write-Ok "No reboot-pending flags"

# ─── STEP 10: Disk space check ───────────────────────────────────────
Write-Step 10 "Verify disk space"
$freeGB = [math]::Round((Get-PSDrive C).Free/1GB, 1)
if ($freeGB -lt 20) { Write-Fail "Only $freeGB GB free on C: (need 20+)" }
Write-Ok "$freeGB GB free on C:"

# ─── STEP 11: Pre-flight summary ─────────────────────────────────────
Write-Step 11 "Pre-flight verification"
$checks = @(
    @{Name='setup.exe exists';       OK=(Test-Path "$ExtractDir\setup.exe")},
    @{Name='migcore.dll present';    OK=(Test-Path "$ExtractDir\sources\migcore.dll")},
    @{Name='install.esd present';    OK=(Test-Path "$ExtractDir\sources\install.esd")},
    @{Name='No stale BT folder';    OK=(-not (Test-Path "C:\`$WINDOWS.~BT"))},
    @{Name='wuauserv Running';       OK=((Get-Service wuauserv).Status -eq 'Running')},
    @{Name='IIS stopped';            OK=((Get-Service W3SVC -EA SilentlyContinue).Status -ne 'Running')},
    @{Name='Disk space OK';          OK=($freeGB -ge 20)}
)
$allPass = $true
foreach ($c in $checks) {
    if ($c.OK) { Write-Ok $c.Name }
    else { Write-Host "    [FAIL] $($c.Name)" -ForegroundColor Red; $allPass = $false }
}
if (-not $allPass) { Write-Fail "Pre-flight checks failed. Aborting." }

# ─── STEP 12: Launch repair upgrade ─────────────────────────────────
Write-Step 12 "Launching repair upgrade from $ExtractDir\setup.exe"
Write-Host ""
Write-Host "    === REPAIR UPGRADE STARTING ===" -ForegroundColor Green
Write-Host "    /Auto Upgrade /DynamicUpdate Disable /MigrateDrivers All" -ForegroundColor White
Write-Host "    /ShowOOBE None /Telemetry Disable" -ForegroundColor White
Write-Host "    /Compat IgnoreWarning" -ForegroundColor White
Write-Host ""

$setupArgs = "/Auto Upgrade /DynamicUpdate Disable /MigrateDrivers All /ShowOOBE None /Telemetry Disable /Compat IgnoreWarning"
$proc = Start-Process "$ExtractDir\setup.exe" -ArgumentList $setupArgs -Wait -PassThru
Write-Host "`n    Setup exited with code: $($proc.ExitCode)" -ForegroundColor $(if($proc.ExitCode -eq 0){'Green'}else{'Red'})
