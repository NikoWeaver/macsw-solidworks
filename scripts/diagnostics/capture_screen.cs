using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

class CaptureScreen {
    [DllImport("user32.dll")]
    static extern IntPtr GetDC(IntPtr hWnd);

    [DllImport("user32.dll")]
    static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);

    [DllImport("gdi32.dll")]
    static extern bool BitBlt(IntPtr hObject, int nXDest, int nYDest, int nWidth, int nHeight, IntPtr hObjectSource, int nXSrc, int nYSrc, int dwRop);

    [DllImport("user32.dll")]
    static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll")]
    static extern bool IsWindowVisible(IntPtr hWnd);

    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    struct RECT {
        public int Left, Top, Right, Bottom;
    }

    const int SRCCOPY = 0x00CC0020;

    static bool EnumChild(IntPtr hwnd, IntPtr lParam) {
        StringBuilder cls = new StringBuilder(256);
        GetClassName(hwnd, cls, 256);
        if (cls.ToString() == "SysTreeView32" && IsWindowVisible(hwnd)) {
            RECT r;
            GetWindowRect(hwnd, out r);
            int w = r.Right - r.Left;
            int h = r.Bottom - r.Top;
            if (w > 50 && h > 50) {
                Console.WriteLine(string.Format("Screen capture tree 0x{0:X8}: ({1},{2}) {3}x{4}", hwnd.ToInt64(), r.Left, r.Top, w, h));
                IntPtr screenDc = GetDC(IntPtr.Zero);
                using (Bitmap bmp = new Bitmap(w, h, PixelFormat.Format24bppRgb)) {
                    using (Graphics g = Graphics.FromImage(bmp)) {
                        IntPtr destDc = g.GetHdc();
                        BitBlt(destDc, 0, 0, w, h, screenDc, r.Left, r.Top, SRCCOPY);
                        g.ReleaseHdc(destDc);
                    }
                    string path = string.Format("Z:\\Volumes\\Data\\Workspace\\WineSW\\scratch\\screen_tree_0x{0:X8}.png", hwnd.ToInt64());
                    bmp.Save(path, ImageFormat.Png);
                    Console.WriteLine("Saved: " + path);
                }
                ReleaseDC(IntPtr.Zero, screenDc);
            }
        }
        return true;
    }

    static bool EnumTop(IntPtr hwnd, IntPtr lParam) {
        EnumChildWindows(hwnd, EnumChild, IntPtr.Zero);
        return true;
    }

    static void Main() {
        EnumWindows(EnumTop, IntPtr.Zero);
    }
}
