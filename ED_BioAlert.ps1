#############################################################################
####              Sevetamryn & Claude 2026                               ####
#############################################################################
# THIS SOFTWARE IS PROVIDED “AS IS” AND ANY EXPRESS OR IMPLIED WARRANTIES,
# INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
# AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
# CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
# EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
# PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
# OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
# WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
# OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
# EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#############################################################################
#
# Command line options:
#   (none)        Live mode: tail the newest journal file, TTS active
#   -ScanAll      Process all journal files in log directory, console output only
#   -TestFile     Process a single journal file with TTS active from line 1,
#                 simulating live mode without a running game
#                 Example: .\ED_BioAlert.ps1 -TestFile “path\to\Journal.log”
#
#############################################################################
param(
    [switch]$ScanAll,
    [string]$TestFile
)

# Load configuration
$_config = Get-Content (Join-Path $PSScriptRoot "ED_BioAlert.config.json") -Raw | ConvertFrom-Json

$Global:debug      = $_config.Debug
$Global:ListEvents = $_config.ListEvents
$Global:TTSvolume  = $_config.TTSVolume
$Global:Mining     = $_config.Mining
$Global:LiveMode   = $true
$Global:TTS        = $true
if ($ScanAll)   { $Global:LiveMode = $false; $Global:TTS = $false }
if ($TestFile)  { $Global:LiveMode = $false }

if (-not $LogPath) {
    if ($_config.LogPath) { $LogPath = $_config.LogPath }
    else { $LogPath = Join-Path $env:USERPROFILE "Saved Games\Frontier Developments\Elite Dangerous" }
}
$FilePattern = "Journal*.log"

# creat Folder for system files if not exist
New-Item -Path (Join-Path $LogPath "SystemData") -ItemType Directory -Force | Out-Null

# Text to Speach Support
$Global:TTSAvailable = $false
if ($PSVersionTable.PSEdition -eq "Desktop") {
    try {
        Add-Type -AssemblyName System.Speech
        $speaker = New-Object System.Speech.Synthesis.SpeechSynthesizer
        # Look for voices installed
        # $speaker.GetInstalledVoices() | Select-Object -ExpandProperty VoiceInfo
        $speaker.SelectVoice($_config.TTSVoice)
        $speaker.Volume = $Global:TTSvolume
        $Global:TTSAvailable = $true
    } catch {
        Write-Host "TTS initialisation failed: $_"
    }
}

# System Initialisation
$Global:Starsystem = @{}
$Global:SystemName = "unknown"
$Global:AlertedSpecies = @{}
$Global:SystemScanAnnounced = $false

# Tracks the file currently being tailed
$currentFile = $null
$currentStream = $null
$lastLength = 0

Function Get-NewestLogFile {
    Get-ChildItem -Path $LogPath -Filter $FilePattern |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

Function Import-SpeciesData {
    $Global:SpeciesAlerts = @()
    $SpeciesPath = Join-Path $PSScriptRoot "SpeciesData"
    if (Test-Path $SpeciesPath) {
        foreach ($file in Get-ChildItem -Path $SpeciesPath -Filter "*.json") {
            $entries = Get-Content $file.FullName -Raw | ConvertFrom-Json
            foreach ($entry in $entries) {
                $Global:SpeciesAlerts += $entry
            }
        }
    }
    New-EDMessage -Voice $Global:debug -Message "Loaded $($Global:SpeciesAlerts.Count) species alert definitions"
}

Function Test-SpeciesConditions {
    param(
        [Parameter(Mandatory=$true)] $Conditions,
        [Parameter(Mandatory=$true)] $Body,
        [Parameter(Mandatory=$true)] [int]$BioCount
    )

    if ($Conditions.planet_class.Count -gt 0 -and $Body.PlanetClass -notin $Conditions.planet_class) { return $false }
    if ($Conditions.atmosphere_type.Count -gt 0 -and $Body.AtmosphereType -notin $Conditions.atmosphere_type) { return $false }
    if ($Conditions.volcanism.Count -gt 0 -and $Body.Volcanism -notin $Conditions.volcanism) { return $false }
    if ($Conditions.star_type.Count -gt 0) {
        $ParentStarType = $null
        foreach ($parent in $Body.Parents) {
            $starID = $parent.Star
            if ($starID -ne $null -and $Global:Starsystem[$starID].StarType) {
                $ParentStarType = $Global:Starsystem[$starID].StarType
                break
            }
        }
        if ($ParentStarType -notin $Conditions.star_type) { return $false }
    }
    if ($Conditions.temperature.min -ne $null -and $Body.SurfaceTemperature -lt $Conditions.temperature.min) { return $false }
    if ($Conditions.temperature.max -ne $null -and $Body.SurfaceTemperature -gt $Conditions.temperature.max) { return $false }
    if ($Conditions.gravity.min -ne $null -and $Body.SurfaceGravity -lt $Conditions.gravity.min) { return $false }
    if ($Conditions.gravity.max -ne $null -and $Body.SurfaceGravity -gt $Conditions.gravity.max) { return $false }
    if ($Conditions.bio_signals.min -ne $null -and $BioCount -lt $Conditions.bio_signals.min) { return $false }
    if ($Conditions.bio_signals.max -ne $null -and $BioCount -gt $Conditions.bio_signals.max) { return $false }
    if ($Conditions.PSObject.Properties.Name -contains "was_footfalled" -and $Conditions.was_footfalled -ne $null) {
        if ($Body.WasFootfalled -ne $Conditions.was_footfalled) { return $false }
    }

    return $true
}

Function Invoke-SpeciesAlerts {
    param(
        [Parameter(Mandatory=$true)] $Body,
        [Parameter(Mandatory=$true)] [string]$BodyNameShort,
        [Parameter(Mandatory=$true)] [int]$BioCount
    )

    foreach ($species in $Global:SpeciesAlerts) {
        $alertKey = "$($Body.BodyID)_$($species.genus)_$($species.species)"
        if ($Global:AlertedSpecies[$alertKey]) { continue }

        foreach ($alert in $species.alerts) {
            if (Test-SpeciesConditions -Conditions $alert.conditions -Body $Body -BioCount $BioCount) {
                $value = [math]::Round($species.reward / 1000000, 1)
                $message = $alert.tts_alert `
                    -replace '\{body\}', $BodyNameShort `
                    -replace '\{value\}', $value
                New-EDMessage -Voice $Global:TTS -Message $message
                $Global:AlertedSpecies[$alertKey] = $true
                break  # first matching alert level only
            }
        }
    }
}

Function Invoke-DSSAlerts {
    param(
        [Parameter(Mandatory=$true)] $Body,
        [Parameter(Mandatory=$true)] [string]$BodyNameShort,
        [Parameter(Mandatory=$true)] [int]$BioCount
    )

    foreach ($confirmedGenus in $Body.Genuses) {
        $genusName = $confirmedGenus.Genus_Localised
        foreach ($species in $Global:SpeciesAlerts) {
            if ($species.genus -ne $genusName) { continue }
            if (-not $species.dss_tts_alert) { continue }

            $dssKey = "$($Body.BodyID)_$($species.genus)_$($species.species)_dss"
            if ($Global:AlertedSpecies[$dssKey]) { continue }

            foreach ($alert in $species.alerts) {
                if (Test-SpeciesConditions -Conditions $alert.conditions -Body $Body -BioCount $BioCount) {
                    $value = [math]::Round($species.reward / 1000000, 1)
                    $message = $species.dss_tts_alert `
                        -replace '\{body\}', $BodyNameShort `
                        -replace '\{value\}', $value
                    New-EDMessage -Voice $Global:TTS -Message $message
                    $Global:AlertedSpecies[$dssKey] = $true
                    break
                }
            }
        }
    }
}

Function New-EDMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [bool]$Voice,
        [Parameter(Mandatory = $true)] [string]$Message
        )

    if ($Voice -and $Global:TTSAvailable) {
        $dummy = $speaker.SpeakAsync($Message)
        Write-Host $Message
    } elseif ($Voice) {
        Write-Host $Message -ForegroundColor Green
    } else {
        Write-Host $Message
    }
}

Function Write-Starsystem {
    param([string]$Timestamp)
    if ($Global:Starsystem.Count -gt 0) {
        $fixed = @{}
        foreach ($key in $Global:Starsystem.Keys) {
            $fixed["$key"] = $Global:Starsystem[$key]
        }
        $systemFile = Join-Path $LogPath "SystemData\$($Global:SystemName).json"
        $fixed | ConvertTo-Json -Depth 10 | Set-Content $systemFile

        ## New-EDMessage -Voice $Global:debug -Message "write system data to disk for $($Global:SystemName)"

        ## set creation time regarding timestamp (importand for log import)
        if ($Timestamp) { (Get-Item $systemFile).LastWriteTime = [datetime]$Timestamp }
    }
    # clear data
    $Global:Starsystem = @{}
    $Global:SystemName = "unknown"
    $Global:AlertedSpecies = @{}
    $Global:SystemScanAnnounced = $false
}

Function Read-Starsystem {
    $systemFile = Join-Path $LogPath "SystemData\$($Global:SystemName).json"
    if (Test-Path $systemFile) {
        $Data = Get-Content $systemFile -Raw | ConvertFrom-Json
        foreach ($key in $Data.PSObject.Properties.Name) {
            $intKey = [int]$key
            $body = $Data.$key
            if ($body.Genuses) {
                $list = [System.Collections.Generic.List[object]]::new()
                foreach ($g in $body.Genuses) { $list.Add($g) }
                $body | Add-Member -MemberType NoteProperty -Name Genuses -Value $list -Force
            }
            $Global:Starsystem[$intKey] = $body
        }
        ## New-EDMessage -Voice $Global:debug -Message "Load system information for $($Global:SystemName)"
    }
}

Function Invoke-LogLine {
    param([string]$RawLine)
    $line = $RawLine | ConvertFrom-Json
    if ($line.StarSystem) {
        $line.StarSystem = $line.StarSystem -replace '\*', 'STAR'
    }
    if ($line.Genuses) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($g in $line.Genuses) { $list.Add($g) }
        $line.Genuses = $list
    }
    Invoke-EDEvent -line $line
}

Function Invoke-EDEvent {
    param($line)

    ### write event types to console
    if ($Global:ListEvents -and $Global:TTS -and $line.event -ne "Music") {
        Write-Host "New Event:" $line.event 
    }
    $updated = $false

    ### 
    # System Data persistance handling
    ###
 
    ### Write System data on game exit
    if ($line.event -eq "Shutdown" -and $Global:Starsystem.Count -gt 0) {
        Write-Starsystem -Timestamp $line.timestamp
    }

    ### force read on new logfile / carrier location on session start
    if ($line.event -eq "Location" -or $line.event -eq "CarrierLocation") {
        Write-Starsystem -Timestamp $line.timestamp
        $Global:SystemName = $line.StarSystem
        Read-Starsystem
    }

    ### Starsystem changed since last event
    if ( ($Global:Starsystem.Count -gt 0) -and
            ($line.StarSystem -ne $null) -and
            ($line.StarSystem -ne $Global:SystemName)
        ) {
        Write-Starsystem -Timestamp $line.timestamp
        $Global:SystemName = $line.StarSystem
        Read-Starsystem
    }
 
    ### FSDJump / CarrierJump - read existing system data if available
    if ($line.event -eq "FSDJump" -or $line.event -eq "CarrierJump") {
        $Global:SystemName = $line.StarSystem
        $Global:Starsystem = @{}
        $Global:SystemScanAnnounced = $false
        New-EDMessage -Voice $Global:debug -Message "System jump finished to $($Global:SystemName)"
        ## Read System from Disk
        Read-Starsystem
    }

    ###
    # incomming data event handling
    ###

    ### Scan Event handling
    if ($line.event -eq "Scan" -or $line.event -eq "ScanBaryCentre") {
        $updated = $true
        if ( $Global:Starsystem[$line.BodyID] -eq $null ) {
            $Global:Starsystem[$line.BodyID] += $line
        } else {
            foreach ($prop in $line.PSObject.Properties) { 
                    $Global:Starsystem[$line.BodyID] | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $prop.Value -Force 
            }
        }
    }

    ### FSS / SAA Events
    if (($line.event -eq "FSSBodySignals") -or ($line.event -eq "SAASignalsFound")) {
        $updated = $true
        if ( $Global:Starsystem[$line.BodyID] -eq $null ) {
            $Global:Starsystem[$line.BodyID] += $line
        } else {
            if ($line.Signals -ne $null) { $Global:Starsystem[$line.BodyID] | Add-Member -MemberType NoteProperty -Name Signals -Value $line.Signals -Force }
            if ($line.Genuses -ne $null) { $Global:Starsystem[$line.BodyID] | Add-Member -MemberType NoteProperty -Name Genuses -Value $line.Genuses -Force }
            if ($line.Rings   -ne $null) { $Global:Starsystem[$line.BodyID] | Add-Member -MemberType NoteProperty -Name Rings   -Value $line.Rings   -Force }
        }
    }

    ### ScanOrganic Events
    if ($line.event -eq "ScanOrganic" ){   # -and $line.ScanType -eq "Log"){
       if ($Global:debug) {Write-Host "Organic Scan:" $line.ScanType}
        $Genusfound = $false
        if ($Global:Starsystem[$line.Body].SystemAddress -eq $line.SystemAddress ) {
            for ($i = 0; $i -lt $Global:Starsystem[$line.Body].Genuses.Count; $i++) {
                ## we have a matching genus entry in the list
                if ($line.Genus -eq $Global:Starsystem[$line.Body].Genuses[$i].Genus) {
                    foreach ($key in $line.PSObject.Properties.Name ) {
                        $Global:Starsystem[$line.Body].Genuses[$i] | Add-Member -MemberType NoteProperty -Name $key -Value $line.$key -Force
                    }
                $Genusfound = $true
                } 
            }
            if ( -not $Genusfound ) {
                if (-not $Global:Starsystem[$line.Body].Genuses ) {
                    $Global:Starsystem[$line.Body] | Add-Member -MemberType NoteProperty -Name Genuses -Value ([System.Collections.Generic.List[object]]::new()) -Force
                }
                $Global:Starsystem[$line.Body].Genuses += $line
            }
        } else {
            Write-Host -ForegroundColor Red "Late Message. Bioscan is from" $line.SystemAddress "and we are in system" $Global:Starsystem[$line.Body].SystemAddress
        }
    }

    ### FSS Signals

    # Tourits Beaconm
    if ($line.event -eq "FSSSignalDiscovered" -and $line.SignalType -eq "TouristBeacon"){
        New-EDMessage -Voice $Global:TTS -Message "There is Tourist Beacon here named $($line.SignalName)"
    }
    # stellar phenomena
    if ($line.event -eq "FSSSignalDiscovered" -and $line.SignalName -eq '$Fixed_Event_Life_Cloud;'){
        New-EDMessage -Voice $Global:TTS -Message "Found a $($line.SignalName_Localised) here"
    }

            

    ###
    # Evaluation Part
    ###
    
    ###
    if ($updated) {
        ## evaluate short body name
        if ( $Global:Starsystem[$line.BodyID].BodyName ) {
            if ( $Global:Starsystem[$line.BodyID].BodyName -match "^$($Global:SystemName).+" ) {
                $BodyNameShort = $Global:Starsystem[$line.BodyID].BodyName.Substring($Global:SystemName.Length).Trim()
            } else {
                $BodyNameShort = $Global:Starsystem[$line.BodyID].BodyName
            }
        }

        ####
        # Processing signals
        ####
        if ($Global:Starsystem[$line.BodyID].Signals.count ) {

            ###
            # Process Bio Signals
            ###
            If ( $BioSignales = $Global:Starsystem[$line.BodyID].Signals | Where-Object -Property "Type" -EQ '$SAA_SignalType_Biological;' ) {
                Invoke-SpeciesAlerts -Body $Global:Starsystem[$line.BodyID] -BodyNameShort $BodyNameShort -BioCount $BioSignales.Count
            }

            ###
            # Process Ressource Signals
            ###
            if ($line.event -eq "SAASignalsFound") {

                ### DSS genus-confirmed alerts
                if ( $BioSignales -and $Global:Starsystem[$line.BodyID].Genuses.Count -gt 0 ) {
                    Invoke-DSSAlerts -Body $Global:Starsystem[$line.BodyID] -BodyNameShort $BodyNameShort -BioCount $BioSignales.Count
                }

                ### Log all found ressouirces to console
                foreach ($Signal in $Global:Starsystem[$line.BodyID].Signals) {
                    if ($Signal.Type -notlike "*SAA_SignalType*" ) {
                        Write-Host $BodyNameShort $Signal.Count "Hotspost(s) found for" $Signal.Type
                    }
                }
            
                ### Tritium found
                if ( $Tritium = $Global:Starsystem[$line.BodyID].Signals | Where-Object -Property "Type" -EQ "Tritium" ) {
                    New-EDMessage -Voice $Global:TTS -Message "$($Tritium.count) Tritium Hotspots detected here."
                }
            }
        }

        ###
        # Handle pristine Rings
        ###
        if ( $Global:Mining -and $Global:Starsystem[$line.BodyID].Rings.count -and $Global:Starsystem[$line.BodyID].ReserveLevel -eq "PristineResources" ) {

            ### Icy Rings found 
            If ( $IcyRings = $Global:Starsystem[$line.BodyID].Rings | Where-Object -Property "RingClass" -EQ "eRingClass_Icy" ) {
                New-EDMessage -Voice $Global:TTS -Message "Body $BodyNameShort has pristine icy rings present."
            }

        }
            
    }

    ###
    # evaluation finished
    ###
            
    ###
    # Finished FSS detected / discovered System 
    ###
    if (-not $Global:SystemScanAnnounced -and ($line.event -eq "FSSAllBodiesFound" -or ($line.event -eq "FSSDiscoveryScan" -and $line.Progress -eq 1 ))) {
        $Global:SystemScanAnnounced = $true
        New-EDMessage -Voice $Global:TTS -Message "Finished Scan detected, found $($Global:Starsystem.Count) system members"

        # Log Console Bodies with Signals
        foreach ($Key in $Global:Starsystem.keys) {
            if ($Global:Starsystem[$Key].Signals -ne $null) {

                foreach ($Signal in $Global:Starsystem[$Key].Signals) {
                    Write-Host $Global:Starsystem[$Key].BodyName "Found" $Signal.Count $Signal.Type_Localised "Signals"
                }
            }
        }
    }
}



# Load species alert definitions
Import-SpeciesData

New-EDMessage -Voice $Global:TTS -Message "Monitoring Elite Dangerous Logfiles now!"


###
# Life scan logfile
###
while ($Global:LiveMode) {

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
        # $lastLength = $currentStream.Length  # Skip existing content
        # we fully read in the newest file to get up to date
        $lastLength = 0 # read in existing lines, stay quiet during catch-up
        $Global:TTS = $false # suppress TTS during catch-up read
        $currentStream.Seek($lastLength, 'Begin') | Out-Null

        # Announce new logfile
        New-EDMessage -Voice $Global:debug -Message "Switched to new log file: $($currentFile.Name)"
    }

    # Read new lines
    if ($currentStream.Length -gt $lastLength) {
        $reader = New-Object System.IO.StreamReader($currentStream)
        $currentStream.Seek($lastLength, 'Begin') | Out-Null

        while (-not $reader.EndOfStream) {
            Invoke-LogLine -RawLine $reader.ReadLine()
        }

        $lastLength = $currentStream.Position
    }

    Start-Sleep -Milliseconds 200
    if ( -not $Global:TTS ) { New-EDMessage -Voice $true -Message "I'm up to date with the existing session data" }
    $Global:TTS = $true # catch-up done, TTS active again
}


###
# Import Logfiles
###

if ($TestFile) {
    $Logfiles = @(Get-Item $TestFile)
} else {
    $Logfiles = Get-ChildItem -Path $LogPath -Filter $FilePattern | Sort-Object Name
}

foreach ($file in $Logfiles) {

    $reader = [System.IO.File]::OpenText($file.FullName)
    while (($read = $reader.ReadLine()) -ne $null) {
        Invoke-LogLine -RawLine $read
    }
    $reader.Close()
    if ($Global:debug) { Write-Host "file $file finished ... " }
}

