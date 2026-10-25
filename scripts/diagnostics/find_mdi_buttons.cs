using System;
using System.Runtime.InteropServices;
using System.Text;

class FindMdiButtons {
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

    static void DumpTree(IntPtr parent, int indent) {
        EnumChildWindows(parent, (c, l) => {
            if (GetParent(c) == parent) {
                StringBuilder cls = new StringBuilder(256);
                GetClassName(c, cls, 256);
                StringBuilder title = new StringBuilder(256);
                GetWindowText(c, title, 256);
                RECT r;
                GetWindowRect(c, out r);
                int w = r.Right - r.Left;
                int h = r.Bottom - r.Top;
                bool vis = IsWindowVisible(c);
                int style = GetWindowLong(c, -16);
                int exstyle = GetWindowLong(c, -20);
                string pad = new string(' ', indent * 2);
                Console.WriteLine($"{pad}[0x{c.ToInt64():X}] Vis={vis} Rect=({r.Left},{r.Top},{r.Right},{r.Bottom}) {w}x{h} Cls='{cls}' Title='{title}' Style=0x{style:X8}");
                DumpTree(c, indent + 1);
            }
            return true;
        }, IntPtr.Zero);
    }

    static void Main() {
        EnumWindows((h, l) => {
            StringBuilder cls = new StringBuilder(256);
            GetClassName(h, cls, 256);
            StringBuilder title = new StringBuilder(256);
            GetWindowText(h, title, 256);
            if (title.ToString().Contains("SOLIDWORKS Premium")) {
                Console.WriteLine($"Found SW Main: [0x{h.ToInt64():X}] '{title}'");
                DumpTree(h, 1);
            }
            return true;
        }, IntPtr.Zero);
    }
}
