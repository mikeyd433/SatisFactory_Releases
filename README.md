# SatisFactory — Windows downloads

Public download hub for **SatisFactory**. The builds here are produced automatically from
the private source repos and refreshed on every change — so this is always the latest.

## Install / update (one line)

Open **PowerShell** and paste:

```powershell
irm https://raw.githubusercontent.com/mikeyd433/SatisFactory_Releases/main/install-satisfactory.ps1 | iex
```

That installs (or updates) everything:

- the **SatisFactory VST3** plugin (for REAPER / any VST3 host),
- the **Standalone** app (no DAW needed),
- the **SatisFactory editor**,
- plus Start-Menu and Desktop shortcuts.

Re-run the same line any time to update to the newest build. No account or token needed.

> **Tip:** to put the plugin in the machine-wide folder REAPER scans automatically, run
> PowerShell **as administrator** before pasting the line. Otherwise the plugin installs to
> your per-user VST3 folder and the installer tells you the one path to add in REAPER.

### Options (when you download the script instead of piping it)

```powershell
# Download once, then run with options:
powershell -ExecutionPolicy Bypass -File .\install-satisfactory.ps1 -PluginOnly
```

| Option         | Effect                                                        |
| -------------- | ------------------------------------------------------------- |
| `-PluginOnly`  | Install just the VST3 + Standalone (skip the editor).         |
| `-SystemVst3`  | Force the system VST3 folder (needs administrator).           |
| `-NoShortcuts` | Don't create Start-Menu / Desktop shortcuts.                  |

## Manual download

Prefer to grab the zip yourself? Use the Releases on this repo:

- **VST3 + Standalone:** [`vst3-latest`](../../releases/tag/vst3-latest) →
  `SatisFactory-Windows-VST3-and-Standalone.zip`
- **Editor:** [`editor-latest`](../../releases/tag/editor-latest) →
  `SatisFactory-Editor-Windows.zip`

Unzip, then copy `SatisFactory.vst3` into `C:\Program Files\Common Files\VST3` and re-scan
plugins in your DAW. Run `satisfactory_editor.exe` from the editor folder.

## What is SatisFactory?

A cartridge-based instrument system: design an instrument in the editor, export a bundle,
and play it in the VST3 (or Standalone). The plugin plays a built-in reference synth out of
the box — point `SF_BUNDLE` at an exported bundle to load your own cartridge.

---

*These are unsigned developer builds. This repo is generated automatically — do not edit by
hand; the installer and this page are synced from the source repo's `tools/` and `mirror/`.*
