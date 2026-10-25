using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Collections.Generic;

class TestFloatingElevation {
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
    public static extern IntPtr SetParent(IntPtr hWndChild, IntPtr hWndNewParent);

    [DllImport("user32.dll")]
    public static extern IntPtr GetDesktopWindow();

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern int GetWindowLongW(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    public static extern int SetWindowLongW(IntPtr hWnd, int nIndex, int dwNewLong);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    const int GWL_STYLE = -16;
    const int GWL_EXSTYLE = -20;
    const uint WS_POPUP = 0x80000000;
    const int WS_EX_TOOLWINDOW = 0x00000080;
    const int WS_EX_TOPMOST = 0x00000008;

    static readonly IntPtr HWND_TOPMOST = (IntPtr)(-1);
    const uint SWP_NOSIZE = 0x0001;
    const uint SWP_NOMOVE = 0x0002;
    const uint SWP_NOACTIVATE = 0x0010;
    const uint SWP_FRAMECHANGED = 0x0020;
    const uint SWP_SHOWWINDOW = 0x0040;

    static void Main(string[] args) {
        bool elevate = (args.Length > 0 && args[0] == "--elevate");
        Console.WriteLine("=== SolidWorks Window Diagnostic & Elevation Probe ===");
        Console.WriteLine("Mode: " + (elevate ? "ELEVATE (Path 1 Active)" : "INSPECT ONLY"));

        uint swPid = 0;
        IntPtr swMainHwnd = IntPtr.Zero;

        // 1. Locate SolidWorks main window and PID
        EnumWindows((hWnd, lp) => {
            StringBuilder sb = new StringBuilder(256);
            GetWindowTextW(hWnd, sb, 256);
            string title = sb.ToString();
            if (title.Contains("SOLIDWORKS")) {
                swMainHwnd = hWnd;
                GetWindowThreadProcessId(hWnd, out swPid);
                Console.WriteLine(string.Format("Found SolidWorks: HWND=0x{0:X}, PID={1}, Title='{2}'", hWnd.ToInt64(), swPid, title));
                return false;
            }
            return true;
        }, IntPtr.Zero);

        if (swPid == 0) {
            Console.WriteLine("ERROR: Could not find running SOLIDWORKS process.");
            return;
        }

        IntPtr desktopHwnd = GetDesktopWindow();
        List<IntPtr> swWindows = new List<IntPtr>();

        // 2. Enumerate all top-level windows belonging to SolidWorks PID
        EnumWindows((hWnd, lp) => {
            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            if (pid == swPid) {
                swWindows.Add(hWnd);
            }
            return true;
        }, IntPtr.Zero);

        Console.WriteLine(string.Format("Total top-level windows for SolidWorks PID {0}: {1}", swPid, swWindows.Count));

        int floatingCount = 0;
        int elevatedCount = 0;

        foreach (IntPtr hWnd in swWindows) {
            StringBuilder clsSb = new StringBuilder(256);
            GetClassNameW(hWnd, clsSb, 256);
            string cls = clsSb.ToString();

            StringBuilder titleSb = new StringBuilder(256);
            GetWindowTextW(hWnd, titleSb, 256);
            string title = titleSb.ToString();

            RECT r;
            GetWindowRect(hWnd, out r);
            int w = r.Right - r.Left;
            int h = r.Bottom - r.Top;

            int style = GetWindowLongW(hWnd, GWL_STYLE);
            int exstyle = GetWindowLongW(hWnd, GWL_EXSTYLE);
            IntPtr parent = GetParent(hWnd);
            bool vis = IsWindowVisible(hWnd);

            bool isPopup = ((uint)style & WS_POPUP) != 0;
            bool isMini = cls.Contains("MiniWnd") || cls.Contains("MiniFrame") || cls.Contains("CMiniDock") || title.Contains("属性") || title.Contains("Property");
            bool isTopmost = (exstyle & WS_EX_TOPMOST) != 0;
            bool isToolWindow = (exstyle & WS_EX_TOOLWINDOW) != 0;

            if (hWnd != swMainHwnd) {
                Console.WriteLine(string.Format("HWND=0x{0:X} Cls='{1}' Title='{2}' Rect=({3},{4},{5},{6}) W={7} H={8} Vis={9} Parent=0x{10:X} Style=0x{11:X8} ExStyle=0x{12:X8} Topmost={13}",
                    hWnd.ToInt64(), cls, title, r.Left, r.Top, r.Right, r.Bottom, w, h, vis, parent.ToInt64(), style, exstyle, isTopmost));
            }

            if (isMini || (isPopup && hWnd != swMainHwnd)) {
                floatingCount++;
                if (isTopmost && isToolWindow && (parent == IntPtr.Zero || parent == desktopHwnd)) {
                    elevatedCount++;
                }

                if (elevate) {
                    Console.WriteLine(string.Format("--> ELEVATING HWND 0x{0:X} ('{1}')...", hWnd.ToInt64(), title));
                    // A: Detach to desktop
                    if (parent != desktopHwnd && parent != IntPtr.Zero) {
                        SetParent(hWnd, desktopHwnd);
                    }
                    // B: Set styles
                    SetWindowLongW(hWnd, GWL_EXSTYLE, exstyle | WS_EX_TOOLWINDOW | WS_EX_TOPMOST);
                    // C: Set z-order to topmost
                    SetWindowPos(hWnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED | SWP_NOACTIVATE | SWP_SHOWWINDOW);

                    // D: If window is lost/hidden or has zero dimension, restore it
                    if (w < 50 || h < 50 || r.Left < 0 || r.Top < 0 || r.Left > 2500) {
                        Console.WriteLine(string.Format("--> RESCUING lost window to (700, 200, 350, 450)..."));
                        SetWindowPos(hWnd, HWND_TOPMOST, 700, 200, 350, 450, SWP_FRAMECHANGED | SWP_SHOWWINDOW);
                    }
                }
            }
        }

        Console.WriteLine(string.Format("=== Summary: Floating/Popup Windows: {0}, Fully Elevated: {1} ===", floatingCount, elevatedCount));
    }
}
