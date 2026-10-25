using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Text;
using System.Runtime.InteropServices;

class CaptureActiveDialog {
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern IntPtr GetDC(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);

    [DllImport("gdi32.dll")]
    public static extern bool BitBlt(IntPtr hdcDest, int nXDest, int nYDest, int nWidth, int nHeight, IntPtr hdcSrc, int nXSrc, int nYSrc, int dwRop);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left, Top, Right, Bottom;
    }

    static void Main() {
        IntPtr fg = GetForegroundWindow();
        StringBuilder t = new StringBuilder(256);
        GetWindowTextW(fg, t, 256);
        RECT rc;
        GetWindowRect(fg, out rc);
        int w = rc.Right - rc.Left;
        int h = rc.Bottom - rc.Top;

        Console.WriteLine(string.Format("Foreground: {0:X8}, Title='{1}', Size={2}x{3}", fg.ToInt64(), t, w, h));

        if (w > 0 && h > 0) {
            using (Bitmap bmp = new Bitmap(w, h)) {
                using (Graphics g = Graphics.FromImage(bmp)) {
                    IntPtr hdcDest = g.GetHdc();
                    IntPtr hdcSrc = GetDC(fg);
                    BitBlt(hdcDest, 0, 0, w, h, hdcSrc, 0, 0, 0x00CC0020);
                    ReleaseDC(fg, hdcSrc);
                    g.ReleaseHdc(hdcDest);
                }
                bmp.Save("Z:\\Volumes\\Data\\Workspace\\WineSW\\scratch\\active_dialog.png", ImageFormat.Png);
                Console.WriteLine("Saved active_dialog.png");
            }
        }
    }
}
