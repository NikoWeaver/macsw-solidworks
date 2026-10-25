using System;
using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;

class TestThemeFont : Form {
    [DllImport("uxtheme.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
    static extern IntPtr OpenThemeData(IntPtr hWnd, string pszClassList);

    [DllImport("uxtheme.dll", ExactSpelling = true)]
    static extern int CloseThemeData(IntPtr hTheme);

    [DllImport("uxtheme.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
    static extern int DrawThemeText(IntPtr hTheme, IntPtr hdc, int iPartId, int iStateId, string pszText, int iCharCount, uint dwTextFlags, uint dwTextFlags2, ref RECT pRect);

    [DllImport("uxtheme.dll", ExactSpelling = true)]
    static extern int GetThemeSysFont(IntPtr hTheme, int iFontId, out LOGFONTW plf);

    [DllImport("uxtheme.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
    static extern int GetThemeFont(IntPtr hTheme, IntPtr hdc, int iPartId, int iStateId, int iPropId, out LOGFONTW plf);

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

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left, Top, Right, Bottom;
        public RECT(int l, int t, int r, int b) { Left = l; Top = t; Right = r; Bottom = b; }
    }

    protected override void OnPaint(PaintEventArgs e) {
        base.OnPaint(e);
        IntPtr hTheme = OpenThemeData(this.Handle, "Button");
        Console.WriteLine("OpenThemeData Button: " + hTheme.ToString("X"));
        if (hTheme != IntPtr.Zero) {
            // TMT_FONT = 210
            // Parts for Button: BP_COMMANDLINK = 6, BP_COMMANDLINKGLYPH = 7
            LOGFONTW lf;
            int hr = GetThemeFont(hTheme, e.Graphics.GetHdc(), 6, 1, 210, out lf);
            e.Graphics.ReleaseHdc();
            Console.WriteLine(string.Format("GetThemeFont hr={0}, Face='{1}', H={2}, CS={3}", hr, lf.lfFaceName, lf.lfHeight, lf.lfCharSet));

            // Check sys fonts
            for (int id = 801; id <= 809; id++) {
                LOGFONTW slf;
                int shr = GetThemeSysFont(hTheme, id, out slf);
                if (shr == 0) {
                    Console.WriteLine(string.Format("SysFont {0}: Face='{1}', H={2}, CS={3}", id, slf.lfFaceName, slf.lfHeight, slf.lfCharSet));
                }
            }

            CloseThemeData(hTheme);
        }
    }

    [STAThread]
    static void Main() {
        Application.EnableVisualStyles();
        TestThemeFont f = new TestThemeFont();
        f.Show();
        Application.DoEvents();
        System.Threading.Thread.Sleep(300);
        f.Close();
    }
}
