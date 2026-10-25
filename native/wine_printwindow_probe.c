/* Optional regression probe: owns all windows; never attaches to SOLIDWORKS. */
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <dwmapi.h>
#include <stdio.h>
#include <string.h>

static unsigned prints, clients, checks, failures;
static HWND child;
static const COLORREF root_color = RGB(190,40,60), child_color = RGB(30,170,80);

static void check(BOOL ok, const char *label)
{
    ++checks;
    if (!ok) { ++failures; fprintf(stderr, "FAIL: %s\n", label); }
}

static LRESULT CALLBACK window_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam)
{
    if (msg == WM_PRINT) ++prints;
    if (msg == WM_PAINT || msg == WM_PRINTCLIENT)
    {
        PAINTSTRUCT ps;
        RECT rect;
        HDC dc = msg == WM_PAINT ? BeginPaint(hwnd, &ps) : (HDC)wparam;
        HBRUSH brush = CreateSolidBrush(hwnd == child ? child_color : root_color);
        GetClientRect(hwnd, &rect);
        FillRect(dc, &rect, brush);
        DeleteObject(brush);
        if (msg == WM_PAINT) EndPaint(hwnd, &ps);
        else
        {
            SCROLLINFO si = {sizeof(si), SIF_RANGE | SIF_PAGE, 0, 99, 24, 0, 0};
            ++clients;
            if (hwnd == child) SetScrollInfo(hwnd, SB_VERT, &si, TRUE);
        }
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

static void capture(HINSTANCE instance, unsigned flags, const char *state, BOOL legacy)
{
    HWND cover = NULL;
    HWND root = CreateWindowExW(WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
        L"MacSWPrintWindowProbe", L"PrintWindow regression", WS_OVERLAPPEDWINDOW,
        250, 250, 360, 190, NULL, NULL, instance, NULL);
    check(root != NULL, "create root");
    if (!root) return;
    child = CreateWindowW(L"MacSWPrintWindowProbe", L"", WS_CHILD | WS_VISIBLE,
        0, 0, 300, 24, root, (HMENU)1, instance, NULL);
    check(child != NULL, "create child");
    ShowWindow(root, SW_SHOWNOACTIVATE);
    RedrawWindow(root, NULL, NULL, RDW_INVALIDATE | RDW_ALLCHILDREN | RDW_UPDATENOW);
    /* A fresh native window must reach the compositor before flags=2 capture. */
    DWORD deadline = GetTickCount() + 50;
    MSG message;
    do
    {
        while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE))
        { TranslateMessage(&message); DispatchMessageW(&message); }
        Sleep(1);
    } while ((LONG)(deadline - GetTickCount()) > 0);
    DwmFlush();
    if (!strcmp(state, "offscreen"))
        SetWindowPos(root, NULL, -10000, -10000, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    if (!strcmp(state, "occluded"))
    {
        cover = CreateWindowExW(WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
            L"STATIC", L"", WS_POPUP | WS_VISIBLE, 250, 250, 360, 190,
            NULL, NULL, instance, NULL);
        SetWindowPos(cover, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        UpdateWindow(cover);
    }
    if (!strcmp(state, "hidden")) ShowWindow(root, SW_HIDE);

    RECT wr;
    POINT origin = {0, 0};
    GetWindowRect(root, &wr);
    ClientToScreen(root, &origin);
    HDC screen = GetDC(NULL), dc = CreateCompatibleDC(screen);
    HBITMAP bitmap = CreateCompatibleBitmap(screen, wr.right - wr.left, wr.bottom - wr.top);
    HGDIOBJ old = SelectObject(dc, bitmap);
    ReleaseDC(NULL, screen);
    PatBlt(dc, 0, 0, wr.right - wr.left, wr.bottom - wr.top, BLACKNESS);
    prints = clients = 0;
    check(PrintWindow(root, dc, flags), "PrintWindow succeeds");
    int dx = flags & PW_CLIENTONLY ? 0 : origin.x - wr.left;
    int dy = flags & PW_CLIENTONLY ? 0 : origin.y - wr.top;
    COLORREF a = GetPixel(dc, dx + 20, dy + 60), b = GetPixel(dc, dx + 20, dy + 12);
    printf("state=%s flags=%u print=%u client=%u vscroll=%d pixels=%06lx,%06lx\n",
        state, flags, prints, clients, !!(GetWindowLongW(child, GWL_STYLE) & WS_VSCROLL), a, b);
    if (legacy)
    {
        check(prints > 0 && clients > 0, "unopted Wine retains message-based capture");
        check(GetWindowLongW(child, GWL_STYLE) & WS_VSCROLL, "legacy reproduces scroll side effect");
    }
    else
    {
        check(prints == 0 && clients == 0, "capture does not enter application print handlers");
        check(!(GetWindowLongW(child, GWL_STYLE) & WS_VSCROLL), "capture does not create scrollbar");
        check(a == (!strcmp(state, "hidden") ? RGB(0,0,0) : root_color), "root cached pixels");
        check(b == (!strcmp(state, "hidden") ? RGB(0,0,0) : child_color), "child cached pixels");
    }
    if (!legacy) check(!PrintWindow((HWND)(ULONG_PTR)0xdeadbeef, dc, flags), "invalid window rejected");
    /* Native Windows may report success for a NULL DC; this is not a valid
     * capture request and is deliberately not a pixel compatibility contract. */
    prints = clients = 0;
    SendMessageW(root, WM_PRINT, (WPARAM)dc, PRF_CLIENT | PRF_CHILDREN);
    check(prints > 0 && clients > 0, "explicit WM_PRINT remains message-based");
    SelectObject(dc, old);
    DeleteObject(bitmap);
    DeleteDC(dc);
    if (cover) DestroyWindow(cover);
    DestroyWindow(root);
    child = NULL;
}

int main(int argc, char **argv)
{
    BOOL unaware = FALSE, legacy = FALSE;
    for (int i = 1; i < argc; ++i)
    {
        if (!strcmp(argv[i], "--unaware")) unaware = TRUE;
        else if (!strcmp(argv[i], "--legacy")) legacy = TRUE;
        else { fprintf(stderr, "usage: %s [--unaware] [--legacy]\n", argv[0]); return 2; }
    }
    check(SetProcessDpiAwarenessContext(unaware ? DPI_AWARENESS_CONTEXT_UNAWARE :
        DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2), "set DPI awareness");
    HINSTANCE instance = GetModuleHandleW(NULL);
    WNDCLASSW cls = {0};
    cls.lpfnWndProc = window_proc;
    cls.hInstance = instance;
    cls.lpszClassName = L"MacSWPrintWindowProbe";
    check(RegisterClassW(&cls) != 0, "register class");
    const char *states[] = {"visible", "offscreen", "occluded", "hidden"};
    for (unsigned i = 0; i < sizeof(states) / sizeof(states[0]); ++i)
        for (unsigned flags = 0; flags <= 2; ++flags) capture(instance, flags, states[i], legacy);
    printf("checks=%u failures=%u mode=%s dpi=%s\n", checks, failures,
        legacy ? "legacy" : "surface", unaware ? "unaware" : "aware");
    return failures ? 1 : 0;
}
