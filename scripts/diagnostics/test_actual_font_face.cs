using System;
using System.Text;
using System.Runtime.InteropServices;

class TestActualFontFace {
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

    [DllImport("user32.dll")]
    static extern IntPtr GetDC(IntPtr hWnd);

    [DllImport("user32.dll")]
    static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);

    static void Main() {
        IntPtr hdc = GetDC(IntPtr.Zero);

        string[] testFaces = { "Tahoma", "Segoe UI", "SimSun", "Microsoft YaHei", "Microsoft YaHei UI", "MS Shell Dlg" };

        foreach (string face in testFaces) {
            IntPtr hFont = CreateFontW(-14, 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, face);
            IntPtr old = SelectObject(hdc, hFont);

            StringBuilder actual = new StringBuilder(256);
            GetTextFaceW(hdc, 256, actual);

            Console.WriteLine(string.Format("Requested: '{0}' -> Actual Realized: '{1}'", face, actual.ToString()));

            SelectObject(hdc, old);
            DeleteObject(hFont);
        }

        ReleaseDC(IntPtr.Zero, hdc);
    }
}
