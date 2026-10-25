using System;
using System.Text;
using System.Runtime.InteropServices;

class ListAllWindows {
    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    static void Main() {
        EnumWindows((hWnd, lParam) => {
            if (IsWindowVisible(hWnd)) {
                StringBuilder title = new StringBuilder(256);
                GetWindowTextW(hWnd, title, 256);
                StringBuilder cls = new StringBuilder(256);
                GetClassNameW(hWnd, cls, 256);
                if (title.Length > 0 || cls.ToString().Contains("Afx") || cls.ToString().Contains("#32770")) {
                    Console.WriteLine(string.Format("HWND: {0:X8}, Cls: '{1}', Title: '{2}'", hWnd.ToInt64(), cls, title));
                }
            }
            return true;
        }, IntPtr.Zero);
    }
}
