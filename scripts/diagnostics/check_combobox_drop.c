/* Reproduce the ComboLBox geometry/visibility regression from patch 0005.
 * Build: x86_64-w64-mingw32-gcc -municode -o check_combobox_drop.exe check_combobox_drop.c
 */
#include <windows.h>
#include <stdio.h>

int wmain(void)
{
    HWND window, combo, child;
    COMBOBOXINFO info = { .cbSize = sizeof(info) };
    RECT before, after, combo_rect, child_before, child_after, child_nozorder;
    int i, count, dropped, visible, parent_is_desktop;

    window = CreateWindowExW(0, L"STATIC", L"combo probe", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                            200, 200, 420, 260, NULL, NULL, GetModuleHandleW(NULL), NULL);
    if (!window) return 2;
    combo = CreateWindowExW(0, L"COMBOBOX", NULL, WS_CHILD | WS_VISIBLE | CBS_DROPDOWNLIST,
                            20, 20, 200, 240, window, NULL, GetModuleHandleW(NULL), NULL);
    if (!combo || !GetComboBoxInfo(combo, &info)) return 3;

    for (i = 0; i < 20; i++)
    {
        WCHAR item[32];
        swprintf(item, 32, L"Option %d", i);
        SendMessageW(combo, CB_ADDSTRING, 0, (LPARAM)item);
    }
    SendMessageW(combo, CB_SETCURSEL, 0, 0);
    GetWindowRect(info.hwndList, &before);
    GetWindowRect(combo, &combo_rect);
    SendMessageW(combo, CB_SHOWDROPDOWN, TRUE, 0);
    GetWindowRect(info.hwndList, &after);
    count = (int)SendMessageW(combo, CB_GETCOUNT, 0, 0);
    dropped = (int)SendMessageW(combo, CB_GETDROPPEDSTATE, 0, 0);
    visible = IsWindowVisible(info.hwndList);
    parent_is_desktop = GetAncestor(info.hwndList, GA_PARENT) == GetDesktopWindow();
    printf("count=%d dropped=%d list_visible=%d desktop_parent=%d style_child=%d\n",
           count, dropped, visible, parent_is_desktop,
           !!(GetWindowLongW(info.hwndList, GWL_STYLE) & WS_CHILD));
    printf("combo=(%ld,%ld)-(%ld,%ld) list_before=(%ld,%ld)-(%ld,%ld) list_after=(%ld,%ld)-(%ld,%ld)\n",
           combo_rect.left, combo_rect.top, combo_rect.right, combo_rect.bottom,
           before.left, before.top, before.right, before.bottom,
           after.left, after.top, after.right, after.bottom);

    child = CreateWindowExW(0, L"STATIC", L"child", WS_CHILD | WS_VISIBLE,
                            20, 70, 100, 24, window, NULL, GetModuleHandleW(NULL), NULL);
    if (!child) return 4;
    GetWindowRect(child, &child_before);
    SetWindowPos(child, HWND_TOPMOST, 50, 100, 140, 30, SWP_SHOWWINDOW);
    GetWindowRect(child, &child_after);
    printf("true_child_unchanged=%d\n", EqualRect(&child_before, &child_after));
    SetWindowPos(child, HWND_TOPMOST, 50, 100, 140, 30, SWP_NOZORDER);
    GetWindowRect(child, &child_nozorder);
    printf("true_child_nozorder_moves=%d\n", !EqualRect(&child_after, &child_nozorder));

    DestroyWindow(window);
    return count == 20 && dropped && visible && parent_is_desktop &&
           after.top >= combo_rect.top && after.top <= combo_rect.bottom + 2 &&
           EqualRect(&child_before, &child_after) &&
           !EqualRect(&child_after, &child_nozorder) ? 0 : 1;
}
