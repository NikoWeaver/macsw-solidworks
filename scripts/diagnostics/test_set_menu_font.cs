using System;
using System.Text;
using System.Runtime.InteropServices;

class TestSetMenuFont {
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
        IntPtr hFont = CreateFontW(
            -12, 0, 0, 0, 400,
            0, 0, 0, 134 /* GB2312 */,
            0, 0, 5 /* CLEARTYPE_QUALITY */,
            0, "Microsoft YaHei UI");

        Console.WriteLine("Created YaHei UI Font handle: " + hFont.ToString("X"));

        IntPtr mainWnd = new IntPtr(0x001314F6); // SLDWORKS main frame
        int count = 0;
        EnumChildWindows(mainWnd, (hWnd, lp) => {
            StringBuilder cls = new StringBuilder(256);
            GetClassNameW(hWnd, cls, 256);
            string c = cls.ToString();

            if (c == "ToolbarWindow32" || c == "Button" || c.Contains("ControlBar") || c.Contains("ToolBar")) {
                IntPtr curFont = SendMessageW(hWnd, WM_GETFONT, IntPtr.Zero, IntPtr.Zero);
                if (curFont == IntPtr.Zero) {
                    SendMessageW(hWnd, WM_SETFONT, hFont, new IntPtr(1));
                    InvalidateRect(hWnd, IntPtr.Zero, true);
                    UpdateWindow(hWnd);
                    count++;
                }
            }
            return true;
        }, IntPtr.Zero);

        Console.WriteLine(string.Format("Updated font for {0} controls!", count));
    }
}
