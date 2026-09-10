# cpuclock

**Your CPU is not running at the speed Windows tells you it is.**

Task Manager shows one averaged "Speed" number. `Win32_Processor.CurrentClockSpeed` — the value almost every script, dashboard and "system info" tool reports — is described by Microsoft's own performance counter documentation as **not accurate** on any processor that manages its own frequency. That is every modern laptop and desktop chip made in the last fifteen years.

`cpuclock` reads the counters Microsoft says you *should* use, and shows you what nothing else does:

- the **real delivered clock in MHz**, per logical processor
- whether that is **above** nominal (turbo working) or **below** it (throttling)
- **`% Performance Limit`** — the performance your chip *guarantees* right now
- whether that limit is coming from **your Windows power plan** or from **the platform** (heat, power budget) — one you can fix in ten seconds, the other you cannot
- **parked cores**
- **DPC and interrupt time**, the usual cause of audio crackle and micro-stutter

Zero dependencies. Read-only. Works without administrator rights.

---

## Windows documents its own numbers as unreliable

These are the actual counter descriptions, read from `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Perflib\009` on the machine this was built on:

> **Processor Frequency** — *"Some processors are capable of regulating their frequency outside of the control of Windows. Processor Frequency will **not accurately reflect** actual processor frequency on these systems. **Use % Processor Performance or Actual Frequency instead.**"*

> **% of Maximum Frequency** — *"…will not accurately reflect… Use Processor Information\\% Processor Performance instead."*

> **% Processor Performance** — *"…as a percentage of the nominal performance… **may exceed 100%**… **will accurately reflect** the performance of these processors."*

> **% Performance Limit** — *"the performance the processor **guarantees** it can provide, as a percentage of nominal. Performance can be limited by Windows power policy, or by the platform as a result of a **power budget, overheating, or other hardware issues**."*

So the correct counters exist, they ship with Windows, and essentially nothing surfaces them. That is the entire reason this tool exists.

Here is the gap on a real machine, measured at the same moment:

| Source | Says | Reality |
|---|---|---|
| `Win32_Processor.MaxClockSpeed` | 1498 MHz | not the maximum — the *nominal* |
| `Win32_Processor.CurrentClockSpeed` | 1298 MHz | documented unreliable |
| `Processor Frequency` counter | 1298 MHz | documented unreliable |
| **cpuclock measured** | **3493 MHz** | **2.33× the reported "maximum"** |

An i7-1065G7 whose real turbo is 3.9 GHz reports a "maximum" of 1.5 GHz. Every tool that trusts that number is wrong by more than a factor of two.

---

## Install

No installer, no dependencies, one file.

```powershell
git clone https://github.com/appsmypass/cpuclock.git
cd cpuclock
powershell -NoProfile -ExecutionPolicy Bypass -File cpuclock.ps1
```

> **About `-ExecutionPolicy Bypass`:** many Windows machines block unsigned `.ps1` files by default. That flag is **process-scoped** — it applies only to that one PowerShell process and changes nothing on your system. You never need to run `Set-ExecutionPolicy`, and this tool will never ask you to.

---

## Usage

```
cpuclock.ps1 [-Seconds <n>] [-Cores] [-Info] [-FromJson <file>] [-Json] [-Quiet]
```

| Flag | What it does |
|---|---|
| `-Seconds <n>` | How long to measure for. Default 5. Longer is more representative. |
| `-Cores` | Show the full per-logical-processor table. |
| `-Info` | Processor, power plan and limits with no timed sample. Returns instantly. |
| `-Json` | Machine-readable report on stdout, nothing else. |
| `-FromJson <file>` | Replay a saved `-Json` report instead of sampling. Diagnose a machine you cannot log into. |
| `-Quiet` | No output at all; use the exit code. |

Exit codes: **0** clean, **1** something worth your attention, **2** the tool could not run.

**Measure while the thing you care about is running.** Start your game, encode or build, then run `cpuclock.ps1 -Seconds 30`.

---

## Real output

Taken on an Intel i7-1065G7 laptop under a two-thread load. Nothing here is mocked up.

```
  cpuclock ──────────────────────────────────────────────────────────
  How fast is your CPU actually running?

  Sampling ──────────────────────────────────────────────────────────
    Measuring for 8 second(s). Run your game, encode or build now.

  Processor ─────────────────────────────────────────────────────────
    Intel(R) Core(TM) i7-1065G7 CPU @ 1.30GHz
      4 physical core(s), 8 logical processor(s)
      Nominal clock : 1.50 GHz   (the 100% reference Windows measures against)

    Power plan    : Ultimate Performance   (running on AC power)
      Processor state allowed by the plan: 100% min, 100% max

  Actual clock speed ────────────────────────────────────────────────
    Running at    : 1.92 GHz
      128.1% of nominal 1.50 GHz  - turbo is working

    What Windows reports, versus what it measured:
      Win32_Processor.CurrentClockSpeed  1.30 GHz   (documented unreliable)
      "Processor Frequency" counter      1.30 GHz   (documented unreliable)
      Win32_Processor.MaxClockSpeed      1.50 GHz   (nominal, NOT the turbo ceiling)
      Measured delivered clock           1.92 GHz   <- the real one

    How busy it really is:
      Busy time        85.7%  █████████████████░░░   time spent not idle
      Real work done  110.0%  ████████████████████   work vs nominal capacity

  What is limiting it ───────────────────────────────────────────────
    Guaranteed performance : 85.0% of nominal, but actually delivering 128.1%.
      The guarantee is a floor, not a ceiling. Your CPU is running past it.
      Reason flags 0x2 : power budget
      Your power plan allows 100%, so this guarantee is set by the platform
      (power budget or heat), not by Windows.

  Per logical processor ─────────────────────────────────────────────
      cpu      clock     of nominal   real work   busy    limit   state
      0    1.93 GHz       128.5%      111.2%   86.6%    85.0%   ok
      1    1.90 GHz       126.9%      103.8%   80.6%    85.0%   ok
      2    1.92 GHz       128.3%      110.2%   85.2%    85.0%   ok
      3    1.94 GHz       129.3%      116.4%   90.8%    85.0%   ok
      4    1.92 GHz       128.0%      111.5%   86.8%    85.0%   ok
      5    1.90 GHz       126.9%      105.0%   82.8%    85.0%   ok
      6    1.92 GHz       128.4%      110.9%   87.2%    85.0%   ok
      7    1.92 GHz       128.0%      110.7%   85.8%    85.0%   ok

  Driver overhead ───────────────────────────────────────────────────
    Deferred procedure calls : 0.4%
    Hardware interrupts      : 1.2%
    High values here are driver time, and show up as audio crackle and stutter.

  Verdict ───────────────────────────────────────────────────────────
    [INFO] Your power plan holds the CPU at 100% minimum state. That maximises responsiveness but also heat and battery drain.
    [INFO] The platform guarantees only 85.0% of nominal, but the CPU is actually delivering 128.1%. That is opportunistic turbo, and it is normal.
    [WARN] The CPU is at 110.0% of its real capacity. It, not the GPU or the disk, is your bottleneck.
```

`-Info`, for when you just want the facts with no waiting:

```
  What is limiting it ───────────────────────────────────────────────
    Guaranteed performance : 85.0% of nominal.
      Reason flags 0x2 : power budget
      Your power plan allows 100%, so this guarantee is set by the platform
      (power budget or heat), not by Windows.

  Per logical processor ─────────────────────────────────────────────
    8 logical processors; 0 parked.  Use -Cores for the full table.

  Verdict ───────────────────────────────────────────────────────────
    [INFO] Your power plan holds the CPU at 100% minimum state. That maximises responsiveness but also heat and battery drain.
    [INFO] The platform currently guarantees only 85.0% of nominal performance. Run a full scan while your game or encode is running to see whether that is actually costing you speed.
```

---

## Two numbers everyone confuses

Almost every CPU reading you have ever seen is **`% Processor Time`** — the fraction of time a core was not idle. It saturates at 100% and tells you nothing about speed. A core crawling at 800 MHz looks exactly as "busy" as one at 3.9 GHz.

**`% Processor Utility`** is the one Task Manager actually plots: real work completed against what the chip could do at nominal speed, and never idle. It can exceed 100%, because turbo is real.

cpuclock shows both, side by side:

```
      Busy time        85.7%  █████████████████░░░   time spent not idle
      Real work done  110.0%  ████████████████████   work vs nominal capacity
```

**The gap between those two lines is your throttling.** When "busy" is high and "real work" is low, your CPU is spending time without getting anything done — that is a downclocked, throttled machine, and no `% Processor Time` reading will ever tell you.

---

## What it tells you, and what to do about it

| Code | Level | Meaning |
|---|---|---|
| `plan-caps-cpu` | FAIL | **Your power plan is limiting the CPU.** Control Panel → Power Options → Change plan settings → Advanced → Processor power management → Maximum processor state → 100%. |
| `clock-collapsed` | FAIL | The CPU is working but running below 60% of nominal. Expect stutter and slow encodes. |
| `throttled-hard` | FAIL | Busy, and pinned under a platform guarantee below 70%. Check cooling and power delivery. |
| `throttled` | WARN | Busy, and the platform guarantee is what is holding it back. |
| `cores-parked` | WARN | Windows has taken cores offline. Threaded work such as encoding will be slower. |
| `cpu-saturated` | WARN | The CPU, not the GPU or the disk, is your bottleneck. |
| `high-dpc` / `high-interrupt` | WARN | Driver time. The usual cause of audio crackle and micro-stutter. |
| `power-saver-plan` | WARN | Power saver is active. Switch before recording or playing. |
| `limit-not-binding` | INFO | The guarantee is low but the chip is turboing past it. Normal. |
| `limit-untested` | INFO | The guarantee is low but the machine was too idle to tell whether it costs you anything. |
| `no-turbo` | INFO | Under load the CPU never went above nominal. |
| `on-battery` | INFO | Sustained clocks are usually much lower than on AC. |

### The distinction nothing else draws

On the test machine the power plan is **Ultimate Performance** with maximum processor state at **100%**, and yet `% Performance Limit` reads **85%**.

Windows is asking for everything. The *platform* is only promising 85%. So the cap is **hardware** — power budget or heat — and no amount of fiddling with power plans will move it.

Flip that around and you get the actionable case: if your plan says 70% and the platform says 100%, you are throwing away a third of your CPU to a setting you can change in ten seconds. `cpuclock` tells you which of those two situations you are in.

### On `Performance Limit Flags`

Windows' own help text for this counter says only *"indicate reasons why the processor performance was limited"* — **it does not document the bits**, and their meaning is platform-dependent.

So cpuclock **always prints the raw hex value**, decodes the commonly-reported bits as a clearly-labelled best-effort, and prints any bit it does not recognise as `unknown (0x…)` rather than inventing a reason. No verdict in this tool depends on that decode alone; the actionable diagnoses come from `% Performance Limit`, which *is* documented.

A confidently wrong diagnosis is worse than no diagnosis.

---

## Read-only, and proved

cpuclock **never writes anything**. No files, no registry, no power settings, no services, no processes touched. There is no `-Fix` mode, so there is nothing to undo.

That is not a promise in a README — it is tested two independent ways:

1. **The source is searched** for all 31 mutating calls (`Set-ItemProperty`, `New-Item`, `Remove-Item`, `Set-CimInstance`, `SetValue`, `WriteAllText`, `Stop-Process`, `reg add`, `bcdedit`, …). Every one must be absent. `powercfg` *is* used, and every single invocation is separately checked to be a query — never `/setac`, `/setdc`, `/change`, `/setactive` or `/import`.
2. **Real state is snapshotted before and after** running the tool in all four modes: active power scheme, the entire `SUB_PROCESSOR` settings block, and the execution policy at both scopes. The two snapshots must be **byte-identical**.

---

## Test evidence

Two suites ship with the tool. Run them yourself.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File selftest.ps1    # 202 synthetic
powershell -NoProfile -ExecutionPolicy Bypass -File realcheck.ps1   # 70 on real hardware
```

### `selftest.ps1` — 202/202 passed

Synthetic fixtures with hand-computed ground truth. **Every field carries a different distinctive value**, so a tool that swaps two of them cannot pass:

```
perfPct 132.5  ·  actualMhz 2650  ·  utilityPct 47.25  ·  timePct 61.75
dpcPct 3.5  ·  interruptPct 7.25  ·  limitPct 88  ·  flags 0x21  ·  reportedMhz 1234
```

Also covered: every risk threshold tested on **both sides** of its boundary; UInt64 counters **above `Int64.MaxValue`** (where a `[long]` cast throws); counter resets becoming `null` and never `0`; mixed-case instance names from two different Windows APIs still pairing; `-Json` → `-FromJson` → `-FromJson` with no drift; **every error path exiting 2 while still emitting valid JSON**; a UTF-8 BOM tolerated; and a **cry-wolf test** requiring a healthy machine to report exactly zero problems.

### `realcheck.ps1` — 70/70 passed on real hardware

Synthetic fixtures are clean and predictable, which is exactly why they miss things. This suite runs against genuine live data:

```
  R1. WMI parse vs an independent PDH parse, field for field
        10 counter instances read from WMI
        30 real fields compared across 10 instances over 6 alternating samples of each API, 0 mismatches
        30 held still and had to agree EXACTLY between the two APIs
        WMI spells them _Total, 0,_Total; PDH spells them 0,_total, _total
        30 of 30 deliberately corrupted values rejected (inverted flag, wrong field offset, percent read as fraction)

  R2. The tool arithmetic vs PDH cooked values over the same window
        30 live counters recomputed; worst relative error 0.000000%

  R3. Known ground truth planted INSIDE a real snapshot
        3 synthetic rows planted among 10 real ones; all found, none leaked

  R4. Cross-checks against built-in Windows commands
        8 per-core instances for 8 logical processors on Intel(R) Core(TM) i7-1065G7 CPU @ 1.30GHz
        active power plan: Ultimate Performance (e005d524-f1ff-479e-98be-0ee8a61237d4)
        PROCTHROTTLEMAX AC = 100%, DC = 100%
        Win32_Battery.BatteryStatus = 1 (on battery: True)
        nominal derived from counters 1,498.1 MHz vs WMI MaxClockSpeed 1498 MHz (0.008% apart)

  R5. Headline claim proven by generating the condition
        this machine was cool: sustained load clocked HIGHER than idle
        idle 2,616 MHz / 174.6%   ->   under load 2,908 MHz / 194.1%
        measured 2,908 MHz against a reported "maximum" of 1498 MHz - 1.94x over
        Win32_Processor.CurrentClockSpeed said 1298 MHz throughout - out by 2.24x
        platform guarantee 85% while delivering 194% - correctly reported as opportunistic turbo

  R6. The tool own -Json output, bounds and aggregate sanity
        10 rows bounds-checked in the tool own JSON
        _total utility 5.3% vs mean of cores 5.3% (their sum would be 42.8%)
        _total 1,375 MHz, cores span 1,252-2,579 MHz

  R7. Read-only, proved by snapshot
        power plan, processor state settings and execution policy all unchanged

  passed 70 / 70
  ALL REAL-HARDWARE CHECKS PASSED
```

A few of those deserve unpacking:

**R2 — `worst relative error 0.000000%`.** The formulas in this tool were not guessed from documentation. PDH exposes its raw counter values alongside its cooked ones, so the tool's own arithmetic was run over two consecutive PDH raw samples — covering the *identical* window PDH used — and compared against PDH's answer. Across 30 live counters the two agree to the digit.

**R1 — comparing two APIs that cannot be sampled at the same instant.** WMI and PDH are different DLLs with different query languages, so the tool's parse is verified field-for-field against a completely independent one. But every field here is *instantaneous*, and one of them — `Parking Status` — is a binary flag that flips **many times per second**. Demanding the two APIs agree on it compares two different moments, not two parses; it reported a mismatch against a perfectly correct tool. Bracketing the PDH read between two WMI reads did not help either, because the core parked and unparked entirely inside the gap.

So the suite **classifies each field before judging it**. Fields that held still across six alternating samples of each API must agree *exactly* — that is the decisive claim, and on a quiet machine all 30 qualify. Fields caught mid-change are reported as undecidable and only checked against their legal domain, because claiming "0 mismatches" about data that cannot be compared would be a lie. Runs where cores 2–7 were parking show `24–28 held still` and name the rest.

**The negative control.** A comparison that tolerates anything proves nothing, so the same check is replayed against deliberately corrupted values — an inverted parking flag, a frequency read from the wrong field offset, a percentage read as a fraction — and **every one must be rejected**. `30 of 30 rejected` is what makes the `0 mismatches` above mean something.

**R5 — the headline claim, proven by generating the condition.** A number that does not throw an error is not the same as a number that is right; a stale value or a plausible constant is exactly what a broken code path returns. So the suite *creates* the condition: it spawns two CPU-bound workers, waits for them to signal `READY` (a JIT-compiling generator needs a readiness signal, not a fixed head start), and requires the measured clock to actually move.

The direction it moves is **not** fixed, and assuming it was produced a failing test against a correct tool. Actual Frequency is the average clock while the CPU is *executing*, not weighted by how much work it did. An idle laptop races to idle — the few instructions that run are dispatched at full turbo — so idle can read *higher* than sustained load once the chip hits its thermal budget. Both were observed on this machine:

| machine state | idle | under sustained load |
|---|---|---|
| cool | 2,616 MHz | **2,908 MHz** |
| already hot | 3,757 MHz | 3,580 MHz |

Both are correct measurements, so the suite asserts what is actually invariant: utility rose sharply, the reading is not a constant, `% Processor Performance` and `Actual Frequency` always agree on direction, and — whichever way it went — the delivered clock **beat the maximum Windows advertises**, by 1.94× here and 2.51× when hot.

**R6 — the aggregate check.** Every individual reading can be within bounds while an aggregate is nonsense. Cores run in **parallel**, so summing their percentages is how a tool ends up claiming 800% CPU. The suite asserts the roll-up is the *mean* of the per-core rows (5.3% — where their sum would be **42.8%**) and that the roll-up clock sits inside the per-core range.

**R3 — ground truth planted inside real data.** Three synthetic rows with known values are appended to a genuine snapshot of the live machine. The tool must find every planted value exactly, and no real value may leak into them or vice versa. It proves the parser works while surrounded by real, irrelevant data — which is how it will actually be used.

---

## Notes on accuracy

- **`% Performance Limit` is a floor, not a ceiling.** A chip can and does deliver more than it guarantees — that is turbo. An earlier build of this tool reported "the CPU is capped" while the machine was running at **214% of nominal**. Real hardware caught it. The tool now only raises a warning when the limit is actually *binding*: the CPU is busy and is not managing to run past it.
- **The counter set is validated against its own redundancy.** `Actual Frequency` must equal `% Processor Performance` × nominal clock. Rows that fail that check have their numbers **withheld** rather than printed with false confidence.
- **Unknown is never reported as zero.** A counter that reset, a missing field or a zero denominator produces `null` and prints `-`. "Unknown" silently masquerading as "perfect" is the most misleading thing a diagnostic can do.
- **Integrated, battery and non-admin paths are all handled.** cpuclock needs no administrator rights; on a machine where a data source is unavailable it says so rather than claiming the data does not exist.
- **Nominal is cross-checked.** The clock derived from live counters agreed with the static `Win32_Processor.MaxClockSpeed` to **0.029%** — two completely independent sources.

---

## Requirements

- Windows with PowerShell 5.1 (in-box on Windows 10 and 11)
- **No administrator rights required**
- No dependencies, no installer, no network access

---

## See also

- [obs-4k60-recorder](https://github.com/appsmypass/obs-4k60-recorder) — the OBS settings that actually record 4K60 without dropping frames
- [framecheck](https://github.com/appsmypass/framecheck) — find dropped and duplicated frames in a recording
- [gpucheck](https://github.com/appsmypass/gpucheck) — whether your GPU was the reason frames dropped
- [diskrate](https://github.com/appsmypass/diskrate) — whether your disk was the reason frames dropped
- [miccheck](https://github.com/appsmypass/miccheck) — why your audio drifted out of sync
- [bootlag](https://github.com/appsmypass/bootlag) — what is making your PC slow to start
- [gamemode](https://github.com/appsmypass/gamemode) — free up your PC before a session

`framecheck` says frames dropped. `diskrate` says whether the disk was why. `gpucheck` says whether the GPU was why. **`cpuclock` says whether the CPU was why.**

---

## License

MIT — see [LICENSE](LICENSE).
