using System;
using System.Runtime.InteropServices;
using System.Text;

class DisableTreeTheme {
    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("uxtheme.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
    static extern int SetWindowTheme(IntPtr hWnd, string pszSubAppName, string pszSubIdList);

    [DllImport("user32.dll")]
    static extern bool RedrawWindow(IntPtr hWnd, IntPtr lprcUpdate, IntPtr hrgnUpdate, uint flags);

    [DllImport("user32.dll")]
    static extern bool InvalidateRect(IntPtr hWnd, IntPtr lpRect, bool bErase);

    [DllImport("user32.dll")]
    static extern bool UpdateWindow(IntPtr hWnd);

    const uint RDW_INVALIDATE = 0x0001;
    const uint RDW_ERASE = 0x0004;
    const uint RDW_ALLCHILDREN = 0x0080;
    const uint RDW_UPDATENOW = 0x0100;
    const uint RDW_FRAME = 0x0400;

    static void Main() {
        int count = 0;
        EnumWindows(delegate(IntPtr top, IntPtr l) {
            StringBuilder t = new StringBuilder(256);
            GetWindowText(top, t, 256);
            if (t.ToString().Contains("SOLIDWORKS")) {
                EnumChildWindows(top, delegate(IntPtr child, IntPtr l2) {
                    StringBuilder cls = new StringBuilder(256);
                    GetClassName(child, cls, 256);
                    string c = cls.ToString();
                    if (c == "SysTreeView32" || c == "SysTabControl32" || c.Contains("Tree") || c.Contains("View")) {
                        int res = SetWindowTheme(child, " ", " ");
                        Console.WriteLine(string.Format("SetWindowTheme on 0x{0:X8} ({1}) result: 0x{2:X8}", child.ToInt64(), c, res));
                        InvalidateRect(child, IntPtr.Zero, true);
                        UpdateWindow(child);
                        RedrawWindow(child, IntPtr.Zero, IntPtr.Zero, RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_UPDATENOW | RDW_FRAME);
                        count++;
                    }
                    return true;
                }, IntPtr.Zero);
            }
            return true;
        }, IntPtr.Zero);

        Console.WriteLine("Total themed controls reset: " + count);
    }
}
