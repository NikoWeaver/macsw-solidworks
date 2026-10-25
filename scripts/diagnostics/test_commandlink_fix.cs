using System;
using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;
using System.Text;

class TestCommandLinkFix : Form {
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

    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetObjectW(IntPtr hgdiobj, int cbBuffer, ref LOGFONTW lpvObject);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct LOGFONTW {
        public int lfHeight;
        public int lfWidth;
        public int lfEscapement;
        public int lfOrientation;
        public int lfWeight;
        public byte lfItalic;
        public byte lfUnderline;
        public byte lfStrikeOut;
        public byte lfCharSet;
        public byte lfOutPrecision;
        public byte lfClipPrecision;
        public byte lfQuality;
        public byte lfPitchAndFamily;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string lfFaceName;
    }

    [DllImport("user32.dll")]
    static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

    const int BS_COMMANDLINK = 0x0000000E;
    const uint BCM_SETNOTE = 0x1609;
    const uint WM_GETFONT = 0x0031;
    const uint WM_SETFONT = 0x0030;

    public TestCommandLinkFix() {
        this.Text = "CommandLink Fix Test";
        this.Width = 500;
        this.Height = 400;

        // Button 1: Default (reproduce bug)
        Button btn1 = new Button { Text = "默认按钮(D)", Location = new Point(20, 20), Size = new Size(440, 70), FlatStyle = FlatStyle.System };
        this.Controls.Add(btn1);

        // Button 2: Set WM_SETFONT
        Button btn2 = new Button { Text = "WM_SETFONT 修复(F)", Location = new Point(20, 100), Size = new Size(440, 70), FlatStyle = FlatStyle.System };
        this.Controls.Add(btn2);

        // Button 3: Disable Theme
        Button btn3 = new Button { Text = "禁用主题修复(T)", Location = new Point(20, 180), Size = new Size(440, 70), FlatStyle = FlatStyle.System };
        this.Controls.Add(btn3);

        // Button 4: Both Theme disabled + SetFont
        Button btn4 = new Button { Text = "双管齐下修复(B)", Location = new Point(20, 260), Size = new Size(440, 70), FlatStyle = FlatStyle.System };
        this.Controls.Add(btn4);

        this.Load += (s, e) => {
            Button[] btns = { btn1, btn2, btn3, btn4 };
            foreach (var b in btns) {
                int style = GetWindowLong(b.Handle, -16);
                SetWindowLong(b.Handle, -16, style | BS_COMMANDLINK);
                SendMessageWString(b.Handle, BCM_SETNOTE, IntPtr.Zero, "测试第二行说明文本：中文应该清晰显示");
            }

            // Inspect font of btn1
            IntPtr hFont1 = SendMessage(btn1.Handle, WM_GETFONT, IntPtr.Zero, IntPtr.Zero);
            Console.WriteLine("btn1 WM_GETFONT: " + hFont1.ToString("X"));
            if (hFont1 != IntPtr.Zero) {
                LOGFONTW lf = new LOGFONTW();
                GetObjectW(hFont1, Marshal.SizeOf(typeof(LOGFONTW)), ref lf);
                Console.WriteLine(string.Format("btn1 LOGFONT: Face='{0}', H={1}, W={2}, CS={3}", lf.lfFaceName, lf.lfHeight, lf.lfWeight, lf.lfCharSet));
            }

            // Fix btn2 with WM_SETFONT
            IntPtr hFontYaHei = CreateFontW(-14, 0, 0, 0, 400, 0, 0, 0, 134, 0, 0, 5, 0, "Microsoft YaHei UI");
            SendMessage(btn2.Handle, WM_SETFONT, hFontYaHei, new IntPtr(1));

            // Fix btn3 with SetWindowTheme
            SetWindowTheme(btn3.Handle, " ", " ");

            // Fix btn4 with both
            SetWindowTheme(btn4.Handle, " ", " ");
            SendMessage(btn4.Handle, WM_SETFONT, hFontYaHei, new IntPtr(1));
        };
    }

    [STAThread]
    static void Main() {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        TestCommandLinkFix f = new TestCommandLinkFix();
        f.Show();
        Application.DoEvents();
        System.Threading.Thread.Sleep(500);

        using (Bitmap bmp = new Bitmap(f.Width, f.Height)) {
            f.DrawToBitmap(bmp, new Rectangle(0, 0, f.Width, f.Height));
            bmp.Save("scratch/commandlink_fix_compare.png");
        }
        Console.WriteLine("Saved scratch/commandlink_fix_compare.png");
        f.Close();
    }
}
