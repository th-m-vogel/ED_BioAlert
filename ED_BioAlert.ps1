########################################################################
####                   Sevetamryn 2026                              ####
########################################################################
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
########################################################################

$Global:debug = $false
$Global:Lifescan = $true
$Global:ListEvents = $false
$Global:TTSvolume = 80

$Global:Mining = $true


$LogPath="$env:USERPROFILE\Saved Games\Frontier Developments\Elite Dangerous"
$FilePattern = "Journal*.log"

# creat Folder for system files if not exist
New-Item -Path "$LogPath\SystemData" -ItemType Directory -Force | Out-Null

# Text to Speach Support
Add-Type -AssemblyName System.Speech
$speaker = New-Object System.Speech.Synthesis.SpeechSynthesizer
# Look for voices installed
# $speaker.GetInstalledVoices() | Select-Object -ExpandProperty VoiceInfo
$speaker.SelectVoice("Microsoft David Desktop")
$speaker.Volume = $Global:TTSvolume

# System Initialisation
$Global:Starsystem = @{}
$Global:SystemName = "unknown"

# Tracks the file currently being tailed
$currentFile = $null
$currentStream = $null
$lastLength = 0

Function Get-NewestLogFile {
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
    } 
    Write-Host $Message
}

Function New-Event {

    ### write event types to console
    if ($Global:ListEvents -and $Global:Lifescan -and $line.event -ne "Music") { 
        Write-Host "New Event:" $line.event 
    }

    ###
    # evaluation shit happens here
    ###
    $updated = $false
            
    ### Listen to Events we are interested in
    ### get initial location and load if available
    if ($line.event -eq "Location" -and $Global:SystemName -eq "unknown" ) {
        $Global:SystemName = $line.StarSystem
        if (Test-Path "$LogPath\SystemData\$Global:SystemName.json") {
            $Data = Get-Content $LogPath\SystemData\$($Global:SystemName).json -Raw | ConvertFrom-Json 
            foreach ($key in $Data.PSObject.Properties.Name) { 
                $intKey = [int]$key 
                $Global:Starsystem[$intKey] = $Data.$key 
            }
            New-EDMessage -Voice $Global:debug -Message "Load system information for $($Global:SystemName)"
        }
    }
        
    
            
    ### StartJump - clear system Data on FSD Jump
    if (($line.event -eq "StartJump" -or $line.event -eq "Shutdown") -and $Global:Starsystem.Count -gt 0) {
        ## Dump System to Disk
        
        $fixed = @{} 
        foreach ($key in $Global:Starsystem.Keys) { 
            $fixed["$key"] = $Global:Starsystem[$key] 
        } 
        $fixed | ConvertTo-Json | Set-Content "$LogPath\SystemData\$($Global:SystemName).json"
        
        New-EDMessage -Voice $Global:debug -Message "Jump detected, wrote system data to disk."
        
        ## set creation time regarding timestamp (importand for log import)
        (Get-Item "$LogPath\SystemData\$($Global:SystemName).json").LastWriteTime = [datetime]$line.timestamp
    }


    ### FSDJump - read exiting system data if exist
    if ($line.event -eq "FSDJump") {
        ## clear Data
        $line.Starsystem
        $Global:SystemName = $line.StarSystem
        New-EDMessage -Voice $Global:debug -Message "System jump finished to $($Global:SystemName)"
        $Global:Starsystem = @{}
        
        ## Read System from Disk
        if (Test-Path "$LogPath\SystemData\$Global:SystemName.json") { 
            New-EDMessage -Voice $Global:debug -Message "Load system information for $($Global:SystemName)"
            # File exists → import JSON into a PSObject with integer keys 
            $Data = Get-Content $LogPath\SystemData\$($Global:SystemName).json -Raw | ConvertFrom-Json 
            foreach ($key in $Data.PSObject.Properties.Name) { 
                $intKey = [int]$key 
                $Global:Starsystem[$intKey] = $Data.$key 
            }
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
            

    ###
    # Evaluation Part
    
    ###
    if ($updated) {
        ## evaluate short body name
        if ( $Global:Starsystem[$line.BodyID].BodyName ) {
            $BodyNameShort = $Global:Starsystem[$line.BodyID].BodyName.Substring($Global:SystemName.Length).Trim()
        }

        ####
        # Processing signals
        ####
        if ($Global:Starsystem[$line.BodyID].Signals.count ) {
            # Write-Host -ForegroundColor Red "Found" $Global:Starsystem[$line.BodyID].Signals.count "signal types"

            ###
            # Process Bio Signals
            ###
            If ( $BioSignales = $Global:Starsystem[$line.BodyID].Signals | Where-Object -Property "Type" -EQ '$SAA_SignalType_Biological;' ) {

                ### Stratum Tectonitas
                    if ( 
                        $Global:Starsystem[$line.BodyID].PlanetClass -eq "High metal content body" -and
                        $Global:Starsystem[$line.BodyID].SurfaceTemperature -gt 165 
                    ) {
                        if ( $BioSignales.count -eq 1 ) {
                        New-EDMessage -Voice $Global:Lifescan -Message "There is a chance to find Stratum Tectonitas on body $BodyNameShort"
                        } else {
                        New-EDMessage -Voice $Global:Lifescan -Message "I's almost certain that there is Stratum Tectonitas on body $BodyNameShort"
                    }
                }
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
            New-Event
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

    $reader = [System.IO.File]::OpenText("$LogPath\$file") 
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
        if ( $line.SystemName ) { $line.SystemName = $line.SystemName -replace '\*', 'STAR' }
        Write-Host -ForegroundColor Red "change special Carater in Systemname"
        ## wtf ...
        New-Event
    } 
    $reader.Close()
    if ($Global:debug) {Write-Host "file $file finished ... "}
}

