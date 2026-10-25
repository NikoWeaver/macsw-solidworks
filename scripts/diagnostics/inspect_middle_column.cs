using System;
using System.Text;
using System.Runtime.InteropServices;

class InspectMiddleColumn {
    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumChildWindows(IntPtr hWnd, EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern IntPtr GetParent(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern int GetWindowLongW(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    const int GWL_STYLE = -16;
    const int GWL_EXSTYLE = -20;

    static void Main() {
        EnumWindows((top, lp) => {
            StringBuilder sb = new StringBuilder(256);
            GetWindowTextW(top, sb, 256);
            if (sb.ToString().Contains("SOLIDWORKS")) {
                EnumChildWindows(top, (child, lp2) => {
                    RECT r;
                    GetWindowRect(child, out r);
                    int w = r.Right - r.Left;
                    int h = r.Bottom - r.Top;
                    if (r.Left >= 280 && r.Left <= 550 && w > 10 && h > 10 && IsWindowVisible(child)) {
                        StringBuilder cls = new StringBuilder(256);
                        GetClassNameW(child, cls, 256);
                        StringBuilder title = new StringBuilder(256);
                        GetWindowTextW(child, title, 256);
                        int style = GetWindowLongW(child, GWL_STYLE);
                        int exstyle = GetWindowLongW(child, GWL_EXSTYLE);
                        Console.WriteLine(string.Format("HWND=0x{0:X} Cls='{1}' Title='{2}' Rect=({3},{4},{5},{6}) W={7} H={8} Style=0x{9:X8} ExStyle=0x{10:X8}",
                            child.ToInt64(), cls, title, r.Left, r.Top, r.Right, r.Bottom, w, h, style, exstyle));
                    }
                    return true;
                }, IntPtr.Zero);
            }
            return true;
        }, IntPtr.Zero);
    }
}
