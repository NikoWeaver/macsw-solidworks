using System;
using System.Text;
using System.Runtime.InteropServices;

class InspectDialog {
    [DllImport("user32.dll")]
    public static extern bool EnumChildWindows(IntPtr hWnd, EnumWindowsProc lpEnumFunc, IntPtr lParam);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    static void Main() {
        IntPtr dlg = (IntPtr)0x6039C;
        StringBuilder title = new StringBuilder(256);
        GetWindowTextW(dlg, title, 256);
        RECT r;
        GetWindowRect(dlg, out r);
        Console.WriteLine(string.Format("Dialog 0x{0:X} Title='{1}' Rect=({2},{3},{4},{5})", dlg.ToInt64(), title, r.Left, r.Top, r.Right, r.Bottom));

        EnumChildWindows(dlg, (child, lp) => {
            StringBuilder cls = new StringBuilder(256);
            GetClassNameW(child, cls, 256);
            StringBuilder text = new StringBuilder(256);
            GetWindowTextW(child, text, 256);
            RECT rc;
            GetWindowRect(child, out rc);
            Console.WriteLine(string.Format("  Control 0x{0:X} Cls='{1}' Text='{2}' Rect=({3},{4},{5},{6})",
                child.ToInt64(), cls, text, rc.Left, rc.Top, rc.Right, rc.Bottom));
            return true;
        }, IntPtr.Zero);
    }
}
