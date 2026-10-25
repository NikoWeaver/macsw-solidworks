using System;
using System.Runtime.InteropServices;
using System.Text;

class FindSketchButton {
    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

    static void Main() {
        IntPtr cmdMgr = (IntPtr)0xB0844; // swCmdMgr
        Console.WriteLine("Inspecting swCmdMgr 0xB0844 children:");
        EnumChildWindows(cmdMgr, delegate(IntPtr child, IntPtr l) {
            StringBuilder cls = new StringBuilder(256);
            GetClassName(child, cls, 256);
            StringBuilder title = new StringBuilder(256);
            GetWindowText(child, title, 256);
            RECT r;
            GetWindowRect(child, out r);
            bool vis = IsWindowVisible(child);
            if (vis) {
                Console.WriteLine(string.Format("  Btn [0x{0:X}] Rect=({1},{2},{3},{4}) W={5} H={6} Cls='{7}' Title='{8}'",
                    child.ToInt64(), r.Left, r.Top, r.Right, r.Bottom, r.Right - r.Left, r.Bottom - r.Top, cls, title));
            }
            return true;
        }, IntPtr.Zero);
    }
}
