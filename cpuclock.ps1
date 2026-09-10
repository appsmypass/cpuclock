#requires -Version 5.1
<#
.SYNOPSIS
    cpuclock - show the real speed your CPU is actually running at, per core,
    and the exact reason Windows is holding it back.

.DESCRIPTION
    Task Manager shows one averaged "Speed" number. Win32_Processor reports a
    "CurrentClockSpeed" that Microsoft's own counter documentation describes as
    unreliable on any processor that manages its own frequency - which is every
    modern laptop and desktop chip.

    cpuclock reads the Processor Information performance counter set directly,
    differences two raw samples, and reports:

      * the real delivered clock in MHz, per logical processor
      * whether that is above nominal (turbo) or below it (throttling)
      * "% Performance Limit" - the performance the chip GUARANTEES right now
      * whether the cap is coming from your Windows power plan or the platform
      * parked cores
      * DPC and interrupt time, the usual cause of audio crackle and stutter

    It writes nothing. See -Info and the README for the read-only proof.

.PARAMETER Seconds
    Sampling window in seconds. Default 5. Longer is more representative.

.PARAMETER Cores
    Show the full per-logical-processor table rather than just a summary.

.PARAMETER Info
    Show the processor, power plan and limits without taking a timed sample.
    Returns immediately.

.PARAMETER FromJson
    Replay a report previously saved with -Json instead of sampling this
    machine. Lets you diagnose a machine you cannot log into.

.PARAMETER Json
    Emit a JSON report on stdout and nothing else.

.PARAMETER Quiet
    Suppress all human-readable output.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File cpuclock.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File cpuclock.ps1 -Seconds 30 -Cores

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File cpuclock.ps1 -Json > report.json
    powershell -NoProfile -ExecutionPolicy Bypass -File cpuclock.ps1 -FromJson report.json
#>
[CmdletBinding()]
param(
    [int]$Seconds = 5,
    [switch]$Cores,
    [switch]$Info,
    [string]$FromJson,
    [switch]$Json,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:ToolVersion = '1.0.0'

# ---------------------------------------------------------------------------
# Output helpers.
#
# Every human-readable line goes through one of these. A single unguarded
# Write-Host would put text on stdout ahead of the JSON document and make
# -Json unparseable, so there are no bare Write-Host calls below this block.
#
# NOTE the variable name. $script:Quiet would collide with the -Quiet
# parameter, which is a different variable in a different scope and leads to
# the flag appearing to do nothing.
# ---------------------------------------------------------------------------
$script:Silent = $false
$script:BannerShown = $false

function Write-Line   { param([string]$T = '') if (-not $script:Silent) { Write-Host $T } }
function Write-Head   { param([string]$T) if (-not $script:Silent) { Write-Host $T -ForegroundColor Cyan } }
function Write-Good   { param([string]$T) if (-not $script:Silent) { Write-Host $T -ForegroundColor Green } }
function Write-Warn   { param([string]$T) if (-not $script:Silent) { Write-Host $T -ForegroundColor Yellow } }
function Write-Bad    { param([string]$T) if (-not $script:Silent) { Write-Host $T -ForegroundColor Red } }
function Write-Dim    { param([string]$T) if (-not $script:Silent) { Write-Host $T -ForegroundColor DarkGray } }

function Write-Rule {
    param([string]$Title)
    $bar = ''
    $width = 70 - $Title.Length - 4
    if ($width -lt 3) { $width = 3 }
    for ($i = 0; $i -lt $width; $i++) { $bar += [char]0x2500 }
    Write-Head ('  ' + $Title + ' ' + $bar)
}

# ---------------------------------------------------------------------------
# Formatting.
# ---------------------------------------------------------------------------
function Format-Mhz {
    param($Value)
    if ($null -eq $Value) { return '-' }
    $v = [double]$Value
    if ($v -ge 1000.0) { return (('{0:N2}' -f ($v / 1000.0)) + ' GHz') }
    return (('{0:N0}' -f $v) + ' MHz')
}

function Format-Pct {
    param($Value)
    if ($null -eq $Value) { return '-' }
    return (('{0:N1}' -f [double]$Value) + '%')
}

function Get-Bar {
    param($Value, [double]$Full = 100.0, [int]$Width = 20)
    if ($null -eq $Value) { return ('?' * $Width) }
    $v = [double]$Value
    if ($v -lt 0) { $v = 0 }
    $filled = [int][math]::Round(($v / $Full) * $Width)
    if ($filled -gt $Width) { $filled = $Width }
    if ($filled -lt 0) { $filled = 0 }
    $out = ''
    for ($i = 0; $i -lt $filled; $i++) { $out += [char]0x2588 }
    for ($i = $filled; $i -lt $Width; $i++) { $out += [char]0x2591 }
    return $out
}

# ---------------------------------------------------------------------------
# Instance names.
#
# The SAME logical processor is spelled differently by different Windows APIs:
# Get-Counter (PDH) hands back "0,_total" and "_total" in lower case, while the
# raw WMI performance class returns "0,_Total" and "_Total". Comparing them
# without normalising means half the data attaches to nothing. Everything goes
# through this one function so there is a single canonical spelling.
# ---------------------------------------------------------------------------
function Format-InstanceName {
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return '' }
    return $Name.Trim().ToLowerInvariant()
}

function Test-TotalInstance {
    param([string]$Name)
    $n = Format-InstanceName $Name
    if ($n -eq '_total') { return $true }
    if ($n.EndsWith(',_total', [StringComparison]::Ordinal)) { return $true }
    return $false
}

# Only real logical processors, i.e. "node,index" with a numeric index.
function Test-CoreInstance {
    param([string]$Name)
    $n = Format-InstanceName $Name
    if ($n -eq '') { return $false }
    if (Test-TotalInstance $n) { return $false }
    $parts = $n.Split(',')
    if ($parts.Count -ne 2) { return $false }
    $node = 0
    $idx = 0
    if (-not [int]::TryParse($parts[0], [ref]$node)) { return $false }
    if (-not [int]::TryParse($parts[1], [ref]$idx)) { return $false }
    return $true
}

function Get-CoreIndex {
    param([string]$Name)
    $n = Format-InstanceName $Name
    $parts = $n.Split(',')
    if ($parts.Count -ne 2) { return $null }
    $idx = 0
    if (-not [int]::TryParse($parts[1], [ref]$idx)) { return $null }
    return $idx
}

# ---------------------------------------------------------------------------
# Reading the counters.
#
# Every numeric field is read through [decimal]. These are UInt64 counters and
# a running machine can legitimately report a value above Int64.MaxValue, which
# makes a [long] cast throw. [decimal] represents every UInt64 exactly and still
# allows signed subtraction.
# ---------------------------------------------------------------------------
function ConvertTo-Number {
    param($Value)
    if ($null -eq $Value) { return $null }
    $s = [string]$Value
    if ($s -eq '') { return $null }
    $d = [decimal]0
    if ([decimal]::TryParse($s, [ref]$d)) { return $d }
    return $null
}

function Test-CounterAvailable {
    $ok = $false
    try {
        $probe = @(Get-CimInstance Win32_PerfRawData_Counters_ProcessorInformation -ErrorAction Stop)
        if ($probe.Count -gt 0) { $ok = $true }
    } catch {
        $ok = $false
    }
    return $ok
}

function Read-ProcessorCounters {
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $items = @()
    try {
        $items = @(Get-CimInstance Win32_PerfRawData_Counters_ProcessorInformation -ErrorAction Stop)
    } catch {
        $items = @()
    }
    foreach ($i in $items) {
        $rows.Add([pscustomobject]@{
            name          = Format-InstanceName $i.Name
            perf          = ConvertTo-Number $i.PercentProcessorPerformance
            perfBase      = ConvertTo-Number $i.PercentProcessorPerformance_Base
            actual        = ConvertTo-Number $i.ActualFrequency
            actualBase    = ConvertTo-Number $i.ActualFrequency_Base
            utility       = ConvertTo-Number $i.PercentProcessorUtility
            utilityBase   = ConvertTo-Number $i.PercentProcessorUtility_Base
            idle          = ConvertTo-Number $i.PercentIdleTime
            dpc           = ConvertTo-Number $i.PercentDPCTime
            interrupt     = ConvertTo-Number $i.PercentInterruptTime
            timestamp     = ConvertTo-Number $i.Timestamp_Sys100NS
            reportedMhz   = ConvertTo-Number $i.ProcessorFrequency
            limitPct      = ConvertTo-Number $i.PercentPerformanceLimit
            limitFlags    = ConvertTo-Number $i.PerformanceLimitFlags
            parked        = ConvertTo-Number $i.ParkingStatus
            pctMaxFreq    = ConvertTo-Number $i.PercentofMaximumFrequency
        })
    }
    return ,$rows.ToArray()
}

# ---------------------------------------------------------------------------
# The arithmetic.
#
# Deliberately a PURE function: two snapshots in, computed rows out, no clock
# and no sleeping. That is what makes it testable against hand-computed ground
# truth instead of racing a real Start-Sleep.
#
# Formulas were not guessed from documentation. They were derived by applying
# candidate arithmetic to PDH's own consecutive raw samples and comparing
# against PDH's cooked value over the identical window; the forms below match
# to 0.000000%.
# ---------------------------------------------------------------------------
function Measure-Sample {
    param($First, $Second, [double]$NominalMhz = 0.0)

    $before = @{}
    foreach ($r in @($First)) {
        if ($null -eq $r) { continue }
        $before[(Format-InstanceName $r.name)] = $r
    }

    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($b in @($Second)) {
        if ($null -eq $b) { continue }
        $key = Format-InstanceName $b.name
        if (-not $before.ContainsKey($key)) { continue }
        $a = $before[$key]

        $dTime = Get-Delta $a.timestamp $b.timestamp

        # Delivered performance as a percentage of nominal. Can exceed 100
        # legitimately: that IS turbo, and clamping it would hide the single
        # most useful thing this tool reports.
        $perfPct = Get-Ratio (Get-Delta $a.perf $b.perf) (Get-Delta $a.perfBase $b.perfBase)

        # Actual delivered clock in MHz, straight from the counter pair.
        $actualMhz = Get-Ratio (Get-Delta $a.actual $b.actual) (Get-Delta $a.actualBase $b.actualBase)

        $utilityPct = Get-Ratio (Get-Delta $a.utility $b.utility) (Get-Delta $a.utilityBase $b.utilityBase)

        # "% Processor Time" is the number almost every script reports. It only
        # measures time spent not-idle, so a core crawling at 800 MHz can look
        # just as busy as one at 3.9 GHz. Kept precisely so it can be contrasted
        # with utility below.
        $timePct = $null
        $dIdle = Get-Delta $a.idle $b.idle
        if ($null -ne $dIdle -and $null -ne $dTime -and $dTime -gt 0) {
            $timePct = 100.0 - (100.0 * [double]$dIdle / [double]$dTime)
            if ($timePct -lt 0.0) { $timePct = 0.0 }
        }

        $dpcPct = $null
        $dDpc = Get-Delta $a.dpc $b.dpc
        if ($null -ne $dDpc -and $null -ne $dTime -and $dTime -gt 0) {
            $dpcPct = 100.0 * [double]$dDpc / [double]$dTime
        }

        $intPct = $null
        $dInt = Get-Delta $a.interrupt $b.interrupt
        if ($null -ne $dInt -and $null -ne $dTime -and $dTime -gt 0) {
            $intPct = 100.0 * [double]$dInt / [double]$dTime
        }

        # The counter set carries its own redundancy: actual frequency must
        # equal delivered-performance times the nominal clock. If a row fails
        # that, the parse is not trustworthy and the numbers are withheld
        # rather than printed with false confidence.
        $derivedNominal = $null
        if ($null -ne $actualMhz -and $null -ne $perfPct -and $perfPct -gt 0.0001) {
            $derivedNominal = $actualMhz / ($perfPct / 100.0)
        }

        $consistent = $true
        if ($NominalMhz -gt 0 -and $null -ne $actualMhz -and $null -ne $perfPct) {
            $expected = ($perfPct / 100.0) * $NominalMhz
            if ($expected -gt 0) {
                $rel = 100.0 * [math]::Abs($actualMhz - $expected) / $expected
                if ($rel -gt 1.0) { $consistent = $false }
            }
        }

        $parked = $false
        if ($null -ne $b.parked -and [double]$b.parked -ne 0) { $parked = $true }

        $limitPct = $null
        if ($null -ne $b.limitPct) { $limitPct = [double]$b.limitPct }

        $flags = $null
        if ($null -ne $b.limitFlags) { $flags = [long]$b.limitFlags }

        $reported = $null
        if ($null -ne $b.reportedMhz) { $reported = [double]$b.reportedMhz }

        $out.Add([pscustomobject]@{
            name           = $key
            isTotal        = (Test-TotalInstance $key)
            isCore         = (Test-CoreInstance $key)
            coreIndex      = (Get-CoreIndex $key)
            perfPct        = $perfPct
            actualMhz      = $actualMhz
            derivedNominal = $derivedNominal
            utilityPct     = $utilityPct
            timePct        = $timePct
            dpcPct         = $dpcPct
            interruptPct   = $intPct
            parked         = $parked
            limitPct       = $limitPct
            limitFlags     = $flags
            reportedMhz    = $reported
            consistent     = $consistent
        })
    }
    return ,$out.ToArray()
}

# -Info takes no timed sample, but several of the most useful fields are
# instantaneous rather than cumulative: the performance limit, its flags and
# the parking state are all valid from a single read. This produces rows with
# those populated and every delta-derived field left null - deliberately null
# and not zero, so "not measured" can never be mistaken for "measured as none".
function ConvertTo-InstantRows {
    param($Snapshot)
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($b in @($Snapshot)) {
        if ($null -eq $b) { continue }
        $key = Format-InstanceName $b.name
        $parked = $false
        if ($null -ne $b.parked -and [double]$b.parked -ne 0) { $parked = $true }
        $limitPct = $null
        if ($null -ne $b.limitPct) { $limitPct = [double]$b.limitPct }
        $flags = $null
        if ($null -ne $b.limitFlags) { $flags = [long]$b.limitFlags }
        $reported = $null
        if ($null -ne $b.reportedMhz) { $reported = [double]$b.reportedMhz }
        $out.Add([pscustomobject]@{
            name           = $key
            isTotal        = (Test-TotalInstance $key)
            isCore         = (Test-CoreInstance $key)
            coreIndex      = (Get-CoreIndex $key)
            perfPct        = $null
            actualMhz      = $null
            derivedNominal = $null
            utilityPct     = $null
            timePct        = $null
            dpcPct         = $null
            interruptPct   = $null
            parked         = $parked
            limitPct       = $limitPct
            limitFlags     = $flags
            reportedMhz    = $reported
            consistent     = $true
        })
    }
    return ,$out.ToArray()
}

function Get-Delta {
    param($A, $B)
    if ($null -eq $A -or $null -eq $B) { return $null }
    $d = [decimal]$B - [decimal]$A
    # A counter that went backwards is not a small negative measurement, it is
    # a counter reset. Reporting it as 0 would let "unknown" masquerade as
    # "idle", so it becomes null instead.
    if ($d -lt 0) { return $null }
    return $d
}

function Get-Ratio {
    param($Num, $Den)
    if ($null -eq $Num -or $null -eq $Den) { return $null }
    if ([decimal]$Den -eq 0) { return $null }
    return [double]([decimal]$Num / [decimal]$Den)
}

# ---------------------------------------------------------------------------
# Processor identity.
# ---------------------------------------------------------------------------
function Get-Processor {
    $p = $null
    try {
        $p = @(Get-CimInstance Win32_Processor -ErrorAction Stop)[0]
    } catch {
        return $null
    }
    if ($null -eq $p) { return $null }
    $maxMhz = ConvertTo-Number $p.MaxClockSpeed
    $curMhz = ConvertTo-Number $p.CurrentClockSpeed
    $nMax = $null
    if ($null -ne $maxMhz) { $nMax = [double]$maxMhz }
    $nCur = $null
    if ($null -ne $curMhz) { $nCur = [double]$curMhz }
    return [pscustomobject]@{
        name              = [string]$p.Name
        maxClockMhz       = $nMax
        currentClockMhz   = $nCur
        cores             = [int]$p.NumberOfCores
        logical           = [int]$p.NumberOfLogicalProcessors
        loadPercentage    = $p.LoadPercentage
    }
}

# ---------------------------------------------------------------------------
# Power plan.
#
# powercfg is a native tool and writes to stderr. With $ErrorActionPreference
# set to Stop that becomes a terminating NativeCommandError complete with a red
# stack trace, so it is relaxed for the duration of these functions.
#
# Every powercfg call here is a QUERY. Nothing in this file sets a power
# setting, and the test suite greps for the mutating verbs to prove it.
# ---------------------------------------------------------------------------
function Get-PowerPlan {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $guid = $null
        $planName = $null
        $raw = ''
        try { $raw = (& powercfg /getactivescheme 2>&1 | Out-String) } catch { $raw = '' }
        if ($raw -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
            $guid = $Matches[1]
        }
        if ($raw -match '\(([^)]+)\)') { $planName = $Matches[1].Trim() }

        $onBattery = $null
        try {
            $bat = @(Get-CimInstance Win32_Battery -ErrorAction Stop)
            if ($bat.Count -gt 0) {
                # BatteryStatus 2 == plugged in / AC. Anything else is discharging.
                $onBattery = ([int]$bat[0].BatteryStatus -ne 2)
            }
        } catch {
            $onBattery = $null
        }

        $maxState = Get-ProcThrottle $guid 'PROCTHROTTLEMAX' $onBattery
        $minState = Get-ProcThrottle $guid 'PROCTHROTTLEMIN' $onBattery

        return [pscustomobject]@{
            guid          = $guid
            name          = $planName
            onBattery     = $onBattery
            maxProcState  = $maxState
            minProcState  = $minState
        }
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Get-ProcThrottle {
    param([string]$Guid, [string]$Setting, $OnBattery)
    if ([string]::IsNullOrEmpty($Guid)) { return $null }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $text = ''
        try { $text = (& powercfg /query $Guid SUB_PROCESSOR $Setting 2>&1 | Out-String) } catch { $text = '' }
        if ([string]::IsNullOrEmpty($text)) { return $null }

        $ac = $null
        $dc = $null
        if ($text -match 'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)') {
            $ac = [Convert]::ToInt32($Matches[1], 16)
        }
        if ($text -match 'Current DC Power Setting Index:\s*0x([0-9a-fA-F]+)') {
            $dc = [Convert]::ToInt32($Matches[1], 16)
        }
        # Which one is in force depends on whether the machine is on battery.
        # Reporting the AC value on a laptop running from its battery would name
        # the wrong cap entirely.
        $active = $ac
        if ($null -ne $OnBattery -and $OnBattery -eq $true) { $active = $dc }
        return [pscustomobject]@{ ac = $ac; dc = $dc; active = $active }
    } finally {
        $ErrorActionPreference = $prev
    }
}

# ---------------------------------------------------------------------------
# Performance Limit Flags.
#
# Windows' own counter help says only "Performance Limit Flags indicate reasons
# why the processor performance was limited" - it does not enumerate the bits,
# and the meanings are platform dependent. So the raw value is ALWAYS reported,
# any bit without a known name is shown as its hex value rather than guessed
# at, and no verdict below depends on this decode alone. The actionable
# diagnosis comes from "% Performance Limit", which IS documented.
# ---------------------------------------------------------------------------
function Get-LimitFlagNames {
    param($Flags)
    $names = New-Object 'System.Collections.Generic.List[object]'
    if ($null -eq $Flags) { return ,$names.ToArray() }
    # PerformanceLimitFlags is a UInt32. Bit 31 alone is 2147483648, which does
    # not fit in an Int32, so both the value and the bit masks are 64-bit.
    $v = [long]$Flags
    if ($v -eq 0) { return ,$names.ToArray() }
    $known = @{
        [long]1  = 'thermal'
        [long]2  = 'power budget'
        [long]4  = 'electrical current'
        [long]8  = 'OS power policy'
        [long]16 = 'voltage regulator thermal'
        [long]64 = 'cores disabled'
    }
    for ($bit = 0; $bit -lt 32; $bit++) {
        $mask = [long]1 -shl $bit
        if (($v -band $mask) -ne 0) {
            if ($known.ContainsKey($mask)) { $names.Add($known[$mask]) }
            else { $names.Add('unknown (0x' + $mask.ToString('X') + ')') }
        }
    }
    return ,$names.ToArray()
}

# ---------------------------------------------------------------------------
# Aggregation.
# ---------------------------------------------------------------------------
function Get-TotalRow {
    param($Rows)
    $all = @($Rows)
    $t = @($all | Where-Object { $_.name -eq '_total' })
    if ($t.Count -gt 0) { return $t[0] }
    $t2 = @($all | Where-Object { $_.isTotal })
    if ($t2.Count -gt 0) { return $t2[0] }
    return $null
}

function Get-CoreRows {
    param($Rows)
    $all = @($Rows)
    $c = @($all | Where-Object { $_.isCore } | Sort-Object -Property coreIndex)
    return ,$c
}

# ---------------------------------------------------------------------------
# Rendering.
# ---------------------------------------------------------------------------
function Show-Banner {
    if ($script:BannerShown) { return }
    $script:BannerShown = $true
    Write-Rule 'cpuclock'
    Write-Line '  How fast is your CPU actually running?'
    Write-Line ''
}

function Show-Processor {
    param($Cpu, $Plan, $Nominal)
    Write-Rule 'Processor'
    if ($null -eq $Cpu) {
        Write-Dim '    processor details unavailable'
        Write-Line ''
        return
    }
    Write-Line ('    ' + $Cpu.name)
    $topo = '      ' + $Cpu.cores + ' physical core(s), ' + $Cpu.logical + ' logical processor(s)'
    Write-Line $topo
    if ($null -ne $Nominal) {
        Write-Line ('      Nominal clock : ' + (Format-Mhz $Nominal) + '   (the 100% reference Windows measures against)')
    }
    Write-Line ''

    if ($null -ne $Plan) {
        $pn = $Plan.name
        if ([string]::IsNullOrEmpty($pn)) { $pn = 'unknown' }
        $src = 'AC power'
        if ($null -ne $Plan.onBattery -and $Plan.onBattery -eq $true) { $src = 'battery' }
        Write-Line ('    Power plan    : ' + $pn + '   (running on ' + $src + ')')
        $maxTxt = '-'
        $minTxt = '-'
        if ($null -ne $Plan.maxProcState -and $null -ne $Plan.maxProcState.active) { $maxTxt = [string]$Plan.maxProcState.active + '%' }
        if ($null -ne $Plan.minProcState -and $null -ne $Plan.minProcState.active) { $minTxt = [string]$Plan.minProcState.active + '%' }
        Write-Line ('      Processor state allowed by the plan: ' + $minTxt + ' min, ' + $maxTxt + ' max')
        Write-Line ''
    }
}

function Show-Clock {
    param($Total, $Nominal, $Cpu)
    Write-Rule 'Actual clock speed'
    if ($null -eq $Total) {
        Write-Dim '    no total row in the sample'
        Write-Line ''
        return
    }
    if (-not $Total.consistent) {
        Write-Warn '    The counters disagreed with themselves; speed withheld.'
        Write-Line ''
        return
    }

    $mhz = $Total.actualMhz
    Write-Line ('    Running at    : ' + (Format-Mhz $mhz))
    if ($null -ne $Total.perfPct -and $null -ne $Nominal) {
        $rel = Format-Pct $Total.perfPct
        if ($Total.perfPct -ge 102.0) {
            Write-Good  ('      ' + $rel + ' of nominal ' + (Format-Mhz $Nominal) + '  - turbo is working')
        } elseif ($Total.perfPct -ge 95.0) {
            Write-Line  ('      ' + $rel + ' of nominal ' + (Format-Mhz $Nominal) + '  - at nominal, no turbo headroom used')
        } else {
            Write-Warn  ('      ' + $rel + ' of nominal ' + (Format-Mhz $Nominal) + '  - BELOW nominal')
        }
    }
    Write-Line ''

    # The whole point of the tool: the numbers everyone reads are documented by
    # Microsoft as unreliable, and they disagree with the measured one.
    Write-Line '    What Windows reports, versus what it measured:'
    if ($null -ne $Cpu -and $null -ne $Cpu.currentClockMhz) {
        Write-Dim ('      ' + 'Win32_Processor.CurrentClockSpeed'.PadRight(34) + (Format-Mhz $Cpu.currentClockMhz).PadLeft(9) + '   (documented unreliable)')
    }
    if ($null -ne $Total.reportedMhz) {
        Write-Dim ('      ' + '"Processor Frequency" counter'.PadRight(34) + (Format-Mhz $Total.reportedMhz).PadLeft(9) + '   (documented unreliable)')
    }
    if ($null -ne $Cpu -and $null -ne $Cpu.maxClockMhz) {
        Write-Dim ('      ' + 'Win32_Processor.MaxClockSpeed'.PadRight(34) + (Format-Mhz $Cpu.maxClockMhz).PadLeft(9) + '   (nominal, NOT the turbo ceiling)')
    }
    Write-Line     ('      ' + 'Measured delivered clock'.PadRight(34) + (Format-Mhz $mhz).PadLeft(9) + '   <- the real one')
    Write-Line ''

    if ($null -ne $Total.utilityPct -and $null -ne $Total.timePct) {
        Write-Line '    How busy it really is:'
        Write-Line ('      Busy time      ' + (Format-Pct $Total.timePct).PadLeft(7) + '  ' + (Get-Bar $Total.timePct) + '   time spent not idle')
        Write-Line ('      Real work done ' + (Format-Pct $Total.utilityPct).PadLeft(7) + '  ' + (Get-Bar $Total.utilityPct) + '   work vs nominal capacity')
        Write-Line ''
    }
}

function Show-Limit {
    param($Total, $Plan)
    Write-Rule 'What is limiting it'
    if ($null -eq $Total) {
        Write-Dim '    no data'
        Write-Line ''
        return
    }
    if ($null -eq $Total.limitPct) {
        Write-Dim '    This platform does not report a performance limit.'
        Write-Line ''
        return
    }
    $lp = [double]$Total.limitPct
    $perf = $null
    if ($null -ne $Total.perfPct) { $perf = [double]$Total.perfPct }

    if ($lp -ge 99.5) {
        Write-Good ('    Guaranteed performance : ' + (Format-Pct $lp) + ' of nominal - nothing is holding the CPU back.')
    } elseif ($null -ne $perf -and $perf -gt ($lp * 1.05)) {
        # The guarantee is a floor, not a ceiling. A chip delivering more than
        # it promises is turboing, which is exactly what it should be doing.
        Write-Good ('    Guaranteed performance : ' + (Format-Pct $lp) + ' of nominal, but actually delivering ' + (Format-Pct $perf) + '.')
        Write-Line  '      The guarantee is a floor, not a ceiling. Your CPU is running past it.'
    } elseif ($null -ne $perf) {
        Write-Warn ('    Guaranteed performance : ' + (Format-Pct $lp) + ' of nominal, and only delivering ' + (Format-Pct $perf) + '.')
        Write-Line  '      The platform limit is what is holding this CPU back.'
    } else {
        Write-Line ('    Guaranteed performance : ' + (Format-Pct $lp) + ' of nominal.')
    }

    $flagNames = Get-LimitFlagNames $Total.limitFlags
    $fn = @($flagNames)
    $fv = [long]0
    if ($null -ne $Total.limitFlags) { $fv = [long]$Total.limitFlags }
    if ($fn.Count -gt 0) {
        Write-Line ('      Reason flags 0x' + $fv.ToString('X') + ' : ' + ($fn -join ', '))
    } else {
        Write-Line ('      Reason flags 0x' + $fv.ToString('X') + ' : none set')
    }

    # Separating an OS cap from a platform cap is the actionable part. One you
    # can fix in Settings in ten seconds; the other needs a cooling pad.
    if ($null -ne $Plan -and $null -ne $Plan.maxProcState -and $null -ne $Plan.maxProcState.active) {
        $planMax = [int]$Plan.maxProcState.active
        if ($planMax -lt 100) {
            Write-Bad ('      Your power plan caps the CPU at ' + $planMax + '%. That is a Windows setting, not your hardware.')
        } elseif ($lp -lt 99.5) {
            Write-Line '      Your power plan allows 100%, so this guarantee is set by the platform'
            Write-Line '      (power budget or heat), not by Windows.'
        }
    }
    Write-Line ''
}

function Show-Cores {
    param($Rows, $Nominal, [bool]$Full)
    $coreRows = Get-CoreRows $Rows
    $cr = @($coreRows)
    if ($cr.Count -eq 0) { return }
    $parked = @($cr | Where-Object { $_.parked })

    Write-Rule 'Per logical processor'
    if (-not $Full) {
        Write-Dim ('    ' + $cr.Count + ' logical processors; ' + $parked.Count + ' parked.  Use -Cores for the full table.')
        Write-Line ''
        return
    }
    Write-Dim '      cpu      clock     of nominal   real work   busy    limit   state'
    foreach ($c in $cr) {
        $line = '      ' + ([string]$c.coreIndex).PadRight(4)
        $line += (Format-Mhz $c.actualMhz).PadLeft(9)
        $line += (Format-Pct $c.perfPct).PadLeft(13)
        $line += (Format-Pct $c.utilityPct).PadLeft(12)
        $line += (Format-Pct $c.timePct).PadLeft(8)
        $line += (Format-Pct $c.limitPct).PadLeft(9)
        $state = '   ok'
        if ($c.parked) { $state = '   PARKED' }
        if (-not $c.consistent) { $state = '   inconsistent' }
        $line += $state
        if ($c.parked -or (-not $c.consistent)) { Write-Warn $line } else { Write-Line $line }
    }
    Write-Line ''
}

function Show-Latency {
    param($Total)
    if ($null -eq $Total) { return }
    if ($null -eq $Total.dpcPct -and $null -eq $Total.interruptPct) { return }
    Write-Rule 'Driver overhead'
    Write-Line ('    Deferred procedure calls : ' + (Format-Pct $Total.dpcPct))
    Write-Line ('    Hardware interrupts      : ' + (Format-Pct $Total.interruptPct))
    Write-Dim  '    High values here are driver time, and show up as audio crackle and stutter.'
    Write-Line ''
}

# ---------------------------------------------------------------------------
# Risks.
# ---------------------------------------------------------------------------
function New-Risk {
    param([string]$Code, [string]$Level, [string]$Message)
    return [pscustomobject]@{ code = $Code; level = $Level; message = $Message }
}

function Get-Risks {
    param($Rows, $Total, $Plan, $Nominal, [bool]$Sampled)

    $risks = New-Object 'System.Collections.Generic.List[object]'
    $allRows = @($Rows)

    # An OS-imposed cap is the single most actionable thing this tool can find,
    # and it is checked even in -Info mode because it needs no sample.
    if ($null -ne $Plan -and $null -ne $Plan.maxProcState -and $null -ne $Plan.maxProcState.active) {
        $pm = [int]$Plan.maxProcState.active
        if ($pm -lt 100) {
            $where = 'on AC power'
            if ($null -ne $Plan.onBattery -and $Plan.onBattery -eq $true) { $where = 'on battery' }
            $risks.Add((New-Risk 'plan-caps-cpu' 'FAIL' ('Your power plan limits the CPU to ' + $pm + '% of its speed ' + $where + '. Raise "Maximum processor state" to 100% in Control Panel > Power Options > Change plan settings > Advanced.')))
        }
    }
    if ($null -ne $Plan -and $null -ne $Plan.minProcState -and $null -ne $Plan.minProcState.active) {
        $pmin = [int]$Plan.minProcState.active
        if ($pmin -ge 100) {
            $risks.Add((New-Risk 'plan-pins-cpu' 'INFO' 'Your power plan holds the CPU at 100% minimum state. That maximises responsiveness but also heat and battery drain.'))
        }
    }
    if ($null -ne $Plan -and -not [string]::IsNullOrEmpty($Plan.name)) {
        if ($Plan.name.ToLowerInvariant().Contains('power saver')) {
            $risks.Add((New-Risk 'power-saver-plan' 'WARN' 'The active power plan is Power saver. Switch to Balanced or better before recording or playing.'))
        }
    }
    if ($null -ne $Plan -and $null -ne $Plan.onBattery -and $Plan.onBattery -eq $true) {
        $risks.Add((New-Risk 'on-battery' 'INFO' 'This machine is running on battery. Sustained clocks are usually much lower than on AC power.'))
    }

    # Parking state and the performance limit are instantaneous counter fields,
    # so these checks are valid with or without a timed sample and run in -Info
    # mode too.
    $parked = @($allRows | Where-Object { $_.isCore -and $_.parked })
    if ($parked.Count -gt 0) {
        $risks.Add((New-Risk 'cores-parked' 'WARN' ($parked.Count.ToString() + ' logical processor(s) are parked. Windows has taken them offline to save power; heavily threaded work such as encoding will be slower.')))
    }

    # "% Performance Limit" is the performance the platform GUARANTEES, not the
    # performance it is delivering. On a real laptop this reads 85% while the
    # chip is actually turboing at 214% of nominal, so treating a low limit as
    # throttling on its own cries wolf on healthy hardware. The limit is only a
    # problem when it is actually BINDING: the CPU is busy and is not managing
    # to run past the guarantee.
    if ($null -ne $Total -and $null -ne $Total.limitPct) {
        $lp = [double]$Total.limitPct
        if ($lp -lt 95.0) {
            $perf = $null
            if ($Sampled -and $null -ne $Total.perfPct) { $perf = [double]$Total.perfPct }
            $busy = $false
            if ($Sampled -and $null -ne $Total.utilityPct -and [double]$Total.utilityPct -ge 25.0) { $busy = $true }

            if ($null -eq $perf) {
                $risks.Add((New-Risk 'limit-untested' 'INFO' ('The platform currently guarantees only ' + (Format-Pct $lp) + ' of nominal performance. Run a full scan while your game or encode is running to see whether that is actually costing you speed.')))
            } elseif ($perf -gt ($lp * 1.05)) {
                $risks.Add((New-Risk 'limit-not-binding' 'INFO' ('The platform guarantees only ' + (Format-Pct $lp) + ' of nominal, but the CPU is actually delivering ' + (Format-Pct $perf) + '. That is opportunistic turbo, and it is normal.')))
            } elseif (-not $busy) {
                $risks.Add((New-Risk 'limit-untested' 'INFO' ('The platform currently guarantees only ' + (Format-Pct $lp) + ' of nominal performance, but the CPU was too idle during this sample to tell whether that is costing you anything. Re-run while your game or encode is running.')))
            } elseif ($lp -lt 70.0) {
                $risks.Add((New-Risk 'throttled-hard' 'FAIL' ('The CPU is busy but only reaching ' + (Format-Pct $perf) + ' of nominal, against a platform guarantee of ' + (Format-Pct $lp) + '. Something is throttling it hard - check cooling and power delivery.')))
            } else {
                $risks.Add((New-Risk 'throttled' 'WARN' ('The CPU is busy but only reaching ' + (Format-Pct $perf) + ' of nominal, against a platform guarantee of ' + (Format-Pct $lp) + '. The platform limit is what is holding it back.')))
            }
        }
    }

    if (-not $Sampled) {
        return ,$risks.ToArray()
    }

    $bad = @($allRows | Where-Object { -not $_.consistent })
    if ($bad.Count -gt 0) {
        $risks.Add((New-Risk 'unreliable-counter' 'INFO' ($bad.Count.ToString() + ' counter row(s) failed their own internal consistency check and were not reported.')))
    }

    if ($null -ne $Total -and $Total.consistent) {
        if ($null -ne $Total.perfPct) {
            $pp = [double]$Total.perfPct
            $busy = $false
            if ($null -ne $Total.utilityPct -and [double]$Total.utilityPct -ge 25.0) { $busy = $true }
            if ($busy -and $pp -lt 60.0) {
                $risks.Add((New-Risk 'clock-collapsed' 'FAIL' ('The CPU is working but only running at ' + (Format-Pct $pp) + ' of nominal. Expect stutter and long encodes.')))
            } elseif ($busy -and $pp -lt 100.0) {
                $risks.Add((New-Risk 'no-turbo' 'INFO' ('Under load the CPU stayed at ' + (Format-Pct $pp) + ' of nominal and never turboed above it.')))
            }
        }
        if ($null -ne $Total.utilityPct -and [double]$Total.utilityPct -ge 90.0) {
            $risks.Add((New-Risk 'cpu-saturated' 'WARN' ('The CPU is at ' + (Format-Pct $Total.utilityPct) + ' of its real capacity. It, not the GPU or the disk, is your bottleneck.')))
        }
        if ($null -ne $Total.dpcPct -and [double]$Total.dpcPct -ge 10.0) {
            $risks.Add((New-Risk 'high-dpc' 'WARN' ('Deferred procedure calls are using ' + (Format-Pct $Total.dpcPct) + ' of the CPU. That is driver time, and it is the usual cause of audio crackle and micro-stutter.')))
        }
        if ($null -ne $Total.interruptPct -and [double]$Total.interruptPct -ge 10.0) {
            $risks.Add((New-Risk 'high-interrupt' 'WARN' ('Hardware interrupts are using ' + (Format-Pct $Total.interruptPct) + ' of the CPU. Suspect a misbehaving device or driver.')))
        }
    }

    return ,$risks.ToArray()
}

function Show-Risks {
    param($Risks)
    Write-Rule 'Verdict'
    $r = @()
    if ($null -ne $Risks) { $r = @($Risks) }
    if ($r.Count -eq 0) {
        Write-Good '    No problems found. Your CPU is running at the speed it should be.'
        Write-Line ''
        return
    }
    foreach ($item in $r) {
        if ($null -eq $item) { continue }
        $line = '    [' + $item.level + '] ' + $item.message
        if ($item.level -eq 'FAIL') { Write-Bad $line }
        elseif ($item.level -eq 'WARN') { Write-Warn $line }
        else { Write-Dim $line }
    }
    Write-Line ''
}

function Get-ExitCode {
    param($Risks)
    $r = @()
    if ($null -ne $Risks) { $r = @($Risks) }
    $bad = @($r | Where-Object { $null -ne $_ -and ($_.level -eq 'FAIL' -or $_.level -eq 'WARN') })
    if ($bad.Count -gt 0) { return 1 }
    return 0
}

# ---------------------------------------------------------------------------
# Report assembly.
# ---------------------------------------------------------------------------
function New-Report {
    param($Cpu, $Plan, $Nominal, $Rows, $Risks, [string]$Mode, [bool]$Ok, $ErrorText, $Seconds)
    $rowArr = @()
    if ($null -ne $Rows) { $rowArr = @($Rows) }
    $riskArr = @()
    if ($null -ne $Risks) { $riskArr = @($Risks) }
    return [pscustomobject]@{
        tool        = 'cpuclock'
        version     = $script:ToolVersion
        ok          = $Ok
        error       = $ErrorText
        mode        = $Mode
        seconds     = $Seconds
        nominalMhz  = $Nominal
        processor   = $Cpu
        powerPlan   = $Plan
        rows        = $rowArr
        risks       = $riskArr
    }
}

function Write-Failure {
    param([string]$Message, [string]$Mode)
    if ($Json) {
        $rep = New-Report $null $null $null @() @() $Mode $false $Message $null
        $rep | ConvertTo-Json -Depth 8
    } else {
        Show-Banner
        Write-Bad ('  ' + $Message)
        Write-Line ''
    }
    exit 2
}

# ---------------------------------------------------------------------------
# Allow the test suites to dot-source this file for its functions without
# running a scan.
# ---------------------------------------------------------------------------
if ($MyInvocation.InvocationName -eq '.') { return }

# ===========================================================================
# Main
# ===========================================================================
if ($Json -or $Quiet) { $script:Silent = $true }

$mode = 'scan'
if ($Info) { $mode = 'info' }
if (-not [string]::IsNullOrEmpty($FromJson)) { $mode = 'fromjson' }

if ($Seconds -lt 1 -or $Seconds -gt 3600) {
    Write-Failure ('-Seconds must be between 1 and 3600 (got ' + $Seconds + ').') $mode
}

Show-Banner

$cpu = $null
$plan = $null
$nominal = $null
$rows = @()
$sampled = $false

if ($mode -eq 'fromjson') {
    if (-not (Test-Path -LiteralPath $FromJson)) {
        Write-Failure ('No such report file: ' + $FromJson) $mode
    }
    $text = ''
    try {
        $text = [IO.File]::ReadAllText($FromJson, [Text.Encoding]::UTF8)
    } catch {
        Write-Failure ('Could not read report file: ' + $FromJson) $mode
    }
    # A byte-order mark must be compared by character. "x".StartsWith(bomString)
    # is culture-sensitive and U+FEFF has zero collation weight, which makes it
    # true for EVERY string and quietly removes the first real character.
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    $doc = $null
    try {
        $doc = $text | ConvertFrom-Json
    } catch {
        Write-Failure ('That file is not valid JSON: ' + $FromJson) $mode
    }
    if ($null -eq $doc) { Write-Failure ('That report is empty: ' + $FromJson) $mode }
    $isCpuClock = $false
    try { if ([string]$doc.tool -eq 'cpuclock') { $isCpuClock = $true } } catch { $isCpuClock = $false }
    if (-not $isCpuClock) { Write-Failure ('That is not a cpuclock report: ' + $FromJson) $mode }

    try { $cpu = $doc.processor } catch { $cpu = $null }
    try { $plan = $doc.powerPlan } catch { $plan = $null }
    try { $nominal = $doc.nominalMhz } catch { $nominal = $null }
    $rows = @($doc.rows)
    $sampled = ($rows.Count -gt 0)
    Write-Dim ('  Replaying ' + $FromJson)
    Write-Line ''
} else {
    if (-not (Test-CounterAvailable)) {
        Write-Failure 'The Processor Information performance counters are not available on this machine. Try: lodctr /r' $mode
    }
    $cpu = Get-Processor
    $plan = Get-PowerPlan
    if ($null -ne $cpu -and $null -ne $cpu.maxClockMhz) { $nominal = [double]$cpu.maxClockMhz }

    if ($mode -eq 'info') {
        $snap = Read-ProcessorCounters
        $instant = ConvertTo-InstantRows $snap
        $rows = @($instant)
    }

    if ($mode -eq 'scan') {
        $first = Read-ProcessorCounters
        $f = @($first)
        if ($f.Count -eq 0) {
            Write-Failure 'The processor counters returned no rows.' $mode
        }
        Write-Rule 'Sampling'
        Write-Line ('    Measuring for ' + $Seconds + ' second(s). Run your game, encode or build now.')
        Write-Line ''
        Start-Sleep -Seconds $Seconds
        $second = Read-ProcessorCounters
        $n = 0.0
        if ($null -ne $nominal) { $n = [double]$nominal }
        $measured = Measure-Sample -First $first -Second $second -NominalMhz $n
        $rows = @($measured)
        $sampled = $true

        # Prefer the nominal the counters imply over the one WMI advertises;
        # they agree on healthy hardware, and the derived one keeps the rest of
        # the arithmetic self-consistent when they do not.
        $tot = Get-TotalRow $rows
        if ($null -ne $tot -and $null -ne $tot.derivedNominal -and $tot.consistent) {
            $nominal = [double]$tot.derivedNominal
        }
    }
}

$total = Get-TotalRow $rows

Show-Processor $cpu $plan $nominal
if ($sampled) {
    Show-Clock $total $nominal $cpu
    Show-Limit $total $plan
    Show-Cores $rows $nominal ([bool]$Cores)
    Show-Latency $total
} else {
    Write-Dim '  -Info: no timed sample taken, so there is no measured clock speed.'
    Write-Line ''
    Show-Limit $total $plan
    Show-Cores $rows $nominal ([bool]$Cores)
}

$risks = Get-Risks -Rows $rows -Total $total -Plan $plan -Nominal $nominal -Sampled $sampled
Show-Risks $risks

if ($Json) {
    $report = New-Report $cpu $plan $nominal $rows $risks $mode $true $null $Seconds
    $report | ConvertTo-Json -Depth 8
}

exit (Get-ExitCode $risks)
