using System;
using System.Runtime.InteropServices;
using System.Text;

class ListMdiChildren {
    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr hWnd);

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

    static void Main(string[] args) {
        IntPtr mdiClient = (IntPtr)0x30160;
        EnumChildWindows(mdiClient, delegate(IntPtr child, IntPtr l) {
            if (GetParent(child) == mdiClient) {
                StringBuilder cls = new StringBuilder(256);
                GetClassName(child, cls, 256);
                StringBuilder title = new StringBuilder(256);
                GetWindowText(child, title, 256);
                RECT r;
                GetWindowRect(child, out r);
                bool vis = IsWindowVisible(child);
                int style = GetWindowLong(child, -16);
                Console.WriteLine(string.Format("MdiChild: [0x{0:X}] Vis={1} Rect=({2},{3},{4},{5}) W={6} H={7} Style=0x{8:X8} Cls='{9}' Title='{10}'",
                    child.ToInt64(), vis, r.Left, r.Top, r.Right, r.Bottom, r.Right - r.Left, r.Bottom - r.Top, style, cls, title));
            }
            return true;
        }, IntPtr.Zero);
    }
}
