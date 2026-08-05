# Renode performance lessons — ArduPilot + AM32

This branch (`pr-arudpilot-am32-perf`, based on Renode 1.16.1) carries
performance fixes developed while running two very different real
firmware workloads under Renode:

- **ArduPilot** (STM32F405 KakuteF4, ChibiOS, ~25M guest
  instructions/sim-s, WFI-idle heavy) — harness in the ArduPilot repo
  under `Tools/renode/`.
- **AM32 ESC firmware** (eleven MCU families, motor physics co-simulated
  in-process, ~48M guest instructions/sim-s, MMIO and timer-event
  heavy) — harness in the am32-firmware repo under `Mcu/Renode/`.

The headline numbers, both with bit-identical simulation results:

- AM32 STM32L431 spin: **~1.9x** wall time (median of cpu-pinned
  interleaved A/B pairs; clean pairs reach 2.0x) from the six patches
  on this branch built for net8.0, on top of an earlier ~3x from
  harness-side work (below). Built for net10.0 the same patches
  measure **2.2–2.3x** — the newer runtime adds ~35% by itself.
- ArduPilot F405 boot: trimming unused platform timers alone took the
  steady main loop from 33.6x to 25.7x realtime cost and boot wall time
  from 325s to 216s; the time-framework commit here removes the same
  cost at its source.

## The six changes on this branch

All the code changes live in the `src/Infrastructure` submodule, but
this branch deliberately keeps the recorded submodule commit at STOCK
renode 1.16.1 and carries the changes as `perf_patches/000?-*.patch`
instead: `.gitmodules` keeps pointing at the public
renode-infrastructure repository, so the branch is fully
self-contained — cloneable (including as a future submodule of other
projects) without a forked Infrastructure repository. After
`git submodule update --init --recursive`, apply the patches to the
submodule working tree with:

    ./perf_patches/apply.sh

(idempotent; refuses to run on a wrong Infrastructure base). The
patches apply in order onto Infrastructure commit `add012af0`, the
exact commit stock renode 1.16.1 records.

1. **Time framework: dictionary handler lookup + integer fraction
   math.** `BaseClockSource` looked up clock entries *by delegate* with
   a linear `Delegate.Equals` scan on the path of every peripheral
   timer register read, and advanced entries through `Fraction`
   arithmetic that GCD-reduces per construction. ArduPilot reads TIM4's
   counter (micros()) ~213k/sim-s — the scan profiled at **~49% of the
   emulation thread**. Every `STM32_Timer` contributes five LimitTimer
   entries to the scanned list whether the guest uses it or not.
   Measured 1.41x on the AM32 L431 workload by itself.
2. **Clock source and system bus hot paths** (~10% more):
   `ExchangeClockEntryWith` advanced every entry twice per setter call
   (bidirectional dshot hits it ~200k/sim-s) — now advances only the
   exchanged entry; the reentrancy guards were `ThreadLocal<bool>`
   showing up as `__tls_get_addr` — now plain fields (all access is
   under the lock); `TryGetTag` allocated a closure and two LINQ
   iterators **per bus access** — now a plain loop, skipped entirely
   on the hot path unless an overriding tag exists.
3. **Console EOF spin.** With stdin at EOF, the console reader thread
   looped `Console.Read()` returning -1 forever — a full core burned
   for the life of the process. Invisible on a 24-thread workstation,
   real money on a 2-core CI runner.
4. **System bus access cache + advance-path allocation and lock
   removal** (+6.6%, four cpu-pinned interleaved A/B pairs): a small
   per-address-page cache of resolved access methods in
   `TryFindPeripheralAccessMethods` (99.2% measured hit rate — MMIO
   streams hit the same peripheral in runs; version-stamped, immutable
   entries, null-context lookups uncached on machines with per-context
   registrations; the version is captured BEFORE resolving so a
   registration change racing a lookup can never publish a stale
   peripheral as current, and every `PeripheralCollection` mutation —
   including `Add` — bumps it; diagnostics via
   `sysbus FindCacheStats`); the
   `List<Action>` that `AdvanceInner` allocated on every
   limit-reaching advance is reused; and `Update()` no longer takes a
   nested lock under its only caller's lock.
5. **Bus and clock-source per-access costs: locks, allocations, fast
   paths** (+5.6%): `IsAddressRangeLocked` short-circuits on a volatile
   any-range-locked flag (checked per access, ranges almost never
   locked; raised before a range becomes visible and recounted across
   the global AND per-context collections on unlock, so it is only
   ever stale toward the slow path); the generated per-peripheral
   access locks go from
   `SpinLock(true)` — whose `ContinueTryEnter` spin was 2.9% of the
   machine thread — to plain `Monitor`; and the biggest allocation
   site, `ThreadLocalContext.Initialize` building a `Tuple` +
   `DisposableWrapper` + closure **per bus access**, is replaced by a
   reusable per-thread holder handed out as a struct scope
   (`using var scope = SetLocalContextScoped(...)` — no heap
   allocation at all on the access path). A further ~11% vs the
   patches-1-3 reference in the same commit: `TryGetCurrentCPU` fast
   path and a zero-elapsed skip in `GetClockEntry`'s deposit loop.
6. **Time framework: update clock entries in place** (~13%):
   `ClockEntry` is a fat struct and `BaseClockSource.Update` — 9% of
   the machine thread — copied every enabled entry out through the
   list indexer and back per update. On .NET the loop now walks
   `CollectionsMarshal.AsSpan` over the list's backing array and
   mutates entries in place via `ref`. Safe because the loop body is
   pure arithmetic; limit handlers fire after the loop (from
   `toNotify`), so the list cannot change shape while the span is
   live. The copying loop remains for the mono build.

## Where the time actually goes (both projects agree)

Profile the emulation thread before believing anything. On both
workloads, across mono and .NET 8:

- **Guest CPU emulation (tlib) is 1–3%.** Emulating the ARM is nearly
  free; everything expensive is managed framework machinery around it.
- **The per-event and per-access costs dominate**: clock-entry
  bookkeeping per timer event, SystemBus dispatch per MMIO access
  (tag check, context lookup, access-method lookup, locking — a fixed
  ~2–3µs each), and the tlib→C# reverse-P/Invoke transition itself.
- What that means in practice: **wall time scales with event and MMIO
  rates, not with guest instruction counts.** ArduPilot WFI-idles 80%
  of its cycles and still cost 27x realtime; AM32's fastest lever ever
  measured was raising the dshot frame period (fewer wire edges), not
  anything about the CPU.

The ~21% libcoreclr blob was then split with proper runtime symbols
(dotnet-symbol on libcoreclr.so, addr2line against the .dbg — perf's
buildid cache did not pick it up by itself). Machine-thread shares
measured after the first four commits (commits 5 and 6 then attacked
the top items):

- **Monitor lock enter/exit ~6%** (`JIT_MonReliableEnter/MonExit`):
  the remaining `lock(sync)` pairs in the clock source per event, the
  per-access peripheral locks, machine locks. Commit 5 removed the
  per-access peripheral SpinLocks; clock-source pairs remain.
- **Spin-wait ~3%** (`YieldProcessorNormalized`): the time-framework
  grant handshake between source and handles.
- **ThreadLocal/static machinery ~3.5%** (GetThread,
  ThreadLocalModule, `__tls_get_addr`): SystemBus context tracking and
  the collection's ThreadLocal caches. Commit 5 removed the per-access
  allocations feeding this.
- **Allocations + write barriers + zeroing ~5%**: the dominant site
  (`ThreadLocalContext.Initialize`) is gone with commit 5.
- `BaseClockSource.Update` ~9% (struct copies — halved by commit 6's
  in-place span loop), physics ~12% (real work), tlib ~9%, register
  framework ~3.5%.
- **The tlib→C# transition itself measured 0.17%** —
  the long-standing suspicion that the native/managed crossing
  dominates is WRONG on .NET 8; do not spend effort there.

### Remaining roadmap candidates, in value order

1. Flatten the remaining clock-source lock pairs
   (`GetClockEntry`/`AdvanceInner`/`Exchange` — ~3% of the machine
   thread; most acquisitions are uncontended and same-thread — the
   nested-Update-lock removal here is the pattern).
2. The time-framework grant handshake spin (~3% in
   YieldProcessorNormalized) — blocking instead of spinning where the
   wait is long.
3. A fast path for NVIC ISER/ICER/ISPR words — the hottest MMIO
   peripheral on both firmwares rides the fully general register
   framework (~3.5%).
4. Remaining allocation sites (`JIT_NewS` ~1.4%) and
   `Emulation.TryGetExecutionContext`/`GetCurrentCPU` in STM32_Timer
   IRQ callbacks.
5. NOT the tlib→C# transition (0.17% measured — see above).

## Host-side configuration that matters

- **mono (bundled portable): `MONO_GC_PARAMS=nursery-size=64m` is
  1.58x** on AM32. The default 4MB nursery forced ~800 minor GCs per
  simulated second (every MMIO crossing allocates), each suspending
  every thread by signal — 14k syscalls/s of pure GC signalling.
- **The .NET 8 build is 1.76x over bundled mono** on the same workload,
  bit-identical results. Under .NET, GC knobs (`DOTNET_GCgen0size`,
  `gcConcurrent`, TieredPGO) are all **neutral** — CoreCLR's GC is not
  the bottleneck; don't waste time there. `TieredCompilation=0` is
  ~12% *worse*.
- **The runtime major version is a real lever: .NET 10 is ~1.35x over
  .NET 8** on the patched AM32 workload (`./build.sh --net -F
  net10.0`, SDK 10.0.110), with bit-identical markers, the AM32 suite
  green and the ArduPilot boot byte-identical in instruction count.
  Prefer the newest SDK the host offers. A net8.0 build can also run
  on a newer installed runtime with
  `DOTNET_ROLL_FORWARD=LatestMajor`.
- **Global quantum is a sync interval, not a cost driver**: 1ms vs 10ms
  neutral on both projects. Don't chase it.
- **Silencing log output is neutral** — log entries cost at the
  producer regardless of level, and the logging thread's busy-spin
  dequeue burns its own core off the critical path (as did the console
  EOF spin before commit 3). Whole-process CPU numbers lie; profile
  the emulation *thread*.

## Harness-side lessons (apply to any new platform)

- **Trim unused timers from the platform.** Every declared
  `STM32_Timer` adds five clock entries that every full clock-source
  update walks. ArduPilot's 33.6x → 25.7x came from deleting timers
  the firmware never touches. (The dictionary-lookup commit removes
  the *scan* cost, but per-update advance cost per entry remains.)
- **Don't poll through the SystemBus from C# models.** The AM32 bridge
  polled twelve GPIO registers per physics tick through
  `SystemBus.Read*` — over half of all bus traffic. Caching peripheral
  object references and reading them directly (no bus dispatch, no
  locks) was 1.30x.
- **Batch or event-drive high-rate co-simulation.** The AM32 physics
  batch interval at 20µs vs 10µs is 1.22x; the general rule is that
  everything crossing the framework per-event should justify its rate.
- **PerformanceInMips is a correctness knob here, not performance** —
  both harnesses pin it (48/125) because capture/alignment behaviour
  depends on the instructions-per-quantum granularity; changing it
  re-times captures. The CPU budget itself is nearly free (see above).

## Measurement discipline (hard-won)

- Fix a deterministic probe with **markers** (zero-crossing counts,
  rpm, boot milestones) and require bit-identical markers for every
  "optimization" you keep. Two of the changes tried during this work
  produced plausible-looking speedups with silently different
  simulation timing — the markers caught both.
- **Interleave A/B runs** when the host has any other load; absolute
  numbers drift ±15% but interleaved ratios hold.
- perf on the .NET build needs `DOTNET_PerfMapEnabled=1` **and**
  `DOTNET_EnableWriteXorExecute=0`, or every JIT frame lands in an
  anonymous `memfd:doublemapper` region. Use `--delay` to skip the
  tiered-compilation phase. On mono, disambiguate anonymous exec
  regions (tlib's 32MB rwxp translation cache vs mono JIT) before
  attributing samples — getting it wrong inverts the conclusion.
- **A broken run's profile is garbage.** Firmware that fails to arm or
  boot retries in tight loops; twice during this work a histogram from
  a broken build suggested a 750kHz event storm that simply does not
  exist in a healthy run. Never size optimization work from a run
  whose functional markers are wrong.
- Identify clock entries by logging `Handler.Target.GetType()` at
  registration, and diff per-entry fire-count histograms between
  builds — it finds both regressions and phantom work in minutes.
- **Pin A/B runs to a fixed CPU set** (`taskset -c 16-23`) on a busy
  host: it collapsed run-to-run variance from ±15% to ±1% here and
  made a 6.6% effect cleanly resolvable where unpinned interleaving
  could not.
- **`build.sh -s` UPDATES submodules** — it force-checks-out the
  parent's recorded gitlink, silently discarding a branch checked out
  in `src/Infrastructure`. One whole measurement round here compared
  a stock build believed to be patched. Verify what you measured
  (`git -C src/Infrastructure log`) before believing any A/B result.
- **Hunt zombie emulators before measuring**: one wedged renode from
  an earlier experiment burned a core for an hour and set the noise
  floor for everything after it. `ps -eo pid,etime,pcpu,args | grep
  dotnet` first.

## Failed approaches (documented so nobody repeats them)

- **Per-entry deadline cache in `BaseClockSource.Update`** (skip
  fraction math for entries not yet due): zero measured gain — after
  the dictionary/math commit the update cost is set by *legitimately
  firing* entries (AM32's 50kHz batch), not by the skipped ones — and
  it exposed a semantic mine: peripheral models read timer values from
  inside limit handlers (the notify phase), where lazily-maintained
  values are arbitrarily stale. AM32's capture models measured garbage
  pulse widths and the ESC never armed. Fixing the read changes
  simulation timing (better than before, but different), which
  invalidates every recorded regression figure for no speedup.
- **Rewriting hot C# models in C**: the models' cost is the framework
  dispatch around them, not their bodies. Everything already native
  (tlib, physics) totals under 15%.
- **Cache/data-layout work**: IPC is 2.3–2.8 with low miss rates on
  this code; it is not memory-bound. The frontend-bound share is
  JIT-typical and shrinks by doing less work, not by layout.

## Renode model bugs found along the way (fidelity, not speed)

Kept here because every one of them *looked* like a hang or perf
problem first. ChibiOS/ArduPilot: NVIC ICSR.RETTOBASE reads 0 (tag)
and every interrupt-driven thread wakeup is dropped; `STM32_Timer`
never fires a compare with CCR=0 (bites the tickless tick ~1/65536
alarms — system freezes minutes in while virtual time keeps running);
stock `STM32SPI` never calls FinishTransmission (frame on CS instead);
stock `STM32F4_I2C` can't run ChibiOS I2Cv1; stock `STM32DMA` keeps a
stream's memory offset across NDTR rewrites. AM32: Renode restores
VTOR=0 on firmware self-reset (every machine needs a `macro reset`
re-asserting VectorTableOffset — the fingerprint is a suspiciously
*fast* sim-time ratio with no activity); the monitor treats stdin EOF
as quit; a later `.repl` connection block silently REPLACES an earlier
one. Details and fixes: ArduPilot `Tools/renode/README.md` and AM32
`Mcu/Renode/README.md`.

## Building and using this branch

```
git submodule update --init --recursive
./perf_patches/apply.sh    # patch src/Infrastructure (idempotent)
./build.sh --net           # needs the dotnet SDK on PATH
./renode --disable-gui --console -e 'include @your.resc'
```

This branch defaults the .NET build to **net10.0** (upstream 1.16.1
defaults to net8.0) because the newer runtime is ~1.35x faster (see
host-side configuration above). On a host with only SDK 8, build
with `-F net8.0` — both targets build and run correctly. Delete
stale `obj`/`bin` directories when switching SDKs or target
frameworks, or the build fails with duplicate-attribute CS0579
errors.

Do NOT build with `-s` after applying the patches — it updates
submodules to the recorded gitlinks, silently discarding the patched
Infrastructure working tree (or a branch checked out there for
development; see the measurement-discipline section). Re-run
`apply.sh` if the submodule ever gets reset.

Validated against both harnesses at these commits: the full AM32
scripted suite passes at its recorded per-target figures
(`run_renode_tests.py --renode <this>/renode`), an ArduPilot KakuteF4
ArduCopter ELF boots to a running ChibiOS kernel, and the simulation
markers are bit-identical to stock 1.16.1 throughout.

Cumulative on the AM32 L431 spin probe (cpu-pinned interleaved A/B
pairs on a loaded host, vs the stock 1.16.1 net8.0 portable): built
for net8.0 this branch is **1.87x median** (clean pairs 1.94x and
2.02x); built for net10.0 it measures **2.19–2.32x** (6.8–7.0s
against stock's 14.9–16.1s), putting the 5 sim-s window at ~0.75x
realtime, up from 0.38x. The remaining roadmap above lists where
further gains live.
