using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Threading;

class TestPath1DockElevation {
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
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool RedrawWindow(IntPtr hWnd, IntPtr lprcUpdate, IntPtr hrgnUpdate, uint flags);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    const int GWL_STYLE = -16;
    const int GWL_EXSTYLE = -20;
    const uint WS_POPUP = 0x80000000;
    const uint WS_VISIBLE = 0x10000000;
    const uint WS_CAPTION = 0x00C00000;
    const uint WS_THICKFRAME = 0x00040000;
    const uint WS_CLIPSIBLINGS = 0x04000000;
    const uint WS_CHILD = 0x40000000;

    const int WS_EX_TOOLWINDOW = 0x00000080;
    const int WS_EX_TOPMOST = 0x00000008;

    static readonly IntPtr HWND_TOPMOST = (IntPtr)(-1);
    const uint SWP_FRAMECHANGED = 0x0020;
    const uint SWP_SHOWWINDOW = 0x0040;

    static void Main(string[] args) {
        Console.WriteLine("=== Testing Path 1 Dock Elevation ===");
        IntPtr dveHwnd = IntPtr.Zero;
        IntPtr docHwnd = IntPtr.Zero;

        EnumWindows((hWnd, lp) => {
            StringBuilder sb = new StringBuilder(256);
            GetWindowTextW(hWnd, sb, 256);
            if (sb.ToString().Contains("SOLIDWORKS")) {
                EnumChildWindows(hWnd, (child, lp2) => {
                    StringBuilder t = new StringBuilder(256);
                    GetWindowTextW(child, t, 256);
                    if (t.ToString() == "DVEDockedContainer") {
                        dveHwnd = child;
                        docHwnd = GetParent(child);
                        return false;
                    }
                    return true;
                }, IntPtr.Zero);
            }
            return true;
        }, IntPtr.Zero);

        Console.WriteLine(string.Format("Found DVEDockedContainer: 0x{0:X}, Parent Doc: 0x{1:X}", dveHwnd.ToInt64(), docHwnd.ToInt64()));
        if (dveHwnd == IntPtr.Zero) return;

        // Make it visible and bring to front
        ShowWindow(dveHwnd, 5 /* SW_SHOW */);
        RECT r;
        GetWindowRect(dveHwnd, out r);
        Console.WriteLine(string.Format("DVEDockedContainer Rect: ({0},{1},{2},{3})", r.Left, r.Top, r.Right, r.Bottom));

        // Check whether it can be elevated to Desktop top-level
        int style = GetWindowLongW(dveHwnd, GWL_STYLE);
        int exstyle = GetWindowLongW(dveHwnd, GWL_EXSTYLE);
        Console.WriteLine(string.Format("Original Style=0x{0:X8}, ExStyle=0x{1:X8}", style, exstyle));

        // Test elevating style: remove WS_CHILD, add WS_POPUP | WS_CLIPSIBLINGS
        SetWindowLongW(dveHwnd, GWL_STYLE, (int)(((uint)style & ~WS_CHILD) | WS_POPUP | WS_CLIPSIBLINGS | WS_CAPTION | WS_THICKFRAME));
        SetWindowLongW(dveHwnd, GWL_EXSTYLE, exstyle | WS_EX_TOOLWINDOW | WS_EX_TOPMOST);
        SetParent(dveHwnd, GetDesktopWindow());
        SetWindowPos(dveHwnd, HWND_TOPMOST, 700, 250, 360, 520, SWP_FRAMECHANGED | SWP_SHOWWINDOW);

        Console.WriteLine("DVEDockedContainer elevated to Desktop Top-Level! Sleeping 5s...");
        Thread.Sleep(5000);

        // Restore back to docked inside docHwnd
        Console.WriteLine("Restoring back to docHwnd...");
        SetParent(dveHwnd, docHwnd);
        SetWindowLongW(dveHwnd, GWL_STYLE, style);
        SetWindowLongW(dveHwnd, GWL_EXSTYLE, exstyle);
        SetWindowPos(dveHwnd, IntPtr.Zero, 350, 141, 310, 455, SWP_FRAMECHANGED | SWP_SHOWWINDOW);
        Console.WriteLine("Restored.");
    }
}
