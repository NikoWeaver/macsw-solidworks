using System;
using System.Runtime.InteropServices;
using System.Text;

class DumpCmdMgr {
    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

    static void Main() {
        IntPtr cmdMgr = (IntPtr)0xD0818;
        Console.WriteLine("Dumping swCmdMgr children...");
        EnumChildWindows(cmdMgr, delegate(IntPtr child, IntPtr l) {
            RECT r;
            GetWindowRect(child, out r);
            StringBuilder cls = new StringBuilder(256);
            GetClassName(child, cls, 256);
            StringBuilder title = new StringBuilder(256);
            GetWindowText(child, title, 256);
            bool vis = IsWindowVisible(child);
            Console.WriteLine(string.Format("  [0x{0:X}] Vis={1} Rect=({2},{3},{4},{5}) W={6} H={7} Cls='{8}' Title='{9}'",
                child.ToInt64(), vis, r.Left, r.Top, r.Right, r.Bottom, r.Right - r.Left, r.Bottom - r.Top, cls, title));
            return true;
        }, IntPtr.Zero);
    }
}
