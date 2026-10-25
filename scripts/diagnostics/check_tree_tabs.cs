using System;
using System.Text;
using System.Runtime.InteropServices;

class CheckTreeTabs {
    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumChildWindows(IntPtr hWnd, EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    const uint TCM_GETCURSEL = 0x1300 + 11;
    const uint TCM_GETITEMCOUNT = 0x1300 + 4;

    static void Main() {
        EnumWindows((hWnd, lp) => {
            StringBuilder sb = new StringBuilder(256);
            GetWindowTextW(hWnd, sb, 256);
            if (sb.ToString().Contains("SOLIDWORKS")) {
                EnumChildWindows(hWnd, (child, lp2) => {
                    StringBuilder cls = new StringBuilder(256);
                    GetClassNameW(child, cls, 256);
                    if (cls.ToString() == "SysTabControl32") {
                        int count = SendMessage(child, TCM_GETITEMCOUNT, IntPtr.Zero, IntPtr.Zero).ToInt32();
                        int curSel = SendMessage(child, TCM_GETCURSEL, IntPtr.Zero, IntPtr.Zero).ToInt32();
                        RECT r;
                        GetWindowRect(child, out r);
                        Console.WriteLine(string.Format("Found SysTabControl32 0x{0:X}: ItemCount={1}, CurSel={2}, Rect=({3},{4},{5},{6})",
                            child.ToInt64(), count, curSel, r.Left, r.Top, r.Right, r.Bottom));
                    }
                    return true;
                }, IntPtr.Zero);
            }
            return true;
        }, IntPtr.Zero);
    }
}
