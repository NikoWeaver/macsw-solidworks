using System;
using System.Text;
using System.Runtime.InteropServices;

class DiagnoseDockingPanes {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

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

    static void Main() {
        EnumWindows((hWnd, lp0) => {
            StringBuilder title = new StringBuilder(256);
            GetWindowTextW(hWnd, title, 256);
            if (title.ToString().Contains("SOLIDWORKS")) {
                Console.WriteLine(string.Format("SolidWorks Window: 0x{0:X}, Title: '{1}'", hWnd.ToInt64(), title));

                EnumChildWindows(hWnd, (child, lp1) => {
                    StringBuilder cls = new StringBuilder(256);
                    GetClassNameW(child, cls, 256);
                    StringBuilder text = new StringBuilder(256);
                    GetWindowTextW(child, text, 256);

                    string cStr = cls.ToString();
                    string tStr = text.ToString();

                    // Search for panes, containers, docking, floating frames
                    if (cStr.Contains("XTP") || cStr.Contains("Dock") || cStr.Contains("Mini") ||
                        tStr.Contains("Container") || tStr.Contains("DVE") || tStr.Contains("Tree") ||
                        cStr.Contains("AfxMDIFrame")) {
                        RECT r;
                        GetWindowRect(child, out r);
                        bool vis = IsWindowVisible(child);
                        int style = GetWindowLongW(child, -16);
                        int exstyle = GetWindowLongW(child, -20);
                        IntPtr parent = GetParent(child);

                        Console.WriteLine(string.Format("  [0x{0:X}] Cls='{1}', Title='{2}', Vis={3}, Rect=({4},{5},{6},{7}) W={8} H={9}, Parent=0x{10:X}, Style=0x{11:X8}",
                            child.ToInt64(), cStr, tStr, vis, r.Left, r.Top, r.Right, r.Bottom, r.Right - r.Left, r.Bottom - r.Top, parent.ToInt64(), style));
                    }
                    return true;
                }, IntPtr.Zero);
            }
            return true;
        }, IntPtr.Zero);
    }
}
