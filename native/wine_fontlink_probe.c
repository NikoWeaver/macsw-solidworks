/* Destructive fixtures: run only in a disposable font-test Wine prefix. */
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <stdio.h>
#include <string.h>

static const WCHAR links_key[] = L"Software\\Microsoft\\Windows NT\\CurrentVersion\\FontLink\\SystemLink";
static const WCHAR *names[] = {L"Tahoma", L"Microsoft Sans Serif", L"Lucida Sans Unicode", L"MacSW Probe Unlisted"};
static const WCHAR custom[] = L"PingFang.ttc,PingFang SC\0MyFont.ttf,自定义字体,128,96\0SIMSUN.TTC,SimSun\0";
static const WCHAR empty[] = L"\0";
static const WCHAR unlisted[] = L"UserOnly.ttf,My Font\0";
static const WCHAR large_entry[] = L"Unknown.ttf,自定义回退字体\0";
static const WCHAR default_sc[] =
    L"SIMSUN.TTC,SimSun\0MINGLIU.TTC,PMingLiu\0MSGOTHIC.TTC,MS UI Gothic\0BATANG.TTC,Batang\0"
    L"MSYH.TTC,Microsoft YaHei UI\0MSJH.TTC,Microsoft JhengHei UI\0YUGOTHM.TTC,Yu Gothic UI\0"
    L"MALGUN.TTF,Malgun Gothic\0SEGUISYM.TTF,Segoe UI Symbol\0";
static unsigned checks, failures;

static void check(BOOL ok, const char *label)
{
    ++checks;
    if (!ok) { ++failures; fprintf(stderr, "FAIL: %s\n", label); }
}

static BOOL read_value(HKEY key, const WCHAR *name, DWORD *type, BYTE **data, DWORD *size)
{
    LONG status = RegQueryValueExW(key, name, NULL, type, NULL, size);
    if (status != ERROR_SUCCESS) return FALSE;
    *data = malloc(*size ? *size : 1);
    if (!*data) return FALSE;
    status = RegQueryValueExW(key, name, NULL, type, *data, size);
    if (status != ERROR_SUCCESS) { free(*data); *data = NULL; return FALSE; }
    return TRUE;
}

static void save_or_check(HKEY key, const char *filename, BOOL verify)
{
    FILE *file = fopen(filename, verify ? "rb" : "wb");
    check(file != NULL, "open snapshot");
    if (!file) return;
    for (unsigned i = 0; i < sizeof(names) / sizeof(names[0]); ++i)
    {
        BYTE *data = NULL; DWORD type = 0, size = 0;
        BOOL ok = read_value(key, names[i], &type, &data, &size);
        check(ok, "read fixture");
        if (!ok) break;
        if (verify)
        {
            DWORD header[2] = {0};
            BOOL read_ok = fread(header, sizeof(header), 1, file) == 1;
            check(read_ok, "read snapshot header");
            if (!read_ok) { free(data); break; }
            if (header[1] > 1024 * 1024) { check(FALSE, "bounded snapshot"); free(data); break; }
            BYTE *expected = malloc(header[1] ? header[1] : 1);
            check(expected != NULL, "allocate snapshot");
            if (!expected) { free(data); break; }
            check(fread(expected, 1, header[1], file) == header[1], "read snapshot bytes");
            check(type == header[0] && size == header[1] && !memcmp(data, expected, size),
                  "custom value type, bytes, and order preserved");
            free(expected);
        }
        else
        {
            DWORD header[] = {type, size};
            check(fwrite(header, sizeof(header), 1, file) == 1 && fwrite(data, 1, size, file) == size,
                  "write snapshot");
        }
        printf("fixture=%u type=%lu bytes=%lu\n", i, type, size);
        free(data);
    }
    fclose(file);
}

int main(int argc, char **argv)
{
    if (argc < 2) return 2;
    /* Ensure the new process has executed Wine's codepage/font initialization. */
    HDC dc = GetDC(NULL); ReleaseDC(NULL, dc);
    printf("ACP=%u OEMCP=%u\n", GetACP(), GetOEMCP());
    HKEY key;
    check(RegCreateKeyExW(HKEY_LOCAL_MACHINE, links_key, 0, NULL, 0,
          KEY_QUERY_VALUE | KEY_SET_VALUE, NULL, &key, NULL) == ERROR_SUCCESS, "open links key");
    if (failures) return 1;
    if (!strcmp(argv[1], "setup-custom") && argc == 3)
    {
        check(RegSetValueExW(key, names[0], 0, REG_MULTI_SZ, (BYTE *)custom, sizeof(custom)) == ERROR_SUCCESS, "set custom Tahoma");
        WCHAR large[6000] = {0}; unsigned length = 0;
        for (unsigned i = 0; i < 200; ++i)
        { memcpy(large + length, large_entry, sizeof(large_entry) - sizeof(WCHAR)); length += ARRAYSIZE(large_entry) - 1; }
        check(RegSetValueExW(key, names[1], 0, REG_MULTI_SZ, (BYTE *)large, (length + 1) * sizeof(WCHAR)) == ERROR_SUCCESS, "set large custom list");
        check(RegSetValueExW(key, names[2], 0, REG_MULTI_SZ, (BYTE *)empty, sizeof(empty)) == ERROR_SUCCESS, "set intentionally empty list");
        check(RegSetValueExW(key, names[3], 0, REG_MULTI_SZ, (BYTE *)unlisted, sizeof(unlisted)) == ERROR_SUCCESS, "set unlisted family");
        save_or_check(key, argv[2], FALSE);
    }
    else if (!strcmp(argv[1], "verify-custom") && argc == 3) save_or_check(key, argv[2], TRUE);
    else if (!strcmp(argv[1], "setup-default"))
    {
        check(RegSetValueExW(key, names[0], 0, REG_MULTI_SZ, (BYTE *)default_sc, sizeof(default_sc)) == ERROR_SUCCESS, "set known SC default");
        check(RegDeleteValueW(key, names[1]) == ERROR_SUCCESS, "delete one default family");
    }
    else if (!strcmp(argv[1], "verify-default"))
    {
        BYTE *data = NULL; DWORD type = 0, size = 0;
        const WCHAR *first = GetACP() == 936 ? L"SIMSUN.TTC,SimSun" : GetACP() == 932 ? L"MSGOTHIC.TTC,MS UI Gothic" :
            GetACP() == 949 ? L"GULIM.TTC,Gulim" : GetACP() == 950 ? L"MINGLIU.TTC,PMingLiu" : L"MSGOTHIC.TTC,MS UI Gothic";
        for (unsigned i = 0; i < 2; ++i)
        {
            BOOL ok = read_value(key, names[i], &type, &data, &size);
            check(ok, "default list exists or regenerated");
            if (ok) { check(type == REG_MULTI_SZ && size >= (wcslen(first) + 1) * sizeof(WCHAR) && !wcscmp((WCHAR *)data, first), "locale-specific default order updated"); free(data); data = NULL; }
        }
    }
    else { RegCloseKey(key); return 2; }
    RegCloseKey(key);
    printf("checks=%u failures=%u\n", checks, failures);
    return failures ? 1 : 0;
}
