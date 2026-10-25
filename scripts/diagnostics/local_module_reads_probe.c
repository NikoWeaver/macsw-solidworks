/* local_module_reads_probe.c - functional check and micro-benchmark for patch 0033 (kernelbase local module reads).
 *
 * Prints EnumProcessModules / EnumProcessModulesEx(LIST_MODULES_ALL) and, for every module, the main module (NULL)
 * and a bogus HMODULE, GetModuleBaseNameW / GetModuleFileNameExW / GetModuleInformation with their results and
 * error codes, for these handles:
 *   own process: the pseudo handle; DuplicateHandle(GetCurrentProcess()) with the same access (the way .NET and
 *   SOLIDWORKS do it); OpenProcess(own pid) with QUERY_INFORMATION|VM_READ, with QUERY_LIMITED_INFORMATION only,
 *   with QUERY_INFORMATION only (no VM_READ), and a duplicate with VM_READ only (no query right);
 *   another process (this exe in "child" mode): the CreateProcess handle, OpenProcess with QUERY_LIMITED only and
 *   with QUERY_INFORMATION|VM_READ; and, when lmr32.exe (the i386 build) is next to this exe, a WOW64 child.
 * The text output (stdout) must not depend on MACSW_LOCAL_MODULE_READS or on whether kernelbase has patch 0033
 * (apart from the SizeOfImage of kernelbase.dll itself). "self-dup" must equal "self-pseudo" line by line.
 * Then 4 threads list the modules through the duplicate handle for 2 s while one thread loads and unloads a DLL
 * (no crash is the bar; counts go to stderr), and the timing of one full listing goes to stderr.
 * Build: x86_64-w64-mingw32-gcc -O2 -o local_module_reads_probe.exe local_module_reads_probe.c -lpsapi
 *        i686-w64-mingw32-gcc -O2 -o lmr32.exe local_module_reads_probe.c -lpsapi */
#include <windows.h>
#include <psapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BOGUS ((HMODULE)(ULONG_PTR)0x12340000)

static DWORD err(BOOL ok) { return ok ? 0 : GetLastError(); }

static void module_line(HANDLE process, const char *label, HMODULE m, char *out, size_t size)
{
    WCHAR base[MAX_PATH], path[MAX_PATH]; MODULEINFO mi; DWORD rb, rp, eb, ep, ei; BOOL ri;
    memset(base, 0, sizeof(base)); memset(path, 0, sizeof(path)); memset(&mi, 0, sizeof(mi));
    SetLastError(0xdeadbeef); rb = GetModuleBaseNameW(process, m, base, MAX_PATH); eb = err(rb != 0);
    SetLastError(0xdeadbeef); rp = GetModuleFileNameExW(process, m, path, MAX_PATH); ep = err(rp != 0);
    SetLastError(0xdeadbeef); ri = GetModuleInformation(process, m, &mi, sizeof(mi)); ei = err(ri);
    snprintf(out, size, "%s %p base=%lu/%lu:%ls path=%lu/%lu:%ls info=%d/%lu:%p,%08lx,%p", label, m, rb, eb, base,
             rp, ep, path, ri, ei, mi.lpBaseOfDll, mi.SizeOfImage, mi.EntryPoint);
}

static int list(HANDLE process, const char *label, int verbose)
{
    HMODULE mods[1024]; DWORD needed = 0, n = 0, i; BOOL ok; char line[2048];
    SetLastError(0xdeadbeef);
    ok = EnumProcessModules(process, mods, sizeof(mods), &needed);
    if (verbose) printf("%s EnumProcessModules %d/%lu n=%lu\n", label, ok, err(ok), ok ? needed / (DWORD)sizeof(HMODULE) : 0);
    if (ok)
    {
        n = needed / sizeof(HMODULE); if (n > 1024) n = 1024;
        for (i = 0; i < n; i++)
        {
            module_line(process, label, mods[i], line, sizeof(line));
            if (verbose) printf("%s\n", line);
        }
    }
    if (!verbose) return ok ? (int)n : -1;
    needed = 0; SetLastError(0xdeadbeef);
    ok = EnumProcessModulesEx(process, mods, sizeof(mods), &needed, LIST_MODULES_ALL);
    printf("%s EnumProcessModulesEx(ALL) %d/%lu n=%lu first=%p\n", label, ok, err(ok), ok ? needed / (DWORD)sizeof(HMODULE) : 0,
           ok && needed ? mods[0] : NULL);
    module_line(process, label, NULL, line, sizeof(line)); printf("%s (NULL)\n", line);
    module_line(process, label, BOGUS, line, sizeof(line)); printf("%s (bogus)\n", line);
    /* a buffer that is too small: needed must still be the full size */
    needed = 0; SetLastError(0xdeadbeef);
    ok = EnumProcessModules(process, mods, sizeof(HMODULE), &needed);
    printf("%s EnumProcessModules(1 slot) %d/%lu needed=%lu\n", label, ok, err(ok), needed / (DWORD)sizeof(HMODULE));
    return ok ? (int)n : -1;
}

static HANDLE spawn_child(const char *exe, HANDLE ready)
{
    STARTUPINFOA si = {sizeof(si)}; PROCESS_INFORMATION pi; char cmd[MAX_PATH + 32];
    snprintf(cmd, sizeof(cmd), "\"%s\" child", exe);
    ResetEvent(ready);
    if (!CreateProcessA(NULL, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi))
    { printf("CreateProcess %s failed %lu\n", exe, GetLastError()); return NULL; }
    CloseHandle(pi.hThread);
    if (WaitForSingleObject(ready, 20000)) { printf("child %s not ready\n", exe); TerminateProcess(pi.hProcess, 1); }
    return pi.hProcess;
}

static void list_other(HANDLE child, const char *tag)
{
    char label[64]; HANDLE h;
    snprintf(label, sizeof(label), "%s-full", tag); list(child, label, 1);
    snprintf(label, sizeof(label), "%s-limited", tag);
    if ((h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, GetProcessId(child)))) { list(h, label, 1); CloseHandle(h); }
    snprintf(label, sizeof(label), "%s-qi-vmread", tag);
    if ((h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, FALSE, GetProcessId(child)))) { list(h, label, 1); CloseHandle(h); }
    TerminateProcess(child, 0); WaitForSingleObject(child, 5000); CloseHandle(child);
}

static HANDLE dup_self;
static volatile LONG stop, enum_ok, enum_fail, churn;
static const char *churn_dll;

static DWORD WINAPI lister(void *arg)
{
    while (!stop) { if (list(dup_self, "thread", 0) > 0) InterlockedIncrement(&enum_ok); else InterlockedIncrement(&enum_fail); }
    return 0;
}

static DWORD WINAPI loader(void *arg)
{
    while (!stop) { HMODULE m = LoadLibraryA(churn_dll); if (m) { FreeLibrary(m); InterlockedIncrement(&churn); } }
    return 0;
}

int main(int argc, char **argv)
{
    static const char *extra[] = {"ole32.dll", "oleaut32.dll", "shell32.dll", "comctl32.dll", "windowscodecs.dll",
                                  "wininet.dll", "setupapi.dll"};
    static const char *candidates[] = {"msimg32.dll", "dciman32.dll", "mpr.dll", "sxs.dll", "netapi32.dll"};
    char env[8] = "", exe[MAX_PATH], exe32[MAX_PATH], *slash; HANDLE h, ready, threads[5]; LARGE_INTEGER f, t0, t1;
    int rounds = 20, i, n;
    BOOL wow64 = FALSE;

    ready = CreateEventA(NULL, TRUE, FALSE, "Local\\macsw_lmr_probe_ready");
    for (i = 0; i < (int)(sizeof(extra) / sizeof(extra[0])); i++) LoadLibraryA(extra[i]);
    if (argc > 1 && !strcmp(argv[1], "child")) { SetEvent(ready); Sleep(60000); return 0; }
    if (argc > 1) rounds = atoi(argv[1]);
    GetEnvironmentVariableA("MACSW_LOCAL_MODULE_READS", env, sizeof(env));
    IsWow64Process(GetCurrentProcess(), &wow64);
    printf("probe %s wow64=%d\n", sizeof(void *) == 8 ? "x86_64" : "i386", wow64);

    list(GetCurrentProcess(), "self-pseudo", 1);
    DuplicateHandle(GetCurrentProcess(), GetCurrentProcess(), GetCurrentProcess(), &dup_self, 0, FALSE, DUPLICATE_SAME_ACCESS);
    list(dup_self, "self-dup", 1);
    if ((h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, FALSE, GetCurrentProcessId()))) { list(h, "self-qi-vmread", 1); CloseHandle(h); }
    if ((h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, GetCurrentProcessId()))) { list(h, "self-limited", 1); CloseHandle(h); }
    if ((h = OpenProcess(PROCESS_QUERY_INFORMATION, FALSE, GetCurrentProcessId()))) { list(h, "self-qi", 1); CloseHandle(h); }
    if (DuplicateHandle(GetCurrentProcess(), GetCurrentProcess(), GetCurrentProcess(), &h, PROCESS_VM_READ, FALSE, 0))
    { list(h, "self-vmread", 1); CloseHandle(h); }

    GetModuleFileNameA(NULL, exe, MAX_PATH);
    if ((h = spawn_child(exe, ready))) list_other(h, "child");
    strcpy(exe32, exe);
    if ((slash = strrchr(exe32, '\\'))) strcpy(slash + 1, "lmr32.exe");
    if (sizeof(void *) == 8 && GetFileAttributesA(exe32) != INVALID_FILE_ATTRIBUTES && (h = spawn_child(exe32, ready)))
        list_other(h, "child32");

    /* threads: walks through the duplicate handle while another thread changes the module list */
    for (i = 0; i < (int)(sizeof(candidates) / sizeof(candidates[0])) && !churn_dll; i++)
        if (!GetModuleHandleA(candidates[i])) churn_dll = candidates[i];
    for (i = 0; i < 4; i++) threads[i] = CreateThread(NULL, 0, lister, NULL, 0, NULL);
    threads[4] = CreateThread(NULL, 0, loader, NULL, 0, NULL);
    Sleep(2000); stop = 1;
    WaitForMultipleObjects(5, threads, TRUE, INFINITE);
    printf("threads done\n");
    fprintf(stderr, "THREADS local=%s churn_dll=%s loads=%ld walks_ok=%ld walks_failed=%ld\n", env[0] ? env : "unset",
            churn_dll ? churn_dll : "none", churn, enum_ok, enum_fail);

    QueryPerformanceFrequency(&f); QueryPerformanceCounter(&t0);
    for (i = 0, n = 0; i < rounds; i++) n = list(dup_self, "timing", 0);
    QueryPerformanceCounter(&t1);
    fprintf(stderr, "TIMING local=%s modules=%d rounds=%d per_round_ms=%.2f\n", env[0] ? env : "unset", n, rounds,
            (t1.QuadPart - t0.QuadPart) * 1000.0 / f.QuadPart / rounds);
    return 0;
}
