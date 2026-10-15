#Requires -Version 5.1
<#
.SYNOPSIS
    Sets up the TroyMetrics Benchmark Overlays (v1.15) Power Detector for a Thermal Grizzly WireView Pro II.

.DESCRIPTION
    Finds RivaTuner Statistics Server, installs the TroyMetrics v1.15 overlays if they are missing,
    reads the WireView Pro II sensor from HWiNFO64 shared memory, and writes a
    "(WireView Pro II)" copy of every preset that contains the Power Detector.
    The original presets are never modified.

.PARAMETER RtssFolder
    RivaTuner Statistics Server folder, only needed when it is not detected automatically.

.PARAMETER NoPause
    Fail instead of waiting for the user, and do not pause before closing.
#>
[CmdletBinding()]
param(
    [string]$RtssFolder,
    [switch]$NoPause
)

$UpstreamZipUrl = 'https://github.com/TroyMetrics/Benchmark-Overlays/releases/download/v1.15/TroyMetrics.Benchmark.Overlays.v1.15.zip'
$UpstreamZipSha256 = 'C8B05B8A950B3FD942418E01E14683F968CF2B8346F413653E4C8634D8F48866'
$OutputSuffix = ' (WireView Pro II)'

# v1.15 presets whose Power Detector reads the ASUS ROG Astral per-pin sensors.
$PowerDetectorPresets = @(
    'TroyMetrics 12VHPWR Power Detector.ovl'
    'TM Benchmark 1080p Power Detector.ovl'
    'TroyMetrics Benchmark 3-Fan Power Detector.ovl'
    'TroyMetrics Benchmark 3-Fan PWR+LAT.ovl'
    'TM Benchmark 1080p PWR+LAT.ovl'
)

# Astral reading label (as used in the presets) -> WireView Pro II reading label in HWiNFO.
$AstralToWireView = [ordered]@{
    'GPU 12VHPWR Pin1 Current'          = 'Pin 1 Current'
    'GPU 12VHPWR Pin2 Current'          = 'Pin 2 Current'
    'GPU 12VHPWR Pin3 Current'          = 'Pin 3 Current'
    'GPU 12VHPWR Pin4 Current'          = 'Pin 4 Current'
    'GPU 12VHPWR Pin5 Current'          = 'Pin 5 Current'
    'GPU 12VHPWR Pin6 Current'          = 'Pin 6 Current'
    'GPU 12VHPWR Connector Total Power' = 'Total Power'
}

# .ovl files are ANSI text; Latin-1 maps every byte to one char, so a round trip is byte-exact.
$Latin1 = [System.Text.Encoding]::GetEncoding(28591)

$HwinfoSharedMemoryName = 'Global\HWiNFO_SENS_SM2'
$HwinfoHeaderSize = 44

function Write-Step([string]$Message) { Write-Host "`n>> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host "   [OK] $Message" -ForegroundColor Green }
function Write-Note([string]$Message) { Write-Host "   $Message" }
function Write-Warn([string]$Message) { Write-Host "   [!!] $Message" -ForegroundColor Yellow }

function Read-CString([byte[]]$Bytes, [int]$Offset, [int]$Length) {
    $end = [Array]::IndexOf($Bytes, [byte]0, $Offset, $Length)
    if ($end -lt 0) { $end = $Offset + $Length }
    $Latin1.GetString($Bytes, $Offset, $end - $Offset)
}

# Layout from the HWiNFO SDK (hwisenssm2.h, pack(1)). Element sizes come from the header
# because newer HWiNFO builds append fields to each element.
function ConvertFrom-HwinfoSharedMemory {
    param([Parameter(Mandatory)][byte[]]$Bytes)

    if ($Bytes.Length -lt $HwinfoHeaderSize) { throw 'HWiNFO shared memory is too small to contain a header.' }
    $signature = [System.Text.Encoding]::ASCII.GetString($Bytes, 0, 4)
    if ($signature -ne 'HWiS') { throw "HWiNFO shared memory is not active (signature '$signature')." }

    $sensorOffset = [BitConverter]::ToUInt32($Bytes, 20)
    $sensorSize = [BitConverter]::ToUInt32($Bytes, 24)
    $sensorCount = [BitConverter]::ToUInt32($Bytes, 28)
    $readingOffset = [BitConverter]::ToUInt32($Bytes, 32)
    $readingSize = [BitConverter]::ToUInt32($Bytes, 36)
    $readingCount = [BitConverter]::ToUInt32($Bytes, 40)

    if ($sensorSize -lt 264 -or $readingSize -lt 316) { throw 'HWiNFO shared memory uses an unsupported element size.' }
    if (($sensorOffset + [uint64]$sensorSize * $sensorCount) -gt $Bytes.Length -or
        ($readingOffset + [uint64]$readingSize * $readingCount) -gt $Bytes.Length) {
        throw 'HWiNFO shared memory is truncated.'
    }

    $sensors = @(for ($i = 0; $i -lt $sensorCount; $i++) {
        $o = [int]($sensorOffset + $sensorSize * $i)
        [pscustomobject]@{
            Index    = $i
            Id       = [BitConverter]::ToUInt32($Bytes, $o)
            Instance = [BitConverter]::ToUInt32($Bytes, $o + 4)
            Name     = Read-CString $Bytes ($o + 8) 128
        }
    })
    $readings = @(for ($i = 0; $i -lt $readingCount; $i++) {
        $o = [int]($readingOffset + $readingSize * $i)
        [pscustomobject]@{
            Type        = [BitConverter]::ToUInt32($Bytes, $o)
            SensorIndex = [BitConverter]::ToUInt32($Bytes, $o + 4)
            Label       = Read-CString $Bytes ($o + 12) 128
            Value       = [BitConverter]::ToDouble($Bytes, $o + 284)
        }
    })
    [pscustomobject]@{ Sensors = $sensors; Readings = $readings }
}

function Read-HwinfoSharedMemory {
    try {
        $map = [System.IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting(
            $HwinfoSharedMemoryName, [System.IO.MemoryMappedFiles.MemoryMappedFileRights]::Read)
    } catch {
        return $null
    }
    try {
        $view = $map.CreateViewStream(0, 0, [System.IO.MemoryMappedFiles.MemoryMappedFileAccess]::Read)
        try {
            $bytes = New-Object byte[] $view.Length
            [void]$view.Read($bytes, 0, $bytes.Length)
        } finally {
            $view.Dispose()
        }
    } finally {
        $map.Dispose()
    }
    , $bytes
}

# Returns $null when no WireView sensor is present; throws when it is present but incomplete.
function Get-WireViewBinding {
    param([Parameter(Mandatory)]$SharedMemory)

    $wireViews = @($SharedMemory.Sensors | Where-Object { $_.Name -like '*WireView*' })
    if ($wireViews.Count -eq 0) { return $null }
    $sensor = $wireViews[0]

    $wanted = @($AstralToWireView.Values)
    $readings = @{}
    foreach ($reading in $SharedMemory.Readings) {
        if ($reading.SensorIndex -eq $sensor.Index -and $wanted -contains $reading.Label -and
            -not $readings.ContainsKey($reading.Label)) {
            $readings[$reading.Label] = $reading
        }
    }
    $missing = @($wanted | Where-Object { -not $readings.ContainsKey($_) })
    if ($missing.Count -gt 0) {
        throw "HWiNFO shows '$($sensor.Name)' but not these readings: $($missing -join ', '). Update HWiNFO64 and make sure none of them are hidden."
    }

    # RTSS binds a reading by sensor instance, reading type and label only, not by device.
    # Another sensor with the same instance and a matching label could be picked up instead.
    $conflicts = @(foreach ($reading in $SharedMemory.Readings) {
        if ($reading.SensorIndex -eq $sensor.Index -or $reading.SensorIndex -ge $SharedMemory.Sensors.Count) { continue }
        $other = $SharedMemory.Sensors[$reading.SensorIndex]
        if ($other.Instance -ne $sensor.Instance) { continue }
        foreach ($label in $wanted) {
            if ($reading.Type -eq $readings[$label].Type -and $reading.Label -like "*$label*") {
                "$($other.Name): $($reading.Label)"
            }
        }
    })

    [pscustomobject]@{
        SensorName   = $sensor.Name
        SensorInst   = $sensor.Instance
        Readings     = $readings
        Conflicts    = $conflicts
        ExtraDevices = $wireViews.Count - 1
    }
}

# Repoints the Astral HwInfo data sources at the WireView readings and leaves every other byte alone.
# Source names stay the same, so all formulas and layers that reference them keep working.
function Convert-OvlForWireView {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)]$Binding
    )

    $newline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = $Text -split [regex]::Escape($newline)

    # SensorInst comes before ReadingName inside a section, so index whole sections first.
    $sections = New-Object System.Collections.Generic.List[hashtable]
    $current = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\[[^\]]+\]$') {
            $current = @{}
            $sections.Add($current)
        } elseif ($null -ne $current -and $lines[$i] -match '^([^=]+)=(.*)$') {
            $current[$Matches[1]] = @{ Index = $i; Value = $Matches[2] }
        }
    }

    $remapped = @{}
    foreach ($section in $sections) {
        if (-not ($section.ContainsKey('Provider') -and $section.ContainsKey('ReadingName'))) { continue }
        if ($section['Provider'].Value -ne 'HwInfo') { continue }
        $astralLabel = $section['ReadingName'].Value
        if (-not $AstralToWireView.Contains($astralLabel)) { continue }
        if (-not ($section.ContainsKey('SensorInst') -and $section.ContainsKey('ReadingType'))) {
            throw "Data source '$astralLabel' has no SensorInst or ReadingType line."
        }

        $wireViewLabel = $AstralToWireView[$astralLabel]
        $reading = $Binding.Readings[$wireViewLabel]
        $lines[$section['SensorInst'].Index] = "SensorInst=$($Binding.SensorInst)"
        $lines[$section['ReadingType'].Index] = "ReadingType=$($reading.Type)"
        $lines[$section['ReadingName'].Index] = "ReadingName=$wireViewLabel"
        $remapped[$astralLabel] = $true
    }

    $missing = @($AstralToWireView.Keys | Where-Object { -not $remapped.ContainsKey($_) })
    if ($missing.Count -gt 0) {
        throw "Preset does not have the expected Power Detector data sources (missing: $($missing -join ', '))."
    }
    $lines -join $newline
}

function Get-InstalledProgramFolder([string]$DisplayNamePattern) {
    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($entry in Get-ItemProperty -Path $uninstallKeys -ErrorAction SilentlyContinue) {
        if ($entry.DisplayName -notlike $DisplayNamePattern) { continue }
        if ($entry.InstallLocation) { $entry.InstallLocation.Trim('"') }
        elseif ($entry.UninstallString) { Split-Path ($entry.UninstallString -replace '^"([^"]+)".*$', '$1') }
    }
}

function Get-RunningProgramFolder([string]$ProcessName) {
    Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
        Where-Object { $_.Path } |
        ForEach-Object { Split-Path $_.Path }
}

function Find-RtssFolder([string]$Override) {
    $candidates = @()
    if ($Override) { $candidates += $Override }
    $candidates += Get-RunningProgramFolder 'RTSS'
    $candidates += Get-InstalledProgramFolder 'RivaTuner Statistics Server*'
    $candidates += Join-Path ${env:ProgramFiles(x86)} 'RivaTuner Statistics Server'
    $candidates | Where-Object { $_ -and (Test-Path (Join-Path $_ 'RTSS.exe')) } | Select-Object -First 1
}

function Find-HwinfoExe {
    $folders = @()
    $folders += Get-RunningProgramFolder 'HWiNFO64'
    $folders += Get-InstalledProgramFolder 'HWiNFO*'
    $folders += Join-Path $env:ProgramFiles 'HWiNFO64'
    $folders | Where-Object { $_ } |
        ForEach-Object { Join-Path $_ 'HWiNFO64.exe' } |
        Where-Object { Test-Path $_ } |
        Select-Object -First 1
}

function Install-TroyMetricsOverlays([string]$Rtss) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $work = Join-Path $env:TEMP ('TroyMetrics-v1.15-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        $zip = Join-Path $work 'overlays.zip'
        $oldProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri $UpstreamZipUrl -OutFile $zip -UseBasicParsing
        } finally {
            $ProgressPreference = $oldProgress
        }
        if ((Get-FileHash -Path $zip -Algorithm SHA256).Hash -ne $UpstreamZipSha256) {
            throw 'The downloaded TroyMetrics package did not match the expected checksum. Nothing was installed.'
        }
        Expand-Archive -Path $zip -DestinationPath (Join-Path $work 'x')
        $packageRtss = Get-ChildItem -Path (Join-Path $work 'x') -Recurse -Directory -Filter 'RivaTuner Statistics Server' |
            Select-Object -First 1
        if (-not $packageRtss) { throw 'The TroyMetrics package does not contain a RivaTuner Statistics Server folder.' }
        Copy-Item -Path (Join-Path $packageRtss.FullName '*') -Destination $Rtss -Recurse -Force
    } finally {
        Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-FontInstalled([string]$NamePattern) {
    foreach ($key in 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts', 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts') {
        $fonts = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if ($fonts -and @($fonts.PSObject.Properties.Name -like $NamePattern).Count -gt 0) { return $true }
    }
    $false
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Wait-ForUser([string]$Message) {
    if ($NoPause) { throw $Message }
    Write-Warn $Message
    [void](Read-Host '   Fix that, then press Enter to check again (or close this window to stop)')
}

function Get-WireViewFromHwinfo {
    $startedHwinfo = $false
    while ($true) {
        $bytes = Read-HwinfoSharedMemory
        if ($null -eq $bytes -and -not $startedHwinfo -and -not (Get-Process -Name 'HWiNFO64' -ErrorAction SilentlyContinue)) {
            $exe = Find-HwinfoExe
            if ($exe) {
                Write-Note "Starting HWiNFO64 ($exe)."
                Write-Note 'If HWiNFO asks, tick "Sensors-only" and click Start.'
                Start-Process -FilePath $exe
                $startedHwinfo = $true
                for ($i = 0; $i -lt 30 -and $null -eq $bytes; $i++) {
                    Start-Sleep -Seconds 2
                    $bytes = Read-HwinfoSharedMemory
                }
            }
        }

        if ($null -eq $bytes) {
            if (-not (Get-Process -Name 'HWiNFO64' -ErrorAction SilentlyContinue) -and -not (Find-HwinfoExe)) {
                Wait-ForUser 'HWiNFO64 is not installed. Download it from www.hwinfo.com, install it, and open it in Sensors-only mode.'
            } else {
                Wait-ForUser ('HWiNFO64 is running but not sharing its sensors. In HWiNFO open the sensor window, click the ' +
                    'cogwheel (Configure Sensors) > Main Settings, and turn on "Shared Memory Support".')
            }
            continue
        }

        try {
            $binding = Get-WireViewBinding (ConvertFrom-HwinfoSharedMemory $bytes)
        } catch {
            Wait-ForUser $_.Exception.Message
            continue
        }
        if ($binding) { return $binding }

        Wait-ForUser ('HWiNFO64 does not see a WireView Pro II. Check that its USB cable is connected, close the ' +
            'Thermal Grizzly WireView app (only one program can talk to it), and update HWiNFO64 to 8.42 or newer.')
    }
}

function Invoke-WireViewSetup {
    Write-Host '=== WireView Pro II setup for TroyMetrics Benchmark Overlays v1.15 ===' -ForegroundColor White

    Write-Step 'Looking for RivaTuner Statistics Server (RTSS)'
    $rtss = Find-RtssFolder $RtssFolder
    while (-not $rtss) {
        Wait-ForUser 'RTSS was not found. Install MSI Afterburner from www.guru3d.com and keep RTSS ticked during install.'
        $rtss = Find-RtssFolder $RtssFolder
    }
    Write-Ok $rtss
    $overlays = Join-Path $rtss 'Plugins\Client\Overlays'

    Write-Step 'Checking the TroyMetrics overlays'
    $installed = @($PowerDetectorPresets | Where-Object { Test-Path (Join-Path $overlays $_) })
    if ($installed.Count -eq 0) {
        # Only install into an RTSS without TroyMetrics presets, so an existing (possibly customized) install is never overwritten.
        Write-Note 'Not installed yet. Downloading TroyMetrics Benchmark Overlays v1.15 from GitHub...'
        Install-TroyMetricsOverlays $rtss
        $installed = @($PowerDetectorPresets | Where-Object { Test-Path (Join-Path $overlays $_) })
        if ($installed.Count -eq 0) { throw 'Install finished but no Power Detector presets were found.' }
    }
    Write-Ok "Found $($installed.Count) of $($PowerDetectorPresets.Count) Power Detector presets"
    foreach ($preset in $PowerDetectorPresets | Where-Object { $installed -notcontains $_ }) {
        Write-Note "Not installed, will skip: $preset"
    }

    Write-Step 'Checking the Adderley Bold font'
    if (Test-FontInstalled 'Adderley*') {
        Write-Ok 'Already installed'
    } else {
        $font = Join-Path $rtss 'Fonts\Adderley Bold.ttf'
        if (-not (Test-Path $font)) { throw "Font file not found: $font" }
        (New-Object -ComObject Shell.Application).Namespace(0x14).CopyHere($font, 0x14)
        Write-Ok 'Installed'
    }

    Write-Step 'Finding the WireView Pro II in HWiNFO64'
    $binding = Get-WireViewFromHwinfo
    Write-Ok "$($binding.SensorName) (sensor instance $($binding.SensorInst))"
    $pin1 = $binding.Readings['Pin 1 Current'].Value
    $total = $binding.Readings['Total Power'].Value
    Write-Note ('Live check: Pin 1 = {0:N2} A, Total Power = {1:N1} W' -f $pin1, $total)
    if ($binding.ExtraDevices -gt 0) { Write-Warn "More than one WireView found; using the first one." }
    foreach ($conflict in $binding.Conflicts) {
        Write-Warn "RTSS might read this instead of the WireView: $conflict. If the overlay numbers look wrong, hide that reading in HWiNFO."
    }

    Write-Step 'Creating WireView versions of the presets'
    $created = 0
    foreach ($preset in $installed) {
        $source = Join-Path $overlays $preset
        $target = Join-Path $overlays ([IO.Path]::GetFileNameWithoutExtension($preset) + $OutputSuffix + '.ovl')
        try {
            $text = $Latin1.GetString([IO.File]::ReadAllBytes($source))
            $converted = Convert-OvlForWireView -Text $text -Binding $binding
        } catch {
            Write-Warn "Skipped $preset. $($_.Exception.Message)"
            continue
        }
        [IO.File]::WriteAllBytes($target, $Latin1.GetBytes($converted))
        Write-Ok (Split-Path $target -Leaf)
        $created++
    }
    if ($created -eq 0) { throw 'None of the installed presets could be converted. Reinstall TroyMetrics v1.15 and run setup again.' }

    Write-Host ''
    Write-Host 'All set. To turn it on:' -ForegroundColor Green
    Write-Host '  1. Open RivaTuner Statistics Server and click Setup.'
    Write-Host '  2. On the Plugins tab, tick OverlayEditor.dll, then double-click it.'
    Write-Host '  3. In OverlayEditor: Layouts > Load, pick a preset ending in "(WireView Pro II)", click Open.'
    Write-Host '  Keep HWiNFO64 running while you play. Run this setup again after updating HWiNFO or moving the WireView.'
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not (Test-IsAdmin)) {
        # Writing into Program Files and installing a font needs administrator rights.
        $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
        if ($RtssFolder) { $relaunch += @('-RtssFolder', "`"$RtssFolder`"") }
        if ($NoPause) { $relaunch += '-NoPause' }
        try {
            Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $relaunch
        } catch {
            Write-Warn 'Setup needs administrator permission. Run it again and click Yes when Windows asks.'
            if (-not $NoPause) { [void](Read-Host 'Press Enter to close') }
        }
        return
    }

    $ErrorActionPreference = 'Stop'
    try {
        Invoke-WireViewSetup
    } catch {
        Write-Host "`n   [X] $($_.Exception.Message)" -ForegroundColor Red
        Write-Host '   Nothing in your original overlays was changed.'
    }
    if (-not $NoPause) { [void](Read-Host "`nPress Enter to close") }
}
