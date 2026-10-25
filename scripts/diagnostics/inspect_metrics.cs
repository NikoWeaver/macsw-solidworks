using System;
using System.Text;
using System.Runtime.InteropServices;

class InspectFontMetrics {
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

    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    static extern int GetTextFaceW(IntPtr hdc, int nCount, StringBuilder lpFaceName);

    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    static extern int GetTextMetricsW(IntPtr hdc, out TEXTMETRICW lptm);

    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    static extern uint GetFontUnicodeRanges(IntPtr hdc, IntPtr lpgs);

    [DllImport("user32.dll")]
    static extern IntPtr GetDC(IntPtr hWnd);

    [DllImport("user32.dll")]
    static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct TEXTMETRICW {
        public int tmHeight;
        public int tmAscent;
        public int tmDescent;
        public int tmInternalLeading;
        public int tmExternalLeading;
        public int tmAveCharWidth;
        public int tmMaxCharWidth;
        public int tmWeight;
        public int tmOverhang;
        public int tmDigitizedAspectX;
        public int tmDigitizedAspectY;
        public char tmFirstChar;
        public char tmLastChar;
        public char tmDefaultChar;
        public char tmBreakChar;
        public byte tmItalic;
        public byte tmUnderlined;
        public byte tmStruckOut;
        public byte tmPitchAndFamily;
        public byte tmCharSet;
    }

    static void Main() {
        IntPtr hdc = GetDC(IntPtr.Zero);

        string[] faces = { "Tahoma", "Segoe UI Semibold", "Microsoft YaHei UI" };
        foreach (var face in faces) {
            IntPtr hf = CreateFontW(-16, 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, face);
            SelectObject(hdc, hf);

            StringBuilder actual = new StringBuilder(256);
            GetTextFaceW(hdc, 256, actual);

            TEXTMETRICW tm;
            GetTextMetricsW(hdc, out tm);

            uint glyphCount = GetFontUnicodeRanges(hdc, IntPtr.Zero);

            Console.WriteLine(string.Format("Face: '{0}' -> Actual: '{1}', H={2}, CS={3}, PitchAndFamily=0x{4:X2}, RangesSize={5}",
                face, actual, tm.tmHeight, tm.tmCharSet, tm.tmPitchAndFamily, glyphCount));

            DeleteObject(hf);
        }

        ReleaseDC(IntPtr.Zero, hdc);
    }
}
