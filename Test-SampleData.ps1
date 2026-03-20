#############################################################################
# Test script - runs log import against sample data (Linux / no TTS)
#############################################################################

$LogPath = Join-Path $PSScriptRoot "Sample Data"
$FilePattern = "Journal*.log"
$Global:TestMode = $true   # disables live monitoring loop in main script

. (Join-Path $PSScriptRoot "ED_BioAlert.ps1")
