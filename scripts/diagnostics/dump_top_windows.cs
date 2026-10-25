using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;

class DumpTopWindows {
    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr hWnd);

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

    static void Main() {
        EnumWindows(delegate(IntPtr hWnd, IntPtr l) {
            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            StringBuilder cls = new StringBuilder(256);
            GetClassName(hWnd, cls, 256);
            StringBuilder title = new StringBuilder(256);
            GetWindowText(hWnd, title, 256);
            RECT r;
            GetWindowRect(hWnd, out r);
            bool vis = IsWindowVisible(hWnd);
            int style = GetWindowLong(hWnd, -16);
            int exstyle = GetWindowLong(hWnd, -20);

            if (title.ToString().Contains("SOLIDWORKS") || cls.ToString().Contains("Afx") || title.ToString().Contains("零件") || title.ToString().Contains("装配") || title.ToString().Contains(".SLD")) {
                Console.WriteLine(string.Format("TopWin: [0x{0:X}] PID={1} Vis={2} Rect=({3},{4},{5},{6}) W={7} H={8} Style=0x{9:X8} ExStyle=0x{10:X8} Cls='{11}' Title='{12}'",
                    hWnd.ToInt64(), pid, vis, r.Left, r.Top, r.Right, r.Bottom, r.Right - r.Left, r.Bottom - r.Top, style, exstyle, cls, title));
                
                // Print immediate children
                EnumChildWindows(hWnd, delegate(IntPtr child, IntPtr l2) {
                    if (GetParent(child) == hWnd) {
                        StringBuilder cCls = new StringBuilder(256);
                        GetClassName(child, cCls, 256);
                        StringBuilder cTitle = new StringBuilder(256);
                        GetWindowText(child, cTitle, 256);
                        RECT cr;
                        GetWindowRect(child, out cr);
                        bool cVis = IsWindowVisible(child);
                        Console.WriteLine(string.Format("   Child: [0x{0:X}] Vis={1} Rect=({2},{3},{4},{5}) W={6} H={7} Cls='{8}' Title='{9}'",
                            child.ToInt64(), cVis, cr.Left, cr.Top, cr.Right, cr.Bottom, cr.Right - cr.Left, cr.Bottom - cr.Top, cCls, cTitle));
                    }
                    return true;
                }, IntPtr.Zero);
            }
            return true;
        }, IntPtr.Zero);
    }
}
