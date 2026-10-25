# SOLIDWORKS start-up time under MacSW (patches 0032 and 0033)

Date: 2026-10-24. Host: Apple M2 Pro (6 performance + 4 efficiency cores), 16 GB, macOS 27.0, on AC power.
Wine and SOLIDWORKS run as x86_64 code under Rosetta. SOLIDWORKS 2026 SP4.1.
Branch `startup` (worktree `wt-startup`). First pass based on `integrate` @ ac96ef9; second pass (review,
0033 fix, re-measurement, section "Review") merged with `integrate` @ 857266f.

## Summary

- **Result: start to the main window is about 8-10 s (26-30 %) shorter.** In interleaved runs in the clone
  bottle, the median went from 32.7 s to 24.2 s (first pass, section 4) and from 34.6 s to 24.0 s (second pass
  with the reviewed patches, 4 pairs, section "Review"). The SOLIDWORKS process uses 17-24 % less CPU time up
  to the main window, and the wineserver 63-66 % less.
- **Review (second pass):** one defect fixed: the first 0033 let psapi read the own process through a handle
  without `PROCESS_VM_READ`; now the server checks the access as in stock Wine. psapi results are identical to
  stock Wine, both caches are off without their variable, the WIC cache is thread-safe, and it is stale by
  design for codecs (un)registered while a process runs. The branch is merged with `integrate` (0032/0033
  after 0028); the Python, shell and Swift (shim) tests pass.
- **Cause: wineserver round trips, not SOLIDWORKS's own work.** Before the main window, the main thread of
  SLDWORKS.exe sends about 920,000 requests to the wineserver. Each one costs 15-20 us under Rosetta.
  Two Wine inefficiencies cause 63 % of them:
  1. **WIC component lookups (39 %).** Wine's `windowscodecs` reads the codec list from the registry again for
     every image that SOLIDWORKS decodes (about 25 round trips per decode, thousands of toolbar icons).
     Patch 0032 reads the list once per process.
  2. **Module-list walks (24 %).** SOLIDWORKS lists the modules of its own process with psapi through a
     real process handle. Wine makes one round trip per list entry. Patch 0033 reads the own process
     locally. The walks over the modules of `sldProcMon.exe` (another process) stay.
- Both patches act only when their variable is set. MacSW sets `MACSW_WIC_COMPONENT_CACHE=1` and
  `MACSW_LOCAL_MODULE_READS=1` only for SOLIDWORKS and sw-cli launches (`WineService.environment(solidWorks:
  true)`, `sw-cli`, `wine_runtime.py`).
- **What is left (about 24 s in the clone, load 7-9):** SOLIDWORKS's main thread is now busy for 70-95 %
  of the time. Its CPU time is translated SOLIDWORKS and Wine code under Rosetta (about 19 s of process
  CPU time up to the main window). The remaining round trips are spread thinly over the registry,
  windows and synchronization. This is mostly SOLIDWORKS's own work under Rosetta.
- **No network waits, no font scan, no add-in load on the critical path** (section 3). The clone bottle
  loads 4 add-ins at start (0.9 s by SOLIDWORKS's own log); the real bottle has all start-up add-ins off.
- **Not changed:** the thread-priority mapping for idle threads (no gain, section 5.1), Mono settings
  (section 5.2), msync (section 5.3).
- **First start from a new Wine runtime path is 20-25 s slower** (Rosetta translates the runtime's
  Mach-O files again). This happens once after MacSW.app is installed or moved (section 6).

## Review (second pass)

Adversarial review of 0032/0033 (commit f7e1e3a), merge with `integrate`, and a new interleaved measurement.
Commits on `startup`: 86b68c8 (the first pass's pending edits), a76fe7a (merge), 734f406 (0033 fix, probes,
tests), and this document.

### Findings

| # | Finding | Effect | Action |
|---|---|---|---|
| 1 | **0033 skipped the access check.** It switched to the pseudo handle before the first `ReadProcessMemory`. With a handle to the own process that has no `PROCESS_VM_READ` (`OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)` or `PROCESS_QUERY_INFORMATION` only), `EnumProcessModules(Ex)` and `GetModuleInformation` succeeded, while stock Wine and Windows fail with `ERROR_ACCESS_DENIED`. `GetModuleBaseNameW` and `GetModuleFileNameExW` still failed (their name read uses the caller's handle), so the results did not agree with each other. | More permissive than stock, own process only, no new access to other processes. SOLIDWORKS's handles have full access, so it was not affected. | **Fixed** (734f406): the first read of a walk goes through the caller's handle (the server checks the access), the rest is local. Cost: one round trip per walk instead of none. |
| 2 | **0032 lists are frozen per process.** A codec registered after the first enumeration is not seen until the process restarts. A codec removed while the process runs stays listed, and its cached GUID values (`ContainerFormat`) are still returned. | Shown with a fake registry-only decoder (below). Decoding still works: the removed decoder never matches. Codecs are registered by installers, which do not run inside SOLIDWORKS. | Documented (patch header, this section). Not changed. |
| 3 | **0032 lists are not freed** when `windowscodecs.dll` is unloaded with `FreeLibrary`. | At most a few KB per load/unload cycle. COM never unloads it (`DllCanUnloadNow` returns `S_FALSE`). | Not changed. |
| 4 | **0032 reads a GUID value from the registry while it holds the global `component_info_cache_cs`.** | Only the first read of each value; first reads of different threads are serialised. No deadlock: the lock is recursive and the registry calls do not call back into WIC. | Not changed. |
| 5 | **Merge with `integrate`:** `verify_app.sh` now rejects a BuildManifest key that it does not check, and sw-cli verifies "declared modules". | Without new entries, a packaged app with 0032/0033 would fail `verify_app.sh`. | Fixed in the merge (a76fe7a). |

### Gating (off when the variable is unset)

- Each DLL reads its variable once, on first use. Only the exact value `1` turns the cache on. Unset or any
  other value takes the stock code path: the stock `CreateComponentEnumerator()` loop, the stock registry read
  of a GUID value, and no handle switch in `init_module_iterator()`.
- Evidence with the patched DLLs and the variable unset: the probe output is byte-identical to stock Wine, the
  speed is the stock speed (module listing 29-32 ms vs 8 ms with the variable; decode 1,584 us vs 18 us), and
  the registration test shows the stock behaviour (a new codec is seen at once).
- MacSW sets the variables only for SOLIDWORKS: `WineService.environment(solidWorks: true)` (also used by the
  0025 app-bundle exec plan), `sw-cli` and `wine_runtime.py`. After the merge, `integrate`'s environment
  allowlist never passes them through from MacSW's own environment. `RuntimeTests` now checks both: set for
  SOLIDWORKS, absent for other Wine processes even when the parent environment has them.

### Other processes

- The caches are static data of each process. Nothing is shared between processes; each process fills its
  own on its first use. A new process always reads the current registry.
- Which processes have the variables (from the Wine 11.16 source; not measured, see below):
  - **Yes:** SLDWORKS.exe and every process it starts with `CreateProcess` (`sldProcMon.exe`, the activation
    wizard, which is i386 and ignores them); COM local servers that SOLIDWORKS starts, such as
    `sldsurfacing.exe -Embedding` (`combase` `create_server()` calls `CreateProcessW` with the client's
    environment); `explorer.exe /desktop` (`win32u` starts it with the environment of the first process that
    needs the desktop). When SOLIDWORKS is the first process of the bottle, `wineboot.exe` (ntdll
    `run_wineboot()` passes the first process's environment) and `services.exe` (started by wineboot with an
    inherited environment) have them too.
  - **No:** every service that `services.exe` starts (`rpcss`, `plugplay`, `winedevice`, `svchost`,
    `FNPLicensingService64`): it gives each one `CreateEnvironmentBlock(..., FALSE)`, a new block without the
    variables. Wine processes that MacSW starts for other purposes (installer, tools) do not get them.
  - Effect: in the processes that have them, the same per-process rules apply (a codec registered while the
    process runs is seen after its restart). None of these processes registers WIC codecs.
- `build.nosync/startup/tests2/envdump.c` (reads the environment block of every process of a prefix) was built
  to confirm this in a running SOLIDWORKS, but not run: all four `sw_slot.sh` slots were held by other agents.

### i386 and x86_64

- Only the x86_64 DLLs are patched and shipped. In the test runtimes the i386 `windowscodecs.dll` and
  `kernelbase.dll` are byte-identical to stock (SHA-256 `1a108e7d...` and `66adca8b...`).
- 32-bit processes (the activation wizard `swactwiz.exe` is i386) inherit the variables and ignore them. The
  i386 build of the WIC probe with `MACSW_WIC_COMPONENT_CACHE=1` behaves like stock: a codec registered while
  it runs is seen at once, and 8 x 300 iterations take 1,491 ms (x86_64 with cache: 172 ms; without: 1,856 ms).
- Each process reads its own registry view (64-bit `HKCR\CLSID` for x86_64), as stock Wine does.
- A 64-bit process that lists a 32-bit (WOW64) process takes the unchanged path (the process id is not its
  own); the probe's `child32` lists are the same in all modes.

### psapi results compared with the wineserver path

`local_module_reads_probe.exe` in a separate test prefix (`build.nosync/startup/pfx-probe`), with the stock
runtime and the patched runtime, variable off and on. Output: `build.nosync/startup/tests2/out/lmr-*.txt`.

| Handle | Stock Wine | Patched, off | Patched, on (old 0033) | Patched, on (fixed 0033) |
|---|---|---|---|---|
| own: pseudo handle | 29 modules | same | same | same |
| own: `DuplicateHandle`, same access | 29, equal to pseudo, line by line | same | same | same |
| own: `OpenProcess(QUERY_INFORMATION \| VM_READ)` | 29 | same | same | same |
| own: `OpenProcess(QUERY_LIMITED_INFORMATION)` | fails, error 5 | same | **succeeds** (Enum, ModuleInformation) | fails, error 5 |
| own: `OpenProcess(QUERY_INFORMATION)` | fails, error 5 | same | **succeeds** | fails, error 5 |
| own: duplicate with `VM_READ` only | fails, error 5 | same | same | same |
| other process (child): full / limited / `QUERY_INFORMATION \| VM_READ` | 29 / error 5 / 29 | same | same | same |
| WOW64 child (i386): full / limited / `QUERY_INFORMATION \| VM_READ` | 6 (34 with `LIST_MODULES_ALL`) / error 5 / 6 | same | same | same |

Each case also checks `GetModuleBaseNameW`, `GetModuleFileNameExW` and `GetModuleInformation` for every module,
for `NULL` (main module) and for a bogus `HMODULE` (fails with `ERROR_INVALID_HANDLE`), and a 1-slot buffer
(`needed` is still the full size). With the fixed DLL the output is identical with the variable off and on
(2 runs each), and identical to stock Wine apart from the image sizes of the two patched DLLs. One full
listing through the duplicate handle (29 modules, loaded Mac): 29-32 ms off, 7.5-8.3 ms on.

Not caused by the patches: the i386 build of the probe crashes in stock Wine when it lists another 32-bit
process through a `QUERY_INFORMATION | VM_READ` handle (page fault in the i386 psapi code; the same with the
stock runtime). Not investigated.

### Thread safety

- 0032: the lists are filled once, under `component_info_cache_cs`, and never change after that. A thread reads
  them only after it has filled them or has entered that lock, so it sees the complete lists. The GUID values
  of a component are read and written under the same lock. `wic_cache_staleness_probe.exe threads`: 8 threads
  start at once in a process that has not enumerated yet, so they race the first fill. Each thread does
  300 x (enumerate decoders, metadata readers and converters with their formats, decode a PNG with metadata).
  The digest of the component lists is `7b9e066f` in every thread and iteration, in all four configurations
  (stock and patched, off and on), with 0 decode failures; 5 more runs with the cache, 8 x 1,000 iterations
  each: the same. Time for 8 x 300: 1,775-1,856 ms without the cache, 172 ms with it.
- 0033: the patch changes only which handle reads the list. The walk races with DLL loads and unloads in other
  threads in the same way as stock Wine (the server reads the same memory without a lock, as Windows does).
  Probe: 4 threads walk the list through the duplicate handle while a fifth thread loads and unloads
  `msimg32.dll` for 2 s. No crash in any mode. Walks that fail because the list changed under them: stock 5-9
  of about 130, patched with the variable 0-1 of 530-800.
- The variable is read into a `static LONG` on first use; two threads that race there compute the same value.

### Registration while a process runs (0032)

`wic_cache_staleness_probe.exe` registers a fake decoder (registry keys only, no DLL) in the test prefix:

| Step | Cache off (stock and patched) | Cache on |
|---|---|---|
| decoders before the registration | 8 | 8 |
| same process, after the registration | 9, fake listed | **8, fake not listed** |
| new process (inherits the variable) | 9, fake listed | 9, fake listed |
| registered before the first enumeration, then removed: listed? | no | **yes** |
| ... its `ContainerFormat` | (not listed) | the cached value |
| PNG decode after the removal | works | works |

### Merge and tests

- `git merge integrate` (integrate @ 857266f). Conflicts in `build_winemac.sh`, `package_app.sh`,
  `verify_app.sh` and `WineService.swift`, all additive; both sides kept. The apply order is now
  0001-0022, 0023, 0024, 0025, 0028, 0032, 0033, and the build key lists the patch hashes in that order.
- The full series (28 patches) applies to a pristine `wine-11.16.tar.xz` in that order (`git apply --check`,
  then `git apply`, in `build.nosync/startup/applycheck/`). 0032/0033 are the only patches that touch
  `dlls/windowscodecs` and `dlls/kernelbase`, so the DLLs built from the first-pass tree plus the fixed 0033
  are the DLLs the merged build produces.
- Wiring added in the merge: `verify_app.sh` `MANIFEST_MODULES` and `wine_runtime.py` `DECLARED_MODULES` list
  `WineWindowsCodecsModuleSHA256` and `WineKernelBaseModuleSHA256`; the allowlist tests (Python and Swift) know
  the two keys as MacSW's own. `test_wine_startup_caches.py` checks the order after 0028, the module tables,
  and that the 0033 handle switch comes after the first read.
- Tests: `test_swcli_launcher.sh` passes; `python3 -m unittest discover scripts/tests`: 251 tests, OK.
  `swift test` does not run on this Mac (the Command Line Tools' `swift-package` cannot load
  `BuildServerProtocol.framework`), so the Swift tests ran through `tools/xctest-shim/run.sh`: 239 tests,
  0 failed. `BootstrapStoreLifecycleTests.swift` does not compile under the shim (main-actor isolation of
  its properties); this file is not touched here.

### Re-measurement (interleaved, bottle-s1)

Bottle `bottle-s1` (APFS copy of `bottle-perf2`, not activated). Runtimes: two new APFS copies of `rt-base`
(= `build.nosync/wmi/rt-fix`, MacSW.app's runtime with the fixed `wbemprox.dll` of patch 0028, x86_64 and i386
hashes checked): `rt-s1-stock` (stock `windowscodecs.dll` and `kernelbase.dll`) and `rt-s1-patch` (both DLLs
built from 0032 and the fixed 0033, unstripped, as `build_winemac.sh` ships them; the first pass measured
stripped copies). Both arms set `MACSW_WIC_COMPONENT_CACHE=1 MACSW_LOCAL_MODULE_READS=1`, as MacSW does, so
only the two DLLs differ. One discarded warm-up start per runtime (new runtime paths: Rosetta translates
them once; 74.6 s and 43.6 s), then the arms alternated (stock, patch, stock, patch ...). Every start ran
inside a `tools/sw_slot.sh` slot. 17:24-17:31, load 5.6-7.3 at the launches (the owner's SOLIDWORKS and other
agents' SOLIDWORKS sessions were running).

Median [min-max] of the 4 interleaved pairs:

| Arm | Launch to main frame (s) | SLDWORKS.exe CPU (s) | wineserver CPU (s) |
|---|---|---|---|
| stock DLLs | 34.58 [31.46-35.89] | 24.79 [22.62-25.39] | 7.70 [6.87-8.08] |
| patched DLLs | **24.04 [21.48-25.56]** | 18.73 [17.26-19.70] | **2.60 [2.29-2.95]** |
| change | **-30 %** (per pair -32, -34, -24, -32 %) | -24 % | -66 % |

- Every patched run is faster than every stock run. The first pass measured -26 % (32.7 -> 24.2 s) and a
  wineserver CPU drop of 63 %; this pass agrees.
- The wineserver CPU time hardly depends on the machine load and is the most direct measure of the removed
  round trips: 5.1 s less per start.
- Excluded: a fifth stock run (53.5 s) started at load 10.5, after the load gate's 3-minute limit. Its patch
  partner could not run: all four slots were held by other agents for more than 20 minutes. So the result is
  4 pairs. Raw data: `build.nosync/startup/v2/` (`starts.tsv`, `runs/`).
- The harness (`startbench.py`) passes its own full environment plus MacSW's SOLIDWORKS variables to Wine; MacSW
  itself passes an allowlist since `integrate` 50e1759. The extra variables do not change the timing.

### SOLIDWORKS check

All 9 measured starts (and both warm-ups) reached the main frame with the same window title (SOLIDWORKS
2026 SP4.1), the same windows (splash, activation dialog, main
frame) and the same child processes (`winemenubuilder.exe` sometimes, in both arms). The activation dialog was
answered "activate later" every time (radio states checked). No crash reporter, no message box, no early exit.
SOLIDWORKS's own `SolidWorksPerformance.log` (serial-number line not copied) is the same in both arms apart
from numbers: the same 4 add-ins loaded at start (Autotrace, Design Checker, TolAnalyst, ScanTo3D) and
unloaded at exit, the same `<SW EXIT>` and shutdown lines. The only other difference, a `Z:` entry in
`<DISK_SPACE_INFO>`, appears in 2 patched runs and in the stock warm-up, so it does not depend on the DLLs.

## 1. Method

| Item | Value |
|---|---|
| Bottle | `~/Library/Application Support/MacSW/bottle-perf2`, an APFS copy of `bottle-crashlab`. Not activated. The real bottle was not used. |
| Runtime | `build.nosync/wmi/rt-fix` (MacSW.app's runtime with the fixed `wbemprox.dll` of patch 0028), copied with `cp -cR` for each variant |
| Launch | MacSW's SOLIDWORKS environment (`WINEDEBUG=-all`, `WINE_MONO_AOT=none`, `MACSW_CROSS_PROCESS_SURFACES=1`, the VC++ DLL overrides), the same as `tools/sw_launch_experiment.sh`, on top of the harness's own environment (MacSW passes an allowlist instead) |
| Timer | `scripts/diagnostics/startup/startbench.py`: polls every 0.25 s from macOS (`ps`, the CGWindowList lister `wins`); records the SLDWORKS.exe process, the splash, the main frame (window of SLDWORKS.exe with the long product title), CPU time of every bottle process, and per-thread CPU and priority (`ps -M`) |
| Activation | The clone shows "SOLIDWORKS Product Activation" (`swactwiz.exe /expirycheck`) at 5-8 s. The script checks the two radio buttons with `wtool`, selects "activate later" and posts "Finish". The time the dialog is on screen (1.2-1.4 s) is subtracted (`main_net_s`). Licensing data was not read or changed. |
| A/B | `ab.sh`: arms interleaved (A B C A B C ...), at least 4 runs per arm, a run starts only when the 1-minute load is below 9; runs that fail (see below) are repeated |
| Metrics | `main_net_s` (launch to main frame, minus the dialog); SLDWORKS.exe CPU seconds at the main frame; wineserver CPU seconds at the main frame. The CPU values hardly depend on machine load; the wineserver CPU time is a direct measure of the number of requests. |
| Load | The Mac was busy during all runs: load average 5-9 (Spotlight, other agents' Wine builds and SOLIDWORKS instances, the real bottle's SOLIDWORKS at 94 % CPU). Wall-clock times vary by about ±15 %. |

Tracing and sampling:

- `WINEDEBUG=+server` with stderr piped through a time-stamper (`TSPIPE=1`), one run: 2.25 M lines, 409 MB.
  `srvtrace.py` sums the requests per thread, type and time, and finds the longest waits.
- `/usr/bin/sample` of SLDWORKS.exe and the wineserver (10 ms interval). Under Rosetta the unwinder cannot
  walk PE frames (stacks loop in `__wine_syscall_dispatcher`), but the Unix-side frames below the dispatcher
  are correct. `samplemods.py --syscalls` sums the leaf samples by the Nt* function that the thread is in.
- `WINEDEBUG=+timestamp,+loaddll,+pid` for the DLL load timeline.

Tracing and sampling slow SOLIDWORKS down by 1.5-2x and change one wait (section 5.1). All timings in
sections 4-6 come from runs without tracing or sampling.

Invalid runs (not counted, repeated): 3 runs where the window server reported scaled window sizes (the main
frame was not recognised), 4 runs where the activation tool showed "Failed to obtain a computer identifier"
instead of the wizard (at load 16-19; not answered, SOLIDWORKS was stopped), 1 run where SLDWORKS.exe exited
after a small "SOLIDWORKS Design" message box (load 6.3, no screenshot). They occurred in all arms.

## 2. Time line of one start (clone bottle, before the patches)

| Time (s) | Event |
|---|---|
| 0.3 | SLDWORKS.exe exists (the loader `exec`s it); the wineserver starts with it |
| 0.4-2.0 | `wineboot --init`, `services.exe`, `winedevice.exe`, `FNPLicensingService64.exe`, `plugplay.exe`, `svchost.exe`, `explorer.exe /desktop` |
| 3.4-3.8 | `rpcss.exe`; `sldProcMon.exe` (SOLIDWORKS Resource Monitor) |
| 3.3-5.4 | splash window |
| 5.3-7.9 | `swactwiz.exe /expirycheck` (clone only), answered in 1.2-1.4 s |
| 9-18 | module-list walks of `sldProcMon.exe` and of the own process; WIC lookups; first WPF assemblies at 13 s |
| 14-20 | `sldsurfacing.exe -Embedding` (out-of-process COM server) |
| 28-34 | main frame |

SLDWORKS.exe loads 392 DLLs (`+loaddll`). Its main thread used 17 s of CPU in a 31 s start; the per-thread
poll shows no long pause of the main thread in untraced runs: it alternates between running and short
waits for the wineserver.

## 3. Where the time goes

### 3.1 Wineserver requests of the main thread (traced run, up to the main window)

About 920,000 requests (the trace has one line for the request and one for the reply):

| Share | Requests | What |
|---|---|---|
| 39 % | 358,000 | WIC component lookups: `enum_key` on `CLSID\{7ED96837-...}\Instance` (decoders) and `CLSID\{05AF94D8-...}\Instance` (metadata readers) 297,843; opens of `CLSID`, the category key and `Instance` 21,000 each; `ContainerFormat` / `MetadataFormat` reads 78,000 |
| 24 % | 224,000 | module-list walks: `read_process_memory` 219,142 (129,572 on a `DuplicateHandle` of the own process, 89,570 on `sldProcMon.exe`) and `get_process_info` 5,041 |
| 13 % | 122,000 | other registry (SOLIDWORKS settings) |
| 11 % | 98,000 | `close_handle` (most of them for the keys above) |
| 6 % | 58,000 | windows and user32 (window tree, regions, redraw) |
| 4.5 % | 41,000 | synchronisation (`select`, `release_mutex`: 19,447 mutex releases) |
| 1.4 % | 13,000 | files and mappings |

Per decode, Wine's `ImagingFactory_CreateDecoder()` calls `CreateComponentEnumerator(WICDecoder)`, which opens
`CLSID`, the category and `Instance` keys and enumerates all 8 decoders, and then reads `ContainerFormat` of
each decoder from the registry. The metadata-reader lookup of each frame does the same for 16 readers. The
component objects themselves were already cached by Wine (`component_info_cache`). SOLIDWORKS made about 8,100
decoder and 12,900 metadata-reader enumerations before its main window.

The psapi functions (`EnumProcessModules`, `GetModuleBaseNameW`, `GetModuleFileNameExW`,
`GetModuleInformation`) walk the loader list of the target process from its start with one
`ReadProcessMemory()` per entry. SOLIDWORKS calls them for every module (about 400), so the walks are
quadratic. Wine's `NtReadVirtualMemory()` copies locally only for the `GetCurrentProcess()` pseudo handle.

### 3.2 CPU samples (clean sampled run, 10 ms, main thread, 40 s)

| Share | What |
|---|---|
| 37 % | waiting for a wineserver reply (`server_call_unlocked`, `wait_select_reply`) |
| 25 % | translated user code (SOLIDWORKS, Wine PE code, Mono JIT code) and the Rosetta runtime |
| 16 % | registry calls (`enumerate_key`, `NtOpenKeyEx`, `NtQueryValueKey`, `NtClose`) |
| 8 % | `NtReadVirtualMemory` |
| 10 % | win32u (windows, painting, fonts) |

The wineserver itself was busy only 8 % of the time (288 of 3524 samples in `thread_poll_event`), most of
it in the socket system calls of the request round trip. The cost is the round trip, not the work in the
server: about 15-20 us per request under Rosetta (`docs/performance-tuning.md` §3.5: 17.9 us for
`WaitForSingleObject(h, 0)`).

### 3.3 Items checked and not on the critical path

| Item | Finding |
|---|---|
| Network | 12 `send_socket` / 18 `recv_socket` requests in the whole start. No DNS, HTTP or licence-server timeout on the main thread. The only timed-out waits of the main thread were the COM poll below and the traced-run artifact of section 5.1. |
| COM local server | Wine's `rpc_get_local_class_object()` (combase) checks rpcss once per second. `sldsurfacing.exe -Embedding` registered its class 0.7 s after it was started, the main thread noticed it 0.3 s later. Cost: up to 1 s per start, about 0.3 s measured. Not changed (follow-up: poll every 100 ms). |
| Add-ins | The clone loads Autotrace, Design Checker, TolAnalyst and ScanTo3D at start: 0.9 s together by SOLIDWORKS's `SolidWorksPerformance.log`. The real bottle loads none (`docs/acceptance-2026-10-24.md`). |
| .NET / Wine-Mono | 21 managed assemblies are opened (WPF: PresentationFramework, PresentationCore, WindowsBase, System.Xaml ...) from 13 s. Mono runs JIT (`WINE_MONO_AOT=none`); Wine-Mono 11.3.0 has no AOT images. |
| WMI | SOLIDWORKS's resource-monitor thread runs its WMI queries at idle priority, off the critical path (section 5.1). Patch 0028 removes its busy loop. |
| Fonts | No separate hot spot. Wine keeps its font cache in the registry. |
| Rosetta JIT | Wine's PE DLLs and SOLIDWORKS's DLLs are not Mach-O files, so Rosetta translates their code at run time in every start (the "Rosetta JIT" leaf share in the samples). This cannot be cached. |

## 4. Fix and result

### 4.1 Patches

- **0032 `windowscodecs`: cache the component registry** (`MACSW_WIC_COMPONENT_CACHE=1`). The first
  `CreateComponentEnumerator()` reads the CLSID lists of all six categories and keeps them for the life of the
  process; `ComponentInfo_GetGUIDValue()` keeps the GUID values of a component (`ContainerFormat`,
  `MetadataFormat`, `Vendor` ...). The enumeration result and the per-category error handling are the same as
  before. A codec registered after the first enumeration is seen only after a restart (codecs are registered
  by installers).
- **0033 `kernelbase`: read the own module list locally** (`MACSW_LOCAL_MODULE_READS=1`).
  `init_module_iterator()` reads the first pointer of a walk (LdrData from the PEB) through the caller's
  handle, so the server checks `PROCESS_VM_READ` as before; then it uses the pseudo handle when the process
  id of the handle is our own. One round trip per walk instead of one per list entry. Other processes still
  go through the server. (The first version switched to the pseudo handle before that read; see "Review".)

Both ship as x86_64 DLLs only (SOLIDWORKS is 64-bit). `build_winemac.sh` applies them after 0028 and builds
`windowscodecs.dll` and `kernelbase.dll`; `package_app.sh` copies them and records
`WineWICCachePatchSHA256`, `WineWindowsCodecsModuleSHA256`, `WineLocalModuleReadsPatchSHA256` and
`WineKernelBaseModuleSHA256`; `verify_app.sh` checks them. Without the variables both DLLs behave like stock
Wine.

### 4.2 Function checks

- `scripts/diagnostics/wic_component_cache_probe.c`: lists all WIC decoders, encoders, converters and metadata
  readers with their formats, decodes a 2x1 PNG with tEXt and gAMA chunks (size, pixel format, metadata,
  pixels), then times 2,000 decodes. The output is byte-identical with the cache off and on (2 runs each).
  Time per decode: 904-986 us off, 18 us on.
- `scripts/diagnostics/local_module_reads_probe.c` (first pass): lists the own modules (29) through the pseudo
  handle and through a `DuplicateHandle` with all four psapi functions; the lists are identical in both modes,
  and the module list of a child process still works. One full listing: 22-25 ms off, 4.2-4.3 ms on.
  The second pass extended this probe (handles with fewer rights, other processes, threads) and added
  `wic_cache_staleness_probe.c`; the results are in "Review".
- SOLIDWORKS: see "Review", SOLIDWORKS check.

### 4.3 Start-up A/B (interleaved, same runtime, only the variables differ)

Runtime `rt-opt` (stock runtime + the patched `windowscodecs.dll` and `kernelbase.dll`). Median [min-max]
of 4 runs per arm, 15:28-15:40, load 7.1-8.8:

| Arm | Launch to main frame (s) | SLDWORKS.exe CPU (s) | wineserver CPU (s) |
|---|---|---|---|
| both off | 32.66 [30.61-39.76] | 23.06 [22.94-23.97] | 6.71 [6.52-6.89] |
| `MACSW_WIC_COMPONENT_CACHE=1` | 26.09 [23.83-34.80] | 19.55 [18.82-21.93] | 4.05 [3.75-4.22] |
| both on | **24.21 [21.29-26.23]** | 19.05 [17.39-19.96] | **2.51 [2.38-2.77]** |

An earlier interleaved set with the WIC patch alone (runtime `rt-wic`, 12:51-15:21, load 5-8) gave 33.9 s
(5 runs) off and 26.6 s (4 runs) on.

The second pass repeated this with the fixed 0033, different runtimes for the two arms (stock vs patched
DLLs, both with the variables set) and the unstripped DLLs: -30 % (section "Review", re-measurement).

## 5. Levers tested without a gain

### 5.1 Thread priority of idle threads (wineserver QoS mapping)

In the traced run, the main thread waited 10.0 s (timeout) for an event. The chain: at 19.9 s SOLIDWORKS
creates a resource-monitor thread, sets it to `THREAD_PRIORITY_IDLE` and resumes it; the thread then made no
request until 37.2 s, did its first WMI queries (`CLSID\{4590F811-...}`, WbemLocator) and set the event at
42.7 s; the main thread had waited from 31.3 s and gave up at 41.3 s. On macOS the wineserver maps
IDLE/LOWEST to `THROUGHPUT_QOS_TIER_5` and Mach importance -31 (priority 0), so on a loaded Mac the thread
starves.

This wait does **not** occur in normal runs: the per-thread poll of untraced runs shows no pause of the main
thread, and the idle thread starts at 14-20 s and finishes in time. It appears when SOLIDWORKS is slowed down
(tracing, sampling, a very busy Mac).

A wineserver variant that maps IDLE/LOWEST to `THROUGHPUT_QOS_TIER_2` (utility) was tested in 3+1
interleaved runs: 33.7 s and 35.2 s vs 30.7 s and 30.1 s for the base, with more SLDWORKS.exe CPU (24.5 s
vs 22.5 s) and wineserver CPU (7.7 s vs 6.4 s), because the monitor thread then does its WMI work during
the start. Rejected; not shipped. The importance -31 (priority 0) was not changed in that variant.

### 5.2 Mono

- `WINE_MONO_AOT=interp` (Mono interpreter instead of the JIT), with both patches on: SOLIDWORKS answered the
  activation dialog and then stopped: its CPU time stayed at 10.3 s from 45 s to the 240 s limit, no main
  window (1 run at 15:44, load 11.7). This agrees with MacSW's rule `none` (JIT) for SOLIDWORKS (`docs/recipe.md`).
- Mono AOT images: Wine-Mono 11.3.0 ships none, and MacSW cannot build them on the Mac
  (`docs/mono-decision.md`). With `WINE_MONO_AOT` unset, Mono behaves like `none` when no images exist
  (`docs/performance-tuning.md` §3.4).
- `MONO_ENV_OPTIONS=--llvm`: Wine-Mono is not built with LLVM. Not tested.
- The managed part of the start (WPF assemblies from 13 s) is not a separate hot spot in the samples.

### 5.3 msync

Not re-tested in this work. `docs/acceptance-2026-10-24.md` (section Performance, real bottle, 3 rounds) found
`WINEMSYNC=1` (patch 0017) neutral for SOLIDWORKS: start 22.8 s vs 24.5 s, inside the noise. It stays an
opt-in (`docs/msync.md`). msync removes the round trips of waits, which are 4.5 % of the requests before the
main window (section 3.1), so a large start-up gain is not expected from it.

### 5.4 SOLIDWORKS settings (from `docs/acceptance-2026-10-24.md`, real bottle)

The task-pane news feed and the Resource Monitor (`sldProcMon.exe`) were tested there: no gain. Start-up
add-ins are already off in the real bottle. No setting was changed by this work.

## 6. Rosetta: first start from a new runtime path

Rosetta translates the runtime's Mach-O files (`MacSW` loader, `ntdll.so`, `win32u.so`, `winemac.so`,
`wineserver` ...) ahead of time and caches the result in `/private/var/db/oah`. A runtime at a new path is
translated again, even when the files are APFS copies of a runtime that was used before:

| Runtime copy | First start: splash / main frame (s) | Later starts: splash / main frame (s) |
|---|---|---|
| `rt-wic` (new copy) | 26.7 / 56.7 | 3.3-4.0 / 24.7-36.1 |
| `rt-opt` (new copy) | 27.7 / 57.8 | 3.7-4.3 / 22.6-27.6 |

So the first start after MacSW.app is installed, updated or moved takes 20-25 s longer; later starts do not.
The PE DLLs (all of SOLIDWORKS and most of Wine) are not cached by Rosetta; their code is translated in every
start.

## 7. Files

| File | Purpose |
|---|---|
| `patches/wine-crossover/0032-windowscodecs-cache-component-registry.patch` | WIC component registry cache |
| `patches/wine-crossover/0033-kernelbase-local-module-reads.patch` | local module-list reads |
| `scripts/build_winemac.sh`, `scripts/package_app.sh`, `scripts/verify_app.sh` | build, package and verify the two DLLs |
| `macos/Bootstrap/Sources/MacSWCore/Services/WineService.swift`, `scripts/swcli/sw-cli`, `scripts/swcli/wine_runtime.py` | set the two variables for SOLIDWORKS |
| `scripts/tests/test_wine_startup_caches.py`, `scripts/tests/test_wine_runtime_upgrade.py`, `scripts/test_swcli_launcher.sh`, `macos/Bootstrap/Tests/MacSWCoreTests/RuntimeTests.swift` | wiring tests |
| `scripts/diagnostics/wic_component_cache_probe.c`, `scripts/diagnostics/local_module_reads_probe.c` | function checks and micro-benchmarks (the second extended in the review: access rights, other processes, threads) |
| `scripts/diagnostics/wic_cache_staleness_probe.c` | review: codec registered or removed while a process runs; 8 threads racing the first fill of the cache |
| `scripts/diagnostics/startup/` | `startbench.py` (one timed start in a clone bottle; refuses the real bottle), `ab.sh` (interleaved A/B), `summ.py` (medians), `srvtrace.py` (+server trace summary), `samplemods.py` (leaf profile of a `sample` report), `thr.py` / `thrtl.py` (per-thread timeline) |

Raw data: `build.nosync/startup/` (`starts.tsv`, one directory per run under `runs/`). Second pass:
`build.nosync/startup/v2/` (`starts.tsv`, `runs/`) and `build.nosync/startup/tests2/out/` (probe outputs).
