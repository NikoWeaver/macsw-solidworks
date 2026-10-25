#include <windows.h>
#include <stdio.h>

/* Diagnostic host: pass interpreter options directly to the existing engine. */
int main(int argc, char **argv)
{
    if (argc < 6) {
        fprintf(stderr, "Usage: host engine.dll lib-dir etc-dir mono-options assembly [args]\n");
        return 2;
    }
    HMODULE engine = LoadLibraryA(argv[1]);
    if (!engine) {
        fprintf(stderr, "LoadLibrary failed: %lu\n", GetLastError());
        return 3;
    }
    void (__cdecl *set_dirs)(const char *, const char *) =
        (void *)GetProcAddress(engine, "mono_set_dirs");
    int (__cdecl *run)(int, char **) = (void *)GetProcAddress(engine, "mono_main");
    if (!set_dirs || !run)
        return 4;
    set_dirs(argv[2], argv[3]);
    argv[3] = argv[0];
    printf("Direct mono_main option: %s\n", argv[4]);
    fflush(stdout);
    return run(argc - 3, argv + 3);
}
