using System;
using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;
using System.Text;

class TestCommandLink : Form {
    [DllImport("user32.dll")]
    static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFontW(
        int nHeight, int nWidth, int nEscapement, int nOrientation, int fnWeight,
        uint fdwItalic, uint fdwUnderline, uint fdwStrikeOut, uint fdwCharSet,
        uint fdwOutputPrecision, uint fdwClipPrecision, uint fdwQuality,
        uint fdwPitchAndFamily, string lpszFace);

    const int BS_COMMANDLINK = 0x0000000E;
    const int BS_DEFCOMMANDLINK = 0x0000000F;
    const uint BCM_SETNOTE = 0x1609;
    const uint WM_SETFONT = 0x0030;

    protected override CreateParams CreateParams {
        get {
            CreateParams cp = base.CreateParams;
            return cp;
        }
    }

    public TestCommandLink() {
        this.Text = "CommandLink Font Test";
        this.Width = 450;
        this.Height = 300;

        Button btn = new Button();
        btn.Text = "重试运行该命令(W)";
        btn.Location = new Point(20, 20);
        btn.Size = new Size(380, 70);
        btn.FlatStyle = FlatStyle.System;
        this.Controls.Add(btn);

        Button btn2 = new Button();
        btn2.Text = "切换到 SOLIDWORKS(C)";
        btn2.Location = new Point(20, 100);
        btn2.Size = new Size(380, 70);
        btn2.FlatStyle = FlatStyle.System;
        this.Controls.Add(btn2);

        this.Load += (s, e) => {
            // Set style to BS_COMMANDLINK
            SetStyle(btn.Handle, BS_COMMANDLINK);
            SetStyle(btn2.Handle, BS_COMMANDLINK);

            // Set note text using BCM_SETNOTE
            SendMessageWString(btn.Handle, BCM_SETNOTE, IntPtr.Zero, "如果该命令处于挂起状态，请重试");
            SendMessageWString(btn2.Handle, BCM_SETNOTE, IntPtr.Zero, "激活该程序并更正问题");
        };
    }

    [DllImport("user32.dll", EntryPoint = "SendMessageW", CharSet = CharSet.Unicode)]
    static extern IntPtr SendMessageWString(IntPtr hWnd, uint Msg, IntPtr wParam, string lParam);

    [DllImport("user32.dll")]
    static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

    void SetStyle(IntPtr hWnd, int addStyle) {
        int style = GetWindowLong(hWnd, -16);
        SetWindowLong(hWnd, -16, style | addStyle);
    }

    [STAThread]
    static void Main() {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        TestCommandLink f = new TestCommandLink();
        f.Show();
        Application.DoEvents();
        System.Threading.Thread.Sleep(500);

        // Capture screenshot
        using (Bitmap bmp = new Bitmap(f.Width, f.Height)) {
            f.DrawToBitmap(bmp, new Rectangle(0, 0, f.Width, f.Height));
            bmp.Save("scratch/commandlink_test.png");
        }
        Console.WriteLine("Saved scratch/commandlink_test.png");
        f.Close();
    }
}
