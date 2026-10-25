using System;
using System.Text;
using System.Runtime.InteropServices;

class DumpAllSwWindows {
    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumChildWindows(IntPtr hWnd, EnumWindowsProc lpEnumFunc, IntPtr lParam);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

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
        EnumWindows((hWnd, lp0) => {
            StringBuilder title = new StringBuilder(256);
            GetWindowTextW(hWnd, title, 256);
            string tStr = title.ToString();
            if (tStr.Contains("SOLIDWORKS")) {
                Console.WriteLine(string.Format("=== TOP HWND: 0x{0:X}, Title: '{1}' ===", hWnd.ToInt64(), tStr));
                DumpChildren(hWnd, 1);
            }
            return true;
        }, IntPtr.Zero);
    }

    static void DumpChildren(IntPtr parent, int indent) {
        EnumChildWindows(parent, (child, lp) => {
            if (GetParent(child) != parent) return true; // only direct children to show true tree hierarchy

            StringBuilder cls = new StringBuilder(256);
            GetClassNameW(child, cls, 256);
            StringBuilder title = new StringBuilder(256);
            GetWindowTextW(child, title, 256);
            RECT r;
            GetWindowRect(child, out r);
            int style = GetWindowLongW(child, GWL_STYLE);
            int exstyle = GetWindowLongW(child, GWL_EXSTYLE);
            bool vis = IsWindowVisible(child);

            string ind = new string(' ', indent * 2);
            Console.WriteLine(string.Format("{0}[0x{1:X}] Cls='{2}' Title='{3}' Rect=({4},{5},{6},{7}) W={8} H={9} Vis={10} Style=0x{11:X8} ExStyle=0x{12:X8}",
                ind, child.ToInt64(), cls, title, r.Left, r.Top, r.Right, r.Bottom, r.Right - r.Left, r.Bottom - r.Top, vis, style, exstyle));

            DumpChildren(child, indent + 1);
            return true;
        }, IntPtr.Zero);
    }
}
