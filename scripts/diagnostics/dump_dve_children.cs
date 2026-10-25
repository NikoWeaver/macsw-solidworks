using System;
using System.Text;
using System.Runtime.InteropServices;

class DumpDveChildren {
    [DllImport("user32.dll")]
    public static extern bool EnumChildWindows(IntPtr hWnd, EnumWindowsProc lpEnumFunc, IntPtr lParam);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern int GetWindowLongW(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool InvalidateRect(IntPtr hWnd, IntPtr lpRect, bool bErase);

    [DllImport("user32.dll")]
    public static extern bool UpdateWindow(IntPtr hWnd);

    [DllImport("uxtheme.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
    static extern int SetWindowTheme(IntPtr hWnd, string pszSubAppName, string pszSubIdList);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    const int GWL_STYLE = -16;
    const int GWL_EXSTYLE = -20;

    static void Main() {
        IntPtr hDve = (IntPtr)0x30D66;
        Console.WriteLine(string.Format("=== Dumping Children of DVEDockedContainer 0x{0:X} ===", hDve.ToInt64()));

        EnumChildWindows(hDve, (child, lp) => {
            StringBuilder cls = new StringBuilder(256);
            GetClassNameW(child, cls, 256);
            StringBuilder title = new StringBuilder(256);
            GetWindowTextW(child, title, 256);
            RECT r;
            GetWindowRect(child, out r);
            int style = GetWindowLongW(child, GWL_STYLE);
            int exstyle = GetWindowLongW(child, GWL_EXSTYLE);
            bool vis = IsWindowVisible(child);

            Console.WriteLine(string.Format("Child 0x{0:X} Cls='{1}' Title='{2}' Rect=({3},{4},{5},{6}) W={7} H={8} Vis={9} Style=0x{10:X8} ExStyle=0x{11:X8}",
                child.ToInt64(), cls, title, r.Left, r.Top, r.Right, r.Bottom, r.Right - r.Left, r.Bottom - r.Top, vis, style, exstyle));
            return true;
        }, IntPtr.Zero);
    }
}
