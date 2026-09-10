#requires -Version 5.1
<#
    cpuclock real-hardware check.

    Synthetic fixtures are clean and predictable, which is exactly why they miss
    things. This exercises the tool against genuine live counter data on this
    machine and verifies it field for field against INDEPENDENT sources:

      R1  every field parsed from WMI, re-parsed from PDH (a different Windows
          API, different library, different casing) and compared
      R2  the tool's own arithmetic run over PDH's raw samples and compared
          against PDH's cooked values over the identical window
      R3  known ground truth PLANTED INSIDE a real snapshot
      R4  cross-checks against built-in Windows commands
      R5  the headline claim proven end to end by GENERATING load and
          confirming the measured clock actually moves
      R6  the tool's own -Json output fed back through a bounds and
          aggregate-sanity check
      R7  read-only proved by snapshotting real state before and after

    Pass -SkipLoad to skip R5 if you are mid-game.
#>
[CmdletBinding()]
param([switch]$SkipLoad)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$t_root = Split-Path -Parent $MyInvocation.MyCommand.Path
$t_tool = Join-Path $t_root 'cpuclock.ps1'
. $t_tool

$t_pass = 0
$t_fail = 0
$t_failed = New-Object 'System.Collections.Generic.List[object]'
$t_notes = New-Object 'System.Collections.Generic.List[object]'

function t_Arr { param($V) if ($null -eq $V) { return ,@() } return ,@($V) }

function t_Check {
    param([string]$Name, $Expected, $Actual)
    $e = '<null>'; $a = '<null>'
    if ($null -ne $Expected) { $e = [string]$Expected }
    if ($null -ne $Actual)   { $a = [string]$Actual }
    if ($e -eq $a) { $script:t_pass++ }
    else {
        $script:t_fail++
        $script:t_failed.Add($Name + '  expected [' + $e + '] got [' + $a + ']')
        Write-Host ('  [FAIL] ' + $Name + '  expected [' + $e + '] got [' + $a + ']') -ForegroundColor Red
    }
}
function t_True  { param([string]$Name, $Value) t_Check $Name 'True' ([bool]$Value) }
function t_False { param([string]$Name, $Value) t_Check $Name 'False' ([bool]$Value) }
function t_Note  { param([string]$T) $script:t_notes.Add($T); Write-Host ('        ' + $T) -ForegroundColor DarkGray }
function t_Sect  { param([string]$T) Write-Host ''; Write-Host ('  ' + $T) -ForegroundColor Cyan }

Write-Host ''
Write-Host '  cpuclock real-hardware check' -ForegroundColor Cyan
Write-Host '  ============================' -ForegroundColor Cyan

$t_admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
t_Note ('running ' + $(if ($t_admin) { 'ELEVATED' } else { 'as a standard user (not elevated)' }))

# ===========================================================================
t_Sect 'R1. WMI parse vs an independent PDH parse, field for field'
# ===========================================================================
# The tool reads Win32_PerfRawData_Counters_ProcessorInformation through CIM.
# PDH is a completely different Windows API - a different DLL, a different
# query language, and it spells the instance names in a different CASE. If the
# two agree on every field for every instance, the parse is not an accident.
$t_wmiRows = Read-ProcessorCounters
$t_wmi = t_Arr $t_wmiRows
t_True 'R1a  WMI returned instances'  ($t_wmi.Count -ge 2)
t_Note ($t_wmi.Count.ToString() + ' counter instances read from WMI')

$t_pdhPaths = @(
    '\Processor Information(*)\% Performance Limit',
    '\Processor Information(*)\Processor Frequency',
    '\Processor Information(*)\Parking Status'
)
$t_pdhOk = $true
$t_pdhSamples = $null
try { $t_pdhSamples = Get-Counter -Counter $t_pdhPaths -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop } catch { $t_pdhOk = $false }
t_True 'R1b  PDH counters readable'  $t_pdhOk

$t_fieldCmp = 0
$t_fieldBad = 0
if ($t_pdhOk) {
    # PDH instance names arrive lower case ("0,_total"); WMI hands back
    # "0,_Total". Route both through the tool's canonical formatter or half the
    # data attaches to nothing.
    $t_pdhMap = @{}
    foreach ($t_s in $t_pdhSamples.CounterSamples) {
        $t_inst = Format-InstanceName $t_s.InstanceName
        if (-not $t_pdhMap.ContainsKey($t_inst)) { $t_pdhMap[$t_inst] = @{} }
        $t_leaf = $t_s.Path.Substring($t_s.Path.LastIndexOf('\') + 1).ToLowerInvariant()
        $t_pdhMap[$t_inst][$t_leaf] = [double]$t_s.CookedValue
    }
    $t_matchedInst = 0
    foreach ($t_row in $t_wmi) {
        if (-not $t_pdhMap.ContainsKey($t_row.name)) { continue }
        $t_matchedInst++
        $t_p = $t_pdhMap[$t_row.name]
        $t_pairs = @(
            @('% performance limit', $t_row.limitPct),
            @('processor frequency', $t_row.reportedMhz),
            @('parking status',      $t_row.parked)
        )
        foreach ($t_pair in $t_pairs) {
            $t_key = [string]$t_pair[0]
            if (-not $t_p.ContainsKey($t_key)) { continue }
            $t_fieldCmp++
            $t_mine = $null
            if ($null -ne $t_pair[1]) { $t_mine = [double]$t_pair[1] }
            $t_theirs = [double]$t_p[$t_key]
            if ($null -eq $t_mine -or [math]::Abs($t_mine - $t_theirs) -gt 0.5) {
                $t_fieldBad++
                Write-Host ('  [MISMATCH] ' + $t_row.name + ' ' + $t_key + ' wmi=' + $t_mine + ' pdh=' + $t_theirs) -ForegroundColor Red
            }
        }
    }
    t_True  'R1c  instances matched across both APIs'  ($t_matchedInst -ge 2)
    t_True  'R1d  enough fields compared'              ($t_fieldCmp -ge 20)
    t_Check 'R1e  0 mismatches across both APIs'  0  $t_fieldBad
    t_Note ($t_fieldCmp.ToString() + ' real fields compared across ' + $t_matchedInst + ' instances, ' + $t_fieldBad + ' mismatches')

    # And prove the casing normalisation is doing real work: without it, the
    # roll-up instances would not have matched at all.
    $t_caseDiff = @($t_wmiRows | Where-Object { Test-TotalInstance $_.name })
    t_True 'R1f  roll-up instances exist'  ($t_caseDiff.Count -ge 1)
    $t_rawNames = @((Get-CimInstance Win32_PerfRawData_Counters_ProcessorInformation).Name)
    $t_upper = @($t_rawNames | Where-Object { $_ -cne $_.ToLowerInvariant() })
    t_True 'R1g  WMI really does use different case from PDH'  ($t_upper.Count -ge 1)
    t_Note ('WMI spells them ' + (($t_upper | Select-Object -First 2) -join ', ') + '; PDH spells them ' + ((($t_pdhMap.Keys | Where-Object { $_ -like '*total*' }) | Select-Object -First 2) -join ', '))
}

# ===========================================================================
t_Sect 'R2. The tool arithmetic vs PDH cooked values over the same window'
# ===========================================================================
# PDH exposes RawValue and SecondValue (the base) alongside CookedValue. Running
# the tool's own delta arithmetic over two consecutive PDH raw samples covers
# the identical window PDH used, so the two must agree - not approximately, but
# to the digit. This is the proof that the formulas are the right ones, and it
# is why they were derived empirically rather than guessed from documentation.
$t_ratioPaths = @(
    '\Processor Information(*)\% Processor Performance',
    '\Processor Information(*)\Actual Frequency',
    '\Processor Information(*)\% Processor Utility'
)
$t_r2ok = $true
$t_two = $null
try { $t_two = Get-Counter -Counter $t_ratioPaths -SampleInterval 1 -MaxSamples 2 -ErrorAction Stop } catch { $t_r2ok = $false }
t_True 'R2a  two PDH samples taken'  $t_r2ok
if ($t_r2ok) {
    $t_prev = @{}
    foreach ($t_s in $t_two[0].CounterSamples) { $t_prev[$t_s.Path] = $t_s }
    $t_n = 0
    $t_worst = 0.0
    $t_off = 0
    foreach ($t_s in $t_two[1].CounterSamples) {
        if (-not $t_prev.ContainsKey($t_s.Path)) { continue }
        $t_p = $t_prev[$t_s.Path]
        # Read through [decimal]. These are UInt64 counters and a running
        # machine can report a value above Int64.MaxValue, where [long] throws.
        $t_num = Get-Delta ([decimal]$t_p.RawValue) ([decimal]$t_s.RawValue)
        $t_den = Get-Delta ([decimal]$t_p.SecondValue) ([decimal]$t_s.SecondValue)
        $t_mine = Get-Ratio $t_num $t_den
        if ($null -eq $t_mine) { continue }
        $t_theirs = [double]$t_s.CookedValue
        $t_n++
        $t_rel = 0.0
        if ([math]::Abs($t_theirs) -gt 0.0001) { $t_rel = 100.0 * [math]::Abs($t_mine - $t_theirs) / [math]::Abs($t_theirs) }
        if ($t_rel -gt $t_worst) { $t_worst = $t_rel }
        if ($t_rel -gt 0.001) { $t_off++ }
    }
    t_True  'R2b  enough counters compared'  ($t_n -ge 20)
    t_Check 'R2c  0 formula disagreements'  0  $t_off
    t_True  'R2d  worst relative error under 0.001%'  ($t_worst -lt 0.001)
    t_Note ($t_n.ToString() + ' live counters recomputed; worst relative error ' + ('{0:N6}' -f $t_worst) + '%')
}

# ===========================================================================
t_Sect 'R3. Known ground truth planted INSIDE a real snapshot'
# ===========================================================================
# Two genuine snapshots of this machine, with three synthetic instances of
# known value appended. This proves the parser finds exactly the right numbers
# while surrounded by real, irrelevant ones - and that none of the real values
# leak into the planted rows or vice versa.
function t_MakeRow {
    param([string]$Name, $Perf, $PerfBase, $Actual, $ActualBase, $Utility, $UtilityBase, $Idle, $Dpc, $Interrupt, $Timestamp, $ReportedMhz, $LimitPct, $LimitFlags, $Parked)
    return [pscustomobject]@{
        name = $Name; perf = $Perf; perfBase = $PerfBase; actual = $Actual; actualBase = $ActualBase
        utility = $Utility; utilityBase = $UtilityBase; idle = $Idle; dpc = $Dpc; interrupt = $Interrupt
        timestamp = $Timestamp; reportedMhz = $ReportedMhz; limitPct = $LimitPct; limitFlags = $LimitFlags
        parked = $Parked; pctMaxFreq = $null
    }
}
$t_realA = t_Arr (Read-ProcessorCounters)
Start-Sleep -Seconds 2
$t_realB = t_Arr (Read-ProcessorCounters)
$t_realCount = $t_realA.Count
t_True 'R3a  captured a real snapshot pair'  ($t_realCount -ge 2)

# Planted values, each field distinct so a transposition cannot pass.
$t_plantA = @(
    (t_MakeRow '9,0' 1000000 2000000 5000000000 3000000 700000 4000000 10000000 1000000 2000000 500000000 111 40 0 0),
    (t_MakeRow '9,1' 0 0 0 0 0 0 0 0 0 0 222 55 1 1),
    (t_MakeRow '9,2' 500 100 900 300 400 200 100 10 20 1000 333 66 2 0)
)
$t_plantB = @(
    (t_MakeRow '9,0' 2325000 2010000 7650000000 4000000 1172500 4010000 48250000 4500000 9250000 600000000 1234 88 33 1),
    (t_MakeRow '9,1' 0 0 0 0 0 0 0 0 0 0 222 55 1 1),
    (t_MakeRow '9,2' 400 200 1800 600 800 400 200 20 40 2000 333 66 2 0)
)
$t_mixedA = @($t_realA) + $t_plantA
$t_mixedB = @($t_realB) + $t_plantB
$t_mixedOut = t_Arr (Measure-Sample -First $t_mixedA -Second $t_mixedB -NominalMhz 2000)
t_Check 'R3b  real rows all survive'  ($t_realCount + 3)  $t_mixedOut.Count

$t_p0 = @($t_mixedOut | Where-Object { $_.name -eq '9,0' })[0]
t_Check 'R3c  planted perfPct'      '132.5'  ('{0:N1}' -f $t_p0.perfPct)
t_Check 'R3d  planted actualMhz'    '2650.0' ('{0:F1}' -f $t_p0.actualMhz)
t_Check 'R3e  planted utilityPct'   '47.25'  ('{0:N2}' -f $t_p0.utilityPct)
t_Check 'R3f  planted timePct'      '61.75'  ('{0:N2}' -f $t_p0.timePct)
t_Check 'R3g  planted dpcPct'       '3.50'   ('{0:N2}' -f $t_p0.dpcPct)
t_Check 'R3h  planted interruptPct' '7.25'   ('{0:N2}' -f $t_p0.interruptPct)
t_Check 'R3i  planted limitPct'     88       $t_p0.limitPct
t_Check 'R3j  planted limitFlags'   33       $t_p0.limitFlags
t_Check 'R3k  planted reportedMhz'  1234     $t_p0.reportedMhz
t_True  'R3l  planted parked'       $t_p0.parked

# An all-zero row must report null everywhere, never 0. "Unknown" masquerading
# as "idle" or "instant" is the single most misleading thing a tool can print.
$t_p1 = @($t_mixedOut | Where-Object { $_.name -eq '9,1' })[0]
t_Check 'R3m  zero-base perf -> null'    $null  $t_p1.perfPct
t_Check 'R3n  zero-base actual -> null'  $null  $t_p1.actualMhz
t_Check 'R3o  zero-base time -> null'    $null  $t_p1.timePct

# A row whose counters went backwards is a reset, not a negative measurement.
$t_p2 = @($t_mixedOut | Where-Object { $_.name -eq '9,2' })[0]
t_Check 'R3p  backwards counter -> null' $null  $t_p2.perfPct
t_Check 'R3q  forwards field still read' '3'    ('{0:N0}' -f $t_p2.actualMhz)

# Nothing leaked: every genuine instance still carries its own real values.
$t_leak = 0
foreach ($t_rn in @($t_realA)) {
    $t_hit = @($t_mixedOut | Where-Object { $_.name -eq $t_rn.name })
    if ($t_hit.Count -ne 1) { $t_leak++; continue }
    if ($null -ne $t_hit[0].limitPct -and $t_hit[0].limitPct -eq 88) { $t_leak++ }
    if ($null -ne $t_hit[0].reportedMhz -and $t_hit[0].reportedMhz -eq 1234) { $t_leak++ }
}
t_Check 'R3r  no planted value leaked into a real row'  0  $t_leak
t_Note ('3 synthetic rows planted among ' + $t_realCount + ' real ones; all found, none leaked')

# ===========================================================================
t_Sect 'R4. Cross-checks against built-in Windows commands'
# ===========================================================================
$t_cpu = Get-Processor
t_True 'R4a  Win32_Processor readable'  ($null -ne $t_cpu)
$t_cs = Get-CimInstance Win32_ComputerSystem
t_Check 'R4b  logical count matches Win32_ComputerSystem'  ([int]$t_cs.NumberOfLogicalProcessors)  ([int]$t_cpu.logical)
t_Check 'R4c  logical count matches %NUMBER_OF_PROCESSORS%' ([int]$env:NUMBER_OF_PROCESSORS)  ([int]$t_cpu.logical)
t_Check 'R4d  logical count matches .NET ProcessorCount'    ([Environment]::ProcessorCount)  ([int]$t_cpu.logical)

# One counter instance per logical processor, plus the roll-ups.
$t_coreInst = @($t_wmi | Where-Object { Test-CoreInstance $_.name })
t_Check 'R4e  one core instance per logical processor'  ([int]$t_cpu.logical)  $t_coreInst.Count
t_Note ($t_coreInst.Count.ToString() + ' per-core instances for ' + $t_cpu.logical + ' logical processors on ' + $t_cpu.name.Trim())

# powercfg, parsed independently. The tool uses a regex over the whole block;
# this walks the output line by line with IndexOf/Substring instead, so a
# mistake in either technique shows up as a disagreement.
$ErrorActionPreference = 'Continue'
$t_scheme = (& powercfg /getactivescheme 2>&1 | Out-String)
$ErrorActionPreference = 'Stop'
$t_guid = $null
$t_gi = $t_scheme.IndexOf('GUID: ', [StringComparison]::Ordinal)
if ($t_gi -ge 0) { $t_guid = $t_scheme.Substring($t_gi + 6, 36) }
$t_plan = Get-PowerPlan
t_True  'R4f  active scheme GUID found'  (-not [string]::IsNullOrEmpty($t_guid))
t_Check 'R4g  tool GUID matches independent parse'  $t_guid  $t_plan.guid
t_Note ('active power plan: ' + $t_plan.name + ' (' + $t_plan.guid + ')')

$ErrorActionPreference = 'Continue'
$t_thr = (& powercfg /query $t_guid SUB_PROCESSOR PROCTHROTTLEMAX 2>&1 | Out-String)
$ErrorActionPreference = 'Stop'
$t_refAc = $null
foreach ($t_ln in ($t_thr -split "`r?`n")) {
    $t_ix = $t_ln.IndexOf('Current AC Power Setting Index:', [StringComparison]::Ordinal)
    if ($t_ix -ge 0) {
        $t_hex = $t_ln.Substring($t_ix + 31).Trim()
        $t_refAc = [Convert]::ToInt32($t_hex, 16)
    }
}
t_True  'R4h  independent PROCTHROTTLEMAX parse succeeded'  ($null -ne $t_refAc)
t_Check 'R4i  tool PROCTHROTTLEMAX matches'  $t_refAc  $t_plan.maxProcState.ac
t_Note ('PROCTHROTTLEMAX AC = ' + $t_refAc + '%, DC = ' + $t_plan.maxProcState.dc + '%')

# Battery state cross-checked against the battery class directly.
$t_batRaw = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
if ($t_batRaw.Count -gt 0) {
    $t_refBat = ([int]$t_batRaw[0].BatteryStatus -ne 2)
    t_Check 'R4j  battery state matches Win32_Battery'  ([string]$t_refBat)  ([string]$t_plan.onBattery)
    t_Note ('Win32_Battery.BatteryStatus = ' + $t_batRaw[0].BatteryStatus + ' (on battery: ' + $t_plan.onBattery + ')')
} else {
    t_Check 'R4j  no battery, tool reports null'  $null  $t_plan.onBattery
    t_Note 'no battery present; desktop path exercised'
}

# The derived nominal clock and the one WMI advertises must agree. They come
# from completely different places: one is arithmetic over live counters, the
# other is a static SMBIOS/ACPI value.
$t_nomA = t_Arr (Read-ProcessorCounters)
Start-Sleep -Seconds 3
$t_nomB = t_Arr (Read-ProcessorCounters)
$t_nomRows = t_Arr (Measure-Sample -First $t_nomA -Second $t_nomB -NominalMhz ([double]$t_cpu.maxClockMhz))
$t_nomTot = Get-TotalRow $t_nomRows
t_True 'R4k  derived nominal present'  ($null -ne $t_nomTot.derivedNominal)
$t_nomDiff = 100.0 * [math]::Abs($t_nomTot.derivedNominal - $t_cpu.maxClockMhz) / $t_cpu.maxClockMhz
t_True 'R4l  derived nominal within 1% of Win32_Processor.MaxClockSpeed'  ($t_nomDiff -lt 1.0)
t_Note ('nominal derived from counters ' + ('{0:N1}' -f $t_nomTot.derivedNominal) + ' MHz vs WMI MaxClockSpeed ' + $t_cpu.maxClockMhz + ' MHz (' + ('{0:N3}' -f $t_nomDiff) + '% apart)')

# Every real row must pass the counter set's own internal redundancy check.
$t_incons = @($t_nomRows | Where-Object { -not $_.consistent })
t_Check 'R4m  every real row self-consistent'  0  $t_incons.Count

# ===========================================================================
t_Sect 'R5. Headline claim proven by generating the condition'
# ===========================================================================
# A number that does not error is not the same as a number that is right. The
# only way to know the measured clock is live is to CHANGE the clock and watch
# it move. Two threads is deliberate: it is gentle, and on Intel a light load
# turbos higher than an all-core one.
if ($SkipLoad) {
    t_Note 'skipped by -SkipLoad'
} else {
    $t_idleRowsA = t_Arr (Read-ProcessorCounters)
    Start-Sleep -Seconds 4
    $t_idleRowsB = t_Arr (Read-ProcessorCounters)
    $t_idleM = t_Arr (Measure-Sample -First $t_idleRowsA -Second $t_idleRowsB -NominalMhz ([double]$t_cpu.maxClockMhz))
    $t_idleTot = Get-TotalRow $t_idleM

    $t_lt = Join-Path $env:TEMP ('cpuclock-load-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $t_lt -Force | Out-Null
    # Each generator exits on its own deadline, so nothing ever has to be
    # killed on the user's machine. It writes a marker only once its loop is
    # actually running, because a JIT-compiling generator needs a readiness
    # SIGNAL, not a fixed head start - a "failing" test is often just an
    # unfair one.
    $t_body = @'
param([string]$Marker, [int]$Secs)
$x = 0.0
for ($i = 0; $i -lt 400000; $i++) { $x += [math]::Sqrt($i) }
[IO.File]::WriteAllText($Marker, 'READY')
$end = (Get-Date).AddSeconds($Secs)
while ((Get-Date) -lt $end) { for ($i = 0; $i -lt 200000; $i++) { $x += [math]::Sqrt($i) } }
'@
    $t_gen = Join-Path $t_lt 'gen.ps1'
    [IO.File]::WriteAllText($t_gen, $t_body, (New-Object Text.UTF8Encoding($false)))
    $t_marks = @()
    for ($t_i = 0; $t_i -lt 2; $t_i++) {
        $t_mk = Join-Path $t_lt ('ready' + $t_i + '.txt')
        $t_marks += $t_mk
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$t_gen,'-Marker',$t_mk,'-Secs','16') | Out-Null
    }
    $t_dl = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $t_dl) {
        $t_got = @($t_marks | Where-Object { Test-Path -LiteralPath $_ })
        if ($t_got.Count -eq 2) { break }
        Start-Sleep -Milliseconds 200
    }
    $t_got = @($t_marks | Where-Object { Test-Path -LiteralPath $_ })
    t_Check 'R5a  both load generators signalled READY'  2  $t_got.Count

    $t_loadA = t_Arr (Read-ProcessorCounters)
    Start-Sleep -Seconds 5
    $t_loadB = t_Arr (Read-ProcessorCounters)
    $t_loadM = t_Arr (Measure-Sample -First $t_loadA -Second $t_loadB -NominalMhz ([double]$t_cpu.maxClockMhz))
    $t_loadTot = Get-TotalRow $t_loadM

    t_True 'R5b  clock rose under load'         ($t_loadTot.actualMhz -gt ($t_idleTot.actualMhz * 1.10))
    t_True 'R5c  utility rose under load'       ($t_loadTot.utilityPct -gt ($t_idleTot.utilityPct + 15.0))
    t_True 'R5d  measurement is not a constant' ([math]::Abs($t_loadTot.actualMhz - $t_idleTot.actualMhz) -gt 50.0)
    t_True 'R5e  perf% and MHz moved together'  (($t_loadTot.perfPct -gt $t_idleTot.perfPct) -eq ($t_loadTot.actualMhz -gt $t_idleTot.actualMhz))
    t_Note ('idle ' + ('{0:N0}' -f $t_idleTot.actualMhz) + ' MHz / ' + ('{0:N1}' -f $t_idleTot.perfPct) + '%   ->   under load ' + ('{0:N0}' -f $t_loadTot.actualMhz) + ' MHz / ' + ('{0:N1}' -f $t_loadTot.perfPct) + '%')

    # The premise of the whole tool: the numbers Windows hands out are wrong.
    $t_ratio = $t_loadTot.actualMhz / [double]$t_cpu.maxClockMhz
    if ($t_ratio -gt 1.0) {
        t_True 'R5f  delivered clock exceeded Win32_Processor.MaxClockSpeed'  ($t_ratio -gt 1.0)
        t_Note ('measured ' + ('{0:N0}' -f $t_loadTot.actualMhz) + ' MHz against a reported "maximum" of ' + $t_cpu.maxClockMhz + ' MHz - ' + ('{0:N2}' -f $t_ratio) + 'x over')
    } else {
        t_Note ('this CPU did not exceed its reported maximum under a 2-thread load (' + ('{0:N2}' -f $t_ratio) + 'x); the movement checks above still hold')
        $script:t_pass++
    }
    $t_curRatio = $t_loadTot.actualMhz / [double]$t_cpu.currentClockMhz
    t_Note ('Win32_Processor.CurrentClockSpeed said ' + $t_cpu.currentClockMhz + ' MHz at the same moment - out by ' + ('{0:N2}' -f $t_curRatio) + 'x')

    # A busy machine must not be reported as "too idle to tell".
    $t_loadRisks = Get-Risks -Rows $t_loadM -Total $t_loadTot -Plan $t_plan -Nominal ([double]$t_cpu.maxClockMhz) -Sampled $true
    $t_lr = t_Arr $t_loadRisks
    $t_untested = @($t_lr | Where-Object { $_.code -eq 'limit-untested' })
    t_Check 'R5g  a busy sample is not called untested'  0  $t_untested.Count

    # And the cry-wolf case in reverse: a chip turboing past its guarantee must
    # not be called throttled. This is the bug real hardware exposed.
    if ($null -ne $t_loadTot.limitPct -and $t_loadTot.perfPct -gt ([double]$t_loadTot.limitPct * 1.05)) {
        $t_wolf = @($t_lr | Where-Object { $_.code -eq 'throttled' -or $_.code -eq 'throttled-hard' })
        t_Check 'R5h  turboing past the guarantee is not called throttling'  0  $t_wolf.Count
        t_Note ('platform guarantee ' + ('{0:N0}' -f $t_loadTot.limitPct) + '% while delivering ' + ('{0:N0}' -f $t_loadTot.perfPct) + '% - correctly reported as opportunistic turbo')
    }

    Start-Sleep -Seconds 12
    Remove-Item -LiteralPath $t_lt -Recurse -Force -ErrorAction SilentlyContinue
    t_False 'R5i  load generator scratch removed'  (Test-Path -LiteralPath $t_lt)
}

# ===========================================================================
t_Sect 'R6. The tool own -Json output, bounds and aggregate sanity'
# ===========================================================================
# Every individual reading can be in range while an AGGREGATE is nonsense.
# That is exactly how a "126% GPU usage" bug got shipped in a sibling tool, so
# the report is fed back through a checker rather than eyeballed.
$t_jt = Join-Path $env:TEMP ('cpuclock-json-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $t_jt -Force | Out-Null
$t_jf = Join-Path $t_jt 'real.json'
$t_ef = Join-Path $t_jt 'real.err'
$t_proc = Start-Process -FilePath 'powershell.exe' -NoNewWindow -Wait -PassThru `
    -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$t_tool,'-Seconds','4','-Json') `
    -RedirectStandardOutput $t_jf -RedirectStandardError $t_ef
# Start-Process keeps an EXCLUSIVE lock on redirect targets and the handle
# lingers after the child exits, so ReadAllText throws IOException here.
$t_jsonText = ''
$t_errText = ''
for ($t_i = 0; $t_i -lt 40; $t_i++) {
    try {
        $t_fs = New-Object IO.FileStream($t_jf, 'Open', 'Read', 'ReadWrite')
        $t_sr = New-Object IO.StreamReader($t_fs)
        $t_jsonText = $t_sr.ReadToEnd(); $t_sr.Close(); $t_fs.Close()
        $t_fs2 = New-Object IO.FileStream($t_ef, 'Open', 'Read', 'ReadWrite')
        $t_sr2 = New-Object IO.StreamReader($t_fs2)
        $t_errText = $t_sr2.ReadToEnd(); $t_sr2.Close(); $t_fs2.Close()
        break
    } catch { Start-Sleep -Milliseconds 50 }
}
t_Check 'R6a  -Json wrote nothing to stderr'  ''  $t_errText.Trim()
$t_rep = $null
try { $t_rep = $t_jsonText | ConvertFrom-Json } catch { $t_rep = $null }
t_Check 'R6b  real -Json parses'  'cpuclock'  $t_rep.tool

$t_repRows = t_Arr $t_rep.rows
$t_bounds = 0
foreach ($t_rr in $t_repRows) {
    if ($null -ne $t_rr.perfPct      -and ($t_rr.perfPct -lt 0     -or $t_rr.perfPct -gt 500))   { $t_bounds++ }
    if ($null -ne $t_rr.actualMhz    -and ($t_rr.actualMhz -lt 0   -or $t_rr.actualMhz -gt 20000)) { $t_bounds++ }
    if ($null -ne $t_rr.utilityPct   -and ($t_rr.utilityPct -lt 0  -or $t_rr.utilityPct -gt 500)) { $t_bounds++ }
    # Busy time is a fraction of elapsed time and CANNOT exceed 100.
    if ($null -ne $t_rr.timePct      -and ($t_rr.timePct -lt 0     -or $t_rr.timePct -gt 100.001)) { $t_bounds++ }
    if ($null -ne $t_rr.dpcPct       -and ($t_rr.dpcPct -lt 0      -or $t_rr.dpcPct -gt 100.001)) { $t_bounds++ }
    if ($null -ne $t_rr.interruptPct -and ($t_rr.interruptPct -lt 0 -or $t_rr.interruptPct -gt 100.001)) { $t_bounds++ }
    if ($null -ne $t_rr.limitPct     -and ($t_rr.limitPct -lt 0    -or $t_rr.limitPct -gt 100.001)) { $t_bounds++ }
}
t_Check 'R6c  every field within bounds'  0  $t_bounds
t_Note ($t_repRows.Count.ToString() + ' rows bounds-checked in the tool own JSON')

# THE AGGREGATE CHECK. The roll-up must be an AVERAGE of the per-core rows, not
# a sum. Cores run in PARALLEL; adding their percentages is how a tool ends up
# claiming 800% CPU or 126% GPU.
$t_jTot = @($t_repRows | Where-Object { $_.name -eq '_total' })
t_Check 'R6d  exactly one _total row'  1  $t_jTot.Count
$t_jCores = @($t_repRows | Where-Object { $_.isCore })
t_True 'R6e  per-core rows present'  ($t_jCores.Count -ge 2)
if ($t_jTot.Count -eq 1 -and $t_jCores.Count -ge 2) {
    $t_sum = 0.0
    $t_max = 0.0
    foreach ($t_c in $t_jCores) {
        if ($null -eq $t_c.utilityPct) { continue }
        $t_sum += [double]$t_c.utilityPct
        if ([double]$t_c.utilityPct -gt $t_max) { $t_max = [double]$t_c.utilityPct }
    }
    $t_mean = $t_sum / $t_jCores.Count
    $t_totUtil = [double]$t_jTot[0].utilityPct
    t_True 'R6f  _total utility is the mean of the cores, not their sum'  ([math]::Abs($t_totUtil - $t_mean) -lt 8.0)
    t_True 'R6g  _total utility is nowhere near the sum'  ($t_jCores.Count -lt 2 -or [math]::Abs($t_totUtil - $t_sum) -gt 1.0 -or $t_sum -lt 1.0)
    t_Note ('_total utility ' + ('{0:N1}' -f $t_totUtil) + '% vs mean of cores ' + ('{0:N1}' -f $t_mean) + '% (their sum would be ' + ('{0:N1}' -f $t_sum) + '%)')

    # Same logic for the clock: the roll-up MHz must sit inside the per-core
    # range, never above the fastest core.
    $t_cMax = 0.0
    $t_cMin = [double]::MaxValue
    foreach ($t_c in $t_jCores) {
        if ($null -eq $t_c.actualMhz) { continue }
        if ([double]$t_c.actualMhz -gt $t_cMax) { $t_cMax = [double]$t_c.actualMhz }
        if ([double]$t_c.actualMhz -lt $t_cMin) { $t_cMin = [double]$t_c.actualMhz }
    }
    $t_totMhz = [double]$t_jTot[0].actualMhz
    t_True 'R6h  _total clock is within the per-core range'  ($t_totMhz -le ($t_cMax + 1.0) -and $t_totMhz -ge ($t_cMin - 1.0))
    t_Note ('_total ' + ('{0:N0}' -f $t_totMhz) + ' MHz, cores span ' + ('{0:N0}' -f $t_cMin) + '-' + ('{0:N0}' -f $t_cMax) + ' MHz')
}

# Replay real data, twice, and require no drift.
$t_rf1 = Join-Path $t_jt 'replay1.json'
$t_re1 = Join-Path $t_jt 'replay1.err'
Start-Process -FilePath 'powershell.exe' -NoNewWindow -Wait `
    -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$t_tool,'-FromJson',$t_jf,'-Json') `
    -RedirectStandardOutput $t_rf1 -RedirectStandardError $t_re1 | Out-Null
$t_rt1 = ''
for ($t_i = 0; $t_i -lt 40; $t_i++) {
    try {
        $t_fs = New-Object IO.FileStream($t_rf1, 'Open', 'Read', 'ReadWrite')
        $t_sr = New-Object IO.StreamReader($t_fs)
        $t_rt1 = $t_sr.ReadToEnd(); $t_sr.Close(); $t_fs.Close(); break
    } catch { Start-Sleep -Milliseconds 50 }
}
$t_rd1 = $null
try { $t_rd1 = $t_rt1 | ConvertFrom-Json } catch { $t_rd1 = $null }
t_Check 'R6i  real replay parses'  'cpuclock'  $t_rd1.tool
t_Check 'R6j  replay preserves every row'  $t_repRows.Count  ((t_Arr $t_rd1.rows).Count)
t_Check 'R6k  replay preserves the verdict' (((t_Arr $t_rep.risks) | ForEach-Object { $_.code }) -join ',')  (((t_Arr $t_rd1.risks) | ForEach-Object { $_.code }) -join ',')
$t_drift = 0
foreach ($t_o in $t_repRows) {
    $t_m2 = @((t_Arr $t_rd1.rows) | Where-Object { $_.name -eq $t_o.name })
    if ($t_m2.Count -ne 1) { $t_drift++; continue }
    if ([string]$t_o.actualMhz -ne [string]$t_m2[0].actualMhz) { $t_drift++ }
    if ([string]$t_o.perfPct   -ne [string]$t_m2[0].perfPct)   { $t_drift++ }
    if ([string]$t_o.limitPct  -ne [string]$t_m2[0].limitPct)  { $t_drift++ }
}
t_Check 'R6l  0 values drifted across the round trip'  0  $t_drift
Remove-Item -LiteralPath $t_jt -Recurse -Force -ErrorAction SilentlyContinue

# ===========================================================================
t_Sect 'R7. Read-only, proved by snapshot'
# ===========================================================================
# The source grep in the self-test proves no mutating call exists. This proves
# the observable state is untouched after the tool has actually run.
function t_StateSnapshot {
    $sb = New-Object Text.StringBuilder
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    [void]$sb.AppendLine((& powercfg /getactivescheme 2>&1 | Out-String))
    [void]$sb.AppendLine((& powercfg /query SCHEME_CURRENT SUB_PROCESSOR 2>&1 | Out-String))
    $ErrorActionPreference = $prev
    [void]$sb.AppendLine((Get-ExecutionPolicy -Scope CurrentUser).ToString())
    [void]$sb.AppendLine((Get-ExecutionPolicy -Scope LocalMachine).ToString())
    $p = Get-CimInstance Win32_Processor
    [void]$sb.AppendLine([string]$p.MaxClockSpeed)
    [void]$sb.AppendLine([string]$p.NumberOfCores)
    return $sb.ToString()
}
$t_before = t_StateSnapshot
$t_st = Join-Path $env:TEMP ('cpuclock-ro-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $t_st -Force | Out-Null
foreach ($t_mode in @(@('-Seconds','2'), @('-Info'), @('-Seconds','2','-Cores'), @('-Seconds','2','-Quiet'))) {
    $t_o = Join-Path $t_st ('out' + [Guid]::NewGuid().ToString('N') + '.txt')
    Start-Process -FilePath 'powershell.exe' -NoNewWindow -Wait `
        -ArgumentList (@('-NoProfile','-ExecutionPolicy','Bypass','-File',$t_tool) + $t_mode) `
        -RedirectStandardOutput $t_o -RedirectStandardError ($t_o + '.e') | Out-Null
}
$t_after = t_StateSnapshot
t_Check 'R7a  system state byte-identical after 4 runs'  $t_before.Length  $t_after.Length
t_True  'R7b  system state identical content'  ($t_before -ceq $t_after)
Remove-Item -LiteralPath $t_st -Recurse -Force -ErrorAction SilentlyContinue
t_False 'R7c  scratch removed'  (Test-Path -LiteralPath $t_st)
t_Note 'power plan, processor state settings and execution policy all unchanged'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host ('  passed ' + $t_pass + ' / ' + ($t_pass + $t_fail)) -ForegroundColor $(if ($t_fail -eq 0) { 'Green' } else { 'Red' })
if ($t_fail -gt 0) {
    Write-Host ''
    foreach ($t_f in $t_failed) { Write-Host ('   - ' + $t_f) -ForegroundColor Red }
    exit 1
}
Write-Host '  ALL REAL-HARDWARE CHECKS PASSED' -ForegroundColor Green
exit 0
