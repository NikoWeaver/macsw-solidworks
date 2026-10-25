using System;
using System.Text;
using System.Runtime.InteropServices;

class CheckStockFonts {
    [DllImport("gdi32.dll")]
    public static extern IntPtr GetStockObject(int fnObject);

    [DllImport("gdi32.dll", CharSet = CharSet.Auto)]
    public static extern int GetObject(IntPtr hgdiobj, int cbBuffer, ref LOGFONT lpvObject);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public struct LOGFONT {
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

    const int SYSTEM_FONT = 13;
    const int DEFAULT_GUI_FONT = 17;
    const int SYSTEM_FIXED_FONT = 16;
    const int ANSI_VAR_FONT = 12;

    static void Check(string name, int id) {
        IntPtr h = GetStockObject(id);
        LOGFONT lf = new LOGFONT();
        GetObject(h, Marshal.SizeOf(typeof(LOGFONT)), ref lf);
        Console.WriteLine(string.Format("{0}: Face='{1}', Height={2}, CharSet={3}", name, lf.lfFaceName, lf.lfHeight, lf.lfCharSet));
    }

    static void Main() {
        Check("DEFAULT_GUI_FONT", DEFAULT_GUI_FONT);
        Check("SYSTEM_FONT", SYSTEM_FONT);
        Check("SYSTEM_FIXED_FONT", SYSTEM_FIXED_FONT);
        Check("ANSI_VAR_FONT", ANSI_VAR_FONT);
    }
}
