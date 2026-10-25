using System;
using System.Runtime.InteropServices;
using System.Text;

class InspectTitlebarWnd {
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
                Console.WriteLine(string.Format("SW Main: [0x{0:X}] '{1}'", h.ToInt64(), title));
                EnumChildWindows(h, (c, cl) => {
                    if (!IsWindowVisible(c)) return true;
                    RECT r;
                    GetWindowRect(c, out r);
                    int w = r.Right - r.Left;
                    int h_val = r.Bottom - r.Top;
                    if (w < 5 || h_val < 5) return true;
                    StringBuilder cls = new StringBuilder(256);
                    GetClassName(c, cls, 256);
                    StringBuilder txt = new StringBuilder(256);
                    GetWindowText(c, txt, 256);
                    int style = GetWindowLong(c, -16);
                    if ((style & 0x00C00000) == 0x00C00000 || cls.ToString().StartsWith("Afx:") || txt.Length > 0) {
                        Console.WriteLine(string.Format("  Child: [0x{0:X}] ({1},{2},{3},{4}) {5}x{6} Cls='{7}' Title='{8}' Style=0x{9:X8}",
                            c.ToInt64(), r.Left, r.Top, r.Right, r.Bottom, w, h_val, cls, txt, style));
                    }
                    return true;
                }, IntPtr.Zero);
            }
            return true;
        }, IntPtr.Zero);
    }
}
