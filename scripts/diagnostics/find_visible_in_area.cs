using System;
using System.Text;
using System.Runtime.InteropServices;

class FindVisibleWindowsInArea {
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
                        RECT r;
                        GetWindowRect(child, out r);
                        if (r.Left >= 330 && r.Left <= 660 && (r.Right - r.Left) > 10 && (r.Bottom - r.Top) > 10) {
                            StringBuilder cls = new StringBuilder(256);
                            GetClassNameW(child, cls, 256);
                            StringBuilder title = new StringBuilder(256);
                            GetWindowTextW(child, title, 256);
                            IntPtr p = GetParent(child);
                            Console.WriteLine(string.Format("HWND=0x{0:X} Parent=0x{1:X} Cls='{2}' Title='{3}' Rect=({4},{5},{6},{7})",
                                child.ToInt64(), p.ToInt64(), cls, title, r.Left, r.Top, r.Right, r.Bottom));
                        }
                    }
                    return true;
                }, IntPtr.Zero);
            }
            return true;
        }, IntPtr.Zero);
    }
}
