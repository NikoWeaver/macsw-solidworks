using System;
using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;

class TestGdiVsUxtheme : Form {
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFontW(
        int nHeight, int nWidth, int nEscapement, int nOrientation, int fnWeight,
        uint fdwItalic, uint fdwUnderline, uint fdwStrikeOut, uint fdwCharSet,
        uint fdwOutputPrecision, uint fdwClipPrecision, uint fdwQuality,
        uint fdwPitchAndFamily, string lpszFace);

    [DllImport("gdi32.dll")]
    static extern IntPtr SelectObject(IntPtr hdc, IntPtr hgdiobj);

    [DllImport("gdi32.dll")]
    static extern bool DeleteObject(IntPtr hObject);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int DrawTextW(IntPtr hdc, string lpchText, int cchText, ref RECT lprc, uint format);

    [DllImport("uxtheme.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
    static extern IntPtr OpenThemeData(IntPtr hWnd, string pszClassList);

    [DllImport("uxtheme.dll", ExactSpelling = true)]
    static extern int CloseThemeData(IntPtr hTheme);

    [DllImport("uxtheme.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
    static extern int DrawThemeText(IntPtr hTheme, IntPtr hdc, int iPartId, int iStateId, string pszText, int iCharCount, uint dwTextFlags, uint dwTextFlags2, ref RECT pRect);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left, Top, Right, Bottom;
        public RECT(int l, int t, int r, int b) { Left = l; Top = t; Right = r; Bottom = b; }
    }

    protected override void OnPaint(PaintEventArgs e) {
        base.OnPaint(e);
        IntPtr hdc = e.Graphics.GetHdc();

        // 1. Raw GDI with Tahoma, charset=1
        IntPtr f1 = CreateFontW(-14, 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, "Tahoma");
        IntPtr oldF = SelectObject(hdc, f1);
        RECT r1 = new RECT(20, 20, 400, 50);
        DrawTextW(hdc, "1. GDI Tahoma (CS=1): 中文测试", -1, ref r1, 0);

        // 2. Raw GDI with YaHei, charset=1
        IntPtr f2 = CreateFontW(-14, 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, "Microsoft YaHei UI");
        SelectObject(hdc, f2);
        RECT r2 = new RECT(20, 60, 400, 90);
        DrawTextW(hdc, "2. GDI YaHei (CS=1): 中文测试", -1, ref r2, 0);

        // 3. uxtheme DrawThemeText with Button part 6 (BP_COMMANDLINK)
        IntPtr hTheme = OpenThemeData(this.Handle, "Button");
        if (hTheme != IntPtr.Zero) {
            RECT r3 = new RECT(20, 100, 400, 140);
            DrawThemeText(hTheme, hdc, 6, 1, "3. Theme CommandLink: 中文测试", -1, 0, 0, ref r3);
            CloseThemeData(hTheme);
        }

        SelectObject(hdc, oldF);
        DeleteObject(f1);
        DeleteObject(f2);
        e.Graphics.ReleaseHdc();
    }

    [STAThread]
    static void Main() {
        Application.EnableVisualStyles();
        TestGdiVsUxtheme f = new TestGdiVsUxtheme();
        f.Text = "GDI vs UXTHEME";
        f.Width = 450;
        f.Height = 200;
        f.Show();
        Application.DoEvents();
        System.Threading.Thread.Sleep(300);

        using (Bitmap bmp = new Bitmap(f.ClientSize.Width, f.ClientSize.Height)) {
            f.DrawToBitmap(bmp, new Rectangle(0, 0, bmp.Width, bmp.Height));
            bmp.Save("scratch/gdi_vs_uxtheme.png");
        }
        Console.WriteLine("Saved scratch/gdi_vs_uxtheme.png");
        f.Close();
    }
}
