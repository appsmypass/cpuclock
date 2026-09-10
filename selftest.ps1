#requires -Version 5.1
<#
    cpuclock self-test - synthetic ground truth.

    Every field is planted with a DIFFERENT distinctive value, so a tool that
    swaps two of them cannot pass. Boundaries are tested on both sides. A
    healthy machine must produce zero risks, so the tool cannot cry wolf.

    NOTE ON VARIABLE NAMES: this file dot-sources cpuclock.ps1 to get at its
    functions, and dot-sourcing imports the script's param() TYPE CONSTRAINTS
    into this scope. Assigning an array to a local $Json here would throw
    "Cannot convert System.Object[] to SwitchParameter" and blame this file.
    Every local is therefore prefixed t_ and never reuses a tool parameter name.
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$t_root = Split-Path -Parent $MyInvocation.MyCommand.Path
$t_tool = Join-Path $t_root 'cpuclock.ps1'
. $t_tool

$t_pass = 0
$t_fail = 0
$t_failed = New-Object 'System.Collections.Generic.List[object]'

function t_Check {
    param([string]$Name, $Expected, $Actual)
    $e = '<null>'
    $a = '<null>'
    if ($null -ne $Expected) { $e = [string]$Expected }
    if ($null -ne $Actual)   { $a = [string]$Actual }
    if ($e -eq $a) {
        $script:t_pass++
    } else {
        $script:t_fail++
        $script:t_failed.Add($Name + '  expected [' + $e + '] got [' + $a + ']')
        Write-Host ('  [FAIL] ' + $Name + '  expected [' + $e + '] got [' + $a + ']') -ForegroundColor Red
    }
}

function t_Near {
    param([string]$Name, [double]$Expected, $Actual, [double]$Tol = 0.0000001)
    if ($null -eq $Actual) {
        $script:t_fail++
        $script:t_failed.Add($Name + '  expected ' + $Expected + ' got <null>')
        Write-Host ('  [FAIL] ' + $Name + '  expected ' + $Expected + ' got <null>') -ForegroundColor Red
        return
    }
    $d = [math]::Abs([double]$Actual - $Expected)
    if ($d -le $Tol) {
        $script:t_pass++
    } else {
        $script:t_fail++
        $script:t_failed.Add($Name + '  expected ' + $Expected + ' got ' + $Actual)
        Write-Host ('  [FAIL] ' + $Name + '  expected ' + $Expected + ' got ' + $Actual) -ForegroundColor Red
    }
}

function t_True {
    param([string]$Name, $Value)
    t_Check $Name 'True' ([bool]$Value)
}

function t_False {
    param([string]$Name, $Value)
    t_Check $Name 'False' ([bool]$Value)
}

function t_Section { param([string]$T) Write-Host ''; Write-Host ('  ' + $T) -ForegroundColor Cyan }

# A function ending "return ,$list.ToArray()" emits the array as ONE pipeline
# object, so @(f()) is a 1-element array CONTAINING the real one - which invents
# a phantom record with every field blank. Passing the call as an ARGUMENT binds
# the array itself, so this helper is safe where @(f()) is not.
#
# The unary comma below is load bearing for the same reason in reverse: a plain
# "return @($V)" would UNROLL the array back into the pipeline and hand a single
# object to the caller, whose .Count then does not exist under StrictMode.
function t_Arr {
    param($V)
    if ($null -eq $V) { return ,@() }
    return ,@($V)
}

# ---------------------------------------------------------------------------
# Row builder matching Read-ProcessorCounters' output shape exactly.
# ---------------------------------------------------------------------------
function t_Row {
    param(
        [string]$Name,
        $Perf = $null, $PerfBase = $null,
        $Actual = $null, $ActualBase = $null,
        $Utility = $null, $UtilityBase = $null,
        $Idle = $null, $Dpc = $null, $Interrupt = $null, $Timestamp = $null,
        $ReportedMhz = $null, $LimitPct = $null, $LimitFlags = $null,
        $Parked = $null, $PctMaxFreq = $null
    )
    return [pscustomobject]@{
        name = $Name
        perf = $Perf; perfBase = $PerfBase
        actual = $Actual; actualBase = $ActualBase
        utility = $Utility; utilityBase = $UtilityBase
        idle = $Idle; dpc = $Dpc; interrupt = $Interrupt; timestamp = $Timestamp
        reportedMhz = $ReportedMhz; limitPct = $LimitPct; limitFlags = $LimitFlags
        parked = $Parked; pctMaxFreq = $PctMaxFreq
    }
}

Write-Host ''
Write-Host '  cpuclock self-test' -ForegroundColor Cyan
Write-Host '  ==================' -ForegroundColor Cyan

# ===========================================================================
t_Section 'A. Delta arithmetic against hand-computed ground truth'
# ===========================================================================
# Nominal 2000 MHz. Every field carries its own distinctive value:
#   perfPct 132.5   actualMhz 2650   utilityPct 47.25   timePct 61.75
#   dpcPct 3.5      interruptPct 7.25   limitPct 88   flags 0x21
#   reportedMhz 1234   parked 1
# No two are equal, so transposing any pair fails a test.
$t_a1 = @(
    (t_Row -Name '_Total' -Perf 1000000 -PerfBase 2000000 -Actual 5000000000 -ActualBase 3000000 `
           -Utility 700000 -UtilityBase 4000000 -Idle 10000000 -Dpc 1000000 -Interrupt 2000000 `
           -Timestamp 500000000 -ReportedMhz 999 -LimitPct 50 -LimitFlags 0 -Parked 0)
)
$t_a2 = @(
    (t_Row -Name '_Total' -Perf 2325000 -PerfBase 2010000 -Actual 7650000000 -ActualBase 4000000 `
           -Utility 1172500 -UtilityBase 4010000 -Idle 48250000 -Dpc 4500000 -Interrupt 9250000 `
           -Timestamp 600000000 -ReportedMhz 1234 -LimitPct 88 -LimitFlags 33 -Parked 1)
)
# deltas: perf 1325000 / base 10000              = 132.5%
#         actual 2650000000 / base 1000000       = 2650 MHz
#         utility 472500 / base 10000            = 47.25%
#         idle 38250000 / time 100000000         => 61.75% busy
#         dpc 3500000 / time 100000000           = 3.5%
#         intr 7250000 / time 100000000          = 7.25%
$t_m = Measure-Sample -First $t_a1 -Second $t_a2 -NominalMhz 2000
$t_rows = @($t_m)
t_Check 'A0  one row produced'            1        $t_rows.Count
$t_r = $t_rows[0]
t_Near  'A1  perfPct = 132.5'             132.5    $t_r.perfPct
t_Near  'A2  actualMhz = 2650'            2650     $t_r.actualMhz
t_Near  'A3  utilityPct = 47.25'          47.25    $t_r.utilityPct
t_Near  'A4  timePct = 61.75'             61.75    $t_r.timePct
t_Near  'A5  dpcPct = 3.5'                3.5      $t_r.dpcPct
t_Near  'A6  interruptPct = 7.25'         7.25     $t_r.interruptPct
t_Check 'A7  limitPct from 2nd sample'    88       $t_r.limitPct
t_Check 'A8  limitFlags from 2nd sample'  33       $t_r.limitFlags
t_Check 'A9  reportedMhz from 2nd sample' 1234     $t_r.reportedMhz
t_True  'A10 parked'                      $t_r.parked
t_Near  'A11 derivedNominal = 2000'       2000     $t_r.derivedNominal
t_True  'A12 consistent vs nominal 2000'  $t_r.consistent
t_True  'A13 turbo above 100 not clamped' ($t_r.perfPct -gt 100)
t_True  'A14 _Total flagged as total'     $t_r.isTotal
t_False 'A15 _Total is not a core'        $t_r.isCore

# Inconsistent nominal must be refused, not reported.
$t_m2 = Measure-Sample -First $t_a1 -Second $t_a2 -NominalMhz 1500
$t_rows2 = @($t_m2)
t_False 'A16 inconsistent nominal refused' $t_rows2[0].consistent

# Within 1% is still accepted.
$t_m3 = Measure-Sample -First $t_a1 -Second $t_a2 -NominalMhz 2010
t_True  'A17 nominal within 1% accepted'  ((t_Arr $t_m3)[0].consistent)

# UInt64 values ABOVE Int64.MaxValue (9223372036854775807). A [long] cast
# throws here; [decimal] represents every UInt64 exactly.
$t_big1 = @((t_Row -Name '0,0' -Perf 9223372036854775000 -PerfBase 9223372036854775000 `
                   -Actual 9223372036854775000 -ActualBase 9223372036854775000 -Timestamp 1000))
$t_big2 = @((t_Row -Name '0,0' -Perf 9223372036854785000 -PerfBase 9223372036854780000 `
                   -Actual 9223372036854795000 -ActualBase 9223372036854780000 -Timestamp 2000))
$t_bigm = t_Arr (Measure-Sample -First $t_big1 -Second $t_big2 -NominalMhz 0)
t_Near  'A18 UInt64 > Int64.MaxValue perf'   2     $t_bigm[0].perfPct
t_Near  'A19 UInt64 > Int64.MaxValue actual' 4     $t_bigm[0].actualMhz

# A counter that went backwards is a reset, not a negative measurement.
# It must become null. Reporting 0 would make "unknown" look like "idle".
$t_back = t_Arr (Measure-Sample -First (@((t_Row -Name '0,1' -Perf 500 -PerfBase 100 -Idle 900 -Timestamp 100))) `
                           -Second (@((t_Row -Name '0,1' -Perf 400 -PerfBase 200 -Idle 800 -Timestamp 200))) -NominalMhz 0)
t_Check 'A20 counter reset -> null not 0'  $null  $t_back[0].perfPct
t_Check 'A21 idle reset -> null not 0'     $null  $t_back[0].timePct

# Zero denominator must be null, not a divide-by-zero and not 0.
$t_zero = t_Arr (Measure-Sample -First (@((t_Row -Name '0,2' -Perf 10 -PerfBase 50 -Timestamp 100))) `
                           -Second (@((t_Row -Name '0,2' -Perf 20 -PerfBase 50 -Timestamp 100))) -NominalMhz 0)
t_Check 'A22 zero base -> null'            $null  $t_zero[0].perfPct

# Missing fields stay null rather than defaulting to zero.
$t_nul = t_Arr (Measure-Sample -First (@((t_Row -Name '0,3' -Timestamp 100))) `
                          -Second (@((t_Row -Name '0,3' -Timestamp 200))) -NominalMhz 0)
t_Check 'A23 absent perf -> null'          $null  $t_nul[0].perfPct
t_Check 'A24 absent actual -> null'        $null  $t_nul[0].actualMhz
t_Check 'A25 absent limit -> null'         $null  $t_nul[0].limitPct

# An instance present only in the second snapshot has no baseline and is dropped.
$t_orph = t_Arr (Measure-Sample -First $t_a1 -Second (@($t_a2[0], (t_Row -Name '0,9' -Perf 1 -PerfBase 1 -Timestamp 1))) -NominalMhz 2000)
t_Check 'A26 unpaired instance dropped'    1  $t_orph.Count

# Empty input must produce an empty array, not a phantom blank record.
# ($x = f(); @($x)) is the only safe form; @(f()) would wrap the array itself.
$t_empty = Measure-Sample -First @() -Second @() -NominalMhz 2000
t_Check 'A27 empty in -> empty out'        0  ((t_Arr $t_empty).Count)

# ===========================================================================
t_Section 'B. Instance-name canonicalisation'
# ===========================================================================
# PDH spells these lower case ("_total", "0,_total") and raw WMI spells them
# with a capital T. Anything that compares them literally loses half the data.
t_Check 'B1  _Total normalises'        '_total'    (Format-InstanceName '_Total')
t_Check 'B2  0,_Total normalises'      '0,_total'  (Format-InstanceName '0,_Total')
t_Check 'B3  whitespace trimmed'       '0,3'       (Format-InstanceName '  0,3 ')
t_Check 'B4  empty stays empty'        ''          (Format-InstanceName '')
t_True  'B5  _Total is total'          (Test-TotalInstance '_Total')
t_True  'B6  0,_total is total'        (Test-TotalInstance '0,_total')
t_False 'B7  0,3 is not total'         (Test-TotalInstance '0,3')
t_True  'B8  0,3 is a core'            (Test-CoreInstance '0,3')
t_False 'B9  _total is not a core'     (Test-CoreInstance '_total')
t_False 'B10 0,_Total is not a core'   (Test-CoreInstance '0,_Total')
t_False 'B11 non-numeric not a core'   (Test-CoreInstance 'a,b')
t_False 'B12 single part not a core'   (Test-CoreInstance '5')
t_Check 'B13 core index parsed'        3           (Get-CoreIndex '0,3')
t_Check 'B14 core index node 1'        7           (Get-CoreIndex '1,7')

# The casing trap end to end: WMI-cased first sample, PDH-cased second sample.
# If the pairing were case-sensitive this would produce zero rows.
$t_mixA = @((t_Row -Name '_Total' -Perf 100 -PerfBase 100 -Timestamp 1))
$t_mixB = @((t_Row -Name '_total' -Perf 350 -PerfBase 200 -Timestamp 2))
$t_mix = t_Arr (Measure-Sample -First $t_mixA -Second $t_mixB -NominalMhz 0)
t_Check 'B15 mixed case still pairs'   1      $t_mix.Count
t_Near  'B16 mixed case value correct' 2.5    $t_mix[0].perfPct

# ===========================================================================
t_Section 'C. Performance Limit Flags decoding'
# ===========================================================================
t_Check 'C1  0 -> no names'        0  ((t_Arr (Get-LimitFlagNames 0)).Count)
t_Check 'C2  null -> no names'     0  ((t_Arr (Get-LimitFlagNames $null)).Count)
t_Check 'C3  2 -> power budget'    'power budget'  ((t_Arr (Get-LimitFlagNames 2)) -join ',')
t_Check 'C4  1 -> thermal'         'thermal'       ((t_Arr (Get-LimitFlagNames 1)) -join ',')
t_Check 'C5  17 -> two names'      'thermal,voltage regulator thermal'  ((t_Arr (Get-LimitFlagNames 17)) -join ',')
t_Check 'C5b 33 -> known + unknown' 'thermal,unknown (0x20)'  ((t_Arr (Get-LimitFlagNames 33)) -join ',')
t_Check 'C6  8 -> OS policy'       'OS power policy'  ((t_Arr (Get-LimitFlagNames 8)) -join ',')
# An unrecognised bit is shown as hex rather than guessed at. Windows does not
# document these bits, and a confidently wrong reason is worse than none.
t_Check 'C7  256 -> unknown hex'   'unknown (0x100)'  ((t_Arr (Get-LimitFlagNames 256)) -join ',')
# Bit 31 is 2147483648, which overflows Int32. This crashed the first build.
t_Check 'C8  bit 31 no overflow'   'unknown (0x80000000)'  ((t_Arr (Get-LimitFlagNames 2147483648)) -join ',')
t_Check 'C9  all bits set count'   32  ((t_Arr (Get-LimitFlagNames 4294967295)).Count)

# ===========================================================================
t_Section 'D. Risk detection, both sides of every boundary'
# ===========================================================================
function t_Plan {
    param($Name = 'Balanced', $Battery = $false, $MaxAc = 100, $MaxDc = 100, $MinAc = 5, $MinDc = 5)
    return [pscustomobject]@{
        guid = '00000000-0000-0000-0000-000000000000'
        name = $Name
        onBattery = $Battery
        maxProcState = [pscustomobject]@{ ac = $MaxAc; dc = $MaxDc; active = $(if ($Battery) { $MaxDc } else { $MaxAc }) }
        minProcState = [pscustomobject]@{ ac = $MinAc; dc = $MinDc; active = $(if ($Battery) { $MinDc } else { $MinAc }) }
    }
}
function t_Total {
    param($Perf = 100.0, $Util = 20.0, $TimeP = 20.0, $Dpc = 1.0, $Intr = 1.0, $Limit = 100.0, $Parked = $false, $Consistent = $true)
    return [pscustomobject]@{
        name = '_total'; isTotal = $true; isCore = $false; coreIndex = $null
        perfPct = $Perf; actualMhz = 2000.0; derivedNominal = 2000.0
        utilityPct = $Util; timePct = $TimeP; dpcPct = $Dpc; interruptPct = $Intr
        parked = $Parked; limitPct = $Limit; limitFlags = 0; reportedMhz = 1000.0
        consistent = $Consistent
    }
}
function t_Codes {
    param($Risks)
    $r = @($Risks)
    if ($r.Count -eq 0) { return '' }
    return (($r | ForEach-Object { $_.code }) -join ',')
}
function t_Has {
    param([string]$Name, $Risks, [string]$Code)
    $r = @($Risks)
    $hit = @($r | Where-Object { $_.code -eq $Code })
    t_Check $Name 1 $hit.Count
}
function t_HasNot {
    param([string]$Name, $Risks, [string]$Code)
    $r = @($Risks)
    $hit = @($r | Where-Object { $_.code -eq $Code })
    t_Check $Name 0 $hit.Count
}

# THE CRY-WOLF TEST. A completely healthy machine must report nothing at all.
$t_healthy = Get-Risks -Rows @((t_Total)) -Total (t_Total) -Plan (t_Plan) -Nominal 2000 -Sampled $true
t_Check 'D1  healthy machine -> 0 risks'  0  (@($t_healthy).Count)
t_Check 'D2  healthy machine -> exit 0'   0  (Get-ExitCode $t_healthy)

# Power plan caps.
$t_r = Get-Risks -Rows @((t_Total)) -Total (t_Total) -Plan (t_Plan -MaxAc 70) -Nominal 2000 -Sampled $true
t_Has     'D3  plan cap 70 detected'   $t_r 'plan-caps-cpu'
$t_r = Get-Risks -Rows @((t_Total)) -Total (t_Total) -Plan (t_Plan -MaxAc 99) -Nominal 2000 -Sampled $true
t_Has     'D4  plan cap 99 detected'   $t_r 'plan-caps-cpu'
$t_r = Get-Risks -Rows @((t_Total)) -Total (t_Total) -Plan (t_Plan -MaxAc 100) -Nominal 2000 -Sampled $true
t_HasNot  'D5  plan cap 100 is fine'   $t_r 'plan-caps-cpu'

# On battery the DC index is the one in force. Reporting the AC value on a
# laptop running from its battery names the wrong cap entirely.
$t_r = Get-Risks -Rows @((t_Total)) -Total (t_Total) -Plan (t_Plan -Battery $true -MaxAc 100 -MaxDc 50) -Nominal 2000 -Sampled $true
t_Has     'D6  battery uses DC cap'    $t_r 'plan-caps-cpu'
t_Has     'D7  battery reported'       $t_r 'on-battery'
$t_r = Get-Risks -Rows @((t_Total)) -Total (t_Total) -Plan (t_Plan -Battery $false -MaxAc 100 -MaxDc 50) -Nominal 2000 -Sampled $true
t_HasNot  'D8  on AC ignores DC cap'   $t_r 'plan-caps-cpu'

$t_r = Get-Risks -Rows @((t_Total)) -Total (t_Total) -Plan (t_Plan -Name 'Power saver') -Nominal 2000 -Sampled $true
t_Has     'D9  power saver detected'   $t_r 'power-saver-plan'
$t_r = Get-Risks -Rows @((t_Total)) -Total (t_Total) -Plan (t_Plan -MinAc 100) -Nominal 2000 -Sampled $true
t_Has     'D10 min state 100 noted'    $t_r 'plan-pins-cpu'

# Performance limit thresholds. The limit is a GUARANTEE, not a ceiling, so a
# low limit is only a fault when it is actually BINDING - the CPU is busy and
# is not running past it. This was found on real hardware, where a healthy chip
# reports an 85% guarantee while turboing at 214% of nominal.
$t_r = Get-Risks -Rows @((t_Total -Limit 85 -Perf 214 -Util 50)) -Total (t_Total -Limit 85 -Perf 214 -Util 50) -Plan (t_Plan) -Nominal 2000 -Sampled $true
t_HasNot  'D11 turbo past guarantee is not throttling' $t_r 'throttled'
t_HasNot  'D11b and not throttled-hard'                $t_r 'throttled-hard'
t_Has     'D11c reported as not binding'               $t_r 'limit-not-binding'
t_Check   'D11d that alone does not fail the run'  0  (Get-ExitCode $t_r)

$t_r = Get-Risks -Rows @((t_Total -Limit 69.9 -Perf 66 -Util 90)) -Total (t_Total -Limit 69.9 -Perf 66 -Util 90) -Plan (t_Plan) -Nominal 2000 -Sampled $true
t_Has     'D12 busy + binding + 69.9 -> hard'  $t_r 'throttled-hard'
$t_r = Get-Risks -Rows @((t_Total -Limit 70.0 -Perf 66 -Util 90)) -Total (t_Total -Limit 70.0 -Perf 66 -Util 90) -Plan (t_Plan) -Nominal 2000 -Sampled $true
t_HasNot  'D13 limit 70.0 not hard'            $t_r 'throttled-hard'
t_Has     'D13b limit 70.0 -> throttled'       $t_r 'throttled'
$t_r = Get-Risks -Rows @((t_Total -Limit 94.9 -Perf 90 -Util 90)) -Total (t_Total -Limit 94.9 -Perf 90 -Util 90) -Plan (t_Plan) -Nominal 2000 -Sampled $true
t_Has     'D14 limit 94.9 binding -> throttled' $t_r 'throttled'
$t_r = Get-Risks -Rows @((t_Total -Limit 95.0 -Perf 90 -Util 90)) -Total (t_Total -Limit 95.0 -Perf 90 -Util 90) -Plan (t_Plan) -Nominal 2000 -Sampled $true
t_HasNot  'D15 limit 95.0 is fine'             $t_r 'throttled'
t_HasNot  'D15b and not reported at all'       $t_r 'limit-not-binding'

# Exactly at the 5% tolerance the limit still counts as binding.
$t_r = Get-Risks -Rows @((t_Total -Limit 80 -Perf 84 -Util 90)) -Total (t_Total -Limit 80 -Perf 84 -Util 90) -Plan (t_Plan) -Nominal 2000 -Sampled $true
t_Has     'D15c perf 84 vs limit 80 binding'   $t_r 'throttled'
$t_r = Get-Risks -Rows @((t_Total -Limit 80 -Perf 85 -Util 90)) -Total (t_Total -Limit 80 -Perf 85 -Util 90) -Plan (t_Plan) -Nominal 2000 -Sampled $true
t_Has     'D15d perf 85 vs limit 80 not binding' $t_r 'limit-not-binding'

# Too idle to tell must say so rather than guess either way.
$t_r = Get-Risks -Rows @((t_Total -Limit 85 -Perf 80 -Util 10)) -Total (t_Total -Limit 85 -Perf 80 -Util 10) -Plan (t_Plan) -Nominal 2000 -Sampled $true
t_Has     'D15e idle machine -> untested'      $t_r 'limit-untested'
t_HasNot  'D15f idle machine not throttled'    $t_r 'throttled'
t_Check   'D15g untested does not fail run' 0  (Get-ExitCode $t_r)

# Clock collapse only counts when the CPU is actually busy; an idle machine
# downclocking is correct behaviour, not a fault.
$t_r = Get-Risks -Rows @((t_Total -Perf 55 -Util 30)) -Total (t_Total -Perf 55 -Util 30) -Plan (t_Plan) -Nominal 2000 -Sampled $true
t_Has     'D16 busy + 55% -> collapsed' $t_r 'clock-collapsed'
$t_r = Get-Risks -Rows @((t_Total -Perf 55 -Util 24.9)) -Total (t_Total -Perf 55 -Util 24.9) -Plan (t_Plan) -Nominal 2000 -Sampled $true
t_HasNot  'D17 idle + 55% is fine'     $t_r 'clock-collapsed'
$t_r = Get-Risks -Rows @((t_Total -Perf 85 -Util 40)) -Total (t_Total -Perf 85 -Util 40) -Plan (t_Plan) -Nominal 2000 -Sampled $true
t_Has     'D18 busy + 85% -> no turbo' $t_r 'no-turbo'
$t_r = Get-Risks -Rows @((t_Total -Perf 130 -Util 40)) -Total (t_Total -Perf 130 -Util 40) -Plan (t_Plan) -Nominal 2000 -Sampled $true
t_HasNot  'D19 turbo 130% is fine'     $t_r 'no-turbo'

$t_r = Get-Risks -Rows @((t_Total -Util 90.0)) -Total (t_Total -Util 90.0) -Plan (t_Plan) -Nominal 2000 -Sampled $true
t_Has     'D20 utility 90 -> saturated' $t_r 'cpu-saturated'
$t_r = Get-Risks -Rows @((t_Total -Util 89.9)) -Total (t_Total -Util 89.9) -Plan (t_Plan) -Nominal 2000 -Sampled $true
t_HasNot  'D21 utility 89.9 is fine'   $t_r 'cpu-saturated'

$t_r = Get-Risks -Rows @((t_Total -Dpc 10.0)) -Total (t_Total -Dpc 10.0) -Plan (t_Plan) -Nominal 2000 -Sampled $true
t_Has     'D22 dpc 10 -> high'         $t_r 'high-dpc'
$t_r = Get-Risks -Rows @((t_Total -Dpc 9.9)) -Total (t_Total -Dpc 9.9) -Plan (t_Plan) -Nominal 2000 -Sampled $true
t_HasNot  'D23 dpc 9.9 is fine'        $t_r 'high-dpc'
$t_r = Get-Risks -Rows @((t_Total -Intr 10.0)) -Total (t_Total -Intr 10.0) -Plan (t_Plan) -Nominal 2000 -Sampled $true
t_Has     'D24 interrupt 10 -> high'   $t_r 'high-interrupt'
$t_r = Get-Risks -Rows @((t_Total -Intr 9.9)) -Total (t_Total -Intr 9.9) -Plan (t_Plan) -Nominal 2000 -Sampled $true
t_HasNot  'D25 interrupt 9.9 is fine'  $t_r 'high-interrupt'

# Parked cores. Only real cores count; the roll-up rows must not be counted.
$t_parkRows = @(
    (t_Total),
    [pscustomobject]@{ name='0,0'; isTotal=$false; isCore=$true; coreIndex=0; perfPct=100.0; actualMhz=2000.0
        derivedNominal=2000.0; utilityPct=10.0; timePct=10.0; dpcPct=1.0; interruptPct=1.0
        parked=$true; limitPct=100.0; limitFlags=0; reportedMhz=1000.0; consistent=$true },
    [pscustomobject]@{ name='0,1'; isTotal=$false; isCore=$true; coreIndex=1; perfPct=100.0; actualMhz=2000.0
        derivedNominal=2000.0; utilityPct=10.0; timePct=10.0; dpcPct=1.0; interruptPct=1.0
        parked=$false; limitPct=100.0; limitFlags=0; reportedMhz=1000.0; consistent=$true }
)
$t_r = Get-Risks -Rows $t_parkRows -Total (t_Total) -Plan (t_Plan) -Nominal 2000 -Sampled $true
t_Has     'D26 parked core detected'   $t_r 'cores-parked'
$t_pk = @(@($t_r) | Where-Object { $_.code -eq 'cores-parked' })
t_True    'D27 counts 1 not 2'         ($t_pk[0].message.StartsWith('1 logical', [StringComparison]::Ordinal))

# An inconsistent row is reported as such and its numbers withheld.
$t_r = Get-Risks -Rows @((t_Total -Consistent $false)) -Total (t_Total -Consistent $false) -Plan (t_Plan) -Nominal 2000 -Sampled $true
t_Has     'D28 inconsistent flagged'   $t_r 'unreliable-counter'

# INFO alone must not fail the run; WARN and FAIL must.
$t_infoOnly = @((New-Risk 'x' 'INFO' 'y'))
t_Check 'D29 INFO only -> exit 0'  0  (Get-ExitCode $t_infoOnly)
t_Check 'D30 WARN -> exit 1'       1  (Get-ExitCode @((New-Risk 'x' 'WARN' 'y')))
t_Check 'D31 FAIL -> exit 1'       1  (Get-ExitCode @((New-Risk 'x' 'FAIL' 'y')))
t_Check 'D32 no risks -> exit 0'   0  (Get-ExitCode @())

# -Info mode still reports instantaneous facts, but nothing delta-derived.
$t_r = Get-Risks -Rows $t_parkRows -Total (t_Total -Limit 60) -Plan (t_Plan -MaxAc 60) -Nominal 2000 -Sampled $false
t_Has     'D33 info: plan cap'         $t_r 'plan-caps-cpu'
t_Has     'D34 info: parked'           $t_r 'cores-parked'
# Without a sample there is no way to know whether the limit is binding, so
# the honest answer is "untested", not a confident FAIL.
t_Has     'D35 info: limit untested'   $t_r 'limit-untested'
t_HasNot  'D35b info: no false FAIL'   $t_r 'throttled-hard'
t_HasNot  'D36 info: no delta risks'   $t_r 'cpu-saturated'

# ===========================================================================
t_Section 'E. Instantaneous rows and formatting'
# ===========================================================================
$t_snap = @(
    (t_Row -Name '_Total' -LimitPct 77 -LimitFlags 5 -Parked 0 -ReportedMhz 1500 -Perf 12345 -Actual 999),
    (t_Row -Name '0,0'    -LimitPct 66 -LimitFlags 1 -Parked 1 -ReportedMhz 1400)
)
$t_inst = t_Arr (ConvertTo-InstantRows $t_snap)
t_Check 'E1  two instant rows'        2      $t_inst.Count
t_Check 'E2  limit carried'           77     $t_inst[0].limitPct
t_Check 'E3  flags carried'           5      $t_inst[0].limitFlags
t_Check 'E4  reported mhz carried'    1500   $t_inst[0].reportedMhz
t_True  'E5  parked carried'          $t_inst[1].parked
# Cumulative fields must be null, not zero: nothing was measured.
t_Check 'E6  perfPct null not 0'      $null  $t_inst[0].perfPct
t_Check 'E7  actualMhz null not 0'    $null  $t_inst[0].actualMhz
t_Check 'E8  utilityPct null not 0'   $null  $t_inst[0].utilityPct
t_Check 'E9  timePct null not 0'      $null  $t_inst[0].timePct
t_True  'E10 instant rows consistent' $t_inst[0].consistent
t_Check 'E11 empty snapshot -> 0'     0      ((t_Arr (ConvertTo-InstantRows @())).Count)

t_Check 'E12 null mhz -> dash'        '-'         (Format-Mhz $null)
t_Check 'E13 1498 -> GHz'             '1.50 GHz'  (Format-Mhz 1498)
t_Check 'E14 850 -> MHz'              '850 MHz'   (Format-Mhz 850)
t_Check 'E15 999.6 -> MHz'            '1,000 MHz' (Format-Mhz 999.6)
t_Check 'E16 3900 -> GHz'             '3.90 GHz'  (Format-Mhz 3900)
t_Check 'E17 null pct -> dash'        '-'         (Format-Pct $null)
t_Check 'E18 132.45 -> 132.5%'        '132.5%'    (Format-Pct 132.45)
t_Check 'E19 bar clamps over 100'     20          ((Get-Bar 250).Length)
t_Check 'E20 bar length at 0'         20          ((Get-Bar 0).Length)
t_Check 'E21 bar handles null'        20          ((Get-Bar $null).Length)
t_Check 'E22 bar handles negative'    20          ((Get-Bar -5).Length)

t_Check 'E23 total row found'         '_total'  ((Get-TotalRow @((t_Total))).name)
t_Check 'E24 no total -> null'        $null     (Get-TotalRow @())
$t_cr = Get-CoreRows $t_parkRows
t_Check 'E25 core rows exclude total' 2         ((t_Arr $t_cr).Count)
t_Check 'E26 core rows sorted'        0         ((t_Arr $t_cr)[0].coreIndex)

# ===========================================================================
t_Section 'F. End to end: modes, JSON and every error path'
# ===========================================================================
$t_tmp = Join-Path $env:TEMP ('cpuclock-selftest-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $t_tmp -Force | Out-Null

function t_Run {
    param([string[]]$ToolArgs, [string]$OutFile)
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $t_tool) + $ToolArgs
    $err = $OutFile + '.err'
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $all -NoNewWindow -Wait -PassThru `
         -RedirectStandardOutput $OutFile -RedirectStandardError $err
    # Start-Process holds an EXCLUSIVE lock on redirect targets, and the handle
    # lingers briefly after the child exits. ReadAllText throws IOException
    # here; a FileStream opened with ReadWrite sharing does not.
    $text = ''
    $errText = ''
    for ($i = 0; $i -lt 40; $i++) {
        try {
            $fs = New-Object IO.FileStream($OutFile, 'Open', 'Read', 'ReadWrite')
            $sr = New-Object IO.StreamReader($fs)
            $text = $sr.ReadToEnd(); $sr.Close(); $fs.Close()
            $fs2 = New-Object IO.FileStream($err, 'Open', 'Read', 'ReadWrite')
            $sr2 = New-Object IO.StreamReader($fs2)
            $errText = $sr2.ReadToEnd(); $sr2.Close(); $fs2.Close()
            break
        } catch {
            Start-Sleep -Milliseconds 50
        }
    }
    return [pscustomobject]@{ code = $p.ExitCode; out = $text; err = $errText }
}

$t_j1 = Join-Path $t_tmp 'r1.json'
$t_res = t_Run @('-Seconds', '2', '-Json') $t_j1
t_Check 'F1  -Json exit is 0 or 1'  'True'  (($t_res.code -eq 0) -or ($t_res.code -eq 1))
t_Check 'F2  -Json writes nothing to stderr'  ''  $t_res.err.Trim()
$t_doc = $null
try { $t_doc = $t_res.out | ConvertFrom-Json } catch { $t_doc = $null }
t_Check 'F3  -Json parses'          'cpuclock'  $t_doc.tool
t_True  'F4  -Json ok flag'         $t_doc.ok
t_Check 'F5  -Json mode'            'scan'      $t_doc.mode
t_True  'F6  -Json has rows'        (@($t_doc.rows).Count -ge 1)
t_True  'F7  -Json has a total row' (@($t_doc.rows | Where-Object { $_.isTotal }).Count -ge 1)
t_True  'F8  -Json nominal present' ($null -ne $t_doc.nominalMhz)

# Replay, then replay the replay. Drift between the two would mean the JSON
# round trip is lossy.
$t_j2 = Join-Path $t_tmp 'r2.json'
$t_res2 = t_Run @('-FromJson', $t_j1, '-Json') $t_j2
$t_doc2 = $null
try { $t_doc2 = $t_res2.out | ConvertFrom-Json } catch { $t_doc2 = $null }
t_Check 'F9  replay parses'         'cpuclock'  $t_doc2.tool
t_Check 'F10 replay mode'           'fromjson'  $t_doc2.mode
t_Check 'F11 replay preserves rows' (@($t_doc.rows).Count)  (@($t_doc2.rows).Count)
t_Check 'F12 replay preserves risks' (($t_doc.risks | ForEach-Object { $_.code }) -join ',')  (($t_doc2.risks | ForEach-Object { $_.code }) -join ',')
t_Check 'F13 replay preserves clock' ([string]$t_doc.nominalMhz)  ([string]$t_doc2.nominalMhz)

$t_j3 = Join-Path $t_tmp 'r3.json'
$t_res3 = t_Run @('-FromJson', $t_j2, '-Json') $t_j3
$t_doc3 = $null
try { $t_doc3 = $t_res3.out | ConvertFrom-Json } catch { $t_doc3 = $null }
t_Check 'F14 replay-of-replay parses' 'cpuclock' $t_doc3.tool
t_Check 'F15 no drift on second replay' (($t_doc2.risks | ForEach-Object { $_.code }) -join ',')  (($t_doc3.risks | ForEach-Object { $_.code }) -join ',')

# -Quiet must produce nothing at all on either stream.
$t_q = Join-Path $t_tmp 'q.txt'
$t_resq = t_Run @('-Seconds', '1', '-Quiet') $t_q
t_Check 'F16 -Quiet stdout empty'  ''  $t_resq.out.Trim()
t_Check 'F17 -Quiet stderr empty'  ''  $t_resq.err.Trim()

# -Info returns without sampling.
$t_i = Join-Path $t_tmp 'i.txt'
$t_resi = t_Run @('-Info') $t_i
t_True  'F18 -Info produces output'  ($t_resi.out.Length -gt 100)
t_Check 'F19 -Info stderr empty'     ''  $t_resi.err.Trim()
t_True  'F20 -Info says no sample'   ($t_resi.out.Contains('no timed sample'))

$t_ij = Join-Path $t_tmp 'ij.json'
$t_resij = t_Run @('-Info', '-Json') $t_ij
$t_docij = $null
try { $t_docij = $t_resij.out | ConvertFrom-Json } catch { $t_docij = $null }
t_Check 'F21 -Info -Json parses'  'info'  $t_docij.mode

# ---- error paths. All must exit 2 and still emit valid JSON under -Json. ----
$t_e1 = Join-Path $t_tmp 'e1.txt'
$t_rese1 = t_Run @('-Seconds', '0') $t_e1
t_Check 'F22 -Seconds 0 exits 2'  2  $t_rese1.code
$t_e2 = Join-Path $t_tmp 'e2.txt'
$t_rese2 = t_Run @('-Seconds', '0', '-Json') $t_e2
t_Check 'F23 -Seconds 0 exits 2 (json)'  2  $t_rese2.code
$t_de2 = $null
try { $t_de2 = $t_rese2.out | ConvertFrom-Json } catch { $t_de2 = $null }
t_Check 'F24 error path emits valid JSON'  'cpuclock'  $t_de2.tool
t_False 'F25 error JSON ok is false'       $t_de2.ok
t_True  'F26 error JSON carries message'   ($t_de2.error.Length -gt 5)

$t_e3 = Join-Path $t_tmp 'e3.txt'
$t_rese3 = t_Run @('-FromJson', (Join-Path $t_tmp 'nope.json'), '-Json') $t_e3
t_Check 'F27 missing file exits 2'  2  $t_rese3.code
$t_de3 = $null
try { $t_de3 = $t_rese3.out | ConvertFrom-Json } catch { $t_de3 = $null }
t_Check 'F28 missing file valid JSON'  'False'  ([string]$t_de3.ok)

$t_junk = Join-Path $t_tmp 'junk.json'
[IO.File]::WriteAllText($t_junk, 'this is not json at all {{{', (New-Object Text.UTF8Encoding($false)))
$t_e4 = Join-Path $t_tmp 'e4.txt'
$t_rese4 = t_Run @('-FromJson', $t_junk, '-Json') $t_e4
t_Check 'F29 junk file exits 2'  2  $t_rese4.code
$t_de4 = $null
try { $t_de4 = $t_rese4.out | ConvertFrom-Json } catch { $t_de4 = $null }
t_Check 'F30 junk file valid JSON'  'False'  ([string]$t_de4.ok)

$t_other = Join-Path $t_tmp 'other.json'
[IO.File]::WriteAllText($t_other, '{"tool":"diskscout","version":"1.0.0"}', (New-Object Text.UTF8Encoding($false)))
$t_e5 = Join-Path $t_tmp 'e5.txt'
$t_rese5 = t_Run @('-FromJson', $t_other, '-Json') $t_e5
t_Check 'F31 foreign report exits 2'  2  $t_rese5.code

# A UTF-8 BOM must be tolerated. Stripping it with StartsWith(bomString) is
# culture-sensitive and U+FEFF has zero collation weight, so that form matches
# EVERY string and silently eats the first real character.
$t_bom = Join-Path $t_tmp 'bom.json'
$t_raw = [IO.File]::ReadAllText($t_j1)
[IO.File]::WriteAllText($t_bom, $t_raw, (New-Object Text.UTF8Encoding($true)))
$t_e6 = Join-Path $t_tmp 'e6.txt'
$t_rese6 = t_Run @('-FromJson', $t_bom, '-Json') $t_e6
$t_de6 = $null
try { $t_de6 = $t_rese6.out | ConvertFrom-Json } catch { $t_de6 = $null }
t_Check 'F32 BOM file still parses'  'cpuclock'  $t_de6.tool
t_True  'F33 BOM file ok'            $t_de6.ok

$t_e7 = Join-Path $t_tmp 'e7.txt'
$t_rese7 = t_Run @('-Seconds', '99999') $t_e7
t_Check 'F34 -Seconds too large exits 2'  2  $t_rese7.code

# ===========================================================================
t_Section 'G. Read-only proof'
# ===========================================================================
# This tool never writes. Rather than assert that in prose, the source is
# searched for every call that could mutate anything.
$t_src = [IO.File]::ReadAllText($t_tool)
$t_banned = @(
    'Set-Content', 'Add-Content', 'Out-File', 'New-Item', 'Remove-Item', 'Move-Item',
    'Copy-Item', 'Rename-Item', 'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty',
    'Set-Item', 'Clear-Item', 'Stop-Process', 'Stop-Service', 'Set-Service', 'Restart-Service',
    'Set-ExecutionPolicy', 'Set-CimInstance', 'Invoke-CimMethod', 'Invoke-WmiMethod',
    'Remove-CimInstance', 'New-CimInstance', 'Set-WmiInstance', 'WriteAllText', 'WriteAllBytes',
    'AppendAllText', 'SetEnvironmentVariable', 'SetValue', 'DeleteValue', 'DeleteSubKey',
    'git config', 'reg add', 'reg delete', 'schtasks', 'bcdedit'
)
foreach ($t_b in $t_banned) {
    $t_found = $t_src.IndexOf($t_b, [StringComparison]::OrdinalIgnoreCase)
    t_Check ('G:  source contains no "' + $t_b + '"')  -1  $t_found
}
# powercfg is used, but only ever to QUERY.
$t_pcfg = @([regex]::Matches($t_src, 'powercfg[^\r\n]*'))
t_True 'G1  powercfg is used'  ($t_pcfg.Count -ge 2)
foreach ($t_mm in $t_pcfg) {
    $t_line = $t_mm.Value
    $t_bad = $false
    foreach ($t_verb in @('/setac', '/setdc', '/change', '/import', '/restoredefault', '/delete', '/duplicate', '/s ', '/setactive')) {
        if ($t_line.IndexOf($t_verb, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $t_bad = $true }
    }
    t_False ('G2  powercfg call is read-only: ' + $t_line.Substring(0, [math]::Min(46, $t_line.Length))) $t_bad
}

# ---------------------------------------------------------------------------
Remove-Item -LiteralPath $t_tmp -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ('  passed ' + $t_pass + ' / ' + ($t_pass + $t_fail)) -ForegroundColor $(if ($t_fail -eq 0) { 'Green' } else { 'Red' })
if ($t_fail -gt 0) {
    Write-Host ''
    foreach ($t_f in $t_failed) { Write-Host ('   - ' + $t_f) -ForegroundColor Red }
    exit 1
}
Write-Host '  ALL SYNTHETIC TESTS PASSED' -ForegroundColor Green
exit 0
