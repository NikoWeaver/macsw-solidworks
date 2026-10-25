using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

class CreateNewDoc {
    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    const uint WM_COMMAND = 0x0111;
    const uint WM_KEYDOWN = 0x0100;
    const uint WM_KEYUP = 0x0101;
    const int VK_CONTROL = 0x11;
    const int VK_N = 0x4E;

    static void Main() {
        IntPtr swHwnd = IntPtr.Zero;
        EnumWindows(delegate(IntPtr top, IntPtr l) {
            StringBuilder sb = new StringBuilder(256);
            GetWindowText(top, sb, 256);
            if (sb.ToString().Contains("SOLIDWORKS Premium 2025")) {
                swHwnd = top;
                return false;
            }
            return true;
        }, IntPtr.Zero);

        if (swHwnd != IntPtr.Zero) {
            Console.WriteLine("Sending Ctrl+N to SW: 0x{0:X}", swHwnd.ToInt64());
            // Standard MFC ID_FILE_NEW is 57600 (0xE100)
            PostMessage(swHwnd, WM_COMMAND, (IntPtr)57600, IntPtr.Zero);
            Thread.Sleep(500);
            Console.WriteLine("Done.");
        }
    }
}
