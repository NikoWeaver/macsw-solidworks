/*
 * msi_spatialiop.exe: turns off the SpatialIOP actions of the SOLIDWORKS core MSI.
 *
 *   msi_spatialiop.exe [--check] PACKAGE.msi
 *
 * The SOLIDWORKS 2026 core MSI unzips swwi\data\spatialiop.zip in the deferred custom action
 * InstallSpatialIOP, through the Windows shell's zip folder. Wine has no zip folder (WineHQ bug
 * 17368), so the install ends with 1603. MacSW runs this tool under Wine on its own copy of the MSI
 * (never on the media) and extracts the zip itself after the install (docs/spatialiop-fix.md).
 *
 * It sets the InstallExecuteSequence condition of CopySpatialIOP, set_InstallSpatialIOP and
 * InstallSpatialIOP to 0. It changes only what it knows: each condition must be the original
 * NOT REMOVE~="ALL" or the edited 0, and each CustomAction row must have the type, source and
 * target of SOLIDWORKS 2026. Otherwise it commits nothing. --check opens the package read-only and
 * only reports.
 *
 * Exit codes: 0 all three actions are off (now, or already before); 3 the package has none of the
 * three (nothing to do); 2 usage; 4 some of the three are missing; 5 a condition is unknown;
 * 6 a custom action is unknown; 7 the database could not be opened, changed or committed;
 * 8 (--check only) the actions are still on.
 */
#include <stdio.h>
#include <wchar.h>
#include <windows.h>
#include <msi.h>
#include <msiquery.h>

#define ORIGINAL_CONDITION L"NOT REMOVE~=\"ALL\""
#define DISABLED_CONDITION L"0"

enum { EXIT_OFF = 0, EXIT_USAGE = 2, EXIT_NONE = 3, EXIT_MISSING = 4, EXIT_CONDITION = 5,
       EXIT_ACTION = 6, EXIT_DATABASE = 7, EXIT_STILL_ON = 8 };

enum state { ABSENT, ORIGINAL, DISABLED, UNKNOWN };

static const struct action {
    const wchar_t *name;
    int type;
    const wchar_t *source;
    const wchar_t *target;
} actions[] = {
    { L"CopySpatialIOP", 1, L"SwInst", L"WIDll_CopySpatialIOP" },
    { L"set_InstallSpatialIOP", 51, L"InstallSpatialIOP", L"[SpatialIOPTempFile];$[SPIOP]files" },
    { L"InstallSpatialIOP", 3073, L"SwInst", L"WIDll_InstallSpatialIOP" },
};
#define ACTION_COUNT (sizeof(actions) / sizeof(actions[0]))

/* The first row of QUERY in *record; ERROR_NO_MORE_ITEMS when there is none. */
static UINT fetch_row(MSIHANDLE database, const wchar_t *query, MSIHANDLE *record)
{
    MSIHANDLE view = 0;
    UINT result = MsiDatabaseOpenViewW(database, query, &view);

    *record = 0;
    if (result == ERROR_SUCCESS)
        result = MsiViewExecute(view, 0);
    if (result == ERROR_SUCCESS)
        result = MsiViewFetch(view, record);
    if (view) {
        MsiViewClose(view);
        MsiCloseHandle(view);
    }
    return result;
}

/* Field FIELD of RECORD as a string; a null field is "". */
static UINT record_string(MSIHANDLE record, UINT field, wchar_t *buffer, DWORD size)
{
    DWORD length = size;

    buffer[0] = L'\0';
    return MsiRecordGetStringW(record, field, buffer, &length);
}

static UINT run_query(MSIHANDLE database, const wchar_t *query)
{
    MSIHANDLE view = 0;
    UINT result = MsiDatabaseOpenViewW(database, query, &view);

    if (result == ERROR_SUCCESS)
        result = MsiViewExecute(view, 0);
    if (view) {
        MsiViewClose(view);
        MsiCloseHandle(view);
    }
    return result;
}

/* Reads the sequence condition of every action into STATES. Returns an exit code, or -1 when the
 * three actions are present, have a known condition and a known custom action row. */
static int inspect(MSIHANDLE database, enum state *states)
{
    wchar_t query[256], condition[256], source[256], target[256];
    MSIHANDLE record;
    unsigned int i, present = 0, missing = 0, unknown = 0;
    UINT result;

    for (i = 0; i < ACTION_COUNT; i++) {
        _snwprintf(query, ARRAYSIZE(query),
                   L"SELECT `Condition` FROM `InstallExecuteSequence` WHERE `Action`='%ls'", actions[i].name);
        query[ARRAYSIZE(query) - 1] = L'\0';
        result = fetch_row(database, query, &record);
        if (result == ERROR_NO_MORE_ITEMS) {
            states[i] = ABSENT;
            missing++;
            continue;
        }
        if (result != ERROR_SUCCESS) {
            fwprintf(stdout, L"%ls: cannot read InstallExecuteSequence (error %u)\n", actions[i].name, result);
            return EXIT_DATABASE;
        }
        present++;
        result = record_string(record, 1, condition, ARRAYSIZE(condition));
        MsiCloseHandle(record);
        if (result == ERROR_SUCCESS && !wcscmp(condition, ORIGINAL_CONDITION))
            states[i] = ORIGINAL;
        else if (result == ERROR_SUCCESS && !wcscmp(condition, DISABLED_CONDITION))
            states[i] = DISABLED;
        else {
            states[i] = UNKNOWN;
            unknown++;
            fwprintf(stdout, L"%ls: unknown condition '%ls'; MacSW knows only '%ls' and '%ls'\n",
                     actions[i].name, result == ERROR_SUCCESS ? condition : L"(too long)",
                     ORIGINAL_CONDITION, DISABLED_CONDITION);
        }
    }
    if (!present) {
        fwprintf(stdout, L"the package has none of the SpatialIOP actions; nothing to change\n");
        return EXIT_NONE;
    }
    for (i = 0; i < ACTION_COUNT; i++)
        if (states[i] == ABSENT)
            fwprintf(stdout, L"%ls: missing from InstallExecuteSequence\n", actions[i].name);
    if (missing)
        return EXIT_MISSING;
    if (unknown)
        return EXIT_CONDITION;

    for (i = 0; i < ACTION_COUNT; i++) {
        int type;

        _snwprintf(query, ARRAYSIZE(query),
                   L"SELECT `Type`, `Source`, `Target` FROM `CustomAction` WHERE `Action`='%ls'", actions[i].name);
        query[ARRAYSIZE(query) - 1] = L'\0';
        result = fetch_row(database, query, &record);
        if (result == ERROR_NO_MORE_ITEMS) {
            fwprintf(stdout, L"%ls: missing from CustomAction\n", actions[i].name);
            return EXIT_ACTION;
        }
        if (result != ERROR_SUCCESS) {
            fwprintf(stdout, L"%ls: cannot read CustomAction (error %u)\n", actions[i].name, result);
            return EXIT_DATABASE;
        }
        type = MsiRecordGetInteger(record, 1);
        if (record_string(record, 2, source, ARRAYSIZE(source)) != ERROR_SUCCESS)
            wcscpy(source, L"(too long)");
        if (record_string(record, 3, target, ARRAYSIZE(target)) != ERROR_SUCCESS)
            wcscpy(target, L"(too long)");
        MsiCloseHandle(record);
        if (type != actions[i].type || wcscmp(source, actions[i].source) || wcscmp(target, actions[i].target)) {
            fwprintf(stdout, L"%ls: unknown custom action (type %d, source '%ls', target '%ls'); "
                     L"MacSW knows type %d, source '%ls', target '%ls'\n", actions[i].name, type, source, target,
                     actions[i].type, actions[i].source, actions[i].target);
            return EXIT_ACTION;
        }
    }
    return -1;
}

static int check(const wchar_t *path)
{
    enum state states[ACTION_COUNT];
    MSIHANDLE database = 0;
    UINT result = MsiOpenDatabaseW(path, MSIDBOPEN_READONLY, &database);
    unsigned int i;
    int code;

    if (result != ERROR_SUCCESS) {
        fwprintf(stdout, L"cannot open %ls (error %u)\n", path, result);
        return EXIT_DATABASE;
    }
    code = inspect(database, states);
    MsiCloseHandle(database);
    if (code >= 0)
        return code;
    for (i = 0; i < ACTION_COUNT; i++)
        if (states[i] != DISABLED) {
            fwprintf(stdout, L"%ls: still on (condition '%ls')\n", actions[i].name, ORIGINAL_CONDITION);
            code = EXIT_STILL_ON;
        }
    if (code == EXIT_STILL_ON)
        return code;
    fwprintf(stdout, L"all three SpatialIOP actions are off\n");
    return EXIT_OFF;
}

static int disable(const wchar_t *path)
{
    enum state states[ACTION_COUNT];
    wchar_t query[256];
    MSIHANDLE database = 0;
    UINT result = MsiOpenDatabaseW(path, MSIDBOPEN_TRANSACT, &database);
    unsigned int i, changed = 0;
    int code;

    if (result != ERROR_SUCCESS) {
        fwprintf(stdout, L"cannot open %ls for writing (error %u)\n", path, result);
        return EXIT_DATABASE;
    }
    code = inspect(database, states);
    if (code >= 0) {
        MsiCloseHandle(database);  /* closed without MsiDatabaseCommit: nothing is written */
        return code;
    }
    for (i = 0; i < ACTION_COUNT; i++) {
        if (states[i] == DISABLED) {
            fwprintf(stdout, L"%ls: condition is already '%ls'\n", actions[i].name, DISABLED_CONDITION);
            continue;
        }
        _snwprintf(query, ARRAYSIZE(query),
                   L"UPDATE `InstallExecuteSequence` SET `Condition`='%ls' WHERE `Action`='%ls'",
                   DISABLED_CONDITION, actions[i].name);
        query[ARRAYSIZE(query) - 1] = L'\0';
        result = run_query(database, query);
        if (result != ERROR_SUCCESS) {
            fwprintf(stdout, L"%ls: update failed (error %u); nothing was committed\n", actions[i].name, result);
            MsiCloseHandle(database);
            return EXIT_DATABASE;
        }
        fwprintf(stdout, L"%ls: condition '%ls' -> '%ls'\n", actions[i].name, ORIGINAL_CONDITION, DISABLED_CONDITION);
        changed++;
    }
    if (changed && (result = MsiDatabaseCommit(database)) != ERROR_SUCCESS) {
        fwprintf(stdout, L"commit failed (error %u)\n", result);
        MsiCloseHandle(database);
        return EXIT_DATABASE;
    }
    MsiCloseHandle(database);
    fwprintf(stdout, L"changed %u of %u SpatialIOP actions\n", changed, (unsigned int)ACTION_COUNT);
    /* Read the result back from disk: only a committed change counts. */
    code = check(path);
    return code == EXIT_OFF ? EXIT_OFF : EXIT_DATABASE;
}

int wmain(int argc, wchar_t **argv)
{
    int code;

    if (argc == 3 && !wcscmp(argv[1], L"--check"))
        code = check(argv[2]);
    else if (argc == 2 && argv[1][0] != L'-')
        code = disable(argv[1]);
    else {
        fwprintf(stderr, L"usage: msi_spatialiop.exe [--check] PACKAGE.msi\n");
        return EXIT_USAGE;
    }
    fflush(stdout);
    return code;
}
