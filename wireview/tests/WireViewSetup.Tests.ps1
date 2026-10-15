# Run with: Invoke-Pester ./wireview/tests
# Set TM_V115_OVERLAYS to the extracted v1.15 "...\Plugins\Client\Overlays" folder to also test the real presets.

BeforeDiscovery {
    $releaseOverlays = $env:TM_V115_OVERLAYS
    $presetCases = @(
        'TroyMetrics 12VHPWR Power Detector.ovl'
        'TM Benchmark 1080p Power Detector.ovl'
        'TroyMetrics Benchmark 3-Fan Power Detector.ovl'
        'TroyMetrics Benchmark 3-Fan PWR+LAT.ovl'
        'TM Benchmark 1080p PWR+LAT.ovl'
    ) | ForEach-Object { @{ Preset = $_ } }
}

BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot) 'WireViewSetup.ps1')

    # Builds a HWiNFO shared memory block (hwisenssm2.h layout). Element sizes are padded
    # past the SDK minimum, as newer HWiNFO builds do, to prove the parser honors the header.
    function New-SharedMemoryBytes {
        param(
            [object[]]$Sensors,
            [object[]]$Readings,
            [string]$Signature = 'HWiS',
            [int]$SensorSize = 392,
            [int]$ReadingSize = 460
        )
        $sensorOffset = 44
        $readingOffset = $sensorOffset + $SensorSize * $Sensors.Count
        $bytes = New-Object byte[] ($readingOffset + $ReadingSize * $Readings.Count)
        $put = {
            param([int]$Offset, [byte[]]$Value)
            [Array]::Copy($Value, 0, $bytes, $Offset, $Value.Length)
        }
        & $put 0 ([Text.Encoding]::ASCII.GetBytes($Signature))
        & $put 20 ([BitConverter]::GetBytes([uint32]$sensorOffset))
        & $put 24 ([BitConverter]::GetBytes([uint32]$SensorSize))
        & $put 28 ([BitConverter]::GetBytes([uint32]$Sensors.Count))
        & $put 32 ([BitConverter]::GetBytes([uint32]$readingOffset))
        & $put 36 ([BitConverter]::GetBytes([uint32]$ReadingSize))
        & $put 40 ([BitConverter]::GetBytes([uint32]$Readings.Count))
        for ($i = 0; $i -lt $Sensors.Count; $i++) {
            $o = $sensorOffset + $SensorSize * $i
            & $put ($o + 4) ([BitConverter]::GetBytes([uint32]$Sensors[$i].Instance))
            & $put ($o + 8) ([Text.Encoding]::ASCII.GetBytes($Sensors[$i].Name))
        }
        for ($i = 0; $i -lt $Readings.Count; $i++) {
            $o = $readingOffset + $ReadingSize * $i
            & $put $o ([BitConverter]::GetBytes([uint32]$Readings[$i].Type))
            & $put ($o + 4) ([BitConverter]::GetBytes([uint32]$Readings[$i].Sensor))
            & $put ($o + 12) ([Text.Encoding]::ASCII.GetBytes($Readings[$i].Label))
            & $put ($o + 284) ([BitConverter]::GetBytes([double]$Readings[$i].Value))
        }
        , $bytes
    }

    function New-WireViewReadings([int]$Sensor, [string[]]$Skip = @()) {
        $readings = for ($pin = 1; $pin -le 6; $pin++) {
            @{ Type = 2; Sensor = $Sensor; Label = "Pin $pin Voltage"; Value = 12.1 }
            @{ Type = 4; Sensor = $Sensor; Label = "Pin $pin Current"; Value = $pin / 2 }
            @{ Type = 5; Sensor = $Sensor; Label = "Pin $pin Power"; Value = $pin * 6 }
        }
        $readings += @{ Type = 4; Sensor = $Sensor; Label = 'Total Current'; Value = 10.5 }
        $readings += @{ Type = 5; Sensor = $Sensor; Label = 'Total Power'; Value = 127.3 }
        @($readings | Where-Object { $Skip -notcontains $_.Label })
    }

    function New-Binding([uint32]$SensorInst = 3) {
        $readings = @{}
        foreach ($label in $AstralToWireView.Values) {
            $readings[$label] = [pscustomobject]@{ Type = $(if ($label -eq 'Total Power') { 5 } else { 4 }) }
        }
        [pscustomobject]@{ SensorInst = $SensorInst; Readings = $readings }
    }

    function New-AstralSource([int]$Index, [string]$Reading, [int]$Type) {
        "[Source$Index]", "Name=$Reading", 'Units=A', 'Format=%0.2f', 'Formula=', 'Provider=HwInfo',
            'SensorInst=17', "ReadingType=$Type", "ReadingName=$Reading"
    }

    function New-Ovl([switch]$WithoutTotalPower) {
        $lines = @('[Master]', 'FontFace=Adderley Bold', '[General]', 'Sources=9')
        $index = 0
        foreach ($astral in $AstralToWireView.Keys) {
            if ($WithoutTotalPower -and $astral -like '*Total Power') { continue }
            $type = if ($astral -like '*Total Power') { 5 } else { 4 }
            $lines += New-AstralSource $index $astral $type
            $index++
        }
        $lines += '[Source7]', 'Name=GPU Temperature', 'Provider=HwInfo', 'SensorInst=0', 'ReadingType=1', 'ReadingName=GPU Temperature'
        $lines += '[Source8]', 'Name=IdealPinAmps', 'Formula=("GPU 12VHPWR Pin1 Current" + "GPU 12VHPWR Pin2 Current") / 2', 'Provider=HAL'
        $lines += '[Layer0]', 'Text=<IF 12VHPWRSensor>%GPU 12VHPWR Pin1 Current%<ELSE>N/A'
        ($lines -join "`r`n") + "`r`n"
    }

    function Get-ChangedLines([string]$Before, [string]$After) {
        $a = $Before -split "`r`n"
        $b = $After -split "`r`n"
        $a.Count | Should -Be $b.Count
        @(for ($i = 0; $i -lt $a.Count; $i++) { if ($a[$i] -cne $b[$i]) { $b[$i] } })
    }
}

Describe 'ConvertFrom-HwinfoSharedMemory' {
    It 'reads sensors and readings using the element sizes from the header' {
        $bytes = New-SharedMemoryBytes -Sensors @(@{ Instance = 0; Name = 'CPU' }, @{ Instance = 3; Name = 'Thermal Grizzly WireView Pro II' }) `
            -Readings @(@{ Type = 4; Sensor = 1; Label = 'Pin 1 Current'; Value = 4.74 })
        $shm = ConvertFrom-HwinfoSharedMemory $bytes

        $shm.Sensors.Count | Should -Be 2
        $shm.Sensors[1].Name | Should -Be 'Thermal Grizzly WireView Pro II'
        $shm.Sensors[1].Instance | Should -Be 3
        $shm.Readings[0].Label | Should -Be 'Pin 1 Current'
        $shm.Readings[0].Type | Should -Be 4
        $shm.Readings[0].SensorIndex | Should -Be 1
        $shm.Readings[0].Value | Should -Be 4.74
    }

    It 'returns empty lists when HWiNFO reports no sensors' {
        $shm = ConvertFrom-HwinfoSharedMemory (New-SharedMemoryBytes -Sensors @() -Readings @())
        $shm.Sensors.Count | Should -Be 0
        $shm.Readings.Count | Should -Be 0
    }

    It 'rejects shared memory that HWiNFO has marked inactive' {
        $bytes = New-SharedMemoryBytes -Sensors @() -Readings @() -Signature 'DEAD'
        { ConvertFrom-HwinfoSharedMemory $bytes } | Should -Throw '*not active*'
    }

    It 'rejects a truncated block' {
        $bytes = New-SharedMemoryBytes -Sensors @(@{ Instance = 0; Name = 'CPU' }) -Readings @()
        { ConvertFrom-HwinfoSharedMemory $bytes[0..99] } | Should -Throw '*truncated*'
    }
}

Describe 'Get-WireViewBinding' {
    It 'finds the WireView sensor instance and the reading types RTSS needs' {
        $bytes = New-SharedMemoryBytes -Sensors @(@{ Instance = 0; Name = 'GPU [#0]: NVIDIA GeForce RTX 4090' }, @{ Instance = 3; Name = 'Thermal Grizzly WireView Pro II' }) `
            -Readings (New-WireViewReadings -Sensor 1)
        $binding = Get-WireViewBinding (ConvertFrom-HwinfoSharedMemory $bytes)

        $binding.SensorName | Should -Be 'Thermal Grizzly WireView Pro II'
        $binding.SensorInst | Should -Be 3
        $binding.Readings['Pin 6 Current'].Type | Should -Be 4
        $binding.Readings['Total Power'].Type | Should -Be 5
        $binding.Readings['Total Power'].Value | Should -Be 127.3
        $binding.Conflicts.Count | Should -Be 0
    }

    It 'returns nothing when no WireView is connected' {
        $bytes = New-SharedMemoryBytes -Sensors @(@{ Instance = 0; Name = 'CPU' }) -Readings @(@{ Type = 5; Sensor = 0; Label = 'Total Power'; Value = 1 })
        Get-WireViewBinding (ConvertFrom-HwinfoSharedMemory $bytes) | Should -BeNullOrEmpty
    }

    It 'names the readings that are missing' {
        $bytes = New-SharedMemoryBytes -Sensors @(@{ Instance = 0; Name = 'Thermal Grizzly WireView Pro II' }) `
            -Readings (New-WireViewReadings -Sensor 0 -Skip 'Pin 4 Current')
        { Get-WireViewBinding (ConvertFrom-HwinfoSharedMemory $bytes) } | Should -Throw '*Pin 4 Current*'
    }

    It 'warns about another sensor that RTSS could match instead' {
        $bytes = New-SharedMemoryBytes -Sensors @(@{ Instance = 0; Name = 'Thermal Grizzly WireView Pro II' }, @{ Instance = 0; Name = 'Corsair PSU' }) `
            -Readings ((New-WireViewReadings -Sensor 0) + @(@{ Type = 5; Sensor = 1; Label = 'Total Power'; Value = 400 }))
        $binding = Get-WireViewBinding (ConvertFrom-HwinfoSharedMemory $bytes)
        $binding.Conflicts | Should -Be @('Corsair PSU: Total Power')
    }

    It 'ignores matching labels on sensors with a different instance' {
        $bytes = New-SharedMemoryBytes -Sensors @(@{ Instance = 0; Name = 'Thermal Grizzly WireView Pro II' }, @{ Instance = 1; Name = 'Corsair PSU' }) `
            -Readings ((New-WireViewReadings -Sensor 0) + @(@{ Type = 5; Sensor = 1; Label = 'Total Power'; Value = 400 }))
        (Get-WireViewBinding (ConvertFrom-HwinfoSharedMemory $bytes)).Conflicts.Count | Should -Be 0
    }
}

Describe 'Convert-OvlForWireView' {
    It 'repoints only SensorInst, ReadingType and ReadingName of the seven Astral sources' {
        $before = New-Ovl
        $after = Convert-OvlForWireView -Text $before -Binding (New-Binding -SensorInst 3)

        $changed = Get-ChangedLines $before $after
        $changed.Count | Should -Be 14   # reading types already match, so 7 SensorInst + 7 ReadingName lines
        $changed | Where-Object { $_ -notmatch '^(SensorInst=3|ReadingName=(Pin [1-6] Current|Total Power))$' } | Should -BeNullOrEmpty
        $after | Should -Match "Name=GPU 12VHPWR Pin1 Current`r`nUnits=A"
        $after | Should -Match 'Formula=\("GPU 12VHPWR Pin1 Current"'
        $after | Should -Match "SensorInst=0`r`nReadingType=1`r`nReadingName=GPU Temperature"
        $after.EndsWith("`r`n") | Should -BeTrue
    }

    It 'writes the reading type HWiNFO reports' {
        $binding = New-Binding
        $binding.Readings['Total Power'] = [pscustomobject]@{ Type = 8 }
        $after = Convert-OvlForWireView -Text (New-Ovl) -Binding $binding
        $after | Should -Match "SensorInst=3`r`nReadingType=8`r`nReadingName=Total Power"
    }

    It 'refuses a preset without the full Power Detector' {
        { Convert-OvlForWireView -Text (New-Ovl -WithoutTotalPower) -Binding (New-Binding) } |
            Should -Throw '*GPU 12VHPWR Connector Total Power*'
    }

    It 'round-trips non-ASCII bytes unchanged' {
        $before = (New-Ovl) + "[Layer9]`r`nText=" + [string][char]0xB0 + "C`r`n"
        $bytesIn = $Latin1.GetBytes($before)
        $after = Convert-OvlForWireView -Text $Latin1.GetString($bytesIn) -Binding (New-Binding)
        $tail = $bytesIn.Length - 9   # "Text=" + 0xB0 + "C" + CRLF
        $bytesOut = $Latin1.GetBytes($after)
        $bytesOut[($bytesOut.Length - 9)..($bytesOut.Length - 1)] | Should -Be $bytesIn[$tail..($bytesIn.Length - 1)]
    }
}

Describe 'v1.15 release presets' -Skip:(-not $releaseOverlays) {
    It 'converts <Preset> by changing only the seven data sources' -ForEach $presetCases {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $env:TM_V115_OVERLAYS $Preset))
        $before = $Latin1.GetString($bytes)
        $after = Convert-OvlForWireView -Text $before -Binding (New-Binding -SensorInst 0)

        $changed = Get-ChangedLines $before $after
        $changed.Count | Should -Be 14   # 7 SensorInst + 7 ReadingName; reading types already match
        $changed | Where-Object { $_ -notmatch '^(SensorInst=0|ReadingName=(Pin [1-6] Current|Total Power))$' } | Should -BeNullOrEmpty
        ([regex]::Matches($after, 'SensorInst=17')).Count | Should -Be 0
        ([regex]::Matches($after, "`r`n")).Count | Should -Be ([regex]::Matches($before, "`r`n")).Count
        # 6 pin labels shrink by 11 chars, Total Power by 22, and 7 x "17" -> "0" by 1 each.
        $Latin1.GetBytes($after).Length | Should -Be ($bytes.Length - 95)
    }
}
