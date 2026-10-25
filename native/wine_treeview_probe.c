#ifndef UNICODE
#define UNICODE
#endif
#define _UNICODE
#include <windows.h>
#include <commctrl.h>
#include <stdio.h>
#include <wchar.h>

/* Explicit v6 manifest is required: an unmanifested probe tests v5 instead. */
static unsigned int checks, failures;

static void expect(const char *name, LONG actual, LONG expected)
{
    checks++;
    if (actual != expected)
    {
        printf("FAIL %s: got %ld, expected %ld\n", name, actual, expected);
        failures++;
    }
}

static void layout(HWND tree, HTREEITEM root, HTREEITEM child, DWORD style,
                   int width, int indent)
{
    RECT a = {0}, b = {0};
    int root_x = 3 + ((style & TVS_LINESATROOT) ? indent : 0);
    if (width) root_x += width + 3;
    expect("get root rect", TreeView_GetItemRect(tree, root, &a, TRUE), TRUE);
    expect("get child rect", TreeView_GetItemRect(tree, child, &b, TRUE), TRUE);
    expect("indent", (LONG)TreeView_GetIndent(tree), indent);
    expect("root label", a.left, root_x);
    expect("child label", b.left, root_x + indent);
}

static void test_case(DWORD style, int width, BOOL rtl)
{
    HWND parent = CreateWindowW(L"STATIC", L"TreeView layout probe", WS_OVERLAPPEDWINDOW,
                               100, 100, 400, 200, NULL, NULL, NULL, NULL);
    HWND tree = CreateWindowExW(rtl ? WS_EX_LAYOUTRTL : 0, WC_TREEVIEWW, L"",
                               WS_CHILD | style, 0, 0, 320, 120, parent, NULL, NULL, NULL);
    HIMAGELIST images = width ? ImageList_Create(width, 20, ILC_COLOR32, 1, 1) : NULL;
    TVINSERTSTRUCTW insert = {0};
    HTREEITEM root, child;
    RECT rect = {0};
    TVHITTESTINFO hit = {0};
    int indent = width + 3 > 19 ? width + 3 : 19;

    if (!parent || !tree || (width && !images))
    {
        printf("FAIL cannot create test controls\n");
        failures++;
        if (parent) DestroyWindow(parent);
        if (images) ImageList_Destroy(images);
        return;
    }
    if (images) TreeView_SetImageList(tree, images, TVSIL_NORMAL);
    insert.hParent = TVI_ROOT;
    insert.hInsertAfter = TVI_LAST;
    insert.item.mask = TVIF_TEXT | TVIF_IMAGE | TVIF_SELECTEDIMAGE | TVIF_CHILDREN;
    insert.item.pszText = L"Root";
    insert.item.cChildren = 1;
    root = TreeView_InsertItem(tree, &insert);
    insert.hParent = root;
    insert.item.pszText = L"Child";
    insert.item.cChildren = 0;
    child = TreeView_InsertItem(tree, &insert);
    TreeView_Expand(tree, root, TVE_EXPAND);
    printf("case style=%08lx width=%d rtl=%d dpi=%u\n", style, width, rtl, GetDpiForWindow(tree));
    layout(tree, root, child, style, width, indent);

    TreeView_GetItemRect(tree, root, &rect, TRUE);
    hit.pt.x = rect.left + 1;
    hit.pt.y = (rect.top + rect.bottom) / 2;
    expect("label hit item", TreeView_HitTest(tree, &hit) == root, TRUE);
    expect("label hit flag", hit.flags, TVHT_ONITEMLABEL);
    if (width)
    {
        hit.pt.x = rect.left - width - 3 + 1;
        expect("image hit item", TreeView_HitTest(tree, &hit) == root, TRUE);
        expect("image hit flag", hit.flags, TVHT_ONITEMICON);
    }

    TreeView_SetIndent(tree, 80);
    layout(tree, root, child, style, width, 80);
    TreeView_SetImageList(tree, images, TVSIL_NORMAL);
    layout(tree, root, child, style, width, 80);
    TreeView_SetImageList(tree, NULL, TVSIL_NORMAL);
    layout(tree, root, child, style, 0, 80);

    DestroyWindow(parent);
    if (images) ImageList_Destroy(images);
}

int wmain(int argc, WCHAR **argv)
{
    const DWORD styles[] = {0, 0x89, TVS_HASBUTTONS | TVS_LINESATROOT};
    const int widths[] = {0, 16, 20, 32};
    INITCOMMONCONTROLSEX init = {sizeof(init), ICC_TREEVIEW_CLASSES};
    BOOL aware = !(argc > 1 && !wcscmp(argv[1], L"--unaware"));
    if (aware) SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    if (!InitCommonControlsEx(&init)) return 2;
    for (unsigned int rtl = 0; rtl < 2; rtl++)
        for (unsigned int style = 0; style < sizeof(styles) / sizeof(styles[0]); style++)
            for (unsigned int width = 0; width < sizeof(widths) / sizeof(widths[0]); width++)
                test_case(styles[style], widths[width], rtl);
    printf("TreeView v6: %u checks, %u failures\n", checks, failures);
    return failures ? 1 : 0;
}
