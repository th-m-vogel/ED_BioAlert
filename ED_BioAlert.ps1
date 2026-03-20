#############################################################################
####                   Sevetamryn 2026                                   ####
#############################################################################
param(
    [switch]$ScanAll
)
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

# Load configuration
$_config = Get-Content (Join-Path $PSScriptRoot "ED_BioAlert.config.json") -Raw | ConvertFrom-Json

$Global:debug      = $_config.Debug
$Global:ListEvents = $_config.ListEvents
$Global:TTSvolume  = $_config.TTSVolume
$Global:Mining     = $_config.Mining
$Global:Lifescan   = $true
if ($ScanAll) { $Global:Lifescan = $false }

if (-not $LogPath) {
    if ($_config.LogPath) { $LogPath = $_config.LogPath }
    else { $LogPath = "$env:USERPROFILE\Saved Games\Frontier Developments\Elite Dangerous" }
}
$FilePattern = "Journal*.log"

# creat Folder for system files if not exist
New-Item -Path "$LogPath\SystemData" -ItemType Directory -Force | Out-Null

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
                New-EDMessage -Voice $Global:Lifescan -Message $message
                $Global:AlertedSpecies[$alertKey] = $true
                break  # first matching alert level only
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
    }
    Write-Host $Message
}

Function Write-Starsystem {
    if ($Global:Starsystem.Count -gt 0) {
        $fixed = @{} 
        foreach ($key in $Global:Starsystem.Keys) { 
            $fixed["$key"] = $Global:Starsystem[$key] 
        } 
        $fixed | ConvertTo-Json | Set-Content "$LogPath\SystemData\$($Global:SystemName).json"
        
        New-EDMessage -Voice $Global:debug -Message "write system data to disk for $($Global:SystemName)"
        
        ## set creation time regarding timestamp (importand for log import)
        (Get-Item "$LogPath\SystemData\$($Global:SystemName).json").LastWriteTime = [datetime]$line.timestamp
    }
    # clear data
    $Global:Starsystem = @{}
    $Global:SystemName = "unknown"
    $Global:AlertedSpecies = @{}
}

Function Read-Starsystem {
    if (Test-Path "$LogPath\SystemData\$Global:SystemName.json") {
        $Data = Get-Content $LogPath\SystemData\$($Global:SystemName).json -Raw | ConvertFrom-Json 
        foreach ($key in $Data.PSObject.Properties.Name) { 
            $intKey = [int]$key 
            $Global:Starsystem[$intKey] = $Data.$key 
        }
        New-EDMessage -Voice $Global:debug -Message "Load system information for $($Global:SystemName)"
    }
}

Function Invoke-EDEvent {

    ### write event types to console
    if ($Global:ListEvents -and $Global:Lifescan -and $line.event -ne "Music") { 
        Write-Host "New Event:" $line.event 
    }
    $updated = $false

    ### 
    # System Data persistance handling
    ###
 
    ### Write System data on game exit
    if ($line.event -eq "Shutdown" -and $Global:Starsystem.Count -gt 0) {
        Write-Starsystem
    }

    ### force read on new logfile / carrier location on session start
    if ($line.event -eq "Location" -or $line.event -eq "CarrierLocation") {
        Write-Starsystem
        $Global:SystemName = $line.StarSystem
        Read-Starsystem
    }

    ### Starsystem changed since last event
    if ( ($Global:Starsystem.Count -gt 0) -and 
            ($line.StarSystem -ne $null) -and 
            ($line.StarSystem -ne $Global:SystemName) 
        ) {
        Write-Starsystem
        $Global:SystemName = $line.StarSystem
        Read-Starsystem
    }
 
    ### FSDJump / CarrierJump - read existing system data if available
    if ($line.event -eq "FSDJump" -or $line.event -eq "CarrierJump") {
        $Global:SystemName = $line.StarSystem
        $Global:Starsystem = @{}
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
            $Global:Starsystem[$line.BodyID] | Add-Member -MemberType NoteProperty -Name Signals -Value $line.Signals -Force
            $Global:Starsystem[$line.BodyID] | Add-Member -MemberType NoteProperty -Name Genuses -Value $line.Genuses -Force
            $Global:Starsystem[$line.BodyID] | Add-Member -MemberType NoteProperty -Name Rings -Value $line.Rings -Force
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
        New-EDMessage -Voice $Global:Lifescan -Message "There is Tourist Beacon here named $($line.SignalName)"
    }
    # stellar phenomena
    if ($line.event -eq "FSSSignalDiscovered" -and $line.SignalName -eq '$Fixed_Event_Life_Cloud;'){
        New-EDMessage -Voice $Global:Lifescan -Message "Found a $($line.SignalName_Localised) here"
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

                ### Log all found ressouirces to console
                foreach ($Signal in $Global:Starsystem[$line.BodyID].Signals) {
                    if ($Signal.Type -notlike "*SAA_SignalType*" ) {
                        Write-Host $BodyNameShort $Signal.Count "Hotspost(s) found for" $Signal.Type
                    }
                }
            
                ### Tritium found
                if ( $Tritium = $Global:Starsystem[$line.BodyID].Signals | Where-Object -Property "Type" -EQ "Tritium" ) {
                    New-EDMessage -Voice $Global:Lifescan -Message "$($Tritium.count) Tritium Hotspots detected here."
                }
            }
        }

        ###
        # Handle pristine Rings
        ###
        if ( $Global:Mining -and $Global:Starsystem[$line.BodyID].Rings.count -and $Global:Starsystem[$line.BodyID].ReserveLevel -eq "PristineResources" ) {

            ### Icy Rings found 
            If ( $IcyRings = $Global:Starsystem[$line.BodyID].Rings | Where-Object -Property "RingClass" -EQ "eRingClass_Icy" ) {
                New-EDMessage -Voice $Global:Lifescan -Message "Body $BodyNameShort has pristine icy rings present."
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
        New-EDMessage -Voice $Global:Lifescan -Message "Finished Scan detected, found $($Global:Starsystem.Count) system members"

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

New-EDMessage -Voice $Global:Lifescan -Message "Monitoring Elite Dangerous Logfiles now!"


###
# Life scan logfile
###
while ($Global:Lifescan) {

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
        $lastLength = 0 # read in exiting lines, stay quiet during read of existing data
        $Global:Lifescan = $false # work quietly during read in of exiting data
        $currentStream.Seek($lastLength, 'Begin') | Out-Null

        # Announce new logfile
        New-EDMessage -Voice $Global:debug -Message "Switched to new log file: $($currentFile.Name)"
    }

    # Read new lines
    if ($currentStream.Length -gt $lastLength) {
        $reader = New-Object System.IO.StreamReader($currentStream)
        $currentStream.Seek($lastLength, 'Begin') | Out-Null

        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine() | ConvertFrom-Json
            ## Genuses need to be expandable later, therefor conversion from array to list
            if ($line.Genuses) {
                $list = [System.Collections.Generic.List[object]]::new()
                foreach ($g in $line.Genuses) {
                    $list.Add($g)
                }
                $line.Genuses = $list
            }
            #
            # call the Event Handler
            Invoke-EDEvent
        }

        $lastLength = $currentStream.Position
    }

    Start-Sleep -Milliseconds 200
    if ( -not $Global:Lifescan ) { New-EDMessage -Voice $true -Message "I'm up to date with the existing session data" }
    $Global:Lifescan = $true # as we had to wait for new log lines, time to talk again
}


###
# Import Logfiles
###

$Logfiles = Get-ChildItem -Path $LogPath -Filter $FilePattern | Sort-Object Name 

foreach ($file in $logfiles ) {

    $reader = [System.IO.File]::OpenText($file.FullName)
    while (($read = $reader.ReadLine()) -ne $null) { 
        $line = $read | ConvertFrom-Json
        if ($line.Genuses) {
            $list = [System.Collections.Generic.List[object]]::new()
            foreach ($g in $line.Genuses) {
                $list.Add($g)
            }
            $line.Genuses = $list
        }

        ## fix for systems having a * in name
        if ( $line.StarSystem ) { 
            $line.StarSystem = $line.StarSystem -replace '\*', 'STAR' 
        }
        ## wtf ...
        Invoke-EDEvent
    } 
    $reader.Close()
    if ($Global:debug) {Write-Host "file $file finished ... "}
}

