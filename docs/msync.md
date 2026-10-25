# msync for MacSW's Wine 11.16 (patch 0017) — STATUS: TESTED, RECOMMENDATION: OPT-IN

Date: 2026-10-23. Host: Apple M2 Pro, 16 GB, macOS 27.0, x86_64 Wine under Rosetta, on AC power.
Branch `msync` in worktree `wt-msync` (patch and build changes in commit a802ba8, merged into
`integrate` in 71f2236; the two defect fixes of section 4.6 in commit 56775ae, not yet merged).
Variant runtime: `runtime/wine-11.16-macsw-msync`.

## Summary

- **Build:** clean. Patch 0017 adds no compiler warnings. The rebuilt `wineserver` links
  `@rpath/libinotify.0.dylib` with rpath `@loader_path/../lib`, as the stock Gcenx server does.
  All modules are ad-hoc signed and pass `codesign --verify --strict`.
- **Always-on part is neutral.** With `WINEMSYNC` unset ("off"), the conformance results are
  identical to the stock runtime, and all 17 benchmark medians are within 0.86x-1.03x of stock.
- **With `WINEMSYNC=1`, sync calls are 3x-25x faster:** event ping-pong 30.6 -> 7.2 us,
  `WaitForSingleObject(h, 0)` 11.2 -> 0.43 us, uncontended mutex 20.6 -> 1.4 us, contended
  semaphore 19.3 -> 2.9 us per item. Thread create+join is 4-7 % slower. Critical sections,
  `Sleep(1)` and timed waits are unchanged.
- **Both known msync defects are fixed (section 4.6, commit 56775ae).** The upstream code had
  4 failing checks from 2 defects (section 4.3). Defect 1 was a hang: if the last handle of a
  mutex is closed while a thread waits on it, the waiter was never woken when the owner thread
  terminates or exits (it must get `WAIT_ABANDONED`). Defect 2: `NtReleaseMutant` returned a
  wrong previous count. After the fixes, msync has 0 failures in `ntdll:sync` and
  `kernel32:sync` in both runs, the same as stock, and the abandoned-mutex probe is 6/6 in both
  modes. Neither marzent/winecx nor CrossOver 26.3.0 has a fix for these defects.
- **Composes with patch 0016:** both apply cleanly, `ntdll.so` builds, and 0016 still releases
  `MEM_RESET` memory (519.7 MB -> 6.9 MB) with msync on.
- **Recommendation: opt-in.** Ship patch 0017 and the rebuilt server, keep msync off by default.
  msync is now safe to offer as an opt-in per-bottle setting; make it the default only after an
  A/B run with SOLIDWORKS itself (section 6).

## 1. Provenance and license

| Item | Value |
|---|---|
| Code used | `marzent/winecx`, branch `ff-wine-11.17`, commit `94044df08f091d9186e979e31bfccf6c41c7600f` "Add msync." (Marc-Aurel Zent, 2026-09-07), on top of upstream Wine 11.17 |
| Same code in | CodeWeavers CrossOver 26.0.0 and 26.3.0 FOSS sources (`crossover-sources-26.3.0.tar.gz`, 149,054,023 B, SHA-256 `ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872`, Last-Modified 2026-07-21; `sources/wine/VERSION` = Wine 11.0) |
| License | LGPL-2.1-or-later (new files: Copyright 2018 Zebediah Figura, 2023 Marc-Aurel Zent), same as Wine and the other MacSW patches |
| Older lineage | `marzent/wine-msync` (LGPL-2.1, patches for CX 22/23, wine-devel, wine-staging up to 9.15; last push 2024-08); `marzent/winecx` branch `MSYNC` (2023 initial implementation) |

Why this source: it is the newest msync (Sep 2026) and is based on Wine 11.17. The 15 Wine files it
touches are byte-identical in Wine 11.16 and 11.17, so it applies unchanged to Wine 11.16 + MacSW
0001-0015. CrossOver 26.3.0 is older (Wine 11.0 base) and its msync files are the same except in one
spot (see below).

Differences from the 11.17 commit (both from CrossOver 26.3.0):

* `server/msync.c` allocates the 64 MB thread-id map and the object pages with
  `mach_vm_map(..., VM_INHERIT_SHARE)` (CrossOver) instead of `mach_vm_allocate()` (11.17 commit).
  `msync_init_shm()` runs before `open_master_socket()` forks the wineserver daemon, so the map is
  created in the parent process; the shipped CrossOver code shares it explicitly. The 11.17
  `fatal_error()` check after the page allocation is kept.
* One trailing space removed.

Two MacSW fixes on top (commit 56775ae, section 4.6). They are not in the 11.17 commit, in
CrossOver 26.3.0, or in any other msync fork that we checked (marzent/wine-msync, WineAndAqua/wine,
PhoenicisOrg/winecx, gamesir-labs/wine): all have the same `msync_destroy()` and
`msync_abandon_mutexes()`.

* `dlls/ntdll/unix/msync.c`: `NtReleaseMutant` returns `1 - count` as the previous count.
* `server/msync.c`, `server/msync.h`: an owned mutex whose last handle is closed while a thread
  waits on it stays on the abandon list until the owner dies.

The patch number is 0017 because 0016 is used on branch `mem-release` (`wt-mem`); 0017 also applies on top of that 0016.

## 2. What changed

### 2.1 Patch 0017 (`MacSW/patches/wine-crossover/0017-ntdll-server-msync.patch`, branch `msync`)

15 files, +2,357/-8 lines. Wine 11.16 already has the "inproc sync" layer that upstream uses for
Linux ntsync (`dlls/ntdll/unix/sync.c`, `server/inproc_sync.c`); on macOS it was compiled out.
msync plugs into that layer:

* `server/msync.c`, `server/inproc_sync.c` (new `#elif defined(__APPLE__)` branch): each event,
  mutex, semaphore and each internal server sync (threads, processes, timers, file objects,
  message queues, completions, ...) gets a 16-byte slot in shared memory pages owned by
  wineserver. A Mach port `wine-<prefix-inode>-msync` is registered in the user's bootstrap
  namespace, and a high-priority message-pump thread handles shared-memory map requests,
  multi-object wait registration and object destruction.
* `dlls/ntdll/unix/msync.c` + `sync.c`: clients map those pages (via Mach memory entries), and
  Set/Reset/PulseEvent, ReleaseMutex/Semaphore, queries and waits work directly on the shared
  memory with atomics plus `__ulock_wait2`/`__ulock_wake` (single-object waits never talk to
  wineserver; multi-object and alertable waits send one Mach message to register, and are woken
  through a per-thread word in a 64 MB shared thread-id map).
* `loader.c`: `msync_init()` after `server_init_process()`.
* Protocol: `get_inproc_sync_fd` reply gets `shm_idx`; `SERVER_PROTOCOL_VERSION` 961 -> 962.

Gate: `WINEMSYNC=1` (any non-zero number), read once by wineserver and by every Wine process.
Without it, wineserver does not create inproc syncs, `get_inproc_device_fd()` returns -1, and all
waits take the normal wineserver path. The only always-on changes are: the protocol number, one
extra `get_inproc_alert_fd` server call per process start (the check that the server is not in
msync mode), and the rebuilt wineserver binary (section 2.2).

Server and clients must agree. A process without `WINEMSYNC` on an msync server prints
`Server is running with WINEMSYNC but this process is not` and exits; a process with
`WINEMSYNC=1` on a normal server fails `bootstrap_look_up` and exits. `wineserver -k` before
switching modes.

### 2.2 Build changes (`scripts/build_winemac.sh`, `package_app.sh`, `verify_app.sh`, `Makefile`)

* Applies 0017 after 0015 and adds its SHA-256 to the build key.
* Builds `server/wineserver` as an 8th target -> `dist/winemac-11.16/wineserver`
  (x86_64, ad-hoc signed, `codesign --verify` in the script). Because of the protocol bump, the
  stock Gcenx `bin/wineserver` can no longer be used with the patched `ntdll.so`;
  `package_app.sh` now installs the built server into `Wine/bin/wineserver` (and records
  `WineMsyncPatchSHA256` in BuildManifest.plist); `verify_app.sh` checks both.
* Inotify parity: the stock Gcenx server links `@rpath/libinotify.0.dylib` (directory change
  notifications, `server/change.c`). The script now configures `--with-inotify` with the
  libinotify-kqueue 20240724 header vendored in `third_party/libinotify-kqueue/` (MIT) and links
  the `libinotify.0.dylib` taken from the SHA-pinned runtime archive, then sets the install name
  to `@rpath/libinotify.0.dylib` and adds rpath `@loader_path/../lib`, as in the stock server.
  Only `server/change.c` uses inotify on macOS, so the other 7 targets are unaffected.
  `make winemac` now also depends on `fetch-runtime`.

## 3. Test and benchmark method

Scripts (sources only): `tools/perf-bench/msync/` — `build_tests.sh` (separate configure with tests
enabled; builds `ntdll_test.exe`, `kernel32_test.exe`, and the bench/probe programs with mingw),
`assemble_runtime.sh`, `smoke.sh`, `conformance.sh`, `bench.sh`, `sync2.c` (new msync-relevant
micro-benchmarks), `findwin.c` (Notepad window probe), `abandon.c` (abandoned-mutex probe, added
after the conformance run). Prefix: `build.nosync/prefix-msync`
(created for this test, created with `WINEMSYNC=1`, `WINEDLLOVERRIDES=mscoree,mshtml=`).

Modes, always with a `wineserver -k` between mode switches:

| Mode | Runtime | `WINEMSYNC` |
|---|---|---|
| stock | `runtime/wine-11.16-macsw` (Gcenx server, 15 patches) | unset |
| off | `runtime/wine-11.16-macsw-msync` (0001-0015 + 0017, rebuilt server) | unset |
| msync | `runtime/wine-11.16-macsw-msync` | `1` |

Bench programs: `tools/perf-bench/sync.c` (event ping-pong, `WaitForSingleObject(h, 0)` on an
unsignaled event, 4-thread contended critical section, `Sleep(1)`, thread create+join) and
`tools/perf-bench/msync/sync2.c` (SetEvent+ResetEvent, wait on a signaled event, uncontended mutex,
`WaitForMultipleObjects` / alertable / `SignalObjectAndWait` ping-pong, 4-thread contended mutex,
1 producer + 4 consumer semaphore, wait on thread handles, 2 ms timed wait). `mutex4_ok` and
`sem4_ok` check that no acquire or item was lost.

## 4. Results

Working files (gitignored): `wt-msync/build/msync-work/` (`bin/` test and bench executables,
`smoke.log`, `conf/`, `bench.txt`, `make-ntdll1617.log`), build log `wt-msync/build/msync-build.log`.

### 4.1 Build

| Check | Result |
|---|---|
| `build_winemac.sh` (0001-0015 + 0017, 8 targets, `MAKE_JOBS=4`) | rc 0. configure finds `sys/inotify.h` and `inotify_add_watch` |
| Compiler warnings | 47, the same list as the 0016 build without 0017 (`wt-mem/build/winemac-build-mem.log`): AppKit deprecations, 3 x `pipe2` availability, bison. None in `msync.c`, `inproc_sync.c` or `sync.c` |
| `dist/winemac-11.16/wineserver` | x86_64, links `@rpath/libinotify.0.dylib` + libSystem (same as stock), rpaths `@loader_path`, `@loader_path/../lib` |
| `assemble_runtime.sh` -> `runtime/wine-11.16-macsw-msync` | `codesign --verify --strict` passes for `winemac.so`, `win32u.so`, `ntdll.so`, `MacSW`, `bin/wineserver`, `bin/wine` |
| `build_tests.sh` | `ntdll_test.exe`, `kernel32_test.exe` (Wine 11.16 tests, with 0017 applied) and the bench programs build |

### 4.2 Smoke checks (`WINEMSYNC=1`, fresh prefix)

| Step | Result |
|---|---|
| `wineboot -u`, new prefix | rc 0, 51.4 s |
| `wineboot -u` again | rc 0, 7.4 s |
| `cmd /c ver` | rc 0, 0.35 s, `Microsoft Windows 10.0.19045` |
| Notepad: window found by `findwin.exe`, closed with `WM_CLOSE` | window `Untitled - Notepad`, visible; notepad exits rc 0 |
| Server log | `msync: bootstrapped mach port on wine-d175b7b-msync.` / `msync: up and running.` |

Proof that msync is really used, and how mode mismatches fail:

| Server | Client | Result |
|---|---|---|
| msync runtime, `WINEMSYNC=1` | `WINEMSYNC=1`, `WINEDEBUG=+sync` | rc 0; 14 `trace:sync:msync_close` lines (objects live in msync shared memory) |
| msync runtime, `WINEMSYNC=1` | `WINEMSYNC` unset | rc 1: `err:sync:msync_init Server is running with WINEMSYNC but this process is not` |
| msync runtime, `WINEMSYNC` unset | `WINEMSYNC=1` | rc 1: `err:sync:msync_init Failed bootstrap_look_up for wine-d175b7b-msync` |
| msync runtime, `WINEMSYNC` unset | `WINEMSYNC` unset | rc 0, `cmd /c ver` works |
| msync runtime (protocol 962), already running | stock runtime client (protocol 961) | rc 1: `wine client error:0: version mismatch 962/961` |

All mismatches fail at once with a clear message; none hangs. The last row needs the server to be
running already: in an earlier try with no server running, the stock client started a server of
its own and worked, so `WINESERVER` alone does not stop two runtimes from being mixed.

### 4.3 Wine conformance tests

`conformance.sh`: `ntdll:sync`, `ntdll:om`, `ntdll:thread`, `kernel32:sync`, `kernel32:thread`,
2 runs per mode, `WINETEST_PLATFORM=wine`. No timeouts and no crashes in any run.

| Test | stock (run 1 / 2) | off | msync |
|---|---|---|---|
| ntdll:sync (429 tests) | 0 / 0 failures | 0 / 0 | **2 / 2** |
| ntdll:om (7,736) | 0 / 0 | 0 / 0 | 0 / 0 |
| ntdll:thread (49) | 0 / 0 | 0 / 0 | 0 / 0 |
| kernel32:sync (~365,000) | 0 / 0 | 0 / 0 | **3 / 3** (2 failures + 1 todo that now succeeds) |
| kernel32:thread (927) | 4 / 4 | 4 / 4 | 4 / 4 |

The 4 `kernel32:thread` failures (`thread.c:2057/2058/2068/2069`, FPU control word) are the same
in all modes, including stock. **off = stock**, test by test.

The failures that only occur with msync (identical in both runs, so not flaky):

| Test line | What fails | Cause |
|---|---|---|
| `ntdll/tests/sync.c:428`, `:433` | `NtReleaseMutant` previous count: expected -1 and 0, got 2 and 1 | `msync_release_mutex_obj()` returns `mutex->count` where Windows returns `1 - count` (its own query function already uses `1 - count`). Only callers that read the previous count of `NtReleaseMutant` see it; `ReleaseMutex()` passes NULL. One-line fix; fixed in commit 56775ae (section 4.6). |
| `kernel32/tests/sync.c:393`, `:397` | Thread A owns a mutex, thread B waits on it, the main thread closes the mutex handle, then terminates A. B must wake with `WAIT_ABANDONED`; with msync B stays blocked (0x102 after 1 s, and B does not exit). | Separate probe (`tools/perf-bench/msync/abandon.c`, 6 cases, owner blocked while B waits): B hangs when the **last** handle is closed, whether the owner is terminated or returns normally while it owns the mutex. When the handle stays open, or a duplicate handle stays open, B wakes with `WAIT_ABANDONED` (0x80). Without msync all 6 cases are correct. Cause (confirmed) and fix: section 4.6. For events and semaphores the same case cannot be seen (nobody can signal an object with no handle). |
| `kernel32/tests/sync.c:1067` | "Test succeeded inside todo block" (timer queue callback count) | Not a regression: msync passes a check that is marked as a known Wine failure. |

`kernel32:sync` takes 10.4 s with msync against 8.5 s without; the difference is the two 1 s
timeouts of the hang case above.

These results are for the upstream code. Section 4.6 has the results after the two fixes.

### 4.4 Benchmarks

`bench.sh`, 5 rounds, interleaved (odd rounds stock -> off -> msync, even rounds the reverse),
`wineserver -k` and a warm-up `nop.exe` before each mode. Median of 5 (min-max in brackets).
Lower is better. Load average during the run: 3.8-6.9 (the other session's work and Spotlight
`mds_stores` at about 100 % of one core); the interleaving spreads that over all modes.

| Metric | stock | off | msync | off/stock | msync/stock |
|---|---|---|---|---|---|
| Event ping-pong, us/round trip | 30.62 (29.1-51.4) | 31.56 (30.7-53.3) | **7.17** (6.75-14.1) | 1.03x | **0.23x** |
| `WaitForSingleObject(h,0)`, unsignaled, us | 11.23 (11.0-16.6) | 10.97 (10.8-16.5) | **0.43** (0.42-0.50) | 0.98x | **0.04x** |
| `WaitForSingleObject(h,0)`, signaled, us | 10.74 (10.1-17.8) | 10.79 (10.7-14.5) | **0.43** (0.42-0.52) | 1.00x | **0.04x** |
| SetEvent+ResetEvent, us/pair | 19.44 (18.0-35.1) | 18.78 (17.6-28.2) | **1.37** (1.35-1.72) | 0.97x | **0.07x** |
| Uncontended mutex wait+release, us | 20.59 (20.3-31.9) | 20.49 (20.1-31.9) | **1.40** (1.39-1.67) | 1.00x | **0.07x** |
| `WaitForMultipleObjects` ping-pong, us | 30.58 (30.2-44.4) | 31.23 (30.1-49.3) | **3.84** (2.86-18.2) | 1.02x | **0.13x** |
| Alertable wait ping-pong, us | 36.07 (29.8-46.8) | 30.96 (30.6-47.6) | **12.58** (5.84-47.2) | 0.86x | **0.35x** |
| `SignalObjectAndWait` ping-pong, us | 32.27 (27.9-44.7) | 28.65 (28.0-42.1) | **8.06** (6.74-13.6) | 0.89x | **0.25x** |
| 4-thread contended mutex, us/acquire | 18.80 (18.0-24.5) | 18.65 (16.4-24.8) | **1.41** (1.36-2.00) | 0.99x | **0.07x** |
| Semaphore, 1 producer / 4 consumers, us/item | 19.28 (19.0-31.6) | 19.26 (18.8-28.3) | **2.88** (2.82-3.94) | 1.00x | **0.15x** |
| 4-thread critical section, 800k enters, ms | 105.4 (55.8-107.9) | 101.5 (57.1-107.9) | 104.4 (75.6-106.9) | 0.96x | 0.99x |
| `Sleep(1)`, ms | 1.254 | 1.255 | 1.256 | 1.00x | 1.00x |
| 2 ms timed wait, ms | 2.271 | 2.271 | 2.255 | 1.00x | 0.99x |
| Thread create+join, us | 212.1 (200-411) | 205.9 (201-295) | 226.3 (219-375) | 0.97x | **1.07x** |
| Wait on thread handles (create+join), us | 197.6 (192-395) | 193.8 (192-318) | 204.6 (196-285) | 0.98x | **1.04x** |
| `mutex4_ok`, `sem4_ok` | 1 in all 5 rounds | 1 in all 5 | 1 in all 5 | | |

Reading the numbers:

* Every call that used to be a wineserver round trip (about 11 us per call under Rosetta) becomes
  a shared-memory atomic (about 0.4 us). Waits that block still need a `__ulock_wait2` and a
  context switch, so ping-pong gains are 3x-8x instead of 25x.
* Critical sections do not change: they do not wait on Win32 sync objects (uncontended ones never
  leave the process, contended ones use Wine's address-wait path), so msync does not touch them.
* Thread creation costs 4-7 % more with msync. A likely cause (not profiled): with msync the server
  creates an msync object for each new thread and process, and each thread registers in the
  thread-id map.
* off vs stock is within the noise; the two values below 0.9x (alertable and `SignalObjectAndWait`
  ping-pong, both faster in "off") have wide, overlapping ranges.

### 4.5 Composition with patch 0016 (`mem-release`, `wt-mem`)

Scratch build: the msync source tree (0001-0015 + 0017) + `0016-ntdll-macos-release-decommitted-memory.patch`.

| Check | Result |
|---|---|
| `git apply --check` / `git apply` of 0016 on top of 0017 | clean (0016 changes only `dlls/ntdll/unix/virtual.c`; 0017 does not touch it). Before this session, 0017 was also checked to apply on top of 0016 |
| `make dlls/ntdll/ntdll.so` (test-build configuration) | rc 0; only the 3 known `pipe2` warnings; `msync_init` present |
| `memchurn.exe op reset` (512 MB, `WINEMSYNC=1`, scratch runtime = msync runtime + this `ntdll.so`) | physical footprint 519.7 MB -> **6.9 MB** (0016 works) |
| `memchurn.exe check` (`WINEMSYNC=1`) | 14/14 PASS |
| `sync2.exe` (`WINEMSYNC=1`, one run) | msync-speed results (mutex 2.2 us, semaphore 4.5 us/item), `mutex4_ok 1`, `sem4_ok 1` |
| `cmd /c ver` | works |

The two patches are independent and can be shipped together. The order in `build_winemac.sh` should
be 0015, 0016, 0017.

### 4.6 Defect fixes (commit 56775ae) and results after the fixes

Date: 2026-10-23, late evening, on battery (86-93 %). Both fixes are in patch 0017 (its header
lists them).

**Fix 1, `NtReleaseMutant` previous count** (`dlls/ntdll/unix/msync.c`,
`msync_release_mutex_obj()`): `*prev_count = 1 - mutex->count;` instead of `mutex->count`, the
same formula as `msync_query_mutex_obj()` and Windows.

**Fix 2, abandoned-mutex hang** (`server/msync.c`, `server/msync.h`). Cause: with msync a
single-object wait is done in the client with `__ulock_wait2`; the waiter holds no reference to the
server object. When the last handle closes, `inproc_sync_destroy()` -> `msync_destroy()` removes the
mutex from `mutex_list` and frees it. When the owner thread then dies, `msync_abandon_mutexes()`
walks `mutex_list`, does not find the mutex, and so does not set it abandoned or wake the waiter.
The shared-memory slot itself stays valid, because the waiting client still holds its own slot
reference (the client cache in `dlls/ntdll/unix/sync.c` defers `msync_close()` until the wait
ends). Without msync the server-side wait holds a reference to the mutex object, so the problem
does not occur. The fix (about 25 lines):

* `msync_destroy()`: if the mutex is owned (`tid` is not 0 and not `~0`) and a client still holds a
  slot reference (`refcount > 1`), mark it `orphaned` and keep it on `mutex_list`, with the
  server's slot reference. Otherwise destroy it as before.
* `msync_abandon_mutexes()`: uses `LIST_FOR_EACH_ENTRY_SAFE`. It abandons owned mutexes as before;
  then it frees each orphaned mutex that no client references any more (`refcount <= 1`). So an
  orphan lives until the first thread exit after its last waiter is done. Because the server keeps
  its slot reference until then, the slot cannot be reused while it is on the list.

Rebuild: `build_winemac.sh` rc 0 (86 s), the same 47 warnings as before, none in the msync files.
All 7 modules and `wineserver` from this build were copied into `runtime/wine-11.16-macsw-msync`
(`assemble_runtime.sh` steps; it refuses an existing runtime), ad-hoc signed, and pass
`codesign --verify --strict`. `wineserver` links `@rpath/libinotify.0.dylib`, rpaths
`@loader_path`, `@loader_path/../lib`. The test executables are unchanged (PE code, not affected).

Abandoned-mutex probe (`abandon.exe`, a scratch prefix, the same prefix before and after):

| Case | off, before | msync, before | off, after | msync, after |
|---|---|---|---|---|
| terminate owner, handle kept | 0x80 | 0x80 | 0x80 | 0x80 |
| terminate owner, last handle closed | 0x80 | **blocked** | 0x80 | **0x80** |
| owner exits, handle kept | 0x80 | 0x80 | 0x80 | 0x80 |
| owner exits, last handle closed | 0x80 | **blocked** | 0x80 | **0x80** |
| terminate owner, handle closed, duplicate kept | 0x80 | 0x80 | 0x80 | 0x80 |
| owner exits, handle closed, duplicate kept | 0x80 | 0x80 | 0x80 | 0x80 |

Smoke checks (`smoke.sh`, `WINEMSYNC=1`, fresh `build.nosync/prefix-msync`): `wineboot -u` new
prefix rc 0, again rc 0, `cmd /c ver` rc 0 (`Microsoft Windows 10.0.19045`), Notepad window found
by `findwin.exe` (`Untitled - Notepad`, visible) and closed with `WM_CLOSE` (rc 0), server log
`msync: bootstrapped mach port ...` / `msync: up and running.`

Conformance (`conformance.sh`, 2 runs per mode, failures per run):

| Test | stock | off | msync before fixes | msync after fixes |
|---|---|---|---|---|
| ntdll:sync | 0 / 0 | 0 / 0 | 2 / 2 | **0 / 0** |
| ntdll:om | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| ntdll:thread | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| kernel32:sync | 0 / 0 | 0 / 0 | 3 / 3 | **1 / 0** |
| kernel32:thread | 4 / 4 | 4 / 4 | 4 / 4 | 4 / 4 |

The one `kernel32:sync` "failure" after the fixes (run 1 only) is `sync.c:1067` "Test succeeded
inside todo block" (timer queue callback count): a timing-dependent known Wine failure that
sometimes passes; it is not a regression. `sync.c:393` and `:397` (abandoned mutex) and
`ntdll/tests/sync.c:428` and `:433` (previous count) now pass in both runs. The 4
`kernel32:thread` failures are the FPU control-word checks that also fail with stock. No test
timed out or crashed, and no server log has an `msync: error` line.

Run times in this session are not comparable with section 4.3: Spotlight (`mds_stores`, about
95 % CPU) indexed the disk and the Mac was on battery, so `kernel32:sync` took 9-253 s in all
three modes (stock 44 s and 70 s). The test counts and failures do not depend on this. The
benchmarks of section 4.4 were not run again; the fixes do not change any fast path (fix 1 is
one subtraction; fix 2 runs only when a mutex is destroyed and at thread exit).

## 5. Risks

* **Correctness gaps:** the two measured defects (abandoned-mutex hang, `NtReleaseMutant`
  previous count) are fixed (section 4.6). Known from the code and not fixed: `PulseEvent` is
  best-effort, and a wait-all may hold objects for a short time before it gives them back. A
  program that depends on these cases can act differently with msync on.
* **MacSW now differs from upstream msync** (the two fixes). When CrossOver or marzent/winecx
  update msync, the fixes must be carried forward or dropped if upstream fixes the same defects.
* **Server and clients must agree** on `WINEMSYNC`. A mismatch fails at once (section 4.2), so the
  launcher must set the variable for every Wine process, including `wineboot`, helper tools and
  anything started from Terminal, and must run `wineserver -k` when it changes the mode.
* **Private Apple APIs:** `__ulock_wait2`, `__ulock_wake`, `mach_msg2_trap`, `bootstrap_register2`.
  They work on macOS 27.0 under Rosetta today; a macOS update can change them. CrossOver ships the
  same code, which lowers this risk, but MacSW would have to follow CrossOver's fixes.
* **Bootstrap namespace:** the Mach port `wine-<prefix inode>-msync` is registered in the user's
  bootstrap namespace. Processes started from a different namespace (for example over ssh) may
  not find it.
* **Memory:** 64 MB of virtual address space per process for the thread-id map (shared, mostly
  not touched), plus the shared object pages.
* **Always-on change (also when msync is off):** the protocol is 962, so the runtime must use the
  rebuilt `wineserver` and no longer Gcenx's. The off-mode tests show no difference from stock,
  but the server binary is now built by MacSW and must be kept in step with `ntdll.so`.
* **Not yet tested with SOLIDWORKS.** All numbers here come from micro-benchmarks and Wine's own
  tests. How much SOLIDWORKS waits on Win32 sync objects (and so how much it gains) is unknown.

## 6. Recommendation: opt-in

1. **Merge patch 0017 and the server build** (branch `msync`). The always-on part is neutral:
   off-mode conformance is identical to stock, and the benchmarks are within noise. 0016 and 0017
   compose. If 0016 is merged first, keep the patch order 0015 -> 0016 -> 0017 in
   `build_winemac.sh`.
2. **Keep `WINEMSYNC` unset by default.** Do not adopt msync as the default yet: it is not
   tested with SOLIDWORKS, `PulseEvent` and wait-all are approximations, and it depends on private
   Apple APIs. The 2 measured defects are fixed (section 4.6); with the fixes, the Wine
   conformance results with msync are the same as stock.
3. **Make it a per-bottle opt-in** (a setting that the launcher turns into `WINEMSYNC=1` for every
   Wine process of that bottle, with `wineserver -k` on change), and do an A/B run with
   SOLIDWORKS: start-up time, opening and rebuilding a large assembly, and a 30-minute session
   with no hangs. If SOLIDWORKS gains clearly and shows no hang, make it the default for new
   bottles.
4. Done (commit 56775ae): the `NtReleaseMutant` previous count and the last-handle-closed
   abandoned-mutex case are fixed, and `conformance.sh`, `abandon.exe` and `smoke.sh` were run
   again (section 4.6). Re-merge branch `msync` into `integrate` to get the fixes there.

Reject is not justified: the gains are large and the risk is controlled by the opt-in switch.
