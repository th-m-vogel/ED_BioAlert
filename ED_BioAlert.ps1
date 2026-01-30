$LogPath="$env:USERPROFILE\Saved Games\Frontier Developments\Elite Dangerous"
$FilePattern = "*.log"

# Tracks the file currently being tailed
$currentFile = $null
$currentStream = $null
$lastLength = 0

function Get-NewestLogFile {
    Get-ChildItem -Path $LogPath -Filter $FilePattern |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

while ($true) {

    # Detect newest file
    $newest = Get-NewestLogFile

    # If no file exists, wait and retry
    if (-not $newest) {
        Start-Sleep -Seconds 1
        continue
    }

    # If file changed (rotation happened)
    if ($currentFile -eq $null -or $newest.FullName -ne $currentFile.FullName) {

        # Close old stream if needed
        if ($currentStream) {
            $currentStream.Close()
            $currentStream.Dispose()
        }

        # Open new stream
        $currentFile = $newest
        $currentStream = [System.IO.File]::Open($currentFile.FullName, 'Open', 'Read', 'ReadWrite')
        $lastLength = $currentStream.Length  # Skip existing content
        $currentStream.Seek($lastLength, 'Begin') | Out-Null

        Write-Host "Switched to new log file: $($currentFile.Name)"
    }

    # Read new lines
    if ($currentStream.Length -gt $lastLength) {
        $reader = New-Object System.IO.StreamReader($currentStream)
        $currentStream.Seek($lastLength, 'Begin') | Out-Null

        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            Write-Host $line   # <-- Replace with your detailed processing later
        }

        $lastLength = $currentStream.Position
    }

    Start-Sleep -Milliseconds 200
}
