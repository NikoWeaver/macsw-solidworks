using System;
using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;

class TestCommandLinkThemeDisable : Form {
    [DllImport("user32.dll")]
    static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", EntryPoint = "SendMessageW", CharSet = CharSet.Unicode)]
    static extern IntPtr SendMessageWString(IntPtr hWnd, uint Msg, IntPtr wParam, string lParam);

    [DllImport("uxtheme.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
    static extern int SetWindowTheme(IntPtr hWnd, string pszSubAppName, string pszSubIdList);

    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFontW(
        int nHeight, int nWidth, int nEscapement, int nOrientation, int fnWeight,
        uint fdwItalic, uint fdwUnderline, uint fdwStrikeOut, uint fdwCharSet,
        uint fdwOutputPrecision, uint fdwClipPrecision, uint fdwQuality,
        uint fdwPitchAndFamily, string lpszFace);

    const int BS_COMMANDLINK = 0x0000000E;
    const uint BCM_SETNOTE = 0x1609;
    const uint WM_SETFONT = 0x0030;

    [DllImport("user32.dll")]
    static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

    public TestCommandLinkThemeDisable() {
        this.Text = "CommandLink Theme Disabled Test";
        this.Width = 500;
        this.Height = 250;

        Button btn1 = new Button {
            Text = "重试运行该命令(W)",
            Location = new Point(20, 20),
            Size = new Size(440, 70),
            FlatStyle = FlatStyle.System
        };
        this.Controls.Add(btn1);

        Button btn2 = new Button {
            Text = "切换到 SOLIDWORKS(C)",
            Location = new Point(20, 110),
            Size = new Size(440, 70),
            FlatStyle = FlatStyle.System
        };
        this.Controls.Add(btn2);

        this.Load += (s, e) => {
            IntPtr hFontSegoe = CreateFontW(-14, 0, 0, 0, 600, 0, 0, 0, 1, 0, 0, 5, 0, "Segoe UI Semibold");

            SetWindowTheme(btn1.Handle, " ", " ");
            int s1 = GetWindowLong(btn1.Handle, -16);
            SetWindowLong(btn1.Handle, -16, s1 | BS_COMMANDLINK);
            SendMessage(btn1.Handle, WM_SETFONT, hFontSegoe, new IntPtr(1));

            SetWindowTheme(btn2.Handle, " ", " ");
            int s2 = GetWindowLong(btn2.Handle, -16);
            SetWindowLong(btn2.Handle, -16, s2 | BS_COMMANDLINK);
            SendMessage(btn2.Handle, WM_SETFONT, hFontSegoe, new IntPtr(1));
        };
    }

    [STAThread]
    static void Main() {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        TestCommandLinkThemeDisable f = new TestCommandLinkThemeDisable();
        f.Show();
        Application.DoEvents();
        System.Threading.Thread.Sleep(500);

        using (Bitmap bmp = new Bitmap(f.ClientSize.Width, f.ClientSize.Height)) {
            f.DrawToBitmap(bmp, new Rectangle(0, 0, bmp.Width, bmp.Height));
            bmp.Save("scratch/commandlink_notheme_test.png");
        }
        Console.WriteLine("Saved scratch/commandlink_notheme_test.png");
        f.Close();
    }
}
