# Mono upstream PR

Repository: `wine-mono/mono` (the runtime, not the packaging repository).
Base branch: `main`.
Submitted PR: [wine-mono/mono#35](https://github.com/wine-mono/mono/pull/35).

## Title

[interp] Honor stdcall in the x86 Windows fast native call path

## Body

### Summary

The interpreter's fast native call path invokes function pointers using C
calling-convention typedefs. On x86 Windows, a stdcall callee removes its
arguments from the stack, but the C call site also adjusts the stack. This
can corrupt the caller's stack and cause a native crash.

This was initially investigated under Wine on macOS/Apple Silicon, then
reproduced independently under Wine on x86_64 Linux, without Rosetta or any
commercial application. The scope is the Windows x86 interpreter ABI path;
this is not a claim that every Mono platform is affected.

### Discovery context: SOLIDWORKS installation

This was discovered during SOLIDWORKS 2025 SP05 installation under Wine on
macOS/Apple Silicon. Its `UpdateBrowserData` MSI action launches a 32-bit
managed database helper and waits for it synchronously, so a failure in
that helper can leave the 64-bit product's installation waiting.

Using the interpreter to work around a separate x86 JIT startup hang
exposed a crash during WinForms initialization, through
`Application.EnableVisualStyles` and `CreateActCtxW`. This was reduced to
the standalone P/Invoke reproducer below and reproduced on Linux without
SOLIDWORKS or its data files.

With the fix, the database action completed and a subsequent installation
reached `SetupCompleteSuccess`. This is supporting application-level
evidence; the independent reproducer and regression test establish the
runtime defect and fix, not full SOLIDWORKS compatibility.

### Implementation

- Add stdcall dispatch for the simple signatures already supported by the
  fast native call path, guarded by `HOST_WIN32 && TARGET_X86`.
- Resolve default Winapi signatures for external P/Invoke wrappers without
  globally treating internal default C signatures as stdcall.
- Keep normalized signature copies alive after interpreter transformation:
  they are stored in runtime `data_items`, so a transform-local allocation
  would be invalid after the transform pool is destroyed.
- Preserve the shared last-error and return-value conversion handling.
- Add `test_0_native_pointer_call_conventions` to `pinvoke2.cs` and matching
  native functions to `libtest.c`. The test interleaves cdecl, explicit
  stdcall, and default Winapi pointer calls 256 times.

The signature-lifetime issue was introduced during development of this
patch, not found in the unmodified release; it is not a separate upstream bug.

### Minimal standalone reproducer

Save as `NativeBridge.c`:

```c
#include <windows.h>

__declspec(dllexport) HANDLE __cdecl bridge_cdecl(void *context)
{
    return CreateActCtxW((PCACTCTXW)context);
}

__declspec(dllexport) HANDLE __stdcall bridge_stdcall(void *context)
{
    return CreateActCtxW((PCACTCTXW)context);
}
```

Save as `NativeBridgeProbe.cs`:

```csharp
using System;
using System.Runtime.InteropServices;

class NativeBridgeProbe
{
    [DllImport("NativeBridge.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr bridge_cdecl(IntPtr context);

    [DllImport("NativeBridge.dll", CallingConvention = CallingConvention.StdCall)]
    static extern IntPtr bridge_stdcall(IntPtr context);

    static void Main(string[] args)
    {
        bool stdcall = args.Length > 0 && args[0] == "stdcall";
        Console.WriteLine("Bridge=" + (stdcall ? "stdcall" : "cdecl"));
        Console.Out.Flush();
        IntPtr value = stdcall ? bridge_stdcall(IntPtr.Zero) : bridge_cdecl(IntPtr.Zero);
        Console.WriteLine("RESULT=" + value);
    }
}
```

Both native wrappers call the same API with the same invalid input and
should return `INVALID_HANDLE_VALUE` (`-1`). This intentionally tests the
call boundary; it does not require an activation-context manifest.

On Debian/Ubuntu with Wine's i386 support, MinGW-w64, Mono's C# compiler,
Xvfb, xauth, curl and xz installed:

```sh
i686-w64-mingw32-gcc -shared -O2 -Wl,--kill-at \
    -o NativeBridge.dll NativeBridge.c
mcs -platform:x86 -out:NativeBridgeProbe.exe NativeBridgeProbe.cs
```

These commands compile only the reproducer, not Mono. The original local
bridge matrix used the same C# source compiled with Wine-Mono's `csc`; the
upstream CI regression described below is compiled with `mcs`.

Download the official runtime into a new work directory containing the two
compiled reproducer files:

```sh
curl -fL https://github.com/wine-mono/wine-mono/releases/download/wine-mono-11.3.0/wine-mono-11.3.0-x86.tar.xz \
    -o runtime.tar.xz
mkdir runtime
tar -xf runtime.tar.xz -C runtime
```

Save as `reproduce.sh`, then run `xvfb-run -a bash reproduce.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
export WINEPREFIX="$PWD/repro-prefix"
export WINEDEBUG=-all
mkdir -p logs
runtime=$(dirname "$(dirname "$(find "$PWD/runtime" -name libmono-2.0-x86.dll -print -quit)")")
test -f "$runtime/lib/mono/4.5/mscorlib.dll"
WINEDLLOVERRIDES='mscoree,mshtml=' timeout -k 5 120 wine wineboot -u
wine reg add 'HKCU\Software\Wine\Mono' /v RuntimePath /t REG_SZ \
    /d "$(winepath -w "$runtime")" /f
sha256sum "$runtime/bin/libmono-2.0-x86.dll"
for mode in interp none; do
    export WINE_MONO_AOT="$mode"
    for convention in cdecl stdcall; do
        set +e
        timeout -k 5 60 wine "$PWD/NativeBridgeProbe.exe" "$convention" \
            > "logs/$mode-$convention.log" 2>&1
        result=$?
        set -e
        echo "$mode $convention exit=$result"
        cat "logs/$mode-$convention.log"
        wineserver -k || true
        wineserver -w
    done
done
```

`WINE_MONO_AOT=none` selects the JIT control. The script's wineserver
operations are scoped by the dedicated `WINEPREFIX`. Use a fresh extraction
for each full run so the engine remains the unmodified official baseline.

### Observed results

Independent host: Debian 13 x86_64, Debian Wine `10.0~repack-6`, amd64/i386
packages, Xvfb, dedicated Wine prefix.

| Engine | Interpreter cdecl | Interpreter stdcall | JIT cdecl | JIT stdcall |
| --- | --- | --- | --- | --- |
| Unmodified 11.3.0 baseline build | Pass | Native crash | Pass | Pass |
| Candidate | Pass | Pass | Pass | Pass |

Successful bridge calls printed `RESULT=-1` and exited 0. The baseline
interpreter reported a page fault executing address `0x028a0080`; the
debugger remained open until the harness timeout (exit 124). Addresses are
run-dependent. The crash report, not the timeout alone, is the evidence.

The Linux bridge baseline was built from the release's pinned Mono commit
`73610cc7350b7b51dd3bde3323a8ae28eaf5f7fc`, with DLL SHA-256
`003255a0ef2a59d47e2052abb883d9925a206a534ee4bcbe8ab8786de5bd3d7b`.

### Upstream regression test and CI evidence

The added upstream-style test is committed at
[9bcc7f5a5c7](https://github.com/YJBeetle/mono/commit/9bcc7f5a5c7a84204f75f7c0affa395bd2109748).
It does not depend on `CreateActCtxW`: native pointer identity functions
exercise the same ABI boundary without Windows API behavior in the assertion.

CI builds the real `libtest.dll`, compiles `pinvoke2.cs` with the existing
`TestDriver.cs`/`TestHelpers.cs`, and runs:

```sh
wine pinvoke2.exe --run-only native_pointer_call_conventions -v
```

The same test executable, native library and managed class libraries are
used for both engines. The CI negative control uses the unmodified DLL from
the official 11.3.0 archive, rather than the separately built local baseline.

[Full before/after CI run](https://github.com/YJBeetle/wine-mono/actions/runs/34644559410)
([pinned workflow and script](https://github.com/YJBeetle/wine-mono/tree/19166056753e490bf4cb78b9c8c841e2adb5452b/.github)):

```text
baseline interpreter:
  Running 'test_0_native_pointer_call_conventions' ...
  Native Crash Reporting
  wine: Unhandled page fault on execute access to 025802B0
  baseline interp exit=124

baseline JIT:
  Regression tests: 1 ran, 0 failed in Tests
  baseline none exit=0

candidate interpreter:
  Regression tests: 1 ran, 0 failed in Tests
  candidate interp exit=0

candidate JIT:
  Regression tests: 1 ran, 0 failed in Tests
  candidate none exit=0
```

The CI requires the test-start marker and native crash/page-fault evidence
for the baseline interpreter, and an explicit `1 ran, 0 failed` plus exit 0
for the three positive controls. Loader failures and generic timeouts do
not satisfy the negative-control assertion. Logs and engine checksums are
uploaded in the `x86-regression-logs` artifact.

The candidate in that run is commit `9bcc7f5a5c7`, based directly on
`wine-mono/mono:main` at `dd89f9da647`. Its matching x86 `mono-sgen.exe`
host and runtime DLL are built together from that revision. A separate
[Wine Mono integration run](https://github.com/YJBeetle/wine-mono/actions/runs/34639563698)
applied the same two commits on top of the current `wine-mono` integration
branch and passed the same interpreter/JIT matrix.

### Scope and limitations

- Reproduced under Wine on both Linux x86_64 and macOS Apple Silicon. Native
  Windows execution has not been tested.
- The new regression covers one pointer argument and a pointer return,
  repeatedly interleaved across calling conventions. It is not exhaustive
  coverage of every supported argument count or marshaling shape.
- This patch does not fix the separate macOS x86 JIT startup hang, add
  arbitrary-signature x86 interpreter P/Invoke support, or establish
  correctness on other architectures.
- The standalone bridge matrix uses the Mono commit pinned by Wine Mono
  11.3.0. The upstream regression CI additionally builds and tests the
  proposed commits directly on the current `main` branch.

---

## Submission record (not part of the PR body)

- Submitted `YJBeetle:codex/x86-interp-stdcall-main`, containing only the
  runtime fix and regression test, against `wine-mono/mono:main`.
- Keep CI infrastructure in the packaging fork, outside the runtime PR.
- PR creation-time state: mergeable with a clean merge state; the repository
  did not report required status checks.
