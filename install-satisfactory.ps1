<#
.SYNOPSIS
  One-click installer / updater for SatisFactory on Windows.

.DESCRIPTION
  Downloads the latest public Windows builds and installs them:
    * the SatisFactory VST3 plugin (for REAPER / any VST3 host),
    * the Standalone app (no DAW needed),
    * the SatisFactory editor,
  and creates Start-Menu + Desktop shortcuts.

  Builds are pulled from the PUBLIC releases mirror, so NO GitHub token is needed.
  Just re-run this script any time to update to the latest build.

  Quick install (PowerShell):
    irm https://raw.githubusercontent.com/mikeyd433/SatisFactory_Releases/main/install-satisfactory.ps1 | iex

  Or download this file and run it (lets you pass the options below):
    powershell -ExecutionPolicy Bypass -File .\install-satisfactory.ps1

.PARAMETER PluginOnly
  Install/update only the VST3 plugin (+ Standalone). Skip the editor.

.PARAMETER SystemVst3
  Install the VST3 into the machine-wide folder (C:\Program Files\Common Files\VST3),
  which REAPER scans automatically. Requires running as Administrator.
  Default: if you are an Administrator the system folder is used automatically;
  otherwise the per-user VST3 folder is used (you add that path in REAPER once).

.PARAMETER NoShortcuts
  Do not create Start-Menu / Desktop shortcuts.

.PARAMETER Mirror
  Override the public mirror repo (owner/name). Default: mikeyd433/SatisFactory_Releases.
#>
[CmdletBinding()]
param(
  [switch]$PluginOnly,
  [switch]$SystemVst3,
  [switch]$NoShortcuts,
  [string]$Mirror = 'mikeyd433/SatisFactory_Releases'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # faster, quieter Invoke-WebRequest

$base      = "https://github.com/$Mirror/releases/download"
$vst3Url   = "$base/vst3-latest/SatisFactory-Windows-VST3-and-Standalone.zip"
$editorUrl = "$base/editor-latest/SatisFactory-Editor-Windows.zip"

function Write-Step($m){ Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok($m){   Write-Host "    $m" -ForegroundColor Green }
function Write-Warn2($m){ Write-Host "    $m" -ForegroundColor Yellow }

# Older PowerShell defaults can fail GitHub's TLS — force TLS 1.2.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$isAdmin = $false
try {
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
             ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {}

if ($SystemVst3 -and -not $isAdmin) {
  throw "-SystemVst3 needs Administrator rights. Right-click PowerShell -> 'Run as administrator', or omit -SystemVst3 to install to your per-user VST3 folder."
}

$work = Join-Path $env:TEMP ("satisfactory_install_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null

function Get-AndExtract([string]$url, [string]$name) {
  $zip = Join-Path $work "$name.zip"
  $out = Join-Path $work $name
  Write-Step "Downloading $name ..."
  try {
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
  } catch {
    throw "Download failed for $name ($url). The build may not be published yet, or there is no network. Details: $($_.Exception.Message)"
  }
  Write-Step "Extracting $name ..."
  if (Test-Path $out) { Remove-Item -Recurse -Force $out }
  Expand-Archive -Path $zip -DestinationPath $out -Force
  return $out
}

$installedVst3 = $null
$standaloneDir = $null
$editorDir     = $null

try {
  # ---------------------------------------------------------------- VST3 + Standalone
  $vst3Root = Get-AndExtract $vst3Url 'vst3'

  $vst3Bundle = Get-ChildItem -Path $vst3Root -Recurse -Directory -Filter 'SatisFactory.vst3' |
                Select-Object -First 1
  if (-not $vst3Bundle) { throw "SatisFactory.vst3 not found inside the downloaded VST3 zip." }

  if ($SystemVst3 -or $isAdmin) {
    $vst3Dir = Join-Path $env:CommonProgramFiles 'VST3'              # C:\Program Files\Common Files\VST3
    $vst3Scope = 'system'
  } else {
    $vst3Dir = Join-Path $env:LOCALAPPDATA 'Programs\Common\VST3'    # per-user, no admin needed
    $vst3Scope = 'user'
  }
  New-Item -ItemType Directory -Force -Path $vst3Dir | Out-Null
  $installedVst3 = Join-Path $vst3Dir 'SatisFactory.vst3'
  if (Test-Path $installedVst3) { Remove-Item -Recurse -Force $installedVst3 }
  Copy-Item -Recurse -Force $vst3Bundle.FullName $installedVst3
  Write-Ok "VST3 installed -> $installedVst3"

  # The Standalone .exe ships in the same zip (keep wasmtime.dll beside it).
  $standaloneExe = Get-ChildItem -Path $vst3Root -Recurse -File -Filter 'SatisFactory.exe' |
                   Select-Object -First 1
  if ($standaloneExe) {
    $standaloneDir = Join-Path $env:LOCALAPPDATA 'SatisFactory\Standalone'
    if (Test-Path $standaloneDir) { Remove-Item -Recurse -Force $standaloneDir }
    New-Item -ItemType Directory -Force -Path $standaloneDir | Out-Null
    Copy-Item -Recurse -Force (Join-Path $standaloneExe.DirectoryName '*') $standaloneDir
    Write-Ok "Standalone installed -> $standaloneDir"
  }

  # ---------------------------------------------------------------- Editor
  if (-not $PluginOnly) {
    $editorRoot = Get-AndExtract $editorUrl 'editor'
    $editorExe = Get-ChildItem -Path $editorRoot -Recurse -File -Filter 'satisfactory_editor.exe' |
                 Select-Object -First 1
    if (-not $editorExe) { throw "satisfactory_editor.exe not found inside the downloaded editor zip." }
    $editorDir = Join-Path $env:LOCALAPPDATA 'SatisFactory\editor'
    if (Test-Path $editorDir) { Remove-Item -Recurse -Force $editorDir }
    New-Item -ItemType Directory -Force -Path $editorDir | Out-Null
    Copy-Item -Recurse -Force (Join-Path $editorExe.DirectoryName '*') $editorDir
    Write-Ok "Editor installed -> $editorDir"
  }

  # ---------------------------------------------------------------- Shortcuts
  if (-not $NoShortcuts) {
    $shell     = New-Object -ComObject WScript.Shell
    $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\SatisFactory'
    New-Item -ItemType Directory -Force -Path $startMenu | Out-Null
    $desktop   = [Environment]::GetFolderPath('Desktop')

    function New-Shortcut([string]$linkPath, [string]$target, [string]$workDir) {
      $sc = $shell.CreateShortcut($linkPath)
      $sc.TargetPath       = $target
      $sc.WorkingDirectory = $workDir
      $sc.Save()
    }

    if ($editorDir) {
      $t = Join-Path $editorDir 'satisfactory_editor.exe'
      New-Shortcut (Join-Path $startMenu 'SatisFactory Editor.lnk') $t $editorDir
      New-Shortcut (Join-Path $desktop   'SatisFactory Editor.lnk') $t $editorDir
      Write-Ok "Shortcuts created: SatisFactory Editor (Start Menu + Desktop)"
    }
    if ($standaloneDir) {
      $t = Join-Path $standaloneDir 'SatisFactory.exe'
      New-Shortcut (Join-Path $startMenu 'SatisFactory Standalone.lnk') $t $standaloneDir
      Write-Ok "Shortcut created: SatisFactory Standalone (Start Menu)"
    }

    # One-click updater: a shortcut that re-runs THIS installer from the public mirror,
    # so a double-click force-updates everything to the latest build. Stays per-user
    # (don't run it as admin) so it keeps updating the folder REAPER is pointed at.
    $updUrl = 'https://raw.githubusercontent.com/mikeyd433/SatisFactory_Releases/main/install-satisfactory.ps1'
    $psExe  = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    foreach ($loc in @((Join-Path $startMenu 'Update SatisFactory.lnk'), (Join-Path $desktop 'Update SatisFactory.lnk'))) {
      $sc = $shell.CreateShortcut($loc)
      $sc.TargetPath       = $psExe
      $sc.Arguments        = "-NoProfile -ExecutionPolicy Bypass -NoExit -Command `"irm $updUrl | iex`""
      $sc.WorkingDirectory = $env:USERPROFILE
      if ($editorDir) { $sc.IconLocation = (Join-Path $editorDir 'satisfactory_editor.exe') + ',0' }
      $sc.Description       = 'Download and install the latest SatisFactory builds'
      $sc.Save()
    }
    Write-Ok "Shortcut created: Update SatisFactory (Start Menu + Desktop) — double-click to update"
  }

  # ---------------------------------------------------------------- Summary
  Write-Host ""
  Write-Host "SatisFactory is up to date." -ForegroundColor Green
  Write-Host "  VST3:       $installedVst3"
  if ($standaloneDir) { Write-Host "  Standalone: $standaloneDir\SatisFactory.exe" }
  if ($editorDir)     { Write-Host "  Editor:     $editorDir\satisfactory_editor.exe" }
  if (-not $NoShortcuts) { Write-Host '  Update:     double-click "Update SatisFactory" on your Desktop any time' -ForegroundColor Green }
  Write-Host ""
  if ($vst3Scope -eq 'user') {
    Write-Warn2 "The VST3 went to your PER-USER folder (no admin needed):"
    Write-Warn2 "  $vst3Dir"
    Write-Warn2 "In REAPER: Options > Preferences > Plug-ins > VST > add that path to the VST3"
    Write-Warn2 "scan list, then click 'Re-scan'. (Tip: re-run this as administrator to install"
    Write-Warn2 "into the system folder REAPER scans automatically.)"
  } else {
    Write-Warn2 "In REAPER: Options > Preferences > Plug-ins > VST > 'Re-scan' to pick up the update."
  }
}
finally {
  Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
