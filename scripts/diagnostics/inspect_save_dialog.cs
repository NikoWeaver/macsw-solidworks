using System;
using System.Text;
using System.Runtime.InteropServices;

class InspectSaveDialog {
    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumChildWindowsProc lpEnumFunc, IntPtr lParam);

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

    [DllImport("user32.dll")]
    public static extern IntPtr GetDC(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);

    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetTextFaceW(IntPtr hdc, int nCount, StringBuilder lpFaceName);

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
        EnumWindows((hWnd, lp0) => {
            StringBuilder title = new StringBuilder(256);
            GetWindowTextW(hWnd, title, 256);
            string tStr = title.ToString();

            bool found = false;
            EnumChildWindows(hWnd, (child, lp1) => {
                StringBuilder text = new StringBuilder(512);
                GetWindowTextW(child, text, 512);
                if (text.ToString().Contains("关闭的文档") || text.ToString().Contains("保存") || text.ToString().Contains("修改")) {
                    found = true;
                }
                return true;
            }, IntPtr.Zero);

            if (found) {
                Console.WriteLine(string.Format("=== FOUND DIALOG: {0:X8} '{1}' ===", hWnd.ToInt64(), tStr));
                EnumChildWindows(hWnd, (child, lp1) => {
                    StringBuilder cls = new StringBuilder(256);
                    GetClassNameW(child, cls, 256);
                    StringBuilder text = new StringBuilder(512);
                    GetWindowTextW(child, text, 512);

                    IntPtr hFont = SendMessageW(child, WM_GETFONT, IntPtr.Zero, IntPtr.Zero);
                    string fontDesc = "None";
                    if (hFont != IntPtr.Zero) {
                        LOGFONTW lf = new LOGFONTW();
                        if (GetObjectW(hFont, Marshal.SizeOf(typeof(LOGFONTW)), ref lf) > 0) {
                            fontDesc = string.Format("Face='{0}', H={1}, CS={2}", lf.lfFaceName, lf.lfHeight, lf.lfCharSet);
                        }
                    }

                    IntPtr hdc = GetDC(child);
                    StringBuilder dcFace = new StringBuilder(128);
                    GetTextFaceW(hdc, 128, dcFace);
                    ReleaseDC(child, hdc);

                    Console.WriteLine(string.Format("  Child {0:X8}, Cls='{1}', Font=[{2}], DCFace='{3}', Text='{4}'",
                        child.ToInt64(), cls, fontDesc, dcFace, text));
                    return true;
                }, IntPtr.Zero);
            }
            return true;
        }, IntPtr.Zero);
    }
}
