using System;
using System.Text;
using System.Runtime.InteropServices;

class InspectMenuBarFont {
    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumChildWindows(IntPtr hWnd, EnumChildWindowsProc lpEnumFunc, IntPtr lParam);
    public delegate bool EnumChildWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

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

    const uint WM_GETFONT = 0x0031;

    static void Main() {
        EnumWindows((hWnd, lParam) => {
            StringBuilder title = new StringBuilder(256);
            GetWindowText(hWnd, title, 256);
            if (title.ToString().Contains("SOLIDWORKS")) {
                Console.WriteLine("Found Main Window: " + hWnd.ToString("X") + " Title: " + title);
                EnumChildWindows(hWnd, (childHwnd, childParam) => {
                    StringBuilder cls = new StringBuilder(256);
                    GetClassName(childHwnd, cls, 256);
                    StringBuilder text = new StringBuilder(256);
                    GetWindowText(childHwnd, text, 256);

                    // Check font
                    IntPtr hFont = SendMessage(childHwnd, WM_GETFONT, IntPtr.Zero, IntPtr.Zero);
                    string fontDesc = "No Font";
                    if (hFont != IntPtr.Zero) {
                        LOGFONT lf = new LOGFONT();
                        if (GetObject(hFont, Marshal.SizeOf(typeof(LOGFONT)), ref lf) > 0) {
                            fontDesc = string.Format("Face='{0}', Height={1}, CharSet={2}", lf.lfFaceName, lf.lfHeight, lf.lfCharSet);
                        }
                    }

                    if (cls.ToString().Contains("Menu") || cls.ToString().Contains("Bar") || cls.ToString().Contains("Toolbar") || text.Length > 0) {
                        Console.WriteLine(string.Format("  HWND: {0:X8}, Class: '{1}', Text: '{2}', Font: [{3}]", 
                            childHwnd.ToInt64(), cls, text, fontDesc));
                    }
                    return true;
                }, IntPtr.Zero);
            }
            return true;
        }, IntPtr.Zero);
    }
}
