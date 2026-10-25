using System;
using System.Runtime.InteropServices;

class TestThemeData {
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr OpenThemeData(IntPtr hWnd, string pszClassList);

    [DllImport("uxtheme.dll")]
    static extern int CloseThemeData(IntPtr hTheme);

    [DllImport("uxtheme.dll")]
    static extern bool IsThemeActive();

    [DllImport("uxtheme.dll")]
    static extern bool IsAppThemed();

    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    static extern int GetCurrentThemeName(
        System.Text.StringBuilder pszThemeFileName, int dwMaxNameChars,
        System.Text.StringBuilder pszColorBuff, int cchMaxColorChars,
        System.Text.StringBuilder pszSizeBuff, int cchMaxSizeChars);

    static void Main() {
        Console.WriteLine("IsThemeActive: " + IsThemeActive());
        Console.WriteLine("IsAppThemed: " + IsAppThemed());

        var theme = new System.Text.StringBuilder(512);
        var color = new System.Text.StringBuilder(512);
        var size = new System.Text.StringBuilder(512);
        int hr = GetCurrentThemeName(theme, 512, color, 512, size, 512);
        Console.WriteLine($"Current Theme: hr={hr}, File='{theme}', Color='{color}', Size='{size}'");

        string[] classes = { "Window", "WINDOW", "Button", "BUTTON", "ScrollBar", "Header", "Tab", "Menu", "Aero", "Mdi" };
        foreach (var cls in classes) {
            IntPtr h = OpenThemeData(IntPtr.Zero, cls);
            Console.WriteLine($"OpenThemeData(0, '{cls}') -> {h}");
            if (h != IntPtr.Zero) CloseThemeData(h);
        }
    }
}
