#Requires -Version 5.1
<#
.SYNOPSIS
Windows 11 PC Transfer Script (Improved)
#>

# ---------------- CONFIG ----------------

$SkipAppDataLocal    = $false
$SkipAppDataLocalLow = $false
$SkipBrowserData     = $false
$SkipSSHKeys         = $false
$SkipScheduledTasks  = $false
$SkipWifiProfiles    = $false
$SkipEnvVars         = $false

$RobocopyThreads = 8

$AppDataExcludeDirs  = @("Temp","cache","Cache","CachedData","CrashDumps",
"GPUCache","Code Cache","ShaderCache","Service Worker",
"Crashpad","crashes","logs","Logs","temp")

$AppDataExcludeFiles = @("*.tmp","*.log","*.dmp","*.lock","thumbs.db","desktop.ini")

# ---------------- HELPERS ----------------

function Write-Header($text) {
Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "  $text" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan
}

function Write-Step($text) { Write-Host " n>> $text" -ForegroundColor Yellow }
function Write-OK($text)   { Write-Host "   [OK] $text" -ForegroundColor Green }
function Write-Skip($text) { Write-Host "   [--] $text" -ForegroundColor DarkGray }
function Write-Warn($text) { Write-Host "   [!!] $text" -ForegroundColor Red }

function Format-Bytes($bytes) {
if ($bytes -ge 1GB) { "{0:N1} GB" -f ($bytes / 1GB) }
elseif ($bytes -ge 1MB) { "{0:N1} MB" -f ($bytes / 1MB) }
else { "{0:N1} KB" -f ($bytes / 1KB) }
}

function Invoke-Robocopy($src, $dst, $extraArgs = @()) {
if (-not (Test-Path $src)) {
Write-Skip "Source not found: $src"
return
}


if ($src -like "*OneDrive*") {
    Write-Warn "OneDrive path detected - ensure files are fully synced!"
}

$null = New-Item -ItemType Directory -Path $dst -Force -ErrorAction SilentlyContinue

$args = @(
    $src, $dst,
    "/E",
    "/COPY:DAT",
    "/DCOPY:DAT",
    "/R:2","/W:3",
    "/MT:$RobocopyThreads",
    "/XJ","/SL",
    "/NP","/NFL","/NDL"
) + $extraArgs

& robocopy @args | Out-Null

if ($LASTEXITCODE -ge 8) {
    Write-Warn "Robocopy error ($LASTEXITCODE): $src"
} else {
    Write-OK "Copied: $src"
}

}

# ---------------- BANNER ----------------

Clear-Host
Write-Host ""
Write-Host "  ==========================================" -ForegroundColor Cyan
Write-Host "   Windows 11 PC Transfer Script" -ForegroundColor Cyan
Write-Host "  ==========================================" -ForegroundColor Cyan

# ---------------- DESTINATION ----------------

Write-Header "Choose Destination"

Write-Host "[1] USB Drives (flash + external)"
Write-Host "[2] Manual path"

$choice = Read-Host "Enter 1 or 2"

if ($choice -eq "1") {

# Detect USB disks flash + external HDD/SSD
$usbDisks = Get-CimInstance Win32_DiskDrive | Where-Object { $_.InterfaceType -eq "USB" }

$usbDrives = foreach ($disk in $usbDisks) {
    Get-CimAssociatedInstance $disk -ResultClassName Win32_DiskPartition |
    ForEach-Object {
        Get-CimAssociatedInstance $_ -ResultClassName Win32_LogicalDisk
    }
}

if (-not $usbDrives) {
    Write-Warn "No USB drives found."
    exit
}

$driveList = @($usbDrives)

for ($i=0; $i -lt $driveList.Count; $i++) {
    $d = $driveList[$i]
    $label = if ($d.VolumeName) { $d.VolumeName } else { "No Label" }
    $free  = Format-Bytes $d.FreeSpace
    $total = Format-Bytes $d.Size

    Write-Host "[$($i+1)] $($d.DeviceID) - $label ($free free / $total total)"
}

$pick = [int](Read-Host "Pick drive") - 1
$DestRoot = "$($driveList[$pick].DeviceID)\PC-Transfer_$env:COMPUTERNAME"

} else {
$DestRoot = Join-Path (Read-Host "Enter path") "PC-Transfer_$env:COMPUTERNAME"
}

New-Item -ItemType Directory -Path $DestRoot -Force | Out-Null

# ---------------- CLOSE BROWSERS ----------------

Get-Process chrome,msedge,firefox -ErrorAction SilentlyContinue | Stop-Process -Force

# ---------------- USER FILES ----------------

Write-Header "User Files"

$folders = @{
Desktop   = [Environment]::GetFolderPath("Desktop")
Documents = [Environment]::GetFolderPath("MyDocuments")
Downloads = "$env:USERPROFILE\Downloads"
Pictures  = [Environment]::GetFolderPath("MyPictures")
Music     = [Environment]::GetFolderPath("MyMusic")
Videos    = [Environment]::GetFolderPath("MyVideos")
}

foreach ($k in $folders.Keys) {
Invoke-Robocopy $folders[$k] (Join-Path $DestRoot "UserFiles$k")
}

# ---------------- APPDATA ----------------
Write-Header "AppData"

$copy = Read-Host 'Copy AppData Roaming? (y/n)'
if ($copy -eq 'y') {
    Invoke-Robocopy $env:APPDATA (Join-Path $DestRoot 'AppData\Roaming')
    Write-Host "DEBUG"
    if (-not $SkipAppDataLocal) {
        Invoke-Robocopy $env:APPDATA (Join-Path $DestRoot 'AppData\Local')
    }
        if (-not $SkipAppDataLocalLow) {
            Invoke-Robocopy $env:APPDATA (Join-Path $DestRoot 'AppData\locallow') 
        }
}

# ---------------- BROWSERS ----------------

Write-Header "Browsers"

if (-not $SkipBrowserData) {
    $browsers = @{
        Chrome  = "$env:LOCALAPPDATA\Google\Chrome\User Data"
        Edge    = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"
        Firefox = "$env:APPDATA\Mozilla\Firefox"
    }

    foreach ($b in @($browsers.Keys)) {
        $src = $browsers[$b]
        $dst = Join-Path $DestRoot "Browsers\$b"
        Invoke-Robocopy $src $dst
    }
}

# ---------------- DONE ----------------

Write-Header "Complete"
Write-Host "Saved to: $DestRoot"
Read-Host "Press Enter to exit"
