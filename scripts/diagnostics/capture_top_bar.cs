using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

class CaptureTopBar {
    [DllImport("user32.dll")]
    public static extern IntPtr GetDC(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);

    [DllImport("gdi32.dll")]
    public static extern bool BitBlt(IntPtr hdcDest, int nXDest, int nYDest, int nWidth, int nHeight, IntPtr hdcSrc, int nXSrc, int nYSrc, int dwRop);

    static void Main() {
        IntPtr mainWnd = new IntPtr(0x001314F6); // SLDWORKS main frame
        IntPtr hdcSrc = GetDC(mainWnd);
        int w = 900;
        int h = 120;
        using (Bitmap bmp = new Bitmap(w, h)) {
            using (Graphics g = Graphics.FromImage(bmp)) {
                IntPtr hdcDest = g.GetHdc();
                BitBlt(hdcDest, 0, 0, w, h, hdcSrc, 0, 0, 0x00CC0020 /* SRCCOPY */);
                g.ReleaseHdc(hdcDest);
            }
            bmp.Save("Z:\\Volumes\\Data\\Workspace\\WineSW\\scratch\\top_bar.png", ImageFormat.Png);
        }
        ReleaseDC(mainWnd, hdcSrc);
        Console.WriteLine("Saved top_bar.png");
    }
}
