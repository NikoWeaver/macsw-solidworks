using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

class TestDrawMdiButton {
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr OpenThemeData(IntPtr hWnd, string pszClassList);

    [DllImport("uxtheme.dll")]
    static extern int CloseThemeData(IntPtr hTheme);

    [DllImport("uxtheme.dll")]
    static extern int DrawThemeBackground(IntPtr hTheme, IntPtr hdc, int iPartId, int iStateId, ref RECT pRect, IntPtr pClipRect);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left, Top, Right, Bottom;
        public RECT(int l, int t, int r, int b) { Left = l; Top = t; Right = r; Bottom = b; }
    }

    static void Main() {
        IntPtr hTheme = OpenThemeData(IntPtr.Zero, "Window");
        Console.WriteLine("hTheme Window: " + hTheme);
        if (hTheme == IntPtr.Zero) return;

        using (Bitmap bmp = new Bitmap(200, 100, PixelFormat.Format32bppArgb)) {
            using (Graphics g = Graphics.FromImage(bmp)) {
                g.Clear(Color.CornflowerBlue);
                IntPtr hdc = g.GetHdc();

                // WP_MDIMINBUTTON = 16, WP_MDIRESTOREBUTTON = 22, WP_MDICLOSEBUTTON = 20
                RECT rMin = new RECT(10, 10, 30, 30);
                RECT rRest = new RECT(35, 10, 55, 30);
                RECT rClose = new RECT(60, 10, 80, 30);

                int hr1 = DrawThemeBackground(hTheme, hdc, 16, 1, ref rMin, IntPtr.Zero);
                int hr2 = DrawThemeBackground(hTheme, hdc, 22, 1, ref rRest, IntPtr.Zero);
                int hr3 = DrawThemeBackground(hTheme, hdc, 20, 1, ref rClose, IntPtr.Zero);

                Console.WriteLine($"DrawThemeBackground: Min=0x{hr1:X8}, Rest=0x{hr2:X8}, Close=0x{hr3:X8}");
                g.ReleaseHdc(hdc);
            }
            bmp.Save(@"Z:\Volumes\Data\Workspace\WineSW\scratch\drawn_theme_buttons.png", ImageFormat.Png);
        }

        CloseThemeData(hTheme);
    }
}
