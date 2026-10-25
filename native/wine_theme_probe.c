/* SPDX-License-Identifier: Apache-2.0
 * Read-only Win32/common-controls gallery. Never writes colors or touches SW.
 */
#ifndef UNICODE
#define UNICODE
#endif
#define _UNICODE
#include <windows.h>
#include <commctrl.h>
#include <uxtheme.h>
#include <stdio.h>
#include <wchar.h>

/* Wine exposes this historical color slot; public MinGW headers omit its name. */
#ifndef COLOR_ALTERNATEBTNFACE
#define COLOR_ALTERNATEBTNFACE 25
#endif

#define PAGE_COUNT 4
#define ID_EXIT 101
#define ID_TILE 201
#define ID_CASCADE 202
#define ID_MAXIMIZE 203
#define ID_RESTORE 204
#define ID_MESSAGE 301
#define ID_WHITE_BUTTON 401
#define PROBE_SELECT_PAGE (WM_APP + 17)

static HINSTANCE instance;
static HWND tabs, pages[PAGE_COUNT], mdi_client, status_bar;
static HWND documents[2];
static HFONT ui_font;
static int selected_page;
static unsigned int failed_controls;

static const struct { int index; const wchar_t *name; } colors[] = {
    {COLOR_SCROLLBAR, L"Scrollbar"}, {COLOR_BACKGROUND, L"Background"},
    {COLOR_ACTIVECAPTION, L"ActiveTitle"}, {COLOR_INACTIVECAPTION, L"InactiveTitle"},
    {COLOR_MENU, L"Menu"}, {COLOR_WINDOW, L"Window"}, {COLOR_WINDOWFRAME, L"WindowFrame"},
    {COLOR_MENUTEXT, L"MenuText"}, {COLOR_WINDOWTEXT, L"WindowText"},
    {COLOR_CAPTIONTEXT, L"TitleText"}, {COLOR_ACTIVEBORDER, L"ActiveBorder"},
    {COLOR_INACTIVEBORDER, L"InactiveBorder"}, {COLOR_APPWORKSPACE, L"AppWorkSpace"},
    {COLOR_HIGHLIGHT, L"Hilight"}, {COLOR_HIGHLIGHTTEXT, L"HilightText"},
    {COLOR_BTNFACE, L"ButtonFace"}, {COLOR_BTNSHADOW, L"ButtonShadow"},
    {COLOR_GRAYTEXT, L"GrayText"}, {COLOR_BTNTEXT, L"ButtonText"},
    {COLOR_INACTIVECAPTIONTEXT, L"InactiveTitleText"},
    {COLOR_BTNHIGHLIGHT, L"ButtonHilight"}, {COLOR_3DDKSHADOW, L"ButtonDkShadow"},
    {COLOR_3DLIGHT, L"ButtonLight"}, {COLOR_INFOTEXT, L"InfoText"},
    {COLOR_INFOBK, L"InfoWindow"}, {COLOR_ALTERNATEBTNFACE, L"ButtonAlternateFace"},
    {COLOR_HOTLIGHT, L"HotTrackingColor"}, {COLOR_GRADIENTACTIVECAPTION, L"GradientActiveTitle"},
    {COLOR_GRADIENTINACTIVECAPTION, L"GradientInactiveTitle"},
    {COLOR_MENUHILIGHT, L"MenuHilight"}, {COLOR_MENUBAR, L"MenuBar"}
};

static HWND control(HWND parent, const wchar_t *cls, const wchar_t *text, DWORD style,
                    int x, int y, int width, int height, int id)
{
    HWND child = CreateWindowExW(0, cls, text, WS_CHILD | WS_VISIBLE | style,
                                x, y, width, height, parent, (HMENU)(INT_PTR)id, instance, NULL);
    if (child) SendMessageW(child, WM_SETFONT, (WPARAM)ui_font, TRUE);
    else {
        fprintf(stderr, "Cannot create %ls: %lu\n", cls, GetLastError());
        ++failed_controls;
    }
    return child;
}

static void label(HWND parent, const wchar_t *text, int y)
{
    control(parent, L"STATIC", text, 0, 12, y, 480, 22, 0);
}

static void tooltip(HWND target, const wchar_t *text)
{
    HWND tip = CreateWindowExW(WS_EX_TOPMOST, TOOLTIPS_CLASSW, NULL,
                              WS_POPUP | TTS_ALWAYSTIP, CW_USEDEFAULT, CW_USEDEFAULT,
                              CW_USEDEFAULT, CW_USEDEFAULT, target, NULL, instance, NULL);
    TOOLINFOW tool = {0};
    tool.cbSize = sizeof(tool);
    tool.uFlags = TTF_IDISHWND | TTF_SUBCLASS;
    tool.hwnd = GetParent(target);
    tool.uId = (UINT_PTR)target;
    tool.lpszText = (wchar_t *)text;
    SendMessageW(tip, TTM_ADDTOOLW, 0, (LPARAM)&tool);
}

static void buttons_page(HWND page)
{
    label(page, L"Standard, default and disabled buttons", 12);
    HWND normal = control(page, L"BUTTON", L"Normal", BS_PUSHBUTTON | WS_TABSTOP, 12, 40, 145, 36, ID_MESSAGE);
    tooltip(normal, L"Tooltip uses system InfoWindow / InfoText colors.");
    control(page, L"BUTTON", L"Default", BS_DEFPUSHBUTTON | WS_TABSTOP, 170, 40, 145, 36, ID_MESSAGE);
    HWND disabled = control(page, L"BUTTON", L"Disabled", BS_PUSHBUTTON, 328, 40, 145, 36, 0);
    EnableWindow(disabled, FALSE);
    label(page, L"Owner-drawn white background / system ButtonText", 94);
    control(page, L"BUTTON", L"", BS_OWNERDRAW | WS_TABSTOP, 12, 121, 230, 65, ID_WHITE_BUTTON);
    control(page, L"BUTTON", L"Standard background", BS_PUSHBUTTON, 254, 121, 220, 65, ID_MESSAGE);
    label(page, L"Checkboxes and radio buttons (click to change state)", 204);
    control(page, L"BUTTON", L"Unchecked", BS_AUTOCHECKBOX | WS_TABSTOP, 12, 233, 160, 25, 0);
    HWND check = control(page, L"BUTTON", L"Checked", BS_AUTOCHECKBOX, 190, 233, 150, 25, 0);
    SendMessageW(check, BM_SETCHECK, BST_CHECKED, 0);
    check = control(page, L"BUTTON", L"Mixed", BS_AUTO3STATE, 345, 233, 125, 25, 0);
    SendMessageW(check, BM_SETCHECK, BST_INDETERMINATE, 0);
    HWND radio = control(page, L"BUTTON", L"Radio A", BS_AUTORADIOBUTTON | WS_GROUP | WS_TABSTOP, 12, 274, 150, 25, 0);
    SendMessageW(radio, BM_SETCHECK, BST_CHECKED, 0);
    control(page, L"BUTTON", L"Radio B", BS_AUTORADIOBUTTON, 190, 274, 150, 25, 0);
    check = control(page, L"BUTTON", L"Disabled checkbox", BS_AUTOCHECKBOX, 12, 315, 250, 25, 0);
    EnableWindow(check, FALSE);
    control(page, L"BUTTON", L"Group box", BS_GROUPBOX, 12, 367, 462, 120, 0);
    control(page, L"STATIC", L"These are real Windows controls, not painted mockups.", 0, 26, 399, 428, 24, 0);
    control(page, L"BUTTON", L"Press for a standard MessageBox", BS_PUSHBUTTON, 26, 435, 350, 30, ID_MESSAGE);
    label(page, L"Hover Normal to inspect the tooltip. Menus are above.", 510);
}

static void inputs_page(HWND page)
{
    label(page, L"Editable / read-only / disabled / password text", 12);
    control(page, L"EDIT", L"Editable: select this text", WS_BORDER | ES_AUTOHSCROLL | WS_TABSTOP, 12, 40, 460, 28, 0);
    control(page, L"EDIT", L"Read-only uses Control, not Window, background", WS_BORDER | ES_READONLY, 12, 78, 460, 28, 0);
    HWND disabled = control(page, L"EDIT", L"Disabled input", WS_BORDER, 12, 116, 220, 28, 0);
    EnableWindow(disabled, FALSE);
    control(page, L"EDIT", L"Password", WS_BORDER | ES_PASSWORD, 245, 116, 227, 28, 0);
    label(page, L"Multiline editor with scrollbars", 160);
    control(page, L"EDIT", L"Windows system colors\r\nSelect text to check highlight contrast.\r\n"
            L"Dark mode is a palette, not a promise about custom skins.\r\nLine 4\r\nLine 5\r\nLine 6\r\nLine 7\r\nLine 8",
            WS_BORDER | ES_MULTILINE | WS_VSCROLL | WS_HSCROLL | WS_TABSTOP, 12, 188, 460, 120, 0);
    label(page, L"Editable combo / drop-down list", 324);
    for (int i = 0; i < 2; ++i) {
        HWND combo = control(page, L"COMBOBOX", L"", (i ? CBS_DROPDOWNLIST : CBS_DROPDOWN) | WS_VSCROLL,
                             12 + i * 240, 352, 220, 170, 0);
        SendMessageW(combo, CB_ADDSTRING, 0, (LPARAM)L"First item");
        SendMessageW(combo, CB_ADDSTRING, 0, (LPARAM)L"Second item");
        SendMessageW(combo, CB_ADDSTRING, 0, (LPARAM)L"Third item");
        SendMessageW(combo, CB_SETCURSEL, 0, 0);
    }
    label(page, L"Date picker and calendar", 399);
    control(page, DATETIMEPICK_CLASSW, L"", DTS_SHORTDATEFORMAT, 12, 427, 220, 28, 0);
    control(page, MONTHCAL_CLASSW, L"", 0, 245, 427, 225, 175, 0);
    control(page, L"BUTTON", L"Calendar preview", BS_GROUPBOX, 12, 470, 220, 115, 0);
    control(page, L"STATIC", L"Open the date picker.\r\nInspect selection and\r\ninactive text.", 0, 26, 498, 190, 75, 0);
}

static void data_page(HWND page)
{
    label(page, L"List view: header, selected row, grid, scrollbar", 12);
    HWND list = control(page, WC_LISTVIEWW, L"", WS_BORDER | LVS_REPORT | LVS_SHOWSELALWAYS,
                        12, 40, 460, 155, 0);
    ListView_SetExtendedListViewStyle(list, LVS_EX_FULLROWSELECT | LVS_EX_GRIDLINES);
    LVCOLUMNW column = {0};
    column.mask = LVCF_TEXT | LVCF_WIDTH;
    column.cx = 205; column.pszText = L"Component"; ListView_InsertColumn(list, 0, &column);
    column.cx = 135; column.pszText = L"State"; ListView_InsertColumn(list, 1, &column);
    column.cx = 135; column.pszText = L"Detail"; ListView_InsertColumn(list, 2, &column);
    for (int i = 0; i < 8; ++i) {
        wchar_t text[64]; swprintf(text, 64, L"Sample component %d", i + 1);
        LVITEMW item = {0}; item.mask = LVIF_TEXT; item.iItem = i; item.pszText = text;
        ListView_InsertItem(list, &item);
        ListView_SetItemText(list, i, 1, L"Ready");
        ListView_SetItemText(list, i, 2, L"Native control");
    }
    ListView_SetItemState(list, 1, LVIS_SELECTED, LVIS_SELECTED);
    label(page, L"Tree view: expand nodes / change selection", 215);
    HWND tree = control(page, WC_TREEVIEWW, L"", WS_BORDER | TVS_HASLINES | TVS_HASBUTTONS | TVS_LINESATROOT | TVS_SHOWSELALWAYS,
                        12, 242, 460, 142, 0);
    TVINSERTSTRUCTW insert = {0};
    insert.hInsertAfter = TVI_LAST; insert.item.mask = TVIF_TEXT; insert.item.pszText = L"Assembly";
    HTREEITEM root = TreeView_InsertItem(tree, &insert);
    insert.hParent = root; insert.item.pszText = L"Part: active"; HTREEITEM part = TreeView_InsertItem(tree, &insert);
    insert.item.pszText = L"Part: inactive"; TreeView_InsertItem(tree, &insert);
    insert.hParent = part; insert.item.pszText = L"Sketch"; TreeView_InsertItem(tree, &insert);
    TreeView_Expand(tree, root, TVE_EXPAND); TreeView_Expand(tree, part, TVE_EXPAND);
    TreeView_SelectItem(tree, part);
    label(page, L"Progress and slider", 400);
    HWND progress = control(page, PROGRESS_CLASSW, L"", 0, 12, 428, 460, 22, 0);
    SendMessageW(progress, PBM_SETPOS, 65, 0);
    HWND track = control(page, TRACKBAR_CLASSW, L"", TBS_AUTOTICKS, 12, 468, 460, 40, 0);
    SendMessageW(track, TBM_SETPOS, TRUE, 40);
    label(page, L"Numeric input / spin control", 528);
    HWND buddy = control(page, L"EDIT", L"42", WS_BORDER | ES_NUMBER, 12, 556, 140, 28, 0);
    HWND spin = control(page, UPDOWN_CLASSW, L"", UDS_ALIGNRIGHT | UDS_SETBUDDYINT | UDS_ARROWKEYS,
                        0, 0, 0, 0, 0);
    SendMessageW(spin, UDM_SETBUDDY, (WPARAM)buddy, 0);
    SendMessageW(spin, UDM_SETRANGE32, 0, 100);
    SendMessageW(spin, UDM_SETPOS32, 0, 42);
}

static void paint_colors(HWND hwnd, HDC dc)
{
    RECT client; GetClientRect(hwnd, &client);
    int width = (client.right - 24) / 2;
    SelectObject(dc, ui_font);
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, GetSysColor(COLOR_BTNTEXT));
    for (size_t i = 0; i < sizeof(colors) / sizeof(colors[0]); ++i) {
        int x = 12 + (int)(i / 16) * width, y = 12 + (int)(i % 16) * 36;
        COLORREF rgb = GetSysColor(colors[i].index);
        RECT swatch = {x, y + 2, x + 32, y + 29};
        HBRUSH brush = CreateSolidBrush(rgb);
        FillRect(dc, &swatch, brush); DeleteObject(brush);
        FrameRect(dc, &swatch, GetSysColorBrush(COLOR_WINDOWFRAME));
        wchar_t text[96];
        swprintf(text, 96, L"%ls\n%u %u %u", colors[i].name, GetRValue(rgb), GetGValue(rgb), GetBValue(rgb));
        RECT label_rect = {x + 40, y, x + width - 3, y + 34};
        DrawTextW(dc, text, -1, &label_rect, DT_LEFT | DT_NOPREFIX);
    }
}

static LRESULT CALLBACK page_proc(HWND hwnd, UINT msg, WPARAM w, LPARAM l)
{
    if (msg == WM_DRAWITEM) {
        DRAWITEMSTRUCT *item = (DRAWITEMSTRUCT *)l;
        if (item->CtlID == ID_WHITE_BUTTON) {
            FillRect(item->hDC, &item->rcItem, (HBRUSH)GetStockObject(WHITE_BRUSH));
            FrameRect(item->hDC, &item->rcItem, GetSysColorBrush(COLOR_WINDOWFRAME));
            SelectObject(item->hDC, ui_font);
            SetTextColor(item->hDC, GetSysColor(COLOR_BTNTEXT));
            SetBkMode(item->hDC, TRANSPARENT);
            RECT text = item->rcItem; text.top += 16;
            DrawTextW(item->hDC, L"Fixed white background\nSystem ButtonText", -1, &text, DT_CENTER | DT_NOPREFIX);
            return TRUE;
        }
    }
    if (msg == WM_COMMAND && LOWORD(w) == ID_MESSAGE) {
        MessageBoxW(GetAncestor(hwnd, GA_ROOT), L"Native MessageBox text and buttons.\nThis probe does not change the bottle.",
                    L"Theme probe dialog", MB_OKCANCEL | MB_ICONINFORMATION);
        return 0;
    }
    if (msg == WM_PAINT && GetWindowLongPtrW(hwnd, GWLP_ID) == 4) {
        PAINTSTRUCT paint; HDC dc = BeginPaint(hwnd, &paint);
        paint_colors(hwnd, dc); EndPaint(hwnd, &paint);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, w, l);
}

static LRESULT CALLBACK document_proc(HWND hwnd, UINT msg, WPARAM w, LPARAM l)
{
    switch (msg) {
    case WM_CREATE:
        control(hwnd, STATUSCLASSNAMEW, L"Resizable MDI child: size grip at right", SBARS_SIZEGRIP, 0, 0, 0, 0, 10);
        break;
    case WM_SIZE:
        SendMessageW(GetDlgItem(hwnd, 10), WM_SIZE, 0, 0);
        break;
    case WM_PAINT: {
        PAINTSTRUCT paint; HDC dc = BeginPaint(hwnd, &paint);
        RECT rect; GetClientRect(hwnd, &rect); rect.left += 14; rect.top += 18; rect.right -= 12; rect.bottom -= 28;
        SelectObject(dc, ui_font); SetBkMode(dc, TRANSPARENT); SetTextColor(dc, GetSysColor(COLOR_WINDOWTEXT));
        DrawTextW(dc, L"Real Win32 MDI child window\n\nClick the title to activate.\nResize, minimize, maximize or restore.\n"
                  L"The Window menu can tile or cascade.\n\nBackground: COLOR_WINDOW\nText: COLOR_WINDOWTEXT\n\n"
                  L"This is NOT SOLIDWORKS / Codejock.", -1, &rect, DT_WORDBREAK | DT_NOPREFIX);
        EndPaint(hwnd, &paint); return 0;
    }
    }
    return DefMDIChildProcW(hwnd, msg, w, l);
}

static void layout(HWND frame)
{
    RECT rect, status; GetClientRect(frame, &rect);
    SendMessageW(status_bar, WM_SIZE, 0, 0); GetWindowRect(status_bar, &status);
    int bottom = rect.bottom - (status.bottom - status.top) - 10;
    int left_width = rect.right * 47 / 100;
    MoveWindow(tabs, 10, 10, left_width, bottom - 10, TRUE);
    for (int i = 0; i < PAGE_COUNT; ++i)
        MoveWindow(pages[i], 16, 45, left_width - 12, bottom - 52, TRUE);
    MoveWindow(mdi_client, left_width + 32, 10, rect.right - left_width - 42, bottom - 10, TRUE);
}

static void show_page(int page)
{
    selected_page = page;
    TabCtrl_SetCurSel(tabs, page);
    for (int i = 0; i < PAGE_COUNT; ++i) ShowWindow(pages[i], i == page ? SW_SHOW : SW_HIDE);
}

static LRESULT CALLBACK frame_proc(HWND hwnd, UINT msg, WPARAM w, LPARAM l)
{
    switch (msg) {
    case PROBE_SELECT_PAGE:
        if (w < PAGE_COUNT) { show_page((int)w); return (LRESULT)w + 1; }
        return 0;
    case WM_SIZE:
        if (tabs && mdi_client && status_bar) layout(hwnd);
        /* DefFrameProc would resize the MDI client over the controls gallery. */
        return 0;
    case WM_NOTIFY:
        if (((NMHDR *)l)->hwndFrom == tabs && ((NMHDR *)l)->code == TCN_SELCHANGE)
            show_page(TabCtrl_GetCurSel(tabs));
        break;
    case WM_COMMAND: {
        HWND active = (HWND)SendMessageW(mdi_client, WM_MDIGETACTIVE, 0, 0);
        switch (LOWORD(w)) {
        case ID_EXIT: DestroyWindow(hwnd); return 0;
        case ID_TILE: SendMessageW(mdi_client, WM_MDITILE, MDITILE_HORIZONTAL, 0); return 0;
        case ID_CASCADE: SendMessageW(mdi_client, WM_MDICASCADE, 0, 0); return 0;
        case ID_MAXIMIZE: if (active) SendMessageW(mdi_client, WM_MDIMAXIMIZE, (WPARAM)active, 0); return 0;
        case ID_RESTORE: if (active) SendMessageW(mdi_client, WM_MDIRESTORE, (WPARAM)active, 0); return 0;
        case ID_MESSAGE: MessageBoxW(hwnd, L"Only this test process is affected.", L"Theme probe", MB_OKCANCEL | MB_ICONINFORMATION); return 0;
        }
        break;
    }
    case WM_DESTROY: PostQuitMessage(0); return 0;
    }
    return DefFrameProcW(hwnd, mdi_client, msg, w, l);
}

static HMENU create_menu(HMENU *window_menu)
{
    HMENU menu = CreateMenu(), file = CreatePopupMenu(), window = CreatePopupMenu(), dialogs = CreatePopupMenu();
    AppendMenuW(file, MF_STRING, ID_EXIT, L"Close probe");
    AppendMenuW(menu, MF_POPUP, (UINT_PTR)file, L"File");
    AppendMenuW(window, MF_STRING, ID_TILE, L"Tile MDI windows");
    AppendMenuW(window, MF_STRING, ID_CASCADE, L"Cascade MDI windows");
    AppendMenuW(window, MF_STRING, ID_MAXIMIZE, L"Maximize active document");
    AppendMenuW(window, MF_STRING, ID_RESTORE, L"Restore active document");
    AppendMenuW(menu, MF_POPUP, (UINT_PTR)window, L"Window");
    AppendMenuW(dialogs, MF_STRING, ID_MESSAGE, L"Standard MessageBox");
    AppendMenuW(menu, MF_POPUP, (UINT_PTR)dialogs, L"Dialogs");
    *window_menu = window;
    return menu;
}

int wmain(int argc, wchar_t **argv)
{
    if (argc == 3 && !wcscmp(argv[1], L"--show-page")) {
        const wchar_t *names[] = {L"controls", L"inputs", L"data", L"colors"};
        HWND window = FindWindowW(L"MacSWThemeProbeFrame", NULL);
        if (!window) return 1;
        for (int i = 0; i < PAGE_COUNT; ++i)
            if (!wcscmp(argv[2], names[i])) return SendMessageW(window, PROBE_SELECT_PAGE, (WPARAM)i, 0) == i + 1 ? 0 : 1;
        return 2;
    }
    if (argc == 2 && !wcscmp(argv[1], L"--close")) {
        HWND window = FindWindowW(L"MacSWThemeProbeFrame", NULL);
        if (window) PostMessageW(window, WM_CLOSE, 0, 0);
        return 0;
    }
    if (argc == 3 && !wcscmp(argv[1], L"--page")) {
        const wchar_t *names[] = {L"controls", L"inputs", L"data", L"colors"};
        int found = 0;
        for (int i = 0; i < PAGE_COUNT; ++i) if (!wcscmp(argv[2], names[i])) { selected_page = i; found = 1; }
        if (!found) return 2;
    } else if (argc != 1 && !(argc == 2 && (!wcscmp(argv[1], L"--dump-colors") || !wcscmp(argv[1], L"--self-test")))) {
        fwprintf(stderr, L"Usage: wine_theme_probe.exe [--page/--show-page controls|inputs|data|colors | --dump-colors | --self-test | --close]\n");
        return 2;
    }
    printf("ThemeActive=%d AppThemed=%d\n", IsThemeActive(), IsAppThemed());
    for (size_t i = 0; i < sizeof(colors) / sizeof(colors[0]); ++i) {
        COLORREF rgb = GetSysColor(colors[i].index);
        printf("%ls=%u %u %u\n", colors[i].name, GetRValue(rgb), GetGValue(rgb), GetBValue(rgb));
    }
    fflush(stdout);
    if (argc == 2 && !wcscmp(argv[1], L"--dump-colors")) return 0;
    instance = GetModuleHandleW(NULL);
    ui_font = (HFONT)GetStockObject(DEFAULT_GUI_FONT);
    INITCOMMONCONTROLSEX common = {sizeof(common), ICC_WIN95_CLASSES | ICC_DATE_CLASSES};
    if (!InitCommonControlsEx(&common)) return 1;
    WNDCLASSW cls = {0}; cls.hInstance = instance; cls.hCursor = LoadCursorW(NULL, IDC_ARROW);
    cls.lpfnWndProc = frame_proc; cls.hbrBackground = GetSysColorBrush(COLOR_BTNFACE); cls.lpszClassName = L"MacSWThemeProbeFrame";
    if (!RegisterClassW(&cls)) return 1;
    cls.lpfnWndProc = page_proc; cls.lpszClassName = L"MacSWThemeProbePage";
    if (!RegisterClassW(&cls)) return 1;
    cls.lpfnWndProc = document_proc; cls.lpszClassName = L"MacSWThemeProbeDocument"; cls.hbrBackground = GetSysColorBrush(COLOR_WINDOW);
    if (!RegisterClassW(&cls)) return 1;
    HMENU window_menu, menu = create_menu(&window_menu);
    int width = GetSystemMetrics(SM_CXSCREEN) - 80, height = GetSystemMetrics(SM_CYSCREEN) - 100;
    if (width > 1260) width = 1260;
    if (height > 850) height = 850;
    HWND frame = CreateWindowW(L"MacSWThemeProbeFrame", L"MacSW Wine theme probe", WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
                               CW_USEDEFAULT, CW_USEDEFAULT, width, height, NULL, menu, instance, NULL);
    if (!frame) { fprintf(stderr, "CreateWindow failed: %lu\n", GetLastError()); return 1; }
    status_bar = control(frame, STATUSCLASSNAMEW, L"Read-only probe | Change palette in MacSW, then reopen this probe | No SW automation", SBARS_SIZEGRIP, 0, 0, 0, 0, 0);
    tabs = control(frame, WC_TABCONTROLW, L"", WS_TABSTOP | WS_CLIPSIBLINGS, 0, 0, 0, 0, 0);
    const wchar_t *titles[] = {L"Controls", L"Inputs", L"Data", L"System colors"};
    for (int i = 0; i < PAGE_COUNT; ++i) {
        TCITEMW item = {0}; item.mask = TCIF_TEXT; item.pszText = (wchar_t *)titles[i];
        TabCtrl_InsertItem(tabs, i, &item);
        pages[i] = CreateWindowW(L"MacSWThemeProbePage", L"", WS_CHILD | WS_CLIPCHILDREN,
                                 0, 0, 0, 0, frame, (HMENU)(INT_PTR)(i + 1), instance, NULL);
    }
    buttons_page(pages[0]); inputs_page(pages[1]); data_page(pages[2]);
    CLIENTCREATESTRUCT client = {window_menu, 5000};
    mdi_client = CreateWindowExW(WS_EX_CLIENTEDGE, L"MDICLIENT", NULL,
                                 WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN | WS_VSCROLL | WS_HSCROLL,
                                 0, 0, 0, 0, frame, NULL, instance, &client);
    layout(frame);
    for (int i = 0; i < 2; ++i) {
        MDICREATESTRUCTW document = {0}; document.szClass = L"MacSWThemeProbeDocument";
        document.szTitle = i ? L"Document B" : L"Document A";
        document.hOwner = instance; document.x = document.y = CW_USEDEFAULT;
        document.cx = document.cy = CW_USEDEFAULT; document.style = WS_VISIBLE | WS_OVERLAPPEDWINDOW;
        documents[i] = (HWND)SendMessageW(mdi_client, WM_MDICREATE, 0, (LPARAM)&document);
    }
    if (!mdi_client || !documents[0] || !documents[1]) { DestroyWindow(frame); return 1; }
    SendMessageW(mdi_client, WM_MDITILE, MDITILE_HORIZONTAL, 0);
    show_page(selected_page);
    ShowWindow(frame, SW_SHOW); UpdateWindow(frame);
    // Hidden descendants are not eligible for tiling; tile after showing the frame.
    SendMessageW(mdi_client, WM_MDITILE, MDITILE_HORIZONTAL, 0);
    printf("READY pid=%lu controls_failed=%u mdi_children=2\n", GetCurrentProcessId(), failed_controls);
    fflush(stdout);
    if (argc == 2 && !wcscmp(argv[1], L"--self-test")) {
        unsigned int failures = failed_controls;
        RECT frame_rect, mdi_rect;
        GetClientRect(frame, &frame_rect); GetWindowRect(mdi_client, &mdi_rect);
        MapWindowPoints(HWND_DESKTOP, frame, (POINT *)&mdi_rect, 2);
        if (mdi_rect.left < frame_rect.right * 47 / 100) ++failures;
        for (int i = 0; i < PAGE_COUNT; ++i) {
            show_page(i);
            if (!IsWindowVisible(pages[i]) || TabCtrl_GetCurSel(tabs) != i) ++failures;
        }
        BOOL maximized = FALSE;
        SendMessageW(mdi_client, WM_MDIMAXIMIZE, (WPARAM)documents[1], 0);
        SendMessageW(mdi_client, WM_MDIGETACTIVE, 0, (LPARAM)&maximized);
        if (!maximized) ++failures;
        SendMessageW(mdi_client, WM_MDIRESTORE, (WPARAM)documents[1], 0);
        SendMessageW(mdi_client, WM_MDIGETACTIVE, 0, (LPARAM)&maximized);
        if (maximized) ++failures;
        SendMessageW(mdi_client, WM_MDIACTIVATE, (WPARAM)documents[0], 0);
        if ((HWND)SendMessageW(mdi_client, WM_MDIGETACTIVE, 0, 0) != documents[0]) ++failures;
        printf("SELF_TEST=%s failures=%u\n", failures ? "FAIL" : "PASS", failures);
        DestroyWindow(frame);
        return failures ? 1 : 0;
    }
    MSG message; int result;
    while ((result = GetMessageW(&message, NULL, 0, 0)) > 0) {
        if (!TranslateMDISysAccel(mdi_client, &message)) { TranslateMessage(&message); DispatchMessageW(&message); }
    }
    return result < 0 ? 1 : 0;
}
