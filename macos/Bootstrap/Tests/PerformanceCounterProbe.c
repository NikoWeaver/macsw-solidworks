#include <windows.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv)
{
    LARGE_INTEGER frequency, value;
    unsigned char *code = NULL;
    if (argc > 1) {
        code = VirtualAlloc(NULL, 4096, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
        if (!code) return 3;
        printf("RWX allocation=%p\n", code);
        fflush(stdout);
    }
    if (!QueryPerformanceFrequency(&frequency)) {
        printf("QPF failed: %lu\n", GetLastError());
        return 1;
    }
    int iterations = code && strncmp(argv[1], "jit", 3) == 0 ? 10 : 100000;
    for (int i = 0; i < iterations; ++i) {
        if (code && strcmp(argv[1], "alloc") != 0) {
            DWORD old_protection;
            if (strcmp(argv[1], "jit-protect") == 0 &&
                !VirtualProtect(code, 4096, PAGE_READWRITE, &old_protection)) return 5;
            if (iterations == 10) { printf("Iteration %d before write\n", i); fflush(stdout); }
            code[0] = 0xb8;
            *(int *)(code + 1) = i;
            code[5] = 0xc3;
            if (iterations == 10) { printf("Iteration %d after write\n", i); fflush(stdout); }
            if (strcmp(argv[1], "jit-protect") == 0 &&
                !VirtualProtect(code, 4096, PAGE_EXECUTE_READ, &old_protection)) return 6;
            if (i == 0) { puts("Code written"); fflush(stdout); }
            FlushInstructionCache(GetCurrentProcess(), code, 6);
            if (i == 0) { puts("Cache flushed"); fflush(stdout); }
            if (strcmp(argv[1], "write") != 0) {
                if (((int (__cdecl *)(void))code)() != i) { printf("Generated code mismatch at %d\n", i); return 4; }
                if (i == 0) { puts("Code executed"); fflush(stdout); }
            }
        }
        if (!QueryPerformanceCounter(&value)) return 2;
        if (iterations == 10) { printf("Iteration %d completed\n", i); fflush(stdout); }
    }
    printf("QPC passed: frequency=%lld value=%lld\n", frequency.QuadPart, value.QuadPart);
    return 0;
}
