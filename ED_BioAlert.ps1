#### Sevetamryn 2026 ####

$debug = $false

$LogPath="$env:USERPROFILE\Saved Games\Frontier Developments\Elite Dangerous"
$FilePattern = "*.log"

# creat Folder for system files if not exist
New-Item -Path "$LogPath\SystemData" -ItemType Directory -Force | Out-Null

# Text to Speach Support
Add-Type -AssemblyName System.Speech
$speaker = New-Object System.Speech.Synthesis.SpeechSynthesizer
# Look for voices installed
# $speaker.GetInstalledVoices() | Select-Object -ExpandProperty VoiceInfo
$speaker.SelectVoice("Microsoft David Desktop")
$dummy = $speaker.SpeakAsync("Monitoring Elite Dangerous Logfiles now!")
$Lifescan = $true

# System Initialisation
$Starsystem = @{}

# Tracks the file currently being tailed
$currentFile = $null
$currentStream = $null
$lastLength = 0

function Get-NewestLogFile {
    Get-ChildItem -Path $LogPath -Filter $FilePattern |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

Function New-EDMessage { 
    [CmdletBinding()] 
    param( 
        [Parameter(Mandatory = $true)] [bool]$Voice, 
        [Parameter(Mandatory = $true)] [string]$Message 
        ) 
        
    if ($Voice) {
        $dummy = $speaker.SpeakAsync($Message)
    } else {
        Write-Host $Message
    }
            
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

        # Announce new logfile
        New-EDMessage -Voice $Lifescan -Message "Switched to new log file: $($currentFile.Name)"
    }

    # Read new lines
    if ($currentStream.Length -gt $lastLength) {
        $reader = New-Object System.IO.StreamReader($currentStream)
        $currentStream.Seek($lastLength, 'Begin') | Out-Null

        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine() | ConvertFrom-Json
            
            ### write event types to console
            Write-Host $line.event

            ###
            # evaluation shit happens here
            ###
            $updated = $false
            
            ### Listen to Events we are interested in

            # need to care about scanned systems - event":"FSSDiscoveryScan", "Progress":1.000000 }

            
            ### StartJump - clear system Data on FSD Jump
            if ($line.event -eq "StartJump") {
                
                New-EDMessage -Voice $Lifescan -Message "System jump detected, safe system data to disk"
                ## Dump System to Disk
                $fixed = @{} 
                foreach ($key in $Starsystem.Keys) { $fixed["$key"] = $Starsystem[$key] } $fixed | ConvertTo-Json | Set-Content "$LogPath\SystemData\$($Starsystem[$key].StarSystem).json"
            }
            ### FSDJump - read exiting system data if exist
            if ($line.event -eq "FSDJump") {
                ## clear Data
                $Starsystem = @{}
                ## Read System from Disk
                if (Test-Path "$LogPath\SystemData\$($Line.StarSystem).json") { 
                    # File exists → import JSON into a PSObject with integer keys 
                    $Data = Get-Content $LogPath\SystemData\$($Line.StarSystem).json -Raw | ConvertFrom-Json 
                    $Starsystem = @{} 
                    foreach ($key in $Data.PSObject.Properties.Name) { 
                        $intKey = [int]$key 
                        $Starsystem[$intKey] = $Data.$key 
                    }
                    Write-Host "##### JSON file loaded for $($Line.StarSystem)" 

                    $Starsystem | Format-Table
                }
            }


            ### Scan Events
            if ($line.event -eq "Scan" -or $line.event-eq "ScanBaryCentre") {
                $updated = $true
                if ( $Starsystem[$line.BodyID] -eq $null ) {
                    $Starsystem[$line.BodyID] += $line
                } else {
                    foreach ($prop in $line.PSObject.Properties) { 
                         $Starsystem[$line.BodyID] | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $prop.Value -Force 
                    }
                }
                ###
                if ($debug) {New-EDMessage -Voice $Lifescan -Message "Detected Scan type $($line.ScanType) for body number $($line.BodyID). Starsystem has now $($Starsystem.Count) members"}
                # $Starsystem[$line.BodyID] | Format-List

            }
            ### FSS / SAA Events
            if (($line.event -eq "FSSBodySignals") -or ($line.event -eq "SAASignalsFound")) {
                $updated = $true
                if ( $Starsystem[$line.BodyID] -eq $null ) {
                    $Starsystem[$line.BodyID] += $line
                } else {
                    $Starsystem[$line.BodyID] | Add-Member -MemberType NoteProperty -Name Signals -Value $line.Signals -Force
                }
                if ($debug) {New-EDMessage -Voice $Lifescan -Message "FSS or SAA signals detected for body numer $($line.BodyID). Starsystem has now $($Starsystem.Count) members"}
                
            }
            

            ###
            # Evaluation Part
            ###
            if ($updated) {
               if ($Starsystem[$line.BodyID].Signals) {
                    ### Shout out HMC with Signals
                    If ($Starsystem[$line.BodyID].PlanetClass -eq "High metal content body") {
                        New-EDMessage -Voice $Lifescan -Message "High metal content body with signals found"
                        $Starsystem[$line.BodyID].Signals | Format-Table
                    }
                }
            }

            ###
            # evaluation finished
            ###
            
            ###
            # Finished FSS detected / discovered System 
            ###
            if ($line.event -eq "FSSAllBodiesFound" -or ($line.event -eq "FSSDiscoveryScan" -and $line.Progress -eq 1 )) {
                New-EDMessage -Voice $Lifescan -Message "Finished FSS Scan detected, found $($Starsystem.Count) system members"

                # Log Console Bodies with Signals
                foreach ($Key in $Starsystem.keys) {
                    if ($Starsystem[$Key].Signals -ne $null) {
                        Write-Host $Starsystem[$Key].BodyName $Starsystem[$Key].Signals
                    }
                }
            }
        }

        $lastLength = $currentStream.Position
    }

    Start-Sleep -Milliseconds 200
}
