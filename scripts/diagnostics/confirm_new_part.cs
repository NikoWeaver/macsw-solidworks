using System;
using System.Runtime.InteropServices;
using System.Text;

class ConfirmNewPart {
    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    const uint BM_CLICK = 0x00F5;
    const uint WM_COMMAND = 0x0111;

    static void Main() {
        EnumWindows(delegate(IntPtr top, IntPtr l) {
            StringBuilder title = new StringBuilder(256);
            GetWindowText(top, title, 256);
            if (title.ToString().Contains("新建") || title.ToString().Contains("New")) {
                Console.WriteLine("Found New Dialog: " + title.ToString());
                // Send IDOK (1)
                SendMessage(top, WM_COMMAND, (IntPtr)1, IntPtr.Zero);
            }
            return true;
        }, IntPtr.Zero);
    }
}
