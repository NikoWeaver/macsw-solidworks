using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

class CaptureToolbar {
    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left, Top, Right, Bottom;
    }

    static void Main() {
        IntPtr tbWnd = new IntPtr(0x000F1462);
        RECT rc;
        GetWindowRect(tbWnd, out rc);
        int w = rc.Right - rc.Left;
        int h = rc.Bottom - rc.Top;
        if (w <= 0 || h <= 0) { w = 300; h = 50; }

        using (Bitmap bmp = new Bitmap(w, h)) {
            using (Graphics g = Graphics.FromImage(bmp)) {
                IntPtr hdc = g.GetHdc();
                PrintWindow(tbWnd, hdc, 0);
                g.ReleaseHdc(hdc);
            }
            bmp.Save("Z:\\Volumes\\Data\\Workspace\\WineSW\\scratch\\toolbar.png", ImageFormat.Png);
        }
        Console.WriteLine(string.Format("Saved toolbar.png: {0}x{1}", w, h));
    }
}
