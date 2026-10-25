using System;
using System.Text;
using System.Runtime.InteropServices;

class Program {
    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll")]
    static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    static extern bool IsWindowVisible(IntPtr hWnd);

    [StructLayout(LayoutKind.Sequential)]
    struct RECT {
        public int Left, Top, Right, Bottom;
    }

    [DllImport("user32.dll")]
    static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    static bool EnumChild(IntPtr hwnd, IntPtr lParam) {
        StringBuilder title = new StringBuilder(256);
        GetWindowText(hwnd, title, 256);
        StringBuilder cls = new StringBuilder(256);
        GetClassName(hwnd, cls, 256);

        RECT rect;
        GetWindowRect(hwnd, out rect);
        int w = rect.Right - rect.Left;
        int h = rect.Bottom - rect.Top;

        int style = GetWindowLong(hwnd, -16);
        int exstyle = GetWindowLong(hwnd, -20);
        bool vis = IsWindowVisible(hwnd);

        if (w > 0 && h > 0) {
            Console.WriteLine(string.Format("  CHILD 0x{0:X8} | ({1,4},{2,4}, {3,4}x{4,4}) | Vis:{5} | Style: 0x{6:X8} | Ex: 0x{7:X8} | Class: {8,-25} | Title: '{9}'",
                hwnd.ToInt64(), rect.Left, rect.Top, w, h, vis, style, exstyle, cls.ToString(), title.ToString()));
        }
        return true;
    }

    static bool EnumTop(IntPtr hwnd, IntPtr lParam) {
        StringBuilder title = new StringBuilder(256);
        GetWindowText(hwnd, title, 256);
        StringBuilder cls = new StringBuilder(256);
        GetClassName(hwnd, cls, 256);

        RECT rect;
        GetWindowRect(hwnd, out rect);
        int w = rect.Right - rect.Left;
        int h = rect.Bottom - rect.Top;

        Console.WriteLine(string.Format("TOP 0x{0:X8} | ({1,4},{2,4}, {3,4}x{4,4}) | Class: {5,-20} | Title: '{6}'",
            hwnd.ToInt64(), rect.Left, rect.Top, w, h, cls.ToString(), title.ToString()));

        if (cls.ToString().StartsWith("Afx:") || cls.ToString().Contains("SLDWORKS") || title.ToString().Length > 0) {
            EnumChildWindows(hwnd, EnumChild, IntPtr.Zero);
        }
        return true;
    }

    static void Main() {
        Console.WriteLine("Enumerating all windows...");
        EnumWindows(EnumTop, IntPtr.Zero);
    }
}
