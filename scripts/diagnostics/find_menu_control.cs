using System;
using System.Text;
using System.Runtime.InteropServices;

class FindMenuControl {
    [DllImport("user32.dll")]
    public static extern bool EnumChildWindows(IntPtr hWnd, EnumChildWindowsProc lpEnumFunc, IntPtr lParam);
    public delegate bool EnumChildWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern IntPtr SendMessageW(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

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

    const uint WM_GETFONT = 0x0031;

    static void Main() {
        IntPtr mainWnd = new IntPtr(0x001314F6); // SLDWORKS main frame
        EnumChildWindows(mainWnd, (hWnd, lp) => {
            StringBuilder text = new StringBuilder(256);
            GetWindowTextW(hWnd, text, 256);
            string t = text.ToString();
            if (t.Contains("(F)") || t.Contains("(V)") || t.Contains("(T)") || t.Contains("(E)") || t.Contains("文件")) {
                StringBuilder cls = new StringBuilder(256);
                GetClassNameW(hWnd, cls, 256);

                IntPtr hFont = SendMessageW(hWnd, WM_GETFONT, IntPtr.Zero, IntPtr.Zero);
                string fDesc = "No Font";
                if (hFont != IntPtr.Zero) {
                    LOGFONTW lf = new LOGFONTW();
                    if (GetObjectW(hFont, Marshal.SizeOf(typeof(LOGFONTW)), ref lf) > 0) {
                        fDesc = string.Format("Face='{0}', H={1}, CS={2}", lf.lfFaceName, lf.lfHeight, lf.lfCharSet);
                    }
                }
                Console.WriteLine(string.Format("Control HWND: {0:X8}, Class: '{1}', Font: [{2}], Text: '{3}'",
                    hWnd.ToInt64(), cls, fDesc, t));
            }
            return true;
        }, IntPtr.Zero);
    }
}
