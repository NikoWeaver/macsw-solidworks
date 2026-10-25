using System;
using System.Text;
using System.Runtime.InteropServices;

class InspectTaskDialog {
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
    public static extern int GetWindowLongW(IntPtr hWnd, int nIndex);

    const uint WM_GETFONT = 0x0031;
    const int GWL_STYLE = -16;

    static void Main() {
        EnumWindows((hWnd, lp0) => {
            StringBuilder title = new StringBuilder(256);
            GetWindowTextW(hWnd, title, 256);
            string tStr = title.ToString();
            if (tStr.Contains("保存") || tStr.Contains("SOLIDWORKS")) {
                Console.WriteLine(string.Format("Window HWND: {0:X8}, Title: '{1}'", hWnd.ToInt64(), tStr));
                EnumChildWindows(hWnd, (child, lp1) => {
                    StringBuilder cls = new StringBuilder(256);
                    GetClassNameW(child, cls, 256);
                    StringBuilder text = new StringBuilder(512);
                    GetWindowTextW(child, text, 512);
                    int style = GetWindowLongW(child, GWL_STYLE);

                    IntPtr hFont = SendMessageW(child, WM_GETFONT, IntPtr.Zero, IntPtr.Zero);
                    string fontDesc = "No Font";
                    if (hFont != IntPtr.Zero) {
                        LOGFONTW lf = new LOGFONTW();
                        if (GetObjectW(hFont, Marshal.SizeOf(typeof(LOGFONTW)), ref lf) > 0) {
                            fontDesc = string.Format("Face='{0}', H={1}, CS={2}", lf.lfFaceName, lf.lfHeight, lf.lfCharSet);
                        }
                    }

                    Console.WriteLine(string.Format("  Child {0:X8}: Cls='{1}', Style={2:X8}, Font=[{3}], Text='{4}'",
                        child.ToInt64(), cls, style, fontDesc, text));
                    return true;
                }, IntPtr.Zero);
            }
            return true;
        }, IntPtr.Zero);
    }
}
