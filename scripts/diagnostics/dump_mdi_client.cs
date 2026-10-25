using System;
using System.Runtime.InteropServices;
using System.Text;

class DumpMdiClient {
    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr hWnd);

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

    static void PrintChildren(IntPtr parent, int indent) {
        EnumChildWindows(parent, delegate(IntPtr child, IntPtr l) {
            if (GetParent(child) == parent) {
                StringBuilder cls = new StringBuilder(256);
                GetClassName(child, cls, 256);
                StringBuilder title = new StringBuilder(256);
                GetWindowText(child, title, 256);
                RECT r;
                GetWindowRect(child, out r);
                bool vis = IsWindowVisible(child);
                int style = GetWindowLong(child, -16);
                int exstyle = GetWindowLong(child, -20);
                string pad = new string(' ', indent * 2);
                Console.WriteLine(string.Format("{0}[0x{1:X}] Vis={2} Rect=({3},{4},{5},{6}) W={7} H={8} Style=0x{9:X8} ExStyle=0x{10:X8} Cls='{11}' Title='{12}'",
                    pad, child.ToInt64(), vis, r.Left, r.Top, r.Right, r.Bottom, r.Right - r.Left, r.Bottom - r.Top, style, exstyle, cls, title));
                PrintChildren(child, indent + 1);
            }
            return true;
        }, IntPtr.Zero);
    }

    static void Main(string[] args) {
        IntPtr mdiClient = (IntPtr)0x30160;
        Console.WriteLine("Dumping MDI Client 0x30160 children:");
        PrintChildren(mdiClient, 1);
    }
}
