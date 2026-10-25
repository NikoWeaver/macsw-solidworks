using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

class CaptureWindow {
    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool PrintWindow(IntPtr hwnd, IntPtr hdcBlt, uint nFlags);

    [DllImport("user32.dll")]
    static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    static extern bool IsWindowVisible(IntPtr hWnd);

    [StructLayout(LayoutKind.Sequential)]
    struct RECT {
        public int Left, Top, Right, Bottom;
    }

    const uint TVM_GETCOUNT = 0x1100 + 5;

    static bool EnumChild(IntPtr hwnd, IntPtr lParam) {
        StringBuilder cls = new StringBuilder(256);
        GetClassName(hwnd, cls, 256);
        if (cls.ToString() == "SysTreeView32" && IsWindowVisible(hwnd)) {
            RECT r;
            GetWindowRect(hwnd, out r);
            int w = r.Right - r.Left;
            int h = r.Bottom - r.Top;
            int count = (int)SendMessage(hwnd, TVM_GETCOUNT, IntPtr.Zero, IntPtr.Zero);
            Console.WriteLine(string.Format("Found visible SysTreeView32 0x{0:X8}: {1}x{2}, items={3}", hwnd.ToInt64(), w, h, count));
            if (w > 10 && h > 10) {
                using (Bitmap bmp = new Bitmap(w, h)) {
                    using (Graphics g = Graphics.FromImage(bmp)) {
                        IntPtr hdc = g.GetHdc();
                        bool res = PrintWindow(hwnd, hdc, 0);
                        g.ReleaseHdc(hdc);
                        Console.WriteLine("PrintWindow result: " + res);
                    }
                    bmp.Save("Z:\\Volumes\\Data\\Workspace\\WineSW\\scratch\\tree_capture.png", ImageFormat.Png);
                    Console.WriteLine("Saved to scratch/tree_capture.png");
                }
            }
        }
        return true;
    }

    static bool EnumTop(IntPtr hwnd, IntPtr lParam) {
        StringBuilder title = new StringBuilder(256);
        GetWindowText(hwnd, title, 256);
        if (title.ToString().Contains("SOLIDWORKS")) {
            EnumChildWindows(hwnd, EnumChild, IntPtr.Zero);
        }
        return true;
    }

    static void Main(string[] args) {
        EnumWindows(EnumTop, IntPtr.Zero);
    }
}
