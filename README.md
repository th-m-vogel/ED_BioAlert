# ED_BioAlert

A PowerShell script that monitors Elite Dangerous journal files in real time and announces biological and geological discoveries via text-to-speech and console output.

## Purpose

Elite Dangerous Odyssey introduced biological life forms that can be scanned for significant credit rewards. Finding the right species on the right planet requires knowing the spawn conditions before landing. ED_BioAlert monitors your journal as you play and alerts you when a body's properties match known species conditions - so you never fly past a valuable or rare find.

## Features

- **Live journal monitoring** - tails the newest journal file and reacts to events as they happen
- **FSS alerts** - announces probable species when bio signals are detected during Full Spectrum Scanning, based on body properties (planet class, atmosphere, temperature, gravity, star type)
- **DSS confirmation alerts** - announces confirmed genus after Detailed Surface Scanning, with a separate message per species
- **Color variant alerts** - additional alert when body and star properties match a specific color variant, useful for codex completion hunting
- **Text-to-speech** - spoken announcements on Windows (PowerShell Desktop edition); green console output on Linux / PowerShell Core
- **System scan summary** - announces total body count when FSS scan is complete
- **Geological signals** - logs geological and resource hotspots to console
- **Mining alerts** - optional announcement for pristine icy rings
- **Tourist beacons and stellar phenomena** - announced when detected in FSS

## Requirements

- PowerShell 5.1 (Windows Desktop) or PowerShell 7+ (cross-platform)
- Elite Dangerous with Odyssey

## Installation

1. Clone or download the repository
2. Edit `ED_BioAlert.config.json` to set your journal path and preferences
3. Run `ED_BioAlert.ps1`

## Configuration

Edit `ED_BioAlert.config.json`:

```json
{
  "LogPath":    "",
  "Debug":      false,
  "ListEvents": false,
  "TTSVolume":  80,
  "TTSVoice":   "Microsoft David Desktop",
  "Mining":     true
}
```

| Setting | Description |
|---------|-------------|
| `LogPath` | Path to your Elite Dangerous journal folder. Leave empty to use the default `Saved Games` location. |
| `Debug` | Enable verbose debug messages |
| `ListEvents` | Log every journal event to console |
| `TTSVolume` | Text-to-speech volume (0-100) |
| `TTSVoice` | Windows TTS voice name |
| `Mining` | Enable pristine icy ring alerts |

## Usage

```powershell
# Live mode - monitors the newest journal file
.\ED_BioAlert.ps1

# Process all journal files in the log folder (no TTS, console output only)
.\ED_BioAlert.ps1 -ScanAll

# Test mode - process a single journal file with TTS active from line 1
.\ED_BioAlert.ps1 -TestFile "path\to\Journal.log"
```

## Species Data

Species alert conditions are defined in JSON files under the `SpeciesData\` folder. The system uses a two-layer approach:

- **Base file** (`genus-species.json`) - defines spawn conditions and alert levels (possible / likely / jackpot) based on planet class, atmosphere, temperature, gravity and bio signal count
- **Color file** (`genus-species-color.json`) - defines additional alerts for specific color variants based on parent star type or mineral composition, loaded on top of the base conditions

### Alert levels

| Level | Condition |
|-------|-----------|
| `jackpot` | All conditions met, body never previously visited |
| `likely` | All conditions met |
| `possible` | Minimum conditions met (e.g. only 1 bio signal) |

### Adding new species

Create a new base file in `SpeciesData\` following the existing `stratum-tectonitas.json` as a template. For color variants, create a matching `genus-species-color.json` referencing the base file via the `base` field.

## Currently supported species

- **Stratum Tectonitas** - including Emerald (F-type star) and Amethyst (T-Tauri star) color variants

More species will be added as field data is collected.

## Platform notes

- Text-to-speech requires Windows PowerShell 5.1 (Desktop edition)
- On Linux / PowerShell Core, TTS alerts are printed in green to distinguish them from regular console output
- The script stores per-system scan data in a `SystemData\` subfolder of the journal directory, allowing bio scan state to persist across game sessions
