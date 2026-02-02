#### Sevetamryn 2026 ####

$debug = $false
$Lifescan = $true


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

# System Initialisation
$Global:Starsystem = @{}
$Global:SystemName = "unknown"

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

Function New-Event {

    ### write event types to console
    Write-Host $line.event

    ###
    # evaluation shit happens here
    ###
    $updated = $false
            
    ### Listen to Events we are interested in

    # need to care about scanned systems - event":"FSSDiscoveryScan", "Progress":1.000000 }

            
    ### StartJump - clear system Data on FSD Jump
    if ($line.event -eq "StartJump" -and $Global:Starsystem.Count -gt 0) {
        ## Dump System to Disk
        
        $fixed = @{} 
        foreach ($key in $Global:Starsystem.Keys) { 
            $fixed["$key"] = $Global:Starsystem[$key] 
        } 
        $fixed | ConvertTo-Json | Set-Content "$LogPath\SystemData\$($Global:SystemName).json"
        
        New-EDMessage -Voice $Lifescan -Message "System jump from $($Global:SystemName) detected, wrote system data to disk."
        
        ## set creation time regarding timestamp (importand for log import)
        (Get-Item "$LogPath\SystemData\$($Global:SystemName).json").LastWriteTime = [datetime]$line.timestamp
    }


    ### FSDJump - read exiting system data if exist
    if ($line.event -eq "FSDJump") {
        ## clear Data
        $line.Starsystem
        $Global:SystemName = $line.StarSystem
        New-EDMessage -Voice $Lifescan -Message "System jump finished to $($Global:SystemName)"
        $Global:Starsystem = @{}
        
        ## Read System from Disk
        if (Test-Path "$LogPath\SystemData\$Global:SystemName.json") { 
            New-EDMessage -Voice $Lifescan -Message "Load system information for $($Global:SystemName)"
            # File exists → import JSON into a PSObject with integer keys 
            $Data = Get-Content $LogPath\SystemData\$($Global:SystemName).json -Raw | ConvertFrom-Json 
            foreach ($key in $Data.PSObject.Properties.Name) { 
                $intKey = [int]$key 
                $Global:Starsystem[$intKey] = $Data.$key 
            }
            Write-Host "##### JSON file loaded for $Global:SystemName" 
            
        }
    }


    ### Scan Events
    if ($line.event -eq "Scan" -or $line.event-eq "ScanBaryCentre") {
        $updated = $true
        if ( $Global:Starsystem[$line.BodyID] -eq $null ) {
            $Global:Starsystem[$line.BodyID] += $line
        } else {
            foreach ($prop in $line.PSObject.Properties) { 
                    $Global:Starsystem[$line.BodyID] | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $prop.Value -Force 
            }
        }
        ###
        if ($debug) {New-EDMessage -Voice $Lifescan -Message "Detected Scan type $($line.ScanType) for body number $($line.BodyID). Starsystem has now $($Global:Starsystem.Count) members"}
        

    }
    ### FSS / SAA Events
    if (($line.event -eq "FSSBodySignals") -or ($line.event -eq "SAASignalsFound")) {
        $updated = $true
        if ( $Global:Starsystem[$line.BodyID] -eq $null ) {
            $Global:Starsystem[$line.BodyID] += $line
        } else {
            $Global:Starsystem[$line.BodyID] | Add-Member -MemberType NoteProperty -Name Signals -Value $line.Signals -Force
        }
        if ($debug) {New-EDMessage -Voice $Lifescan -Message "FSS or SAA signals detected for body numer $($line.BodyID). Starsystem has now $($Global:Starsystem.Count) members"}
                
    }
            

    ###
    # Evaluation Part
    ###
    if ($updated) {
        if ($Global:Starsystem[$line.BodyID].Signals) {
            ### Shout out HMC with Signals
            If ($Global:Starsystem[$line.BodyID].PlanetClass -eq "High metal content body") {
                New-EDMessage -Voice $Lifescan -Message "High metal content body with signals found"
                $Global:Starsystem[$line.BodyID].Signals | Format-Table
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
        New-EDMessage -Voice $Lifescan -Message "Finished Scan detected, found $($Global:Starsystem.Count) system members"

        # Log Console Bodies with Signals
        foreach ($Key in $Global:Starsystem.keys) {
            if ($Global:Starsystem[$Key].Signals -ne $null) {
                Write-Host $key $Global:Starsystem[$Key].BodyName $Global:Starsystem[$Key].Signals
            }
        }
    }
}



New-EDMessage -Voice $Lifescan -Message "Monitoring Elite Dangerous Logfiles now!"


###
# Life scan logfile
###
while ($Lifescan) {

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
            New-Event
        }

        $lastLength = $currentStream.Position
    }

    Start-Sleep -Milliseconds 200
}


###
# Import Logfiles
###

$Logfiles = Get-ChildItem -Path $LogPath -Filter $FilePattern | Sort-Object Name 

foreach ($file in $logfiles ) {
    $reader = [System.IO.File]::OpenText("$LogPath\$file") 
    while (($read = $reader.ReadLine()) -ne $null) { 
        $line = $read | ConvertFrom-Json
        New-Event
    } 
    $reader.Close()
}

