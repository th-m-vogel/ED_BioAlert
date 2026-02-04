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

$debug = $false
$Lifescan = $true


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
    if ($debug -and $Lifescan ) { Write-Host $line.event }

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
            New-EDMessage -Voice $debug -Message "Load system information for $($Global:SystemName)"
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
        
        New-EDMessage -Voice $debug -Message "Jump detected, wrote system data to disk."
        
        ## set creation time regarding timestamp (importand for log import)
        (Get-Item "$LogPath\SystemData\$($Global:SystemName).json").LastWriteTime = [datetime]$line.timestamp
    }


    ### FSDJump - read exiting system data if exist
    if ($line.event -eq "FSDJump") {
        ## clear Data
        $line.Starsystem
        $Global:SystemName = $line.StarSystem
        New-EDMessage -Voice $debug -Message "System jump finished to $($Global:SystemName)"
        $Global:Starsystem = @{}
        
        ## Read System from Disk
        if (Test-Path "$LogPath\SystemData\$Global:SystemName.json") { 
            New-EDMessage -Voice $debug -Message "Load system information for $($Global:SystemName)"
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
        ###
    }

    ### FSS / SAA Events
    if (($line.event -eq "FSSBodySignals") -or ($line.event -eq "SAASignalsFound")) {
        $updated = $true
        if ( $Global:Starsystem[$line.BodyID] -eq $null ) {
            $Global:Starsystem[$line.BodyID] += $line
        } else {
            $Global:Starsystem[$line.BodyID] | Add-Member -MemberType NoteProperty -Name Signals -Value $line.Signals -Force
            $Global:Starsystem[$line.BodyID] | Add-Member -MemberType NoteProperty -Name Genuses -Value $line.Genuses -Force
        }
    }

    ### ScanOrganic Events
    if ($line.event -eq "ScanOrganic" ){   # -and $line.ScanType -eq "Log"){
        if ($debug) {Write-Host "Organic Scan:" $line.ScanType}
    }
            

    ###
    # Evaluation Part
    ###
    if ($updated) {
        ### test entry
        foreach ($Signal in $Global:Starsystem[$line.BodyID].Signals) {
            ### Shout out HMC with Signals
            If ($Global:Starsystem[$line.BodyID].PlanetClass -eq "High metal content body" -and $Signal.Type_Localised -eq "Biological") {
                New-EDMessage -Voice $Lifescan -Message "High metal content body with $($Signal.Count) $($Signal.Type_Localised) Signals found"
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

                foreach ($Signal in $Global:Starsystem[$Key].Signals) {
                    Write-Host "Found" $Signal.Count $Signal.Type_Localised "Signals"
                }
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
        # $lastLength = $currentStream.Length  # Skip existing content
        # we fully read in the newest file to get up to date
        $lastLength = 0 # read in exiting lines, stay quiet during read of existing data
        $Lifescan = $false # work quietly during read in of exiting data
        $currentStream.Seek($lastLength, 'Begin') | Out-Null

        # Announce new logfile
        New-EDMessage -Voice $debug -Message "Switched to new log file: $($currentFile.Name)"
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
    if ( -not $Lifescan ) { New-EDMessage -Voice $true -Message "I'm up to date with the existing session data" }
    $Lifescan = $true # as we had to wait for new log lines, time to talk again
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
    if ($debug) {Write-Host "file $file finished ... "}
}

