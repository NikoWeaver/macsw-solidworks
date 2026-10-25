using System;
using System.Text;
using System.Runtime.InteropServices;

class InspectNewDialog {
    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumChildWindows(IntPtr hWnd, EnumChildWindowsProc lpEnumFunc, IntPtr lParam);
    public delegate bool EnumChildWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

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
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left, Top, Right, Bottom;
    }

    const uint WM_GETFONT = 0x0031;

    static void Main() {
        EnumWindows((hWnd, lParam) => {
            StringBuilder title = new StringBuilder(256);
            GetWindowTextW(hWnd, title, 256);
            string titleStr = title.ToString();
            if (titleStr.Contains("新建")) {
                Console.WriteLine(string.Format("=== FOUND DIALOG: HWND {0:X8}, Title: '{1}' ===", hWnd.ToInt64(), titleStr));
                
                EnumChildWindows(hWnd, (childHwnd, childParam) => {
                    StringBuilder cls = new StringBuilder(256);
                    GetClassNameW(childHwnd, cls, 256);
                    StringBuilder text = new StringBuilder(256);
                    GetWindowTextW(childHwnd, text, 256);

                    IntPtr hFont = SendMessageW(childHwnd, WM_GETFONT, IntPtr.Zero, IntPtr.Zero);
                    string fontDesc = "None";
                    if (hFont != IntPtr.Zero) {
                        LOGFONTW lf = new LOGFONTW();
                        if (GetObjectW(hFont, Marshal.SizeOf(typeof(LOGFONTW)), ref lf) > 0) {
                            fontDesc = string.Format("Face='{0}', H={1}, CS={2}", lf.lfFaceName, lf.lfHeight, lf.lfCharSet);
                        }
                    }

                    RECT rc;
                    GetWindowRect(childHwnd, out rc);

                    Console.WriteLine(string.Format("  Child: {0:X8}, Rect: ({1},{2})-({3},{4}), Cls: '{5}', Font: [{6}], Text: '{7}'",
                        childHwnd.ToInt64(), rc.Left, rc.Top, rc.Right, rc.Bottom, cls, fontDesc, text));

                    return true;
                }, IntPtr.Zero);
            }
            return true;
        }, IntPtr.Zero);
    }
}
