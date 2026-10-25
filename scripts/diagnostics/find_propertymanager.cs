using System;
using System.Text;
using System.Runtime.InteropServices;

class FindPropertyManager {
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

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    const int GWL_STYLE = -16;
    const int GWL_EXSTYLE = -20;

    static void Main() {
        Console.WriteLine("Searching for all PropertyManager / DVE / Sketch / Pane windows in running SW...");

        EnumWindows((hWnd, lp) => {
            StringBuilder sb = new StringBuilder(256);
            GetWindowTextW(hWnd, sb, 256);
            if (sb.ToString().Contains("SOLIDWORKS")) {
                Console.WriteLine("SW Main Window: 0x" + hWnd.ToString("X"));
                ScanWindow(hWnd);
            }
            return true;
        }, IntPtr.Zero);
    }

    static void ScanWindow(IntPtr parent) {
        EnumChildWindows(parent, (child, lp) => {
            StringBuilder cls = new StringBuilder(256);
            GetClassNameW(child, cls, 256);
            StringBuilder title = new StringBuilder(256);
            GetWindowTextW(child, title, 256);
            string c = cls.ToString();
            string t = title.ToString();

            if (t.Contains("DVE") || t.Contains("Property") || t.Contains("Sketch") || c.Contains("Mini") || t.Contains("Container") || t.Contains("Tree")) {
                RECT r;
                GetWindowRect(child, out r);
                bool vis = IsWindowVisible(child);
                int style = GetWindowLongW(child, GWL_STYLE);
                int exstyle = GetWindowLongW(child, GWL_EXSTYLE);
                IntPtr p = GetParent(child);

                Console.WriteLine(string.Format("MATCH: HWND=0x{0:X} Parent=0x{1:X} Cls='{2}' Title='{3}' Rect=({4},{5},{6},{7}) W={8} H={9} Vis={10} Style=0x{11:X8} ExStyle=0x{12:X8}",
                    child.ToInt64(), p.ToInt64(), c, t, r.Left, r.Top, r.Right, r.Bottom, r.Right - r.Left, r.Bottom - r.Top, vis, style, exstyle));
            }
            return true;
        }, IntPtr.Zero);
    }
}
