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

.PARAMETER NoAdb
  Skip auto-installing Android platform-tools (adb). adb powers the editor's
  "live mirror to phone" over USB; it's installed by default alongside the editor.
#>
[CmdletBinding()]
param(
  [switch]$PluginOnly,
  [switch]$SystemVst3,
  [switch]$NoShortcuts,
  [switch]$NoAdb,
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

# Process names the SatisFactory apps run as — matched by name so a lingering one
# is caught even when its .Path can't be read (a process started elevated hides
# its path from a non-elevated installer, and a directory holding a running .exe
# can be neither deleted nor renamed, which is what dead-ends the update).
$script:AppProcNames = @('satisfactory_editor', 'SatisFactory')

# Shut down the adb server the editor starts for phone-mirroring. adb daemonizes,
# so its server process keeps running after the editor closes — and it inherited
# the editor's working directory (…\SatisFactory\editor), so that open *directory*
# handle blocks the editor folder from being deleted OR renamed even though no
# SatisFactory app is left running (the exact "locked, nothing running" dead end).
# Graceful 'kill-server' first, then force-kill any stragglers. adb restarts on
# demand, so this is safe to call before any update.
function Stop-Adb {
  $adb = Join-Path $env:LOCALAPPDATA 'SatisFactory\platform-tools\adb.exe'
  if (Test-Path $adb) { try { & $adb 'kill-server' 2>$null | Out-Null } catch {} }
  Get-Process adb -ErrorAction SilentlyContinue | ForEach-Object {
    try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch {}
  }
}

# Stop any SatisFactory app holding files in $dir — matched by exe path under the
# dir OR by known process name — so its files (the .exe and loaded DLLs like
# desktop_drop_plugin.dll) unlock and the dir can be replaced. Returns a list of
# "name (PID n)" for any matching process still alive after the attempt (e.g. one
# running as administrator that a non-elevated installer can't kill), so the
# caller can name the real blocker.
function Stop-AppProcessesIn([string]$dir) {
  Stop-Adb | Out-Null   # release the editor folder if the lingering adb server holds it
  $dirPath = $null
  if ($dir) {
    $resolved = Resolve-Path $dir -ErrorAction SilentlyContinue
    if ($resolved) { $dirPath = $resolved.Path.TrimEnd('\') }
  }
  $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $match = $false
    if ($script:AppProcNames -contains $_.ProcessName) {
      $match = $true                                   # by name (path may be unreadable)
    } elseif ($dirPath) {
      try { $match = ($_.Path -and $_.Path.StartsWith($dirPath, [System.StringComparison]::OrdinalIgnoreCase)) }
      catch { $match = $false }                        # protected process — .Path throws; skip
    }
    $match
  })
  foreach ($p in $procs) {
    try {
      Write-Warn2 "Closing running $($p.ProcessName) (PID $($p.Id)) so it can be updated ..."
      $p.CloseMainWindow() | Out-Null
      if (-not $p.WaitForExit(3000)) { Stop-Process -Id $p.Id -Force -ErrorAction Stop }
    } catch {
      Write-Warn2 "Couldn't close $($p.ProcessName) (PID $($p.Id)) automatically — it may be running as administrator."
    }
  }
  if ($procs.Count) { Start-Sleep -Milliseconds 500 }   # let handles release
  $survivors = @()
  foreach ($p in $procs) {
    try { $p.Refresh(); if (-not $p.HasExited) { $survivors += "$($p.ProcessName) (PID $($p.Id))" } } catch {}
  }
  return $survivors
}

# Best-effort sweep of any "<dir>.old_*" folders an earlier run renamed aside
# but couldn't delete yet (the lock had cleared by now, or it'll try again next
# time). Never throws.
function Clear-AsideDirs([string]$dir) {
  $parent = Split-Path -Parent $dir
  $leaf   = Split-Path -Leaf  $dir
  if (-not (Test-Path $parent)) { return }
  Get-ChildItem -LiteralPath $parent -Directory -Filter "$leaf.old_*" -ErrorAction SilentlyContinue |
    ForEach-Object { try { Remove-Item -Recurse -Force $_.FullName -ErrorAction SilentlyContinue } catch {} }
}

# Replace an install dir: stop anything running from it, then clear it so the
# caller can install fresh. Strategy:
#  1. Stop apps that run from the dir, then try an in-place delete with a few
#     retries (file handles release a beat after a process exits, and a brief
#     antivirus scan / Explorer preview can hold a file for a second or two).
#  2. If that still fails, RENAME the dir aside and let the caller recreate the
#     original path. A rename succeeds for the common *non-app* locks (an open
#     File Explorer window on the folder, antivirus, the Windows Search indexer)
#     that block deletion but not a move — so the update goes through instead of
#     dead-ending. A genuinely running app holds a *loaded DLL*, which blocks the
#     rename too, so the clear "close the app" error below still fires for it.
function Remove-AppDir([string]$dir) {
  if (-not (Test-Path $dir)) { Clear-AsideDirs $dir; return }
  $survivors = Stop-AppProcessesIn $dir
  for ($i = 0; $i -lt 8; $i++) {
    try { Remove-Item -Recurse -Force $dir -ErrorAction Stop; Clear-AsideDirs $dir; return }
    catch { Start-Sleep -Milliseconds (400 + $i * 300) }   # ~0.4s..2.5s, ~11s total
  }
  $aside = "$dir.old_$([Guid]::NewGuid().ToString('N').Substring(0,8))"
  try {
    Move-Item -LiteralPath $dir -Destination $aside -Force -ErrorAction Stop
  } catch {
    # Name the blocker when we found one we couldn't kill (usually an elevated
    # leftover); otherwise point at the usual non-app culprits.
    if ($survivors -and $survivors.Count) {
      throw "Couldn't update '$dir' — still locked by: $($survivors -join ', '). That's a SatisFactory app this installer couldn't close (often because it was started as administrator). End it from Task Manager -> Details tab (right-click -> End task), then re-run the installer. If it keeps coming back, reboot and run the update before opening anything."
    }
    throw "Couldn't update '$dir' — it's locked by another program, but no SatisFactory app was found running. Most likely an open File Explorer window on that folder, antivirus mid-scan, or Windows Search holding it. Close those — or just REBOOT and run the update first thing, before opening the editor. (To see exactly what's holding it: open Resource Monitor -> CPU -> Associated Handles and search 'SatisFactory\editor'; whatever process it names, close it.)"
  }
  # Renamed aside successfully; the original path is now free. Try to delete the
  # old copy now, but don't fail the install if it's still held — Clear-AsideDirs
  # sweeps it on a later run.
  try { Remove-Item -Recurse -Force $aside -ErrorAction SilentlyContinue } catch {}
}

# Install Android platform-tools (adb) to a known per-user location so the editor
# auto-detects it for "live mirror to phone" — no manual adb setup.
#
# Stage-then-swap: download + extract + VERIFY adb.exe in a temp copy FIRST, and
# only then replace the installed copy. A failed/blocked download therefore never
# destroys a working adb (the bug that left platform-tools empty). Non-fatal: on
# any failure it warns and keeps the existing copy.
function Install-PlatformTools {
  $dest = Join-Path $env:LOCALAPPDATA 'SatisFactory\platform-tools'
  try {
    Write-Step "Downloading Android platform-tools (adb) ..."
    $zip = Join-Path $work 'platform-tools.zip'
    Invoke-WebRequest -Uri 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' `
                      -OutFile $zip -UseBasicParsing
    $tmp = Join-Path $work 'platform-tools-extract'
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    # The zip nests everything under a top-level 'platform-tools' folder.
    $src = Join-Path $tmp 'platform-tools'
    if (-not (Test-Path $src)) { $src = $tmp }
    # Verify the staged copy BEFORE touching the installed one.
    if (-not (Test-Path (Join-Path $src 'adb.exe'))) {
      throw "adb.exe was not in the platform-tools download"
    }
    # Stop a running adb server from the old copy so its files unlock, then swap.
    $oldAdb = Join-Path $dest 'adb.exe'
    if (Test-Path $oldAdb) { try { & $oldAdb 'kill-server' 2>$null | Out-Null } catch {} }
    Remove-AppDir $dest
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item -Recurse -Force (Join-Path $src '*') $dest
    if (-not (Test-Path (Join-Path $dest 'adb.exe'))) {
      throw "adb.exe was not copied into $dest"
    }
    Write-Ok "adb installed -> $dest"
    return $dest
  } catch {
    Write-Warn2 "Skipped adb auto-install: $($_.Exception.Message). Existing adb (if any) was left untouched; you can also install Android platform-tools yourself and use 'Locate adb' in the editor."
    if (Test-Path (Join-Path $dest 'adb.exe')) { return $dest } else { return $null }
  }
}

$installedVst3 = $null
$standaloneDir = $null
$editorDir     = $null
$adbDir        = $null

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
    Remove-AppDir $standaloneDir
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
    Remove-AppDir $editorDir
    New-Item -ItemType Directory -Force -Path $editorDir | Out-Null
    Copy-Item -Recurse -Force (Join-Path $editorExe.DirectoryName '*') $editorDir
    Write-Ok "Editor installed -> $editorDir"

    # adb for the editor's "live mirror to phone" over USB — auto-detected by the
    # editor, so the phone link needs no manual setup. Opt out with -NoAdb.
    if (-not $NoAdb) { $adbDir = Install-PlatformTools }
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

    # Phone-app shortcut: opens the public "Install on Android" page (QR + link) so you can
    # scan it from your phone to install/update the SatisFactory Android app. A .url opens
    # the page in your default browser — nothing to install on the PC.
    $phoneUrl = 'https://github.com/mikeyd433/SatisFactory_Releases#install-on-android-phone--tablet'
    foreach ($loc in @((Join-Path $startMenu 'SatisFactory Phone App.url'), (Join-Path $desktop 'SatisFactory Phone App.url'))) {
      Set-Content -LiteralPath $loc -Encoding ASCII -Value @('[InternetShortcut]', "URL=$phoneUrl")
    }
    Write-Ok "Shortcut created: SatisFactory Phone App (Start Menu + Desktop) — scan the QR to install the phone app"
  }

  # ---------------------------------------------------------------- Summary
  Write-Host ""
  Write-Host "SatisFactory is up to date." -ForegroundColor Green
  Write-Host "  VST3:       $installedVst3"
  if ($standaloneDir) { Write-Host "  Standalone: $standaloneDir\SatisFactory.exe" }
  if ($editorDir)     { Write-Host "  Editor:     $editorDir\satisfactory_editor.exe" }
  if ($adbDir)        { Write-Host "  adb:        $adbDir\adb.exe" }
  if (-not $NoShortcuts) { Write-Host '  Update:     double-click "Update SatisFactory" on your Desktop any time' -ForegroundColor Green }
  if (-not $NoShortcuts) { Write-Host '  Phone app:  double-click "SatisFactory Phone App" and scan the QR with your phone' -ForegroundColor Green }
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
