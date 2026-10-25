using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Collections.Generic;

class FindAllProcessPopups {
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
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

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
    const uint WS_POPUP = 0x80000000;
    const uint WS_CHILD = 0x40000000;

    static void Main() {
        uint swPid = 0;
        IntPtr swMain = IntPtr.Zero;

        EnumWindows((h, l) => {
            StringBuilder sb = new StringBuilder(256);
            GetWindowTextW(h, sb, 256);
            if (sb.ToString().Contains("SOLIDWORKS Premium")) {
                swMain = h;
                GetWindowThreadProcessId(h, out swPid);
                return false;
            }
            return true;
        }, IntPtr.Zero);

        Console.WriteLine(string.Format("SW Main: 0x{0:X}, PID={1}", swMain.ToInt64(), swPid));
        if (swPid == 0) return;

        List<IntPtr> allWins = new List<IntPtr>();
        EnumWindows((h, l) => {
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            if (pid == swPid) {
                allWins.Add(h);
            }
            return true;
        }, IntPtr.Zero);

        Console.WriteLine(string.Format("Total top-level windows for SW PID {0}: {1}", swPid, allWins.Count));

        foreach (IntPtr h in allWins) {
            StringBuilder clsSb = new StringBuilder(256);
            GetClassNameW(h, clsSb, 256);
            string cls = clsSb.ToString();

            StringBuilder titleSb = new StringBuilder(256);
            GetWindowTextW(h, titleSb, 256);
            string title = titleSb.ToString();

            int style = GetWindowLongW(h, GWL_STYLE);
            int exstyle = GetWindowLongW(h, GWL_EXSTYLE);
            RECT r;
            GetWindowRect(h, out r);
            bool vis = IsWindowVisible(h);
            IntPtr p = GetParent(h);

            bool isPopup = ((uint)style & WS_POPUP) != 0;
            bool isChild = ((uint)style & WS_CHILD) != 0;

            if (h != swMain && (isPopup || cls.Contains("Mini") || cls.Contains("Frame") || cls.Contains("Toolbar") || title.Length > 0)) {
                if (r.Right - r.Left > 5 && r.Bottom - r.Top > 5) {
                    Console.WriteLine(string.Format("CANDIDATE: HWND=0x{0:X} Parent=0x{1:X} Cls='{2}' Title='{3}' Rect=({4},{5},{6},{7}) W={8} H={9} Vis={10} Style=0x{11:X8} ExStyle=0x{12:X8}",
                        h.ToInt64(), p.ToInt64(), cls, title, r.Left, r.Top, r.Right, r.Bottom, r.Right - r.Left, r.Bottom - r.Top, vis, style, exstyle));
                }
            }
        }
    }
}
