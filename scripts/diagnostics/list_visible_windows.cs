using System;
using System.Runtime.InteropServices;
using System.Text;

class ListVisibleWindows {
    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

    static void Main() {
        EnumWindows(delegate(IntPtr top, IntPtr l) {
            RECT r;
            GetWindowRect(top, out r);
            StringBuilder cls = new StringBuilder(256);
            GetClassName(top, cls, 256);
            StringBuilder title = new StringBuilder(256);
            GetWindowText(top, title, 256);
            bool vis = IsWindowVisible(top);
            if (vis && (r.Right - r.Left) > 10 && (r.Bottom - r.Top) > 10) {
                Console.WriteLine(string.Format("Top [0x{0:X}] Rect=({1},{2},{3},{4}) W={5} H={6} Cls='{7}' Title='{8}'",
                    top.ToInt64(), r.Left, r.Top, r.Right, r.Bottom, r.Right - r.Left, r.Bottom - r.Top, cls, title));
            }
            return true;
        }, IntPtr.Zero);
    }
}
