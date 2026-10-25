using System;
using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;

class TestGdiText {
    [DllImport("gdi32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr CreateFont(
        int nHeight, int nWidth, int nEscapement, int nOrientation, int fnWeight,
        uint fdwItalic, uint fdwUnderline, uint fdwStrikeOut, uint fdwCharSet,
        uint fdwOutputPrecision, uint fdwClipPrecision, uint fdwQuality,
        uint fdwPitchAndFamily, string lpszFace);

    [DllImport("gdi32.dll")]
    public static extern IntPtr SelectObject(IntPtr hdc, IntPtr hgdiobj);

    [DllImport("gdi32.dll")]
    public static extern bool DeleteObject(IntPtr hObject);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int DrawText(IntPtr hDC, string lpString, int nCount, ref RECT lpRect, uint uFormat);

    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetTextFace(IntPtr hdc, int nCount, System.Text.StringBuilder lpFaceName);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left, Top, Right, Bottom;
        public RECT(int l, int t, int r, int b) { Left = l; Top = t; Right = r; Bottom = b; }
    }

    static void Main() {
        string[] fontFaces = new string[] {
            "Microsoft YaHei UI",
            "微软雅黑",
            "SimSun",
            "STSong",
            "MS Shell Dlg",
            "MS Shell Dlg 2",
            "Tahoma",
            "Segoe UI",
            "Segoe UI Semibold"
        };
        string text = "文件(F)  新建(N)...  零件  装配体  工程图  确定";

        using (Bitmap bmp = new Bitmap(800, 320)) {
            using (Graphics g = Graphics.FromImage(bmp)) {
                g.Clear(Color.White);
                IntPtr hdc = g.GetHdc();
                int y = 10;
                foreach (string face in fontFaces) {
                    IntPtr hFont = CreateFont(18, 0, 0, 0, 400, 0, 0, 0, 134 /* GB2312_CHARSET */,
                        0, 0, 0, 0, face);
                    IntPtr oldFont = SelectObject(hdc, hFont);
                    System.Text.StringBuilder sb = new System.Text.StringBuilder(128);
                    GetTextFace(hdc, 128, sb);
                    Console.WriteLine(string.Format("Requested '{0}' -> Selected Face: '{1}'", face, sb.ToString()));
                    RECT rc = new RECT(10, y, 790, y + 35);
                    DrawText(hdc, face + " (" + sb.ToString() + "): " + text, (face + " (" + sb.ToString() + "): " + text).Length, ref rc, 0);
                    SelectObject(hdc, oldFont);
                    DeleteObject(hFont);
                    y += 35;
                }
                g.ReleaseHdc(hdc);
            }
            bmp.Save("Z:\\Volumes\\Data\\Workspace\\WineSW\\scripts\\gdi_font_test.png", System.Drawing.Imaging.ImageFormat.Png);
        }
        Console.WriteLine("Saved test render to gdi_font_test.png");
    }
}
