#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>
#include <windows.h>

static int is_windows_path(const wchar_t *path)
{
    return path[0] != L'\0' && path[1] == L':' &&
           ((path[0] >= L'A' && path[0] <= L'Z') ||
            (path[0] >= L'a' && path[0] <= L'z'));
}

static void print_with_windows_separators(const wchar_t *path)
{
    for (; *path != L'\0'; ++path)
        fputwc(*path == L'/' ? L'\\' : *path, stdout);
}

int wmain(int argc, wchar_t **argv)
{
    const wchar_t *path;
    const wchar_t *cwd;

    if (argc != 2) {
        fwprintf(stderr, L"usage: swcli_path.exe PATH\n");
        return 2;
    }

    path = argv[1];
    if (is_windows_path(path) || (path[0] == L'\\' && path[1] == L'\\')) {
        fputws(path, stdout);
    } else if (path[0] == L'/') {
        fputws(L"Z:", stdout);
        print_with_windows_separators(path);
    } else {
        cwd = _wgetenv(L"SWCLI_POSIX_CWD_WIN");
        if (cwd == NULL || cwd[0] == L'\0') {
            fwprintf(stderr, L"SWCLI_POSIX_CWD_WIN is not set\n");
            return 1;
        }
        fputws(cwd, stdout);
        if (cwd[wcslen(cwd) - 1] != L'\\')
            fputwc(L'\\', stdout);
        print_with_windows_separators(path);
    }
    fputwc(L'\n', stdout);
    return ferror(stdout) ? 1 : 0;
}
