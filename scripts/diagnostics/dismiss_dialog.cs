using System;
using System.Text;
using System.Runtime.InteropServices;

class DismissLoginDialog {
    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    const int SW_HIDE = 0;
    const uint SWP_NOSIZE = 0x0001;
    const uint SWP_NOMOVE = 0x0002;
    const uint SWP_NOZORDER = 0x0004;
    const uint SWP_NOACTIVATE = 0x0010;
    const uint SWP_HIDEWINDOW = 0x0080;
    const uint WM_CLOSE = 0x0010;

    static void Main() {
        EnumWindows((h, l) => {
            StringBuilder cls = new StringBuilder(256);
            GetClassName(h, cls, 256);
            if (cls.ToString() == "#32770") {
                bool isLoginManager = false;
                bool isMsiHelp = false;
                EnumChildWindows(h, (c, cl) => {
                    StringBuilder txt = new StringBuilder(512);
                    GetWindowText(c, txt, 512);
                    string s = txt.ToString();
                    if (s.Contains("Login Manager") || s.Contains("SOLIDWORKS Login Manager")) {
                        isLoginManager = true;
                    }
                    if (s.Contains("Windows Installer") || s.Contains("msiexec")) {
                        isMsiHelp = true;
                    }
                    return true;
                }, IntPtr.Zero);

                if (isLoginManager) {
                    Console.WriteLine("Hiding Login Manager dialog: " + h);
                    SetWindowPos(h, IntPtr.Zero, -10000, -10000, 0, 0, SWP_HIDEWINDOW | SWP_NOACTIVATE | SWP_NOZORDER);
                    ShowWindow(h, SW_HIDE);
                } else if (isMsiHelp) {
                    Console.WriteLine("Closing msiexec help dialog: " + h);
                    SendMessage(h, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
                }
            }
            return true;
        }, IntPtr.Zero);
    }
}
