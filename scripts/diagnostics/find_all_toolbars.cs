using System;
using System.Text;
using System.Runtime.InteropServices;

class FindAllToolbars {
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
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    static void Main() {
        EnumWindows((top, lp) => {
            StringBuilder sb = new StringBuilder(256);
            GetWindowTextW(top, sb, 256);
            if (sb.ToString().Contains("SOLIDWORKS")) {
                EnumChildWindows(top, (child, lp2) => {
                    if (IsWindowVisible(child)) {
                        StringBuilder cls = new StringBuilder(256);
                        GetClassNameW(child, cls, 256);
                        string c = cls.ToString();
                        RECT r;
                        GetWindowRect(child, out r);
                        if (c.Contains("Toolbar") || c.Contains("Bar") || c.Contains("Mini") || c.Contains("Pane")) {
                            StringBuilder title = new StringBuilder(256);
                            GetWindowTextW(child, title, 256);
                            Console.WriteLine(string.Format("HWND=0x{0:X} Cls='{1}' Title='{2}' Rect=({3},{4},{5},{6})",
                                child.ToInt64(), c, title, r.Left, r.Top, r.Right, r.Bottom));
                        }
                    }
                    return true;
                }, IntPtr.Zero);
            }
            return true;
        }, IntPtr.Zero);
    }
}
