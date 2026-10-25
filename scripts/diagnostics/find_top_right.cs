using System;
using System.Runtime.InteropServices;
using System.Text;

class FindTopRightControls {
    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr hWnd);

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

    static void Main() {
        EnumWindows((h, l) => {
            StringBuilder title = new StringBuilder(256);
            GetWindowText(h, title, 256);
            if (title.ToString().Contains("SOLIDWORKS Premium")) {
                Console.WriteLine($"Main: {h} '{title}'");
                EnumChildWindows(h, (c, cl) => {
                    RECT r;
                    GetWindowRect(c, out r);
                    int w = r.Right - r.Left;
                    int hg = r.Bottom - r.Top;
                    // Check if it intersects the top-right area (x > 2700, y between 50 and 150)
                    if (r.Right > 2700 && r.Top >= 40 && r.Bottom <= 150) {
                        StringBuilder cls = new StringBuilder(256);
                        GetClassName(c, cls, 256);
                        StringBuilder txt = new StringBuilder(256);
                        GetWindowText(c, txt, 256);
                        bool vis = IsWindowVisible(c);
                        Console.WriteLine($"Child [0x{c.ToInt64():X}] Vis={vis} Rect=({r.Left},{r.Top},{r.Right},{r.Bottom}) {w}x{hg} Cls='{cls}' Title='{txt}' Parent=0x{GetParent(c).ToInt64():X}");
                    }
                    return true;
                }, IntPtr.Zero);
            }
            return true;
        }, IntPtr.Zero);
    }
}
