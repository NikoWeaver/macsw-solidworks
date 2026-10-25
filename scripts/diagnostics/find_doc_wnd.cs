using System;
using System.Runtime.InteropServices;
using System.Text;

class FindDocWnd {
    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr hWnd);

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

    static void Main() {
        EnumWindows((h, l) => {
            StringBuilder title = new StringBuilder(256);
            GetWindowText(h, title, 256);
            if (title.ToString().Contains("SOLIDWORKS Premium")) {
                EnumChildWindows(h, (c, cl) => {
                    StringBuilder txt = new StringBuilder(256);
                    GetWindowText(c, txt, 256);
                    StringBuilder cls = new StringBuilder(256);
                    GetClassName(c, cls, 256);
                    if (txt.ToString().Contains("零件1") || txt.ToString().Contains("Part1")) {
                        RECT r;
                        GetWindowRect(c, out r);
                        Console.WriteLine($"Found Doc Child: [0x{c.ToInt64():X}] Vis={IsWindowVisible(c)} Rect=({r.Left},{r.Top},{r.Right},{r.Bottom}) Cls='{cls}' Title='{txt}' Parent=0x{GetParent(c).ToInt64():X}");
                    }
                    return true;
                }, IntPtr.Zero);
            }
            return true;
        }, IntPtr.Zero);
    }
}
