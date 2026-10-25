using System;
using System.Text;
using System.Runtime.InteropServices;

class HotFixTaskDialogFonts {
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

    [DllImport("user32.dll")]
    public static extern bool InvalidateRect(IntPtr hWnd, IntPtr lpRect, bool bErase);

    [DllImport("user32.dll")]
    public static extern bool UpdateWindow(IntPtr hWnd);

    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateFontW(
        int nHeight, int nWidth, int nEscapement, int nOrientation, int fnWeight,
        uint fdwItalic, uint fdwUnderline, uint fdwStrikeOut, uint fdwCharSet,
        uint fdwOutputPrecision, uint fdwClipPrecision, uint fdwQuality,
        uint fdwPitchAndFamily, string lpszFace);

    const uint WM_SETFONT = 0x0030;
    const uint WM_GETFONT = 0x0031;

    static void Main() {
        IntPtr hFontMain = CreateFontW(-14, 0, 0, 0, 600, 0, 0, 0, 134, 0, 0, 5, 0, "Microsoft YaHei UI");
        IntPtr hFontNormal = CreateFontW(-12, 0, 0, 0, 400, 0, 0, 0, 134, 0, 0, 5, 0, "Microsoft YaHei UI");

        int count = 0;
        EnumWindows((hWnd, lp0) => {
            EnumChildWindows(hWnd, (child, lp1) => {
                StringBuilder cls = new StringBuilder(256);
                GetClassNameW(child, cls, 256);
                string c = cls.ToString();

                IntPtr curFont = SendMessageW(child, WM_GETFONT, IntPtr.Zero, IntPtr.Zero);
                if (curFont == IntPtr.Zero && (c == "Button" || c == "Static" || c == "ToolbarWindow32" || c.Contains("Link"))) {
                    SendMessageW(child, WM_SETFONT, hFontNormal, new IntPtr(1));
                    InvalidateRect(child, IntPtr.Zero, true);
                    UpdateWindow(child);
                    count++;
                }
                return true;
            }, IntPtr.Zero);
            return true;
        }, IntPtr.Zero);

        Console.WriteLine(string.Format("Hot-fixed fonts for {0} controls in all open windows!", count));
    }
}
