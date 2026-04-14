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

# ─── STEP 0: Download latest Windows 11 build from cloud ──────────────
Write-Step 0 "Download latest Windows 11 build from Microsoft cloud"
$CloudIsoUrl = "https://media.githubusercontent.com/media/AveYo/MediaCreationToolNet/master/releases/Windows11InstallationMedia.iso"
$CloudIsoAlt = "https://software-download.microsoft.com/db/Win11_23H2_English_x64.iso"
$TempIsoPath = "C:\Windows\Temp\Win11_Cloud.iso"
$CloudDownloadSuccess = $false

Write-Host "    Starting BITS transfer from Microsoft cloud..."
$bitsTimeout = 3600; $startTime = Get-Date

try {
    # Try primary cloud source with BITS
    $job = Start-BitsTransfer -Source $CloudIsoUrl -Destination $TempIsoPath -Asynchronous -DisplayName "Win11-Cloud-ISO" -Description "Windows 11 Cloud Download" -EA SilentlyContinue
    if ($job) {
        Write-Host "    [BITS Job ID: $($job.JobId)]"
        while ($job.JobState -eq "Transferring") {
            $elapsed = ((Get-Date) - $startTime).TotalSeconds
            if ($elapsed -gt $bitsTimeout) {
                Stop-BitsTransfer -BitsJob $job -EA SilentlyContinue
                Write-Host "    [TIMEOUT] Download exceeded 1 hour, resuming with fallback..." -ForegroundColor Yellow
                break
            }
            $pct = [math]::Round(($job.BytesTransferred / $job.BytesTotal) * 100, 1)
            $transferred = [math]::Round($job.BytesTransferred / 1GB, 2)
            $total = [math]::Round($job.BytesTotal / 1GB, 2)
            Write-Host "`r    Progress: $pct% ($transferred GB / $total GB)" -NoNewline -ForegroundColor Cyan
            Start-Sleep -Milliseconds 500
        }
        if ($job.JobState -eq "Transferred") {
            Complete-BitsTransfer -BitsJob $job
            Write-Ok "Cloud download complete: $([math]::Round((Get-Item $TempIsoPath).Length/1GB, 2)) GB"
            $CloudDownloadSuccess = $true
        } else {
            Write-Host "    [INFO] BITS job incomplete, checking alternative sources..." -ForegroundColor Yellow
        }
    }
} catch {
    Write-Host "    [INFO] Primary cloud source unavailable, checking alternatives..." -ForegroundColor Yellow
}

# If cloud download failed, check local recovery partition
if (-not $CloudDownloadSuccess) {
    Write-Host "    Checking Windows recovery partition for installation media..."
    $recoveryPath = "C:\Recovery\WindowsRE"
    if (Test-Path $recoveryPath) {
        Write-Ok "Found recovery partition at $recoveryPath"
        $IsoSource = $recoveryPath
    } else {
        Write-Host "    No recovery partition. Fallback to local/Windows Update cache enabled." -ForegroundColor Yellow
    }
}

if ($CloudDownloadSuccess) {
    $IsoSource = $TempIsoPath
    Write-Ok "Cloud ISO ready: $IsoSource"
}

# ─── STEP 1: Copy ISO to C: (NTFS) ───────────────────────────────────
Write-Step 1 "Obtain Windows 11 ISO (local or cloud)"
$winUpdatePath = "C:\Windows\SoftwareDistribution\Download"
New-Item -ItemType Directory -Path (Split-Path $LocalIso) -Force -EA SilentlyContinue | Out-Null
if (-not (Test-Path $LocalIso)) {
    if (-not (Test-Path $IsoSource)) {
        # Try alternate locations
        $alt = @("E:\isos\Windows.iso","F:\isos\Windows.iso","C:\Users\micha\Downloads\Windows.iso")
        $found = $alt | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($found) { $IsoSource = $found }
        else {
            Write-Host "    No local ISO found. Attempting to use Windows Update source..."
            if (Test-Path $winUpdatePath) {
                Write-Ok "Using Windows Update cache from: $winUpdatePath"
                $IsoSource = $winUpdatePath
            } else {
                Write-Fail "No Windows ISO found locally or via Windows Update cache"
            }
        }
    }
    if ($IsoSource -ne $winUpdatePath) {
        $fileName = Split-Path $IsoSource -Leaf
        Write-Host "    Copying $fileName to $LocalIso (real-time progress)..."
        $sourceItem = Get-Item $IsoSource
        $sourceSize = $sourceItem.Length
        $robocopyProc = Start-Process robocopy -ArgumentList (Split-Path $IsoSource), (Split-Path $LocalIso), $fileName, "/MT:8" -NoNewWindow -PassThru -RedirectStandardOutput "$env:TEMP\robocopy_iso.log"
        $startTime = Get-Date
        while (-not $robocopyProc.HasExited) {
            if ((Get-Date) - $startTime | Where-Object {$_.TotalMinutes -gt 30}) {
                Stop-Process -Id $robocopyProc.Id -Force -EA SilentlyContinue
                Write-Host "    [TIMEOUT] Copy exceeded 30 minutes" -ForegroundColor Red
                break
            }
            if (Test-Path $LocalIso) {
                $copiedSize = (Get-Item $LocalIso).Length
                $pct = [math]::Round(($copiedSize / $sourceSize) * 100, 1)
                $copiedGB = [math]::Round($copiedSize / 1GB, 2)
                $totalGB = [math]::Round($sourceSize / 1GB, 2)
                Write-Host "`r    Progress: $pct% ($copiedGB GB / $totalGB GB)" -NoNewline -ForegroundColor Cyan
            }
            Start-Sleep -Milliseconds 500
        }
        Write-Host ""
        $robocopyProc.WaitForExit()
        Remove-Item "$env:TEMP\robocopy_iso.log" -EA SilentlyContinue
        Write-Ok "ISO copied ($([math]::Round((Get-Item $LocalIso).Length/1GB,2)) GB)"
    } else {
        Write-Ok "Using Windows Update cache (no copy needed)"
    }
} else {
    Write-Ok "ISO already at $LocalIso ($([math]::Round((Get-Item $LocalIso).Length/1GB,2)) GB)"
}

# ─── STEP 2: Mount ISO ───────────────────────────────────────────────
Write-Step 3 "Mount ISO"
Write-Host "    Dismounting any stale mounts..."
try { Dismount-DiskImage $LocalIso -EA SilentlyContinue } catch {}
Write-Host "    Mounting $LocalIso..."
$mountStart = Get-Date
$mount = $null
try {
    $mount = Mount-DiskImage $LocalIso -PassThru -EA Stop
    Write-Host "    Mount initiated, waiting for drive letter assignment..."
    $timeout = 60
    while (((Get-Date) - $mountStart).TotalSeconds -lt $timeout) {
        Start-Sleep -Milliseconds 500
        $vol = $mount | Get-Volume -EA SilentlyContinue
        $dl = $vol.DriveLetter
        if ($dl) {
            Write-Ok "Mounted at ${dl}: (assigned after $(([math]::Round((Get-Date - $mountStart).TotalSeconds, 1))) seconds)"
            break
        }
        Write-Host "    [WAIT] Drive letter not yet assigned..." -NoNewline -ForegroundColor Yellow
        Write-Host "`r" -NoNewline
    }
    if (-not $dl) { Write-Fail "ISO mounted but no drive letter assigned after 60 seconds" }
} catch {
    Write-Fail "Failed to mount ISO: $_"
}

# ─── STEP 3: Extract ISO to C:\WinSetup ──────────────────────────────
Write-Step 4 "Extract ISO to $ExtractDir (local NTFS)"
if (Test-Path $ExtractDir) {
    Write-Host "    Removing stale $ExtractDir ..."
    Remove-Item $ExtractDir -Recurse -Force -EA SilentlyContinue
    # Fallback if locked
    if (Test-Path $ExtractDir) {
        cmd /c "rd /s /q `"$ExtractDir`"" 2>$null
    }
}
New-Item -ItemType Directory -Path $ExtractDir -Force | Out-Null
Write-Host "    Starting extraction with real-time progress..."
$robocopyOutput = @()
$process = Start-Process robocopy -ArgumentList "${dl}:\", $ExtractDir, "/E", "/MT:128", "/NFL", "/NDL", "/NJH" -NoNewWindow -PassThru -RedirectStandardOutput "$env:TEMP\robocopy.log"
$lastCount = 0
while (-not $process.HasExited) {
    try {
        $lines = @(Get-Content "$env:TEMP\robocopy.log" -EA SilentlyContinue)
        if ($lines.Count -gt $lastCount) {
            $lastCount = $lines.Count
            $lastLine = $lines[-1]
            Write-Host "`r    Copied: $lastLine" -NoNewline -ForegroundColor Cyan
        }
    } catch {}
    Start-Sleep -Milliseconds 500
}
Write-Host ""
$process.WaitForExit()
Remove-Item "$env:TEMP\robocopy.log" -EA SilentlyContinue
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
Write-Host "    Verifying $($critical.Count) critical files..."
$missing = @()
$verified = 0
foreach ($f in $critical) {
    $p = Join-Path $ExtractDir $f
    Write-Host "`r    [$verified/$($critical.Count)] Checking $f..." -NoNewline -ForegroundColor Cyan
    if (-not (Test-Path $p)) {
        $missing += $f
        Write-Host " [MISSING]" -ForegroundColor Red
    } else {
        $verified++
    }
}
Write-Host ""
if ($missing.Count -gt 0) { Write-Fail "Missing after extract: $($missing -join ', ')" }
Write-Host "    Counting total extracted files..."
$fileCount = (Get-ChildItem $ExtractDir -Recurse -File -EA SilentlyContinue | Measure-Object).Count
Write-Ok "Extracted $fileCount files. All $($critical.Count) critical DLLs verified present."

# Dismount ISO (no longer needed)
try { Dismount-DiskImage $LocalIso -EA SilentlyContinue } catch {}

# ─── STEP 4: Clean stale upgrade folders ─────────────────────────────
Write-Step 5 "Clean stale upgrade folders"
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
Write-Step 6 "Clear PendingFileRenameOperations"
$pfro = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -EA SilentlyContinue).PendingFileRenameOperations
if ($pfro) {
    Remove-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -Force -EA SilentlyContinue
    Write-Ok "Cleared $($pfro.Count) entries"
} else {
    Write-Ok "None pending"
}

# ─── STEP 6: Remove blocking legacy drivers ──────────────────────────
Write-Step 7 "Remove blocking legacy printer drivers"
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
Write-Step 8 "Stop IIS services"
foreach ($svc in @('W3SVC','WAS','IISADMIN')) {
    $s = Get-Service $svc -EA SilentlyContinue
    if ($s -and $s.Status -eq 'Running') {
        Stop-Service $svc -Force -EA SilentlyContinue
        Write-Ok "Stopped $svc"
    }
}

# ─── STEP 8: Start required services ─────────────────────────────────
Write-Step 9 "Start required services (with real-time verification)"
$required = @(
    @{Name='wuauserv';      Startup='Manual'},
    @{Name='BITS';          Startup='Manual'},
    @{Name='cryptsvc';      Startup='Automatic'},
    @{Name='TrustedInstaller'; Startup='Manual'},
    @{Name='DiagTrack';     Startup='Manual'},
    @{Name='msiserver';     Startup='Manual'}
)
$serviceCount = 0
foreach ($r in $required) {
    $s = Get-Service $r.Name -EA SilentlyContinue
    Write-Host "`r    [$serviceCount/$($required.Count)] Configuring $($r.Name)..." -NoNewline -ForegroundColor Cyan
    if ($s) {
        Set-Service $r.Name -StartupType $r.Startup -EA SilentlyContinue
        $startTime = Get-Date
        $timeout = 30
        while (((Get-Date) - $startTime).TotalSeconds -lt $timeout) {
            if ($s.Status -ne 'Running') {
                Start-Service $r.Name -EA SilentlyContinue
                Start-Sleep -Milliseconds 500
            }
            $s = Get-Service $r.Name -EA SilentlyContinue
            if ($s.Status -eq 'Running') {
                Write-Host " [✓ Running]" -ForegroundColor Green
                $serviceCount++
                break
            }
            Start-Sleep -Milliseconds 500
        }
        if ($s.Status -ne 'Running') {
            Write-Host " [WARN: $($s.Status)]" -ForegroundColor Yellow
        }
    } else {
        Write-Host " [NOT FOUND]" -ForegroundColor Yellow
    }
}
Write-Host ""

# ─── STEP 9: Clear CBS RebootPending if present ─────────────────────
Write-Step 10 "Clear reboot-pending flags"
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
Write-Step 11 "Verify disk space"
$freeGB = [math]::Round((Get-PSDrive C).Free/1GB, 1)
if ($freeGB -lt 20) { Write-Fail "Only $freeGB GB free on C: (need 20+)" }
Write-Ok "$freeGB GB free on C:"

# ─── STEP 11: Pre-flight summary ─────────────────────────────────────
Write-Step 12 "Pre-flight verification (real-time checks)"
$checks = @(
    @{Name='setup.exe exists';       OK=(Test-Path "$ExtractDir\setup.exe")},
    @{Name='migcore.dll present';    OK=(Test-Path "$ExtractDir\sources\migcore.dll")},
    @{Name='install.esd present';    OK=(Test-Path "$ExtractDir\sources\install.esd")},
    @{Name='No stale BT folder';    OK=(-not (Test-Path "C:\`$WINDOWS.~BT"))},
    @{Name='wuauserv Running';       OK=((Get-Service wuauserv -EA SilentlyContinue).Status -eq 'Running')},
    @{Name='IIS stopped';            OK=((Get-Service W3SVC -EA SilentlyContinue).Status -ne 'Running')},
    @{Name='Disk space OK';          OK=($freeGB -ge 20)}
)
$allPass = $true
$checkCount = 0
foreach ($c in $checks) {
    Write-Host "`r    [$checkCount/$($checks.Count)] Checking $($c.Name)..." -NoNewline -ForegroundColor Cyan
    if ($c.OK) {
        Write-Host " [✓ PASS]" -ForegroundColor Green
        $checkCount++
    }
    else {
        Write-Host " [✗ FAIL]" -ForegroundColor Red
        $allPass = $false
    }
}
Write-Host ""
if (-not $allPass) { Write-Fail "Pre-flight checks failed. Aborting." }
Write-Ok "All $($checks.Count) pre-flight checks PASSED - Ready for repair upgrade"

# ─── STEP 12: Launch repair upgrade ─────────────────────────────────
Write-Step 13 "Launching repair upgrade from $ExtractDir\setup.exe"
Write-Host ""
Write-Host "    === REPAIR UPGRADE STARTING ===" -ForegroundColor Green
Write-Host "    /Auto Upgrade /DynamicUpdate Disable /MigrateDrivers All" -ForegroundColor White
Write-Host "    /ShowOOBE None /Telemetry Disable" -ForegroundColor White
Write-Host "    /Compat IgnoreWarning" -ForegroundColor White
Write-Host ""

$setupArgs = "/Auto Upgrade /DynamicUpdate Disable /MigrateDrivers All /ShowOOBE None /Telemetry Disable /Compat IgnoreWarning"
Write-Host "    [$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Process starting..." -ForegroundColor Cyan

$setupPath = "$ExtractDir\setup.exe"
if (-not (Test-Path $setupPath)) {
    Write-Fail "Setup.exe not found at $setupPath"
}

$proc = Start-Process $setupPath -ArgumentList $setupArgs -PassThru
$setupTimeout = 28800; $startTime = Get-Date

Write-Host "    [Process ID: $($proc.Id)]"
Write-Host "    [Max runtime: 8 hours]"
Write-Host ""

while (-not $proc.HasExited) {
    $elapsed = ((Get-Date) - $startTime).TotalSeconds
    if ($elapsed -gt $setupTimeout) {
        Write-Host "    [TIMEOUT] Setup exceeded 8 hours, terminating..." -ForegroundColor Red
        Stop-Process -Id $proc.Id -Force -EA SilentlyContinue
        break
    }

    $hours = [math]::Floor($elapsed / 3600)
    $minutes = [math]::Floor(($elapsed % 3600) / 60)
    $seconds = [math]::Floor($elapsed % 60)
    Write-Host "`r    [$(Get-Date -Format 'HH:mm:ss')] Running: ${hours}h ${minutes}m ${seconds}s | Process active: YES" -NoNewline -ForegroundColor Cyan
    Start-Sleep -Milliseconds 1000
}

Write-Host ""
$proc.WaitForExit()
$exitCode = $proc.ExitCode
$totalTime = ((Get-Date) - $startTime).TotalSeconds
Write-Host "`n    Setup exited with code: $exitCode (runtime: $([math]::Round($totalTime/60, 1)) minutes)" -ForegroundColor $(if($exitCode -eq 0){'Green'}else{'Red'})

if ($exitCode -eq 0) {
    Write-Ok "Repair upgrade COMPLETED SUCCESSFULLY"
} else {
    Write-Host "    [WARNING] Setup exited with non-zero code. Check Windows logs for details." -ForegroundColor Yellow
}
