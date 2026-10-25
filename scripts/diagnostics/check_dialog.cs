using System;
using System.Text;
using System.Runtime.InteropServices;

class CheckDialog {
    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);

    static void Main() {
        EnumWindows((h, l) => {
            if (!IsWindowVisible(h)) return true;
            StringBuilder cls = new StringBuilder(256);
            GetClassName(h, cls, 256);
            StringBuilder title = new StringBuilder(256);
            GetWindowText(h, title, 256);
            
            if (cls.ToString() == "#32770" || title.ToString().Contains("SOLIDWORKS")) {
                Console.WriteLine("Found window: " + h + " | Class: " + cls + " | Title: " + title);
                EnumChildWindows(h, (c, cl) => {
                    StringBuilder ccls = new StringBuilder(256);
                    GetClassName(c, ccls, 256);
                    StringBuilder ctitle = new StringBuilder(256);
                    GetWindowText(c, ctitle, 256);
                    if (ctitle.Length > 0) {
                        Console.WriteLine("   Child: " + c + " | " + ccls + " | Text: " + ctitle);
                    }
                    return true;
                }, IntPtr.Zero);
            }
            return true;
        }, IntPtr.Zero);
    }
}
