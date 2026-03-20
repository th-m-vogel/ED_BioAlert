#############################################################################
# Test script - runs log import against journal data on Linux
#############################################################################

$LogPath = Join-Path $PSScriptRoot "..\Journal"
. (Join-Path $PSScriptRoot "ED_BioAlert.ps1") -ScanAll
