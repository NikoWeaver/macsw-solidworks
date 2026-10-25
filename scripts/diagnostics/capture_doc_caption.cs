
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

class CaptureDocCaption {
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("gdi32.dll")] static extern bool BitBlt(IntPtr hdcDest, int nXDest, int nYDest, int nWidth, int nHeight, IntPtr hdcSrc, int nXSrc, int nYSrc, int dwRop);

    static void Main() {
        IntPtr hdcDesk = GetDC(IntPtr.Zero);
        int sx = 2700;
        int sy = 141;
        int w = 240;
        int h = 35;

        using (Bitmap bmp = new Bitmap(w, h)) {
            using (Graphics g = Graphics.FromImage(bmp)) {
                IntPtr hdcDest = g.GetHdc();
                BitBlt(hdcDest, 0, 0, w, h, hdcDesk, sx, sy, 0x00CC0020);
                g.ReleaseHdc(hdcDest);
            }
            bmp.Save(@"Z:\Volumes\Data\Workspace\WineSW\scratch\screen_caption.png", ImageFormat.Png);
            Console.WriteLine("Saved screen_caption.png");
        }
        ReleaseDC(IntPtr.Zero, hdcDesk);
    }
}
