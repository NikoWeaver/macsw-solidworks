using System;
using System.Text;
using System.Runtime.InteropServices;

class FixTaskDialogCommandLink {
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

    [DllImport("uxtheme.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
    static extern int SetWindowTheme(IntPtr hWnd, string pszSubAppName, string pszSubIdList);

    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateFontW(
        int nHeight, int nWidth, int nEscapement, int nOrientation, int fnWeight,
        uint fdwItalic, uint fdwUnderline, uint fdwStrikeOut, uint fdwCharSet,
        uint fdwOutputPrecision, uint fdwClipPrecision, uint fdwQuality,
        uint fdwPitchAndFamily, string lpszFace);

    const uint WM_SETFONT = 0x0030;

    static void Main() {
        IntPtr hFont = CreateFontW(-14, 0, 0, 0, 400, 0, 0, 0, 134, 0, 0, 5, 0, "Microsoft YaHei UI");

        EnumWindows((hWnd, lp0) => {
            StringBuilder title = new StringBuilder(256);
            GetWindowTextW(hWnd, title, 256);
            StringBuilder cls = new StringBuilder(256);
            GetClassNameW(hWnd, cls, 256);

            if (cls.ToString() == "#32770" || title.ToString().Contains("SOLIDWORKS")) {
                EnumChildWindows(hWnd, (child, lp1) => {
                    StringBuilder cCls = new StringBuilder(256);
                    GetClassNameW(child, cCls, 256);
                    if (cCls.ToString() == "Button") {
                        SendMessageW(child, WM_SETFONT, hFont, new IntPtr(1));
                        SetWindowTheme(child, " ", " ");
                        InvalidateRect(child, IntPtr.Zero, true);
                        UpdateWindow(child);
                        Console.WriteLine("Updated button: " + child.ToString("X"));
                    }
                    return true;
                }, IntPtr.Zero);
            }
            return true;
        }, IntPtr.Zero);
        Console.WriteLine("Done.");
    }
}
