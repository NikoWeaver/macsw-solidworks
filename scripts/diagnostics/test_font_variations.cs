using System;
using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;

class TestFontVariations : Form {
    [DllImport("user32.dll")]
    static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFontW(
        int nHeight, int nWidth, int nEscapement, int nOrientation, int fnWeight,
        uint fdwItalic, uint fdwUnderline, uint fdwStrikeOut, uint fdwCharSet,
        uint fdwOutputPrecision, uint fdwClipPrecision, uint fdwQuality,
        uint fdwPitchAndFamily, string lpszFace);

    const int BS_COMMANDLINK = 0x0000000E;
    const uint WM_SETFONT = 0x0030;

    public TestFontVariations() {
        this.Text = "Font Variations";
        this.Width = 600;
        this.Height = 500;

        string[] fonts = {
            "SimSun",
            "Microsoft YaHei",
            "Microsoft YaHei UI",
            "Segoe UI",
            "Tahoma"
        };

        for (int i = 0; i < fonts.Length; i++) {
            Button b = new Button();
            b.Text = fonts[i] + ": 中文测试(T)";
            b.Location = new Point(20, 20 + i * 80);
            b.Size = new Size(540, 70);
            b.FlatStyle = FlatStyle.System;
            this.Controls.Add(b);

            // style BS_COMMANDLINK
            int s = GetWindowLong(b.Handle, -16);
            SetWindowLong(b.Handle, -16, s | BS_COMMANDLINK);

            // Set font with charset 1 (DEFAULT_CHARSET)
            IntPtr hf = CreateFontW(-16, 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, fonts[i]);
            SendMessage(b.Handle, WM_SETFONT, hf, new IntPtr(1));
        }
    }

    [DllImport("user32.dll")]
    static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

    [STAThread]
    static void Main() {
        Application.EnableVisualStyles();
        TestFontVariations f = new TestFontVariations();
        f.Show();
        Application.DoEvents();
        System.Threading.Thread.Sleep(500);

        // Render whole client area
        Bitmap bmp = new Bitmap(f.ClientSize.Width, f.ClientSize.Height);
        f.DrawToBitmap(bmp, new Rectangle(0, 0, bmp.Width, bmp.Height));
        bmp.Save("scratch/font_variations.png");
        Console.WriteLine("Saved scratch/font_variations.png");
        f.Close();
    }
}
