using System;
using System.Text;
using System.Runtime.InteropServices;

class QueryTree {
    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [StructLayout(LayoutKind.Sequential)]
    struct RECT {
        public int Left, Top, Right, Bottom;
    }

    [DllImport("user32.dll")]
    static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    const uint TV_FIRST = 0x1100;
    const uint TVM_GETCOUNT = TV_FIRST + 5;
    const uint TVM_GETBKCOLOR = TV_FIRST + 31;
    const uint TVM_GETTEXTCOLOR = TV_FIRST + 32;
    const uint TVM_GETITEMHEIGHT = TV_FIRST + 28;
    const uint TVM_GETNEXTITEM = TV_FIRST + 10;
    const uint TVGN_ROOT = 0;
    const uint TVGN_NEXTVISIBLE = 6;

    static bool EnumChild(IntPtr hwnd, IntPtr lParam) {
        StringBuilder cls = new StringBuilder(256);
        GetClassName(hwnd, cls, 256);
        if (cls.ToString() == "SysTreeView32") {
            RECT rect;
            GetWindowRect(hwnd, out rect);
            int count = (int)SendMessage(hwnd, TVM_GETCOUNT, IntPtr.Zero, IntPtr.Zero);
            int bkColor = (int)SendMessage(hwnd, TVM_GETBKCOLOR, IntPtr.Zero, IntPtr.Zero);
            int txtColor = (int)SendMessage(hwnd, TVM_GETTEXTCOLOR, IntPtr.Zero, IntPtr.Zero);
            int itemHeight = (int)SendMessage(hwnd, TVM_GETITEMHEIGHT, IntPtr.Zero, IntPtr.Zero);
            IntPtr root = SendMessage(hwnd, TVM_GETNEXTITEM, (IntPtr)TVGN_ROOT, IntPtr.Zero);
            
            Console.WriteLine(string.Format("=== SysTreeView32: 0x{0:X8} ===", hwnd.ToInt64()));
            Console.WriteLine(string.Format("  Rect: ({0},{1}) {2}x{3} | Vis: {4}", rect.Left, rect.Top, rect.Right-rect.Left, rect.Bottom-rect.Top, IsWindowVisible(hwnd)));
            Console.WriteLine(string.Format("  Item Count: {0} | Root Item: 0x{1:X8}", count, root.ToInt64()));
            Console.WriteLine(string.Format("  BkColor: 0x{0:X8} | TxtColor: 0x{1:X8} | ItemHeight: {2}", bkColor, txtColor, itemHeight));

            int style = GetWindowLong(hwnd, -16);
            int exstyle = GetWindowLong(hwnd, -20);
            Console.WriteLine(string.Format("  Style: 0x{0:X8} | ExStyle: 0x{1:X8}", style, exstyle));
        }
        return true;
    }

    static bool EnumTop(IntPtr hwnd, IntPtr lParam) {
        StringBuilder cls = new StringBuilder(256);
        GetClassName(hwnd, cls, 256);
        StringBuilder title = new StringBuilder(256);
        GetWindowText(hwnd, title, 256);

        if (title.ToString().Contains("SOLIDWORKS") || cls.ToString().Contains("Afx:")) {
            EnumChildWindows(hwnd, EnumChild, IntPtr.Zero);
        }
        return true;
    }

    static void Main() {
        EnumWindows(EnumTop, IntPtr.Zero);
    }
}
