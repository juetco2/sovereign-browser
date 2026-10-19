<#
  build-exe.ps1 - compiles cybershield-launcher.ps1 into Cybershield.exe

  Run it once:
      right-click -> Run with PowerShell
  or:
      powershell -ExecutionPolicy Bypass -File .\build-exe.ps1

  Produces Cybershield.exe in this folder. Double-click that from then on.
  The .exe is self-contained: it installs the Google Cloud CLI and signs in
  itself, so the target machine needs nothing pre-installed.
#>

param([string]$OutFile)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src  = Join-Path $here 'cybershield-launcher.ps1'
if ($OutFile) { $out = Join-Path $here $OutFile } else { $out = Join-Path $here 'Cybershield.exe' }

if (-not (Test-Path $src)) { throw "Missing $src" }

# --- ps2exe module ----------------------------------------------------------
if (-not (Get-Command Invoke-PS2EXE -ErrorAction SilentlyContinue)) {
    Write-Host 'Installing the ps2exe module (one time)...'
    try {
        Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
    } catch { }
    try {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    } catch { }
    Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber
}

# --- app icon (best effort - skipped if anything goes wrong) ----------------
$icon = Join-Path $here 'cybershield.ico'
$haveIcon = $false
try {
    Add-Type -AssemblyName System.Drawing
    $size = 64
    $bmp = New-Object Drawing.Bitmap $size, $size
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([Drawing.Color]::FromArgb(11, 16, 32))
    $pen = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(126, 242, 168)), 6
    $g.DrawEllipse($pen, 7, 7, $size - 14, $size - 14)
    $g.DrawLines($pen, @(
        (New-Object Drawing.Point 20, 34),
        (New-Object Drawing.Point 29, 44),
        (New-Object Drawing.Point 45, 22)
    ))
    $g.Dispose()
    $hicon = $bmp.GetHicon()
    $ico = [Drawing.Icon]::FromHandle($hicon)
    $fs = [IO.File]::Create($icon)
    $ico.Save($fs)
    $fs.Close()
    $bmp.Dispose()
    $haveIcon = $true
}
catch { $haveIcon = $false }

# --- compile ----------------------------------------------------------------
$opts = @{
    InputFile   = $src
    OutputFile  = $out
    noConsole   = $true
    title       = 'STAI Cybershield'
    product     = 'STAI Cybershield'
    description = 'Launcher for the locked browser session'
    company     = 'STAI'
    version     = '1.0.0.0'
}
if ($haveIcon) { $opts.iconFile = $icon }

Invoke-PS2EXE @opts

Write-Host ''
Write-Host "Built: $out"
Write-Host 'Double-click it. It installs the Google Cloud CLI and signs in itself.'
