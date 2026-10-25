/*
 * Regression probe for the MacSW native file dialogs (patch 0023).
 * Owns all of its windows and files; never attaches to SOLIDWORKS.
 *
 *   wine_file_dialog_probe.exe native       MACSW_NATIVE_FILE_DIALOGS=1: every panel is
 *                                           answered through MACSW_NATIVE_FILE_DIALOG_TEST
 *                                           (some checks set "all" for themselves)
 *   wine_file_dialog_probe.exe shadow       as native, only the dialog window checks (fewer panels)
 *   wine_file_dialog_probe.exe wine         gate unset: the Wine dialogs must still appear
 *   wine_file_dialog_probe.exe show <ms>    one real open panel kept up <ms> for a screenshot
 *
 * Prints "ok"/"FAIL" lines and exits with the number of failures.
 */
#define COBJMACROS
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <shobjidl.h>
#include <shlwapi.h>
#include <commdlg.h>
#include <cderr.h>
#include <stdarg.h>
#include <stdio.h>

#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))

static unsigned checks, failures;
static HWND owner, owner_edit;
static WCHAR dir[MAX_PATH], file_a[MAX_PATH], file_b[MAX_PATH], subdir[MAX_PATH], file_c[MAX_PATH];
static WCHAR odd_dir[MAX_PATH];
static char *(CDECL *pwine_get_unix_file_name)(const WCHAR *);

static void check(BOOL ok, const char *format, ...)
{
    va_list args;
    char buf[512];

    va_start(args, format);
    vsnprintf(buf, sizeof(buf), format, args);
    va_end(args);
    ++checks;
    if (!ok) ++failures;
    printf("%s %s\n", ok ? "ok  " : "FAIL", buf);
    fflush(stdout);
}

static const char *w2a(const WCHAR *str)
{
    static char buf[4][1024];
    static int n;
    char *ret = buf[n++ & 3];
    WideCharToMultiByte(CP_UTF8, 0, str ? str : L"(null)", -1, ret, sizeof(buf[0]), NULL, NULL);
    return ret;
}

/* The test hook takes unix paths; this is what a user would have picked. */
static void set_response(const WCHAR *first, const WCHAR *second)
{
    WCHAR buf[4096];
    int len = 0;

    if (!first)
    {
        SetEnvironmentVariableW(L"MACSW_NATIVE_FILE_DIALOG_TEST", L"cancel");
        return;
    }
    for (int i = 0; i < 2; i++)
    {
        const WCHAR *path = i ? second : first;
        char *unix_path;
        if (!path) break;
        unix_path = pwine_get_unix_file_name(path);
        if (i) buf[len++] = '\n';
        len += MultiByteToWideChar(CP_UTF8, 0, unix_path, -1, buf + len, ARRAY_SIZE(buf) - len) - 1;
        HeapFree(GetProcessHeap(), 0, unix_path);
    }
    buf[len] = 0;
    SetEnvironmentVariableW(L"MACSW_NATIVE_FILE_DIALOG_TEST", buf);
}

/* A unix path that has no exact Windows form ("q?x.txt"): <unix odd_dir>/<name>. */
static void set_response_odd(const char *name)
{
    WCHAR buf[4096];
    char *unix_dir = pwine_get_unix_file_name(odd_dir);
    int len = MultiByteToWideChar(CP_UTF8, 0, unix_dir, -1, buf, ARRAY_SIZE(buf)) - 1;

    HeapFree(GetProcessHeap(), 0, unix_dir);
    buf[len++] = '/';
    MultiByteToWideChar(CP_UTF8, 0, name, -1, buf + len, ARRAY_SIZE(buf) - len);
    SetEnvironmentVariableW(L"MACSW_NATIVE_FILE_DIALOG_TEST", buf);
}

static void set_env(const WCHAR *name, const WCHAR *value)
{
    SetEnvironmentVariableW(name, value);
}

static const WCHAR *panel_delay = L"300";

static void reset_test_env(void)
{
    set_env(L"MACSW_NATIVE_FILE_DIALOG_TEST", NULL);
    set_env(L"MACSW_NATIVE_FILE_DIALOG_TEST_TYPE", NULL);
    set_env(L"MACSW_NATIVE_FILE_DIALOG_TEST_CONTROLS", NULL);
    set_env(L"MACSW_NATIVE_FILE_DIALOG_TEST_DELAY_MS", panel_delay);
}

/**************************************************************************
 * IFileDialogEvents / IFileDialogControlEvents recorder
 */
struct events
{
    IFileDialogEvents IFileDialogEvents_iface;
    IFileDialogControlEvents IFileDialogControlEvents_iface;
    LONG ref;
    int fileok, folderchange, typechange, selchange, overwrite, items, checks_toggled, buttons;
    int refuse_fileok;
    BOOL owner_disabled_in_fileok;
    DWORD item_ctl[8], item_id[8];
    DWORD check_ctl;
    BOOL check_state;
    UINT fileok_type;
    WCHAR fileok_name[MAX_PATH];
    BOOL close_in_fileok;
    int options_result;               /* the modal dialog a push button opened */
    BOOL ask_window;                  /* GetWindow() in OnFolderChange/OnTypeChange */
    int window_calls, window_ok, window_real;
    WCHAR folder_seen[MAX_PATH];      /* GetFolder() in the last OnFolderChange */
    int subdir_seen;                  /* OnFolderChange calls in subdir */
    BOOL inspect;                     /* check the dialog window in the first OnFolderChange */
    HWND shadow;                      /* the window GetWindow() gave there */
    int fileok_same_window;           /* OnFileOk: GetWindow() gave that window, still hidden */
    WCHAR fileok_edit[MAX_PATH];      /* OnFileOk: its file name box */
    int selchange_window;             /* OnSelectionChange: GetWindow() gave that window, hidden */
    WCHAR selection_seen[MAX_PATH];   /* GetCurrentSelection() in the last OnSelectionChange */
};

static void ask_for_window(struct events *This, IFileDialog *dialog)
{
    IOleWindow *window;
    HWND hwnd = (HWND)0xdead;

    if (!This->ask_window || FAILED(IFileDialog_QueryInterface(dialog, &IID_IOleWindow, (void **)&window))) return;
    This->window_calls++;
    if (SUCCEEDED(IOleWindow_GetWindow(window, &hwnd)))
    {
        This->window_ok++;
        if (IsWindow(hwnd)) This->window_real++;
        if (IsWindow(hwnd) && !This->shadow) This->shadow = hwnd;
    }
    IOleWindow_Release(window);
}

/* A native Show() has a hidden dialog window, the one the Wine dialog shows:
   what SOLIDWORKS's sldfileopen.dll does with it while the dialog opens. */
static WNDPROC shadow_oldproc;
static int shadow_ncdestroy;

static LRESULT CALLBACK shadow_subclass(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam)
{
    if (msg == WM_NCDESTROY) shadow_ncdestroy++;
    return CallWindowProcW(shadow_oldproc, hwnd, msg, wparam, lparam);
}

static BOOL is_hidden(HWND hwnd)
{
    return !IsWindowVisible(hwnd) && !(GetWindowLongW(hwnd, GWL_STYLE) & WS_VISIBLE);
}

static void inspect_window(struct events *This, IFileDialog *dialog)
{
    IOleWindow *window;
    HWND hwnd = NULL, child, focus;
    WCHAR cls[32] = {0};
    HRESULT hr = E_FAIL;
    BOOL hidden = TRUE;

    if (SUCCEEDED(IFileDialog_QueryInterface(dialog, &IID_IOleWindow, (void **)&window)))
    {
        hr = IOleWindow_GetWindow(window, &hwnd);
        IOleWindow_Release(window);
    }
    This->shadow = hwnd;
    if (hwnd) GetClassNameW(hwnd, cls, ARRAY_SIZE(cls));
    check(hr == S_OK && IsWindow(hwnd) && !lstrcmpW(cls, L"#32770") && is_hidden(hwnd),
          "shadow: GetWindow in the first OnFolderChange gives a hidden dialog window (0x%08lx, %p, %s)",
          hr, hwnd, w2a(cls));
    if (!IsWindow(hwnd)) return;
    check(GetDlgItem(hwnd, 0x470) && GetDlgItem(hwnd, 0x480) && GetDlgItem(hwnd, IDOK) &&
          GetDlgItem(hwnd, IDCANCEL) && !GetDlgItem(hwnd, 0x47c),
          "shadow: it has cmb1, edt1, IDOK and IDCANCEL (and no cmb13), as the Wine dialog");
    check(GetWindow(hwnd, GW_OWNER) == owner, "shadow: owned by the owner given to Show() (%p)",
          GetWindow(hwnd, GW_OWNER));
    child = CreateWindowExW(0, L"STATIC", L"pane", WS_CHILD | WS_VISIBLE, 0, 0, 100, 40, hwnd,
                            (HMENU)0x3039, NULL, NULL);
    check(child && GetDlgItem(hwnd, 0x3039) == child, "shadow: a program can put a child window into it");
    shadow_ncdestroy = 0;
    shadow_oldproc = (WNDPROC)SetWindowLongPtrW(hwnd, GWLP_WNDPROC, (LONG_PTR)shadow_subclass);
    ShowWindow(hwnd, SW_SHOW);
    hidden = hidden && is_hidden(hwnd);
    ShowWindow(hwnd, SW_SHOWNORMAL);
    hidden = hidden && is_hidden(hwnd);
    SetWindowPos(hwnd, HWND_TOP, 0, 0, 0, 0, SWP_SHOWWINDOW | SWP_NOMOVE | SWP_NOSIZE);
    hidden = hidden && is_hidden(hwnd);
    SetWindowLongW(hwnd, GWL_STYLE, GetWindowLongW(hwnd, GWL_STYLE) | WS_VISIBLE);
    hidden = hidden && is_hidden(hwnd);
    check(hidden, "shadow: ShowWindow, SetWindowPos and SetWindowLong do not show it");
    focus = GetFocus();
    check(GetActiveWindow() != hwnd && focus != hwnd && !IsChild(hwnd, focus),
          "shadow: neither active nor focused (active %p, focus %p)", GetActiveWindow(), focus);
    /* SWP_NOSENDCHANGING bypasses the dialog procedure; the panel loop hides it again. */
    SetWindowPos(hwnd, NULL, 0, 0, 0, 0,
                 SWP_SHOWWINDOW | SWP_NOSENDCHANGING | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
}

static void fileok_window(struct events *This, IFileDialog *dialog)
{
    IOleWindow *window;
    HWND hwnd = NULL;

    if (!This->shadow || FAILED(IFileDialog_QueryInterface(dialog, &IID_IOleWindow, (void **)&window))) return;
    if (SUCCEEDED(IOleWindow_GetWindow(window, &hwnd)) && hwnd == This->shadow && IsWindow(hwnd) &&
        !IsWindowVisible(hwnd))
        This->fileok_same_window++;
    IOleWindow_Release(window);
    GetDlgItemTextW(This->shadow, 0x480, This->fileok_edit, ARRAY_SIZE(This->fileok_edit));
}

static struct events *impl_from_events(IFileDialogEvents *iface)
{
    return CONTAINING_RECORD(iface, struct events, IFileDialogEvents_iface);
}

static struct events *impl_from_control_events(IFileDialogControlEvents *iface)
{
    return CONTAINING_RECORD(iface, struct events, IFileDialogControlEvents_iface);
}

static HRESULT WINAPI events_QueryInterface(IFileDialogEvents *iface, REFIID riid, void **out)
{
    struct events *This = impl_from_events(iface);
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IFileDialogEvents))
        *out = &This->IFileDialogEvents_iface;
    else if (IsEqualIID(riid, &IID_IFileDialogControlEvents))
        *out = &This->IFileDialogControlEvents_iface;
    else
    {
        *out = NULL;
        return E_NOINTERFACE;
    }
    InterlockedIncrement(&This->ref);
    return S_OK;
}

static ULONG WINAPI events_AddRef(IFileDialogEvents *iface)
{
    return InterlockedIncrement(&impl_from_events(iface)->ref);
}

static ULONG WINAPI events_Release(IFileDialogEvents *iface)
{
    return InterlockedDecrement(&impl_from_events(iface)->ref);
}

static HRESULT WINAPI events_OnFileOk(IFileDialogEvents *iface, IFileDialog *dialog)
{
    struct events *This = impl_from_events(iface);
    WCHAR *name = NULL;

    This->fileok++;
    This->owner_disabled_in_fileok = owner && !IsWindowEnabled(owner);
    IFileDialog_GetFileTypeIndex(dialog, &This->fileok_type);
    if (SUCCEEDED(IFileDialog_GetFileName(dialog, &name)))
    {
        lstrcpynW(This->fileok_name, name, MAX_PATH);
        CoTaskMemFree(name);
    }
    fileok_window(This, dialog);
    if (This->close_in_fileok) IFileDialog_Close(dialog, S_FALSE);
    if (This->refuse_fileok > 0)
    {
        This->refuse_fileok--;
        return S_FALSE;
    }
    return S_OK;
}

static HRESULT WINAPI events_OnFolderChanging(IFileDialogEvents *iface, IFileDialog *dialog, IShellItem *folder)
{
    return S_OK;
}

static HRESULT WINAPI events_OnFolderChange(IFileDialogEvents *iface, IFileDialog *dialog)
{
    struct events *This = impl_from_events(iface);
    IShellItem *folder;
    WCHAR *path;

    This->folderchange++;
    if (SUCCEEDED(IFileDialog_GetFolder(dialog, &folder)))
    {
        if (SUCCEEDED(IShellItem_GetDisplayName(folder, SIGDN_FILESYSPATH, &path)))
        {
            lstrcpynW(This->folder_seen, path, MAX_PATH);
            if (!lstrcmpiW(path, subdir)) This->subdir_seen++;
            CoTaskMemFree(path);
        }
        IShellItem_Release(folder);
    }
    if (This->inspect && !This->shadow) inspect_window(This, dialog);
    ask_for_window(This, dialog);
    return S_OK;
}

static HRESULT WINAPI events_OnSelectionChange(IFileDialogEvents *iface, IFileDialog *dialog)
{
    struct events *This = impl_from_events(iface);
    IOleWindow *window;
    IShellItem *item;
    HWND hwnd = NULL;
    WCHAR *path;

    This->selchange++;
    /* What SOLIDWORKS's handler does: the dialog window and its file name box. */
    if (This->shadow && SUCCEEDED(IFileDialog_QueryInterface(dialog, &IID_IOleWindow, (void **)&window)))
    {
        if (SUCCEEDED(IOleWindow_GetWindow(window, &hwnd)) && hwnd == This->shadow && IsWindow(hwnd) &&
            !IsWindowVisible(hwnd) && GetDlgItem(hwnd, 0x480))
            This->selchange_window++;
        IOleWindow_Release(window);
    }
    if (SUCCEEDED(IFileDialog_GetCurrentSelection(dialog, &item)))
    {
        if (SUCCEEDED(IShellItem_GetDisplayName(item, SIGDN_FILESYSPATH, &path)))
        {
            lstrcpynW(This->selection_seen, path, MAX_PATH);
            CoTaskMemFree(path);
        }
        IShellItem_Release(item);
    }
    return S_OK;
}

static HRESULT WINAPI events_OnShareViolation(IFileDialogEvents *iface, IFileDialog *dialog, IShellItem *item,
                                              FDE_SHAREVIOLATION_RESPONSE *response)
{
    return E_NOTIMPL;
}

static HRESULT WINAPI events_OnTypeChange(IFileDialogEvents *iface, IFileDialog *dialog)
{
    impl_from_events(iface)->typechange++;
    ask_for_window(impl_from_events(iface), dialog);
    return S_OK;
}

static HRESULT WINAPI events_OnOverwrite(IFileDialogEvents *iface, IFileDialog *dialog, IShellItem *item,
                                         FDE_OVERWRITE_RESPONSE *response)
{
    impl_from_events(iface)->overwrite++;
    *response = FDEOR_DEFAULT;
    return S_OK;
}

static IFileDialogEventsVtbl events_vtbl =
{
    events_QueryInterface, events_AddRef, events_Release, events_OnFileOk, events_OnFolderChanging,
    events_OnFolderChange, events_OnSelectionChange, events_OnShareViolation, events_OnTypeChange,
    events_OnOverwrite,
};

static HRESULT WINAPI cevents_QueryInterface(IFileDialogControlEvents *iface, REFIID riid, void **out)
{
    return events_QueryInterface(&impl_from_control_events(iface)->IFileDialogEvents_iface, riid, out);
}

static ULONG WINAPI cevents_AddRef(IFileDialogControlEvents *iface)
{
    return InterlockedIncrement(&impl_from_control_events(iface)->ref);
}

static ULONG WINAPI cevents_Release(IFileDialogControlEvents *iface)
{
    return InterlockedDecrement(&impl_from_control_events(iface)->ref);
}

static HRESULT WINAPI cevents_OnItemSelected(IFileDialogControlEvents *iface, IFileDialogCustomize *customize,
                                             DWORD ctl, DWORD item)
{
    struct events *This = impl_from_control_events(iface);
    if (This->items < 8)
    {
        This->item_ctl[This->items] = ctl;
        This->item_id[This->items] = item;
    }
    This->items++;
    /* Like an application reacting to a choice: show the hidden text control. */
    if (ctl == 102) IFileDialogCustomize_SetControlState(customize, 107, CDCS_VISIBLE | CDCS_ENABLED);
    return S_OK;
}

static BOOL CALLBACK close_options(HWND hwnd, LPARAM lparam)
{
    WCHAR title[64];

    if (GetWindowTextW(hwnd, title, ARRAY_SIZE(title)) && !lstrcmpW(title, L"probe options"))
        PostMessageW(hwnd, WM_COMMAND, IDOK, 0);
    return TRUE;
}

static void CALLBACK end_options(HWND hwnd, UINT msg, UINT_PTR id, DWORD time)
{
    KillTimer(NULL, id);
    EnumThreadWindows(GetCurrentThreadId(), close_options, 0);
}

/* Like "Options..." or "References...": the handler runs a modal dialog. */
static HRESULT WINAPI cevents_OnButtonClicked(IFileDialogControlEvents *iface, IFileDialogCustomize *customize,
                                              DWORD ctl)
{
    struct events *This = impl_from_control_events(iface);

    This->buttons++;
    SetTimer(NULL, 0, 500, end_options);
    This->options_result = MessageBoxW(NULL, L"Options of the probe", L"probe options", MB_OKCANCEL);
    return S_OK;
}

static HRESULT WINAPI cevents_OnCheckButtonToggled(IFileDialogControlEvents *iface, IFileDialogCustomize *customize,
                                                   DWORD ctl, BOOL checked)
{
    struct events *This = impl_from_control_events(iface);
    This->checks_toggled++;
    This->check_ctl = ctl;
    This->check_state = checked;
    return S_OK;
}

static HRESULT WINAPI cevents_OnControlActivating(IFileDialogControlEvents *iface, IFileDialogCustomize *customize,
                                                  DWORD ctl)
{
    return S_OK;
}

static IFileDialogControlEventsVtbl control_events_vtbl =
{
    cevents_QueryInterface, cevents_AddRef, cevents_Release, cevents_OnItemSelected, cevents_OnButtonClicked,
    cevents_OnCheckButtonToggled, cevents_OnControlActivating,
};

static void init_events(struct events *events)
{
    memset(events, 0, sizeof(*events));
    events->IFileDialogEvents_iface.lpVtbl = &events_vtbl;
    events->IFileDialogControlEvents_iface.lpVtbl = &control_events_vtbl;
    events->ref = 1;
}

/**************************************************************************
 * Helpers
 */
static BOOL item_path_is(IShellItem *item, const WCHAR *expected)
{
    WCHAR *path = NULL;
    BOOL ret;

    if (!item || FAILED(IShellItem_GetDisplayName(item, SIGDN_FILESYSPATH, &path))) return FALSE;
    ret = !lstrcmpiW(path, expected);
    if (!ret) printf("     got %s, expected %s\n", w2a(path), w2a(expected));
    CoTaskMemFree(path);
    return ret;
}

static IFileDialog *create_dialog(REFCLSID clsid, struct events *events, DWORD *cookie)
{
    IFileDialog *dialog = NULL;
    IShellItem *folder;

    if (FAILED(CoCreateInstance(clsid, NULL, CLSCTX_INPROC_SERVER, &IID_IFileDialog, (void **)&dialog)))
        return NULL;
    if (SUCCEEDED(SHCreateItemFromParsingName(dir, NULL, &IID_IShellItem, (void **)&folder)))
    {
        IFileDialog_SetFolder(dialog, folder);
        IShellItem_Release(folder);
    }
    if (events)
    {
        init_events(events);
        IFileDialog_Advise(dialog, &events->IFileDialogEvents_iface, cookie);
    }
    return dialog;
}

static void add_controls(IFileDialog *dialog)
{
    IFileDialogCustomize *customize;

    if (FAILED(IFileDialog_QueryInterface(dialog, &IID_IFileDialogCustomize, (void **)&customize))) return;
    IFileDialogCustomize_StartVisualGroup(customize, 100, L"&Configuration:");
    IFileDialogCustomize_AddComboBox(customize, 102);
    IFileDialogCustomize_AddControlItem(customize, 102, 1, L"Default");
    IFileDialogCustomize_AddControlItem(customize, 102, 2, L"Large");
    IFileDialogCustomize_AddControlItem(customize, 102, 3, L"Small");
    IFileDialogCustomize_SetSelectedControlItem(customize, 102, 1);
    IFileDialogCustomize_EndVisualGroup(customize);
    IFileDialogCustomize_AddCheckButton(customize, 101, L"Do not load &hidden components", FALSE);
    IFileDialogCustomize_AddRadioButtonList(customize, 105);
    IFileDialogCustomize_AddControlItem(customize, 105, 1, L"Resolved");
    IFileDialogCustomize_AddControlItem(customize, 105, 2, L"Lightweight");
    IFileDialogCustomize_SetSelectedControlItem(customize, 105, 1);
    IFileDialogCustomize_AddEditBox(customize, 106, L"notes");
    IFileDialogCustomize_AddText(customize, 107, L"Shown after a configuration choice");
    IFileDialogCustomize_SetControlState(customize, 107, 0);
    IFileDialogCustomize_AddPushButton(customize, 108, L"&References...");
    IFileDialogCustomize_Release(customize);
}

static const COMDLG_FILTERSPEC text_filters[] =
{
    { L"Text files", L"*.txt" },
    { L"STEP AP214 (*.step;*.stp)", L"*.step;*.stp" },
    { L"All files (*.*)", L"*.*" },
};

/**************************************************************************
 * IFileOpenDialog / IFileSaveDialog
 */
static void test_open_with_controls(HWND parent)
{
    struct events events;
    IFileDialogCustomize *customize;
    IFileDialog *dialog;
    IShellItem *result = NULL;
    WCHAR *text = NULL;
    DWORD cookie, item = 0;
    BOOL checked = FALSE;
    UINT type = 0;
    HRESULT hr;
    int i, seen102 = 0, seen105 = 0;

    reset_test_env();
    set_response(file_a, NULL);
    set_env(L"MACSW_NATIVE_FILE_DIALOG_TEST_TYPE", L"3");
    set_env(L"MACSW_NATIVE_FILE_DIALOG_TEST_CONTROLS", L"101=1;102=3;105=2;106=hello;108=1");
    dialog = create_dialog(&CLSID_FileOpenDialog, &events, &cookie);
    check(dialog != NULL, "open: CoCreateInstance(CLSID_FileOpenDialog)");
    if (!dialog) return;
    IFileDialog_SetFileTypes(dialog, ARRAY_SIZE(text_filters), text_filters);
    IFileDialog_SetFileTypeIndex(dialog, 1);
    IFileDialog_SetTitle(dialog, L"Open (probe)");
    add_controls(dialog);

    hr = IFileDialog_Show(dialog, parent);
    check(hr == S_OK, "open: Show returns S_OK (0x%08lx)", hr);
    check(SUCCEEDED(IFileDialog_GetResult(dialog, &result)) && item_path_is(result, file_a),
          "open: GetResult is the picked file");
    if (result) IShellItem_Release(result);
    IFileDialog_GetFileTypeIndex(dialog, &type);
    check(type == 3, "open: GetFileTypeIndex follows the Format popup (%u)", type);
    check(events.fileok == 1 && events.fileok_type == 3, "open: OnFileOk once, type known (%d, %u)",
          events.fileok, events.fileok_type);
    check(!lstrcmpiW(events.fileok_name, PathFindFileNameW(file_a)), "open: GetFileName in OnFileOk (%s)",
          w2a(events.fileok_name));
    check(events.folderchange >= 1, "open: OnFolderChange (%d)", events.folderchange);
    check(events.typechange >= 2, "open: OnTypeChange initially and on change (%d)", events.typechange);
    if (parent)
    {
        check(events.owner_disabled_in_fileok, "open: owner disabled while the dialog is up");
        check(IsWindowEnabled(parent), "open: owner enabled again");
    }

    IFileDialog_QueryInterface(dialog, &IID_IFileDialogCustomize, (void **)&customize);
    IFileDialogCustomize_GetCheckButtonState(customize, 101, &checked);
    check(checked, "open: check button state from the panel");
    check(events.checks_toggled == 1 && events.check_ctl == 101 && events.check_state,
          "open: OnCheckButtonToggled(101, TRUE)");
    IFileDialogCustomize_GetSelectedControlItem(customize, 102, &item);
    check(item == 3, "open: combo box selection from the panel (%lu)", item);
    IFileDialogCustomize_GetSelectedControlItem(customize, 105, &item);
    check(item == 2, "open: radio button selection from the panel (%lu)", item);
    for (i = 0; i < events.items && i < 8; i++)
    {
        if (events.item_ctl[i] == 102 && events.item_id[i] == 3) seen102 = 1;
        if (events.item_ctl[i] == 105 && events.item_id[i] == 2) seen105 = 1;
    }
    check(seen102 && seen105, "open: OnItemSelected for combo and radio (%d events)", events.items);
    check(events.buttons == 1 && events.options_result == IDOK,
          "open: a push button's handler runs a modal dialog and the panel still ends (%d, %d)", events.buttons,
          events.options_result);
    hr = IFileDialogCustomize_GetEditBoxText(customize, 106, &text);
    check(SUCCEEDED(hr) && text && !lstrcmpW(text, L"hello"), "open: edit box text from the panel (%s)", w2a(text));
    CoTaskMemFree(text);
    IFileDialogCustomize_Release(customize);
    IFileDialog_Unadvise(dialog, cookie);
    IFileDialog_Release(dialog);
}

static void test_open_multi(void)
{
    IFileOpenDialog *dialog;
    IShellItemArray *results = NULL;
    IShellItem *item;
    DWORD count = 0;
    HRESULT hr;

    reset_test_env();
    set_response(file_a, file_b);
    if (FAILED(CoCreateInstance(&CLSID_FileOpenDialog, NULL, CLSCTX_INPROC_SERVER, &IID_IFileOpenDialog,
                                (void **)&dialog))) return;
    IFileOpenDialog_SetOptions(dialog, FOS_ALLOWMULTISELECT | FOS_FILEMUSTEXIST);
    hr = IFileOpenDialog_Show(dialog, owner);
    check(hr == S_OK, "multi: Show returns S_OK (0x%08lx)", hr);
    check(SUCCEEDED(IFileOpenDialog_GetResults(dialog, &results)), "multi: GetResults");
    if (results)
    {
        IShellItemArray_GetCount(results, &count);
        check(count == 2, "multi: two items (%lu)", count);
        if (count == 2)
        {
            IShellItemArray_GetItemAt(results, 0, &item);
            check(item_path_is(item, file_a), "multi: first item");
            IShellItem_Release(item);
            IShellItemArray_GetItemAt(results, 1, &item);
            check(item_path_is(item, file_b), "multi: second item");
            IShellItem_Release(item);
        }
        IShellItemArray_Release(results);
    }
    IFileOpenDialog_Release(dialog);
}

static void test_pick_folder(void)
{
    IFileDialog *dialog = create_dialog(&CLSID_FileOpenDialog, NULL, NULL);
    IShellItem *result = NULL;
    HRESULT hr;

    reset_test_env();
    set_response(subdir, NULL);
    if (!dialog) return;
    IFileDialog_SetOptions(dialog, FOS_PICKFOLDERS);
    hr = IFileDialog_Show(dialog, owner);
    check(hr == S_OK, "folder: Show returns S_OK (0x%08lx)", hr);
    check(SUCCEEDED(IFileDialog_GetResult(dialog, &result)) && item_path_is(result, subdir),
          "folder: GetResult is the picked folder");
    if (result) IShellItem_Release(result);
    IFileDialog_Release(dialog);
}

static void test_save(const WCHAR *typed, const WCHAR *type, UINT expect_type, const WCHAR *expect_name,
                      BOOL existing)
{
    WCHAR typed_path[MAX_PATH], expected[MAX_PATH];
    struct events events;
    IFileDialog *dialog;
    IShellItem *result = NULL;
    DWORD cookie;
    UINT index = 0;
    HRESULT hr;

    reset_test_env();
    PathCombineW(typed_path, dir, typed);
    PathCombineW(expected, dir, expect_name);
    set_response(typed_path, NULL);
    if (type) set_env(L"MACSW_NATIVE_FILE_DIALOG_TEST_TYPE", type);
    dialog = create_dialog(&CLSID_FileSaveDialog, &events, &cookie);
    if (!dialog) return;
    IFileDialog_SetFileTypes(dialog, ARRAY_SIZE(text_filters), text_filters);
    IFileDialog_SetDefaultExtension(dialog, L"txt");
    IFileDialog_SetFileName(dialog, L"Untitled");
    hr = IFileDialog_Show(dialog, owner);
    check(hr == S_OK, "save %s: Show returns S_OK (0x%08lx)", w2a(typed), hr);
    check(SUCCEEDED(IFileDialog_GetResult(dialog, &result)) && item_path_is(result, expected),
          "save %s: result %s", w2a(typed), w2a(expect_name));
    if (result) IShellItem_Release(result);
    IFileDialog_GetFileTypeIndex(dialog, &index);
    check(index == expect_type, "save %s: file type index %u", w2a(typed), index);
    check(events.overwrite == (existing ? 1 : 0), "save %s: OnOverwrite %d time(s), no second prompt",
          w2a(typed), events.overwrite);
    IFileDialog_Unadvise(dialog, cookie);
    IFileDialog_Release(dialog);
}

static void test_fileok_refused(void)
{
    struct events events;
    IFileDialog *dialog;
    DWORD cookie;
    HRESULT hr;

    reset_test_env();
    set_response(file_a, NULL);
    dialog = create_dialog(&CLSID_FileOpenDialog, &events, &cookie);
    if (!dialog) return;
    events.refuse_fileok = 1;
    hr = IFileDialog_Show(dialog, owner);
    check(hr == S_OK && events.fileok == 2, "refuse: S_FALSE from OnFileOk shows the panel again (%d)",
          events.fileok);
    IFileDialog_Unadvise(dialog, cookie);
    IFileDialog_Release(dialog);
}

static void test_cancel(void)
{
    struct events events;
    IFileDialog *dialog;
    IShellItem *result = NULL;
    DWORD cookie;
    HRESULT hr;

    reset_test_env();
    set_response(NULL, NULL);
    dialog = create_dialog(&CLSID_FileOpenDialog, &events, &cookie);
    if (!dialog) return;
    hr = IFileDialog_Show(dialog, NULL);
    check(hr == HRESULT_FROM_WIN32(ERROR_CANCELLED), "cancel: Show returns ERROR_CANCELLED (0x%08lx)", hr);
    check(events.fileok == 0 && FAILED(IFileDialog_GetResult(dialog, &result)), "cancel: no result, no OnFileOk");
    IFileDialog_Unadvise(dialog, cookie);
    IFileDialog_Release(dialog);
}

/**************************************************************************
 * GetOpenFileName / GetSaveFileName
 */
static const WCHAR ofn_filter[] = L"Text files\0*.txt\0STEP files\0*.step;*.stp\0All files (*.*)\0*.*\0";

static void init_ofn(OPENFILENAMEW *ofn, WCHAR *buffer, DWORD size, DWORD flags)
{
    memset(ofn, 0, sizeof(*ofn));
    ofn->lStructSize = sizeof(*ofn);
    ofn->hwndOwner = owner;
    ofn->lpstrFilter = ofn_filter;
    ofn->nFilterIndex = 1;
    ofn->lpstrFile = buffer;
    ofn->nMaxFile = size;
    ofn->lpstrInitialDir = dir;
    ofn->Flags = flags;
}

static void test_ofn_open(void)
{
    WCHAR buffer[MAX_PATH] = L"", title[MAX_PATH] = L"";
    OPENFILENAMEW ofn;
    BOOL ret;

    reset_test_env();
    set_response(file_a, NULL);
    set_env(L"MACSW_NATIVE_FILE_DIALOG_TEST_TYPE", L"3");
    init_ofn(&ofn, buffer, ARRAY_SIZE(buffer), OFN_EXPLORER | OFN_FILEMUSTEXIST | OFN_HIDEREADONLY);
    ofn.lpstrFileTitle = title;
    ofn.nMaxFileTitle = ARRAY_SIZE(title);
    ret = GetOpenFileNameW(&ofn);
    check(ret, "ofn open: returns TRUE (error 0x%lx)", CommDlgExtendedError());
    check(!lstrcmpiW(buffer, file_a), "ofn open: lpstrFile %s", w2a(buffer));
    check(ofn.nFileOffset == PathFindFileNameW(file_a) - file_a, "ofn open: nFileOffset %u", ofn.nFileOffset);
    check(ofn.nFileExtension == PathFindExtensionW(file_a) - file_a + 1, "ofn open: nFileExtension %u",
          ofn.nFileExtension);
    check(ofn.nFilterIndex == 3, "ofn open: nFilterIndex follows the Format popup (%lu)", ofn.nFilterIndex);
    check(!lstrcmpiW(title, L"a.txt"), "ofn open: lpstrFileTitle %s", w2a(title));
}

static void test_ofn_readonly(void)
{
    WCHAR buffer[MAX_PATH] = L"";
    OPENFILENAMEW ofn;
    BOOL ret;

    reset_test_env();
    set_response(file_a, NULL);
    set_env(L"MACSW_NATIVE_FILE_DIALOG_TEST_CONTROLS", L"2147418113=1");
    init_ofn(&ofn, buffer, ARRAY_SIZE(buffer), OFN_EXPLORER | OFN_FILEMUSTEXIST);
    ret = GetOpenFileNameW(&ofn);
    check(ret && (ofn.Flags & OFN_READONLY), "ofn open: \"Open as read-only\" sets OFN_READONLY");
}

static void test_ofn_multi(void)
{
    WCHAR buffer[1024], expected[1024], *p;
    OPENFILENAMEW ofn;
    UINT len;
    BOOL ret;

    reset_test_env();
    set_response(file_a, file_b);
    buffer[0] = 0;
    init_ofn(&ofn, buffer, ARRAY_SIZE(buffer), OFN_EXPLORER | OFN_ALLOWMULTISELECT | OFN_FILEMUSTEXIST);
    ret = GetOpenFileNameW(&ofn);
    lstrcpyW(expected, dir);
    PathRemoveBackslashW(expected);
    len = lstrlenW(expected);
    p = expected + len + 1;
    lstrcpyW(p, L"a.txt");
    p += 6;
    lstrcpyW(p, L"b.txt");
    p += 6;
    *p++ = 0;
    check(ret && !memcmp(buffer, expected, (p - expected) * sizeof(WCHAR)),
          "ofn multi: \"dir\\0a.txt\\0b.txt\\0\\0\" (%s | %s)", w2a(buffer), w2a(buffer + lstrlenW(buffer) + 1));
    check(ofn.nFileOffset == len + 1 && ofn.nFileExtension == 0, "ofn multi: nFileOffset %u", ofn.nFileOffset);
}

static void test_ofn_save(void)
{
    WCHAR buffer[MAX_PATH] = L"", typed[MAX_PATH], expected[MAX_PATH];
    OPENFILENAMEW ofn;
    BOOL ret;

    reset_test_env();
    PathCombineW(typed, dir, L"out");
    PathCombineW(expected, dir, L"out.txt");
    set_response(typed, NULL);
    init_ofn(&ofn, buffer, ARRAY_SIZE(buffer), OFN_EXPLORER | OFN_OVERWRITEPROMPT);
    ofn.lpstrDefExt = L"txt";
    ret = GetSaveFileNameW(&ofn);
    check(ret && !lstrcmpiW(buffer, expected), "ofn save: default extension appended (%s)", w2a(buffer));
    check(!(ofn.Flags & OFN_EXTENSIONDIFFERENT), "ofn save: OFN_EXTENSIONDIFFERENT clear");

    reset_test_env();
    PathCombineW(typed, dir, L"model");
    PathCombineW(expected, dir, L"model.step");
    set_response(typed, NULL);
    set_env(L"MACSW_NATIVE_FILE_DIALOG_TEST_TYPE", L"2");
    buffer[0] = 0;
    init_ofn(&ofn, buffer, ARRAY_SIZE(buffer), OFN_EXPLORER | OFN_OVERWRITEPROMPT);
    ofn.lpstrDefExt = L"txt";
    ret = GetSaveFileNameW(&ofn);
    check(ret && !lstrcmpiW(buffer, expected) && ofn.nFilterIndex == 2,
          "ofn save: extension of the chosen format (%s, index %lu)", w2a(buffer), ofn.nFilterIndex);
    check((ofn.Flags & OFN_EXTENSIONDIFFERENT) != 0, "ofn save: OFN_EXTENSIONDIFFERENT set");

    reset_test_env();
    set_response(file_a, NULL);
    buffer[0] = 0;
    init_ofn(&ofn, buffer, 5, OFN_EXPLORER);
    ret = GetSaveFileNameW(&ofn);
    check(!ret && CommDlgExtendedError() == FNERR_BUFFERTOOSMALL, "ofn save: FNERR_BUFFERTOOSMALL (0x%lx)",
          CommDlgExtendedError());
}

static void test_ofn_ansi(void)
{
    char buffer[MAX_PATH] = "", expected[MAX_PATH];
    OPENFILENAMEA ofn;
    BOOL ret;

    reset_test_env();
    set_response(file_b, NULL);
    memset(&ofn, 0, sizeof(ofn));
    ofn.lStructSize = sizeof(ofn);
    ofn.hwndOwner = owner;
    ofn.lpstrFilter = "Text files\0*.txt\0";
    ofn.lpstrFile = buffer;
    ofn.nMaxFile = sizeof(buffer);
    ofn.Flags = OFN_EXPLORER | OFN_HIDEREADONLY;
    ret = GetOpenFileNameA(&ofn);
    WideCharToMultiByte(CP_ACP, 0, file_b, -1, expected, sizeof(expected), NULL, NULL);
    check(ret && !lstrcmpiA(buffer, expected) && ofn.nFileOffset == strlen(expected) - 5,
          "ofn ansi: GetOpenFileNameA (%s, offset %u)", buffer, ofn.nFileOffset);
}

static void test_ofn_cancel(void)
{
    WCHAR buffer[MAX_PATH] = L"";
    OPENFILENAMEW ofn;
    BOOL ret;

    reset_test_env();
    set_response(NULL, NULL);
    init_ofn(&ofn, buffer, ARRAY_SIZE(buffer), OFN_EXPLORER);
    ret = GetOpenFileNameW(&ofn);
    check(!ret && !CommDlgExtendedError(), "ofn cancel: FALSE, CommDlgExtendedError 0");
}

/**************************************************************************
 * Wine dialogs: hooks and templates, and everything with the gate unset.
 */
static BOOL wine_dialog_seen;
static int hook_calls;

static BOOL CALLBACK find_dialog(HWND hwnd, LPARAM lparam)
{
    WCHAR cls[32];

    if (GetClassNameW(hwnd, cls, ARRAY_SIZE(cls)) && !lstrcmpW(cls, L"#32770") && IsWindowVisible(hwnd))
    {
        wine_dialog_seen = TRUE;
        PostMessageW(hwnd, WM_COMMAND, IDCANCEL, 0);
        return FALSE;
    }
    return TRUE;
}

static void CALLBACK close_wine_dialog(HWND hwnd, UINT msg, UINT_PTR id, DWORD time)
{
    EnumThreadWindows(GetCurrentThreadId(), find_dialog, 0);
}

static UINT_PTR CALLBACK ofn_hook(HWND dlg, UINT msg, WPARAM wparam, LPARAM lparam)
{
    if (msg == WM_INITDIALOG) hook_calls++;
    return 0;
}

static void test_wine_dialogs(const char *why, BOOL hook_only)
{
    WCHAR buffer[MAX_PATH] = L"";
    OPENFILENAMEW ofn;
    IFileDialog *dialog;
    UINT_PTR timer;
    HRESULT hr;
    BOOL ret;

    reset_test_env();
    set_response(file_a, NULL);    /* must be ignored by the Wine dialog */
    timer = SetTimer(NULL, 0, 1500, close_wine_dialog);

    wine_dialog_seen = FALSE;
    hook_calls = 0;
    init_ofn(&ofn, buffer, ARRAY_SIZE(buffer), OFN_EXPLORER | OFN_ENABLEHOOK);
    ofn.lpfnHook = ofn_hook;
    ret = GetOpenFileNameW(&ofn);
    check(!ret && wine_dialog_seen && hook_calls == 1, "%s: OFN with a hook shows the Wine dialog", why);

    /* With the gate on, only dialogs that let the user type a new file name stay Wine. */
    wine_dialog_seen = FALSE;
    buffer[0] = 0;
    init_ofn(&ofn, buffer, ARRAY_SIZE(buffer), OFN_EXPLORER | (hook_only ? OFN_CREATEPROMPT : 0));
    ret = GetOpenFileNameW(&ofn);
    check(!ret && wine_dialog_seen, "%s: GetOpenFileNameW%s shows the Wine dialog", why,
          hook_only ? " with OFN_CREATEPROMPT" : "");

    wine_dialog_seen = FALSE;
    dialog = create_dialog(&CLSID_FileOpenDialog, NULL, NULL);
    if (dialog && hook_only) IFileDialog_SetOptions(dialog, FOS_CREATEPROMPT | FOS_PATHMUSTEXIST);
    hr = dialog ? IFileDialog_Show(dialog, owner) : E_FAIL;
    check(hr == HRESULT_FROM_WIN32(ERROR_CANCELLED) && wine_dialog_seen,
          "%s: IFileDialog::Show%s shows the Wine dialog (0x%08lx)", why,
          hook_only ? " with FOS_CREATEPROMPT" : "", hr);
    if (dialog) IFileDialog_Release(dialog);
    KillTimer(NULL, timer);
}

/**************************************************************************
 * The dialog window, re-entry, owner activation, changes made outside event
 * handlers, names that Windows cannot use.
 */
static void set_gate(const WCHAR *value)
{
    set_env(L"MACSW_NATIVE_FILE_DIALOGS", value);
}

/* A program that asks for the dialog window while it opens gets it (the
   hidden one) and then the Wine dialog (gate 1); with "all" it gets the panel
   and GetWindow() gives the hidden window in every event. */
static int thread_windows(void);
static struct events *parked_events;
static BOOL parked_alive;

/* While the Wine dialog runs, the hidden window it replaced is still there, hidden. */
static void CALLBACK check_parked_and_close(HWND hwnd, UINT msg, UINT_PTR id, DWORD time)
{
    HWND shadow = parked_events->shadow;

    parked_alive = IsWindow(shadow) && !IsWindowVisible(shadow);
    close_wine_dialog(hwnd, msg, id, time);
}

static void test_dialog_window(void)
{
    struct events events;
    IFileDialog *dialog;
    IShellItem *result = NULL;
    DWORD cookie;
    UINT_PTR timer;
    HRESULT hr;
    int before = thread_windows();

    reset_test_env();
    set_response(file_a, NULL);
    if (!(dialog = create_dialog(&CLSID_FileOpenDialog, &events, &cookie))) return;
    IFileDialog_SetFileTypes(dialog, ARRAY_SIZE(text_filters), text_filters);
    events.ask_window = TRUE;
    wine_dialog_seen = FALSE;
    parked_events = &events;
    parked_alive = FALSE;
    timer = SetTimer(NULL, 0, 1500, check_parked_and_close);
    hr = IFileDialog_Show(dialog, owner);
    KillTimer(NULL, timer);
    check(hr == HRESULT_FROM_WIN32(ERROR_CANCELLED) && wine_dialog_seen,
          "window: asked for while the dialog opens, the Wine dialog is shown (0x%08lx)", hr);
    check(events.window_calls >= 2 && events.window_ok == events.window_calls && events.window_real == events.window_ok,
          "window: GetWindow gives a window before the Wine dialog and in it (%d calls, %d ok, %d real)",
          events.window_calls, events.window_ok, events.window_real);
    check(parked_alive && !IsWindow(events.shadow),
          "window: the first, hidden, window lives until Show() returns (alive %d)", parked_alive);
    IFileDialog_Unadvise(dialog, cookie);
    IFileDialog_Release(dialog);
    check(thread_windows() == before, "window: no window left (%d before, %d after)", before, thread_windows());

    set_gate(L"all");
    reset_test_env();
    set_response(file_a, NULL);
    if ((dialog = create_dialog(&CLSID_FileOpenDialog, &events, &cookie)))
    {
        IFileDialog_SetFileTypes(dialog, ARRAY_SIZE(text_filters), text_filters);
        events.ask_window = TRUE;
        hr = IFileDialog_Show(dialog, owner);
        check(hr == S_OK && SUCCEEDED(IFileDialog_GetResult(dialog, &result)) && item_path_is(result, file_a),
              "window all: the panel is shown anyway (0x%08lx)", hr);
        if (result) IShellItem_Release(result);
        check(events.window_calls >= 2 && events.window_ok == events.window_calls &&
              events.window_real == events.window_calls,
              "window all: GetWindow gives the hidden window in every event (%d calls, %d ok, %d real)",
              events.window_calls, events.window_ok, events.window_real);
        IFileDialog_Unadvise(dialog, cookie);
        IFileDialog_Release(dialog);
    }
    set_gate(L"1");
}

/* "all": the hidden dialog window, from the first event to the end of Show(). */
static void test_shadow_window(void)
{
    struct events events;
    IFileDialog *dialog;
    IShellItem *result = NULL;
    DWORD cookie;
    HRESULT hr;

    set_gate(L"all");
    reset_test_env();
    set_response(file_a, NULL);
    if ((dialog = create_dialog(&CLSID_FileOpenDialog, &events, &cookie)))
    {
        IFileDialog_SetFileTypes(dialog, ARRAY_SIZE(text_filters), text_filters);
        events.inspect = TRUE;
        events.refuse_fileok = 1;
        SetActiveWindow(owner);
        SetFocus(owner_edit);
        hr = IFileDialog_Show(dialog, owner);
        check(hr == S_OK && SUCCEEDED(IFileDialog_GetResult(dialog, &result)) && item_path_is(result, file_a),
              "shadow: the panel's result (0x%08lx)", hr);
        if (result) IShellItem_Release(result);
        check(events.fileok == 2 && events.fileok_same_window == 2,
              "shadow: OnFileOk (twice, S_FALSE once) gets the same window, hidden again (%d, %d)",
              events.fileok, events.fileok_same_window);
        check(!lstrcmpiW(events.fileok_name, L"a.txt") && !lstrcmpiW(events.fileok_edit, L"a.txt"),
              "shadow: GetFileName and its file name box are the panel's name in OnFileOk (%s, %s)",
              w2a(events.fileok_name), w2a(events.fileok_edit));
        /* The test hook goes to the file's folder and selects it before it answers. */
        check(events.folderchange >= 2 && !lstrcmpiW(events.folder_seen, dir),
              "shadow: the hook's folder line gives OnFolderChange in the file's folder (%d, %s)",
              events.folderchange, w2a(events.folder_seen));
        check(events.selchange >= 1 && events.selchange_window == events.selchange &&
              !lstrcmpiW(events.selection_seen, file_a),
              "shadow: its selection line gives OnSelectionChange with the file, GetWindow gives the hidden window (%d, %d, %s)",
              events.selchange, events.selchange_window, w2a(events.selection_seen));
        check(events.shadow && !IsWindow(events.shadow) && shadow_ncdestroy == 1,
              "shadow: destroyed when Show() returns (%p, WM_NCDESTROY %d)", events.shadow, shadow_ncdestroy);
        check(IsWindowEnabled(owner) && GetActiveWindow() == owner && GetFocus() == owner_edit,
              "shadow: owner enabled and active, focus back (active %p, focus %p)", GetActiveWindow(), GetFocus());
        IFileDialog_Unadvise(dialog, cookie);
        IFileDialog_Release(dialog);
    }

    /* A save dialog has it too. */
    reset_test_env();
    set_response(file_b, NULL);
    if ((dialog = create_dialog(&CLSID_FileSaveDialog, &events, &cookie)))
    {
        events.inspect = TRUE;
        hr = IFileDialog_Show(dialog, owner);
        check(hr == S_OK && events.shadow && events.fileok_same_window == 1 && !IsWindow(events.shadow),
              "shadow: save dialogs too (0x%08lx, %p, %d)", hr, events.shadow, events.fileok_same_window);
        IFileDialog_Unadvise(dialog, cookie);
        IFileDialog_Release(dialog);
    }
    set_gate(L"1");
}

static struct events *cancel_events;

static void CALLBACK cancel_hidden_window(HWND hwnd, UINT msg, UINT_PTR id, DWORD time)
{
    KillTimer(NULL, id);
    PostMessageW(cancel_events->shadow, WM_COMMAND, IDCANCEL, 0);
}

static int count_thread_windows;

static BOOL CALLBACK count_window(HWND hwnd, LPARAM lparam)
{
    count_thread_windows++;
    return TRUE;
}

static int thread_windows(void)
{
    count_thread_windows = 0;
    EnumThreadWindows(GetCurrentThreadId(), count_window, 0);
    return count_thread_windows;
}

/* IDCANCEL sent to the hidden window ends Show() like the Wine dialog's
   Cancel; and no hidden window is left behind. */
static void test_shadow_cancel(void)
{
    struct events events;
    IFileDialog *dialog;
    DWORD cookie;
    UINT_PTR timer;
    HRESULT hr;
    int before, i, failed = 0;

    set_gate(L"all");
    reset_test_env();
    set_env(L"MACSW_NATIVE_FILE_DIALOG_TEST_DELAY_MS", L"3000");
    set_response(file_a, NULL);
    if ((dialog = create_dialog(&CLSID_FileOpenDialog, &events, &cookie)))
    {
        events.ask_window = TRUE;
        cancel_events = &events;
        timer = SetTimer(NULL, 0, 800, cancel_hidden_window);
        hr = IFileDialog_Show(dialog, owner);
        KillTimer(NULL, timer);
        check(hr == HRESULT_FROM_WIN32(ERROR_CANCELLED) && !events.fileok && IsWindowEnabled(owner),
              "shadow: IDCANCEL to the hidden window cancels the panel (0x%08lx, OnFileOk %d)", hr, events.fileok);
        IFileDialog_Unadvise(dialog, cookie);
        IFileDialog_Release(dialog);
    }

    before = thread_windows();
    for (i = 0; i < 10; i++)
    {
        reset_test_env();
        set_env(L"MACSW_NATIVE_FILE_DIALOG_TEST_DELAY_MS", L"0");
        set_response(NULL, NULL);
        if (!(dialog = create_dialog(&CLSID_FileOpenDialog, NULL, NULL))) break;
        if (IFileDialog_Show(dialog, owner) != HRESULT_FROM_WIN32(ERROR_CANCELLED)) failed++;
        IFileDialog_Release(dialog);
    }
    check(!failed && thread_windows() == before, "shadow: 10 cancelled panels leave no window (%d before, %d after, %d failed)",
          before, thread_windows(), failed);
    set_gate(L"1");
}

/* Gate unset: the Wine dialog hands out its window as before. */
static void test_wine_dialog_window(const char *why)
{
    struct events events;
    IFileDialog *dialog;
    DWORD cookie;
    UINT_PTR timer;

    if (!(dialog = create_dialog(&CLSID_FileOpenDialog, &events, &cookie))) return;
    IFileDialog_SetFileTypes(dialog, ARRAY_SIZE(text_filters), text_filters);
    events.ask_window = TRUE;
    wine_dialog_seen = FALSE;
    timer = SetTimer(NULL, 0, 1500, close_wine_dialog);
    IFileDialog_Show(dialog, owner);
    KillTimer(NULL, timer);
    check(wine_dialog_seen && events.window_calls >= 1 && events.window_real == events.window_calls,
          "%s: GetWindow gives the Wine dialog's window (%d calls, %d real)", why, events.window_calls,
          events.window_real);
    IFileDialog_Unadvise(dialog, cookie);
    IFileDialog_Release(dialog);
}

static IFileDialog *timer_dialog;
static HRESULT reentry_hr;

static void CALLBACK show_again(HWND hwnd, UINT msg, UINT_PTR id, DWORD time)
{
    UINT_PTR timer;

    KillTimer(NULL, id);
    timer = SetTimer(NULL, 0, 1000, close_wine_dialog);
    reentry_hr = IFileDialog_Show(timer_dialog, owner);
    KillTimer(NULL, timer);
}

static void test_reentry(void)
{
    UINT_PTR timer;
    HRESULT hr;

    reset_test_env();
    set_env(L"MACSW_NATIVE_FILE_DIALOG_TEST_DELAY_MS", L"1500");
    set_response(file_a, NULL);
    if (!(timer_dialog = create_dialog(&CLSID_FileOpenDialog, NULL, NULL))) return;
    reentry_hr = 0x12345678;
    wine_dialog_seen = FALSE;
    timer = SetTimer(NULL, 0, 400, show_again);
    hr = IFileDialog_Show(timer_dialog, owner);
    KillTimer(NULL, timer);
    check(hr == S_OK && reentry_hr == E_UNEXPECTED && !wine_dialog_seen,
          "re-entry: Show() while its panel is up fails, no second dialog (0x%08lx, 0x%08lx)", hr, reentry_hr);
    IFileDialog_Release(timer_dialog);
}

static void CALLBACK change_dialog(HWND hwnd, UINT msg, UINT_PTR id, DWORD time)
{
    IShellItem *folder;

    KillTimer(NULL, id);
    IFileDialog_SetFileTypeIndex(timer_dialog, 3);
    if (SUCCEEDED(SHCreateItemFromParsingName(subdir, NULL, &IID_IShellItem, (void **)&folder)))
    {
        IFileDialog_SetFolder(timer_dialog, folder);
        IShellItem_Release(folder);
    }
}

/* SetFileTypeIndex/SetFolder from a timer, not from an event handler. */
static void test_changes_outside_events(void)
{
    struct events events;
    DWORD cookie;
    UINT type = 0;
    UINT_PTR timer;
    HRESULT hr;

    reset_test_env();
    set_env(L"MACSW_NATIVE_FILE_DIALOG_TEST_DELAY_MS", L"2000");
    set_response(file_a, NULL);
    if (!(timer_dialog = create_dialog(&CLSID_FileOpenDialog, &events, &cookie))) return;
    IFileDialog_SetFileTypes(timer_dialog, ARRAY_SIZE(text_filters), text_filters);
    timer = SetTimer(NULL, 0, 500, change_dialog);
    hr = IFileDialog_Show(timer_dialog, owner);
    KillTimer(NULL, timer);
    IFileDialog_GetFileTypeIndex(timer_dialog, &type);
    check(hr == S_OK && type == 3, "outside events: SetFileTypeIndex reaches the panel (0x%08lx, %u)", hr, type);
    /* The test hook then goes to the answer's folder (dir), so look for any visit. */
    check(events.subdir_seen >= 1, "outside events: SetFolder navigates the panel (%d, last %s)",
          events.subdir_seen, w2a(events.folder_seen));
    IFileDialog_Unadvise(timer_dialog, cookie);
    IFileDialog_Release(timer_dialog);
}

static void test_close_in_fileok(void)
{
    struct events events;
    IFileDialog *dialog;
    DWORD cookie;
    HRESULT hr;

    reset_test_env();
    set_response(file_a, NULL);
    if (!(dialog = create_dialog(&CLSID_FileOpenDialog, &events, &cookie))) return;
    events.close_in_fileok = TRUE;
    hr = IFileDialog_Show(dialog, owner);
    check(hr == S_FALSE && events.fileok == 1, "close: Close(S_FALSE) in OnFileOk ends Show, no new panel (0x%08lx, %d)",
          hr, events.fileok);
    IFileDialog_Unadvise(dialog, cookie);
    IFileDialog_Release(dialog);
}

/* Activation and focus go back where they were. */
static void test_owner_activation(void)
{
    IFileDialog *dialog;
    HWND outer;
    BOOL before;
    HRESULT hr;

    reset_test_env();
    set_response(file_a, NULL);
    if (!(dialog = create_dialog(&CLSID_FileOpenDialog, NULL, NULL))) return;
    SetActiveWindow(owner);
    SetFocus(owner_edit);
    before = GetActiveWindow() == owner && GetFocus() == owner_edit;
    hr = IFileDialog_Show(dialog, owner);
    check(before && hr == S_OK && GetActiveWindow() == owner && GetFocus() == owner_edit,
          "owner: active again, focus back in its child (before %d, active %p, focus %p)", before,
          GetActiveWindow(), GetFocus());

    /* Another modal window had disabled the owner: it stays disabled and that window gets activation back. */
    outer = CreateWindowExW(0, L"STATIC", L"outer modal window", WS_POPUP | WS_CAPTION | WS_VISIBLE,
                            200, 200, 320, 200, owner, NULL, NULL, NULL);
    EnableWindow(owner, FALSE);
    SetActiveWindow(outer);
    before = GetActiveWindow() == outer;
    reset_test_env();
    set_response(file_a, NULL);
    hr = IFileDialog_Show(dialog, owner);
    check(before && hr == S_OK && !IsWindowEnabled(owner) && GetActiveWindow() == outer,
          "owner: disabled by another window, that window is active again (before %d, active %p)", before,
          GetActiveWindow());
    EnableWindow(owner, TRUE);
    DestroyWindow(outer);
    SetActiveWindow(owner);
    IFileDialog_Release(dialog);
}

/* A '/' in a filter's extension once made the Format change raise in AppKit. */
static void test_odd_filter(void)
{
    static const COMDLG_FILTERSPEC filters[] = { { L"Text files", L"*.txt" }, { L"Odd", L"*.a/b" } };
    IFileDialog *dialog;
    IShellItem *result = NULL;
    WCHAR expected[MAX_PATH];
    HRESULT hr;

    reset_test_env();
    PathCombineW(expected, dir, L"odd-filter.txt");
    set_response(expected, NULL);
    set_env(L"MACSW_NATIVE_FILE_DIALOG_TEST_TYPE", L"2");
    if (!(dialog = create_dialog(&CLSID_FileSaveDialog, NULL, NULL))) return;
    IFileDialog_SetFileTypes(dialog, ARRAY_SIZE(filters), filters);
    IFileDialog_SetFileName(dialog, L"Untitled.txt");
    hr = IFileDialog_Show(dialog, owner);
    check(hr == S_OK && SUCCEEDED(IFileDialog_GetResult(dialog, &result)) && item_path_is(result, expected),
          "odd filter: '*.a/b' does not break the Format change (0x%08lx)", hr);
    if (result) IShellItem_Release(result);
    IFileDialog_Release(dialog);
}

static void test_ofn_multi_folders(void)
{
    WCHAR buffer[1024];
    OPENFILENAMEW ofn;
    BOOL ret;

    reset_test_env();
    set_response(file_a, file_c);
    buffer[0] = 0;
    init_ofn(&ofn, buffer, ARRAY_SIZE(buffer), OFN_EXPLORER | OFN_ALLOWMULTISELECT | OFN_FILEMUSTEXIST);
    ret = GetOpenFileNameW(&ofn);
    check(ret && !lstrcmpiW(buffer, file_a) && !buffer[lstrlenW(buffer) + 1] &&
          ofn.nFileOffset == PathFindFileNameW(file_a) - file_a,
          "ofn multi: an item from another folder is left out (%s, offset %u)", w2a(buffer), ofn.nFileOffset);
}

static const char * const odd_names[] = { "q?x.txt", "pi|pe.txt", "quo\"te.txt", "trail. " };

/* Names a macOS file can have but a Windows program cannot open. */
static void test_windows_names(void)
{
    WCHAR buffer[MAX_PATH];
    OPENFILENAMEW ofn;
    HANDLE file;
    BOOL ret;
    UINT i;

    if (!odd_dir[0])
    {
        check(FALSE, "names: the test files could not be created");
        return;
    }
    for (i = 0; i < ARRAY_SIZE(odd_names); i++)
    {
        reset_test_env();
        set_response_odd(odd_names[i]);
        buffer[0] = 0;
        init_ofn(&ofn, buffer, ARRAY_SIZE(buffer), OFN_EXPLORER | OFN_FILEMUSTEXIST);
        ret = GetOpenFileNameW(&ofn);
        file = CreateFileW(buffer, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
        check(ret && file != INVALID_HANDLE_VALUE, "names: '%s' comes back as a name Windows opens (%s)",
              odd_names[i], w2a(buffer));
        if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
    }

    reset_test_env();
    set_response_odd("new?name.txt");
    buffer[0] = 0;
    init_ofn(&ofn, buffer, ARRAY_SIZE(buffer), OFN_EXPLORER | OFN_OVERWRITEPROMPT);
    ret = GetSaveFileNameW(&ofn);
    check(!ret && !CommDlgExtendedError(), "names: a save panel refuses 'new?name.txt'");
}

/**************************************************************************/
static DWORD WINAPI watchdog(void *arg)
{
    Sleep((DWORD)(UINT_PTR)arg);
    printf("FAIL timeout: a dialog did not end\n");
    fflush(stdout);
    ExitProcess(100);
}

static void create_files(void)
{
    HANDLE file;

    /* Point FILE_DIALOG_PROBE_DIR outside ~/Desktop, ~/Documents and ~/Downloads
       so that browsing the panel never needs a macOS folder permission. */
    if (!GetEnvironmentVariableW(L"FILE_DIALOG_PROBE_DIR", dir, MAX_PATH))
    {
        GetTempPathW(MAX_PATH, dir);
        PathAppendW(dir, L"macsw-filedlg");
    }
    CreateDirectoryW(dir, NULL);
    PathCombineW(file_a, dir, L"a.txt");
    PathCombineW(file_b, dir, L"b.txt");
    PathCombineW(subdir, dir, L"sub");
    CreateDirectoryW(subdir, NULL);
    PathCombineW(file_c, subdir, L"c.txt");
    file = CreateFileW(file_a, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
    CloseHandle(file);
    file = CreateFileW(file_b, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
    CloseHandle(file);
    file = CreateFileW(file_c, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
    CloseHandle(file);

    /* Files whose unix names Windows cannot spell; created through \\?\unix\. */
    PathCombineW(odd_dir, dir, L"odd");
    CreateDirectoryW(odd_dir, NULL);
    {
        char *unix_dir = pwine_get_unix_file_name(odd_dir);
        WCHAR path[2 * MAX_PATH], *p;
        UINT i;

        for (i = 0; unix_dir && i < ARRAY_SIZE(odd_names); i++)
        {
            int len;

            lstrcpyW(path, L"\\\\?\\unix");
            len = lstrlenW(path);
            len += MultiByteToWideChar(CP_UTF8, 0, unix_dir, -1, path + len, ARRAY_SIZE(path) - len) - 1;
            path[len++] = '/';
            MultiByteToWideChar(CP_UTF8, 0, odd_names[i], -1, path + len, ARRAY_SIZE(path) - len);
            for (p = path + 8; *p; p++) if (*p == '/') *p = '\\';
            file = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
            if (file == INVALID_HANDLE_VALUE)
            {
                printf("     cannot create %s (error %lu)\n", odd_names[i], GetLastError());
                odd_dir[0] = 0;
                break;
            }
            CloseHandle(file);
        }
        HeapFree(GetProcessHeap(), 0, unix_dir);
    }
}

int wmain(int argc, WCHAR **argv)
{
    const WCHAR *mode = argc > 1 ? argv[1] : L"native";

    pwine_get_unix_file_name = (void *)GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "wine_get_unix_file_name");
    if (!pwine_get_unix_file_name)
    {
        printf("FAIL not running under Wine\n");
        return 1;
    }
    CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    create_files();
    owner = CreateWindowExW(0, L"STATIC", L"MacSW file dialog probe", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                            120, 120, 720, 480, NULL, NULL, NULL, NULL);
    owner_edit = CreateWindowExW(0, L"EDIT", L"", WS_CHILD | WS_VISIBLE | WS_BORDER, 10, 10, 240, 24, owner,
                                 NULL, NULL, NULL);
    UpdateWindow(owner);
    CloseHandle(CreateThread(NULL, 0, watchdog, (void *)(UINT_PTR)(lstrcmpW(mode, L"show") ? 300000 : 180000),
                             0, NULL));
    printf("probe: %s, %d-bit, dir %s\n", w2a(mode), (int)sizeof(void *) * 8, w2a(dir));

    if (!lstrcmpW(mode, L"show"))
    {
        /* One real panel with the custom controls, kept up for a screenshot. */
        panel_delay = argc > 2 ? argv[2] : L"8000";
        test_open_with_controls(owner);
    }
    else if (!lstrcmpW(mode, L"shadow"))
    {
        test_dialog_window();
        test_shadow_window();
        test_shadow_cancel();
    }
    else if (!lstrcmpW(mode, L"wine"))
    {
        test_wine_dialogs("gate unset", FALSE);
        test_wine_dialog_window("gate unset");
    }
    else
    {
        test_open_with_controls(owner);
        test_open_with_controls(NULL);
        test_open_multi();
        test_pick_folder();
        test_save(L"newfile", NULL, 1, L"newfile.txt", FALSE);
        test_save(L"report", L"3", 3, L"report.txt", FALSE);
        test_save(L"model", L"2", 2, L"model.step", FALSE);
        test_save(L"a.txt", NULL, 1, L"a.txt", TRUE);
        test_fileok_refused();
        test_cancel();
        test_ofn_open();
        test_ofn_readonly();
        test_ofn_multi();
        test_ofn_save();
        test_ofn_ansi();
        test_ofn_cancel();
        test_wine_dialogs("fallback", TRUE);
        test_dialog_window();
        test_shadow_window();
        test_shadow_cancel();
        test_reentry();
        test_changes_outside_events();
        test_close_in_fileok();
        test_owner_activation();
        test_odd_filter();
        test_ofn_multi_folders();
        test_windows_names();
    }
    printf("%u checks, %u failures\n", checks, failures);
    fflush(stdout);
    DestroyWindow(owner);
    CoUninitialize();
    return failures;
}
