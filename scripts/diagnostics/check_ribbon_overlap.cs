using System;
using System.Text;
using System.Runtime.InteropServices;

class CheckRibbonOverlap {
    [DllImport("user32.dll")]
    public static extern bool EnumChildWindows(IntPtr hWnd, EnumChildWindowsProc lpEnumFunc, IntPtr lParam);
    public delegate bool EnumChildWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left, Top, Right, Bottom;
    }

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumChildWindowsProc lpEnumFunc, IntPtr lParam);

    static void Main() {
        EnumWindows((mainWnd, lp0) => {
            StringBuilder tMain = new StringBuilder(256);
            GetWindowTextW(mainWnd, tMain, 256);
            if (tMain.ToString().Contains("SOLIDWORKS Premium")) {
                RECT rMain;
                GetWindowRect(mainWnd, out rMain);
                Console.WriteLine(string.Format("Main Window {0:X8} Rect: ({1},{2})-({3},{4}), Size={5}x{6}",
                    mainWnd.ToInt64(), rMain.Left, rMain.Top, rMain.Right, rMain.Bottom, rMain.Right - rMain.Left, rMain.Bottom - rMain.Top));

                EnumChildWindows(mainWnd, (hWnd, lp) => {
                    StringBuilder cls = new StringBuilder(256);
                    GetClassNameW(hWnd, cls, 256);
                    StringBuilder text = new StringBuilder(256);
                    GetWindowTextW(hWnd, text, 256);
                    string c = cls.ToString();
                    string t = text.ToString();

                    RECT rc;
                    GetWindowRect(hWnd, out rc);

                    if (t.Contains("MBD") || t.Contains("Dimension") || t.Contains("CommandManager") || 
                        c.Contains("MDIClient") || c.Contains("SysTabControl32") || t == "Tree Container Wnd" ||
                        (c.Contains("AfxFrameOrView") && (rc.Right - rc.Left) > 500)) {
                        Console.WriteLine(string.Format("  HWND: {0:X8}, Rect: ({1},{2})-({3},{4}), Size={5}x{6}, Cls: '{7}', Text: '{8}'",
                            hWnd.ToInt64(), rc.Left, rc.Top, rc.Right, rc.Bottom, rc.Right - rc.Left, rc.Bottom - rc.Top, c, t));
                    }
                    return true;
                }, IntPtr.Zero);
            }
            return true;
        }, IntPtr.Zero);
    }
}
