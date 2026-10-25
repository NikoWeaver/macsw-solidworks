using System;
using System.Runtime.InteropServices;

class TestAeroLoad {
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    static extern int SetSystemVisualStyle(string pszFilename, string pszColor, string pszSize, int dwReserved);

    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr OpenThemeData(IntPtr hWnd, string pszClassList);

    [DllImport("uxtheme.dll")]
    static extern bool IsThemePartDefined(IntPtr hTheme, int iPartId, int iStateId);

    static void Main() {
        int hr = SetSystemVisualStyle(@"C:\windows\resources\themes\Seven\aero11_seven_clear.msstyles", "NormalColor", "Normal", 0);
        Console.WriteLine($"SetSystemVisualStyle: hr=0x{hr:X8}");
        
        IntPtr hTheme = OpenThemeData(IntPtr.Zero, "Window");
        Console.WriteLine("hTheme Window: " + hTheme);
        if (hTheme != IntPtr.Zero) {
            for (int i = 1; i <= 24; i++) {
                bool def = IsThemePartDefined(hTheme, i, 1);
                if (def) Console.WriteLine($"Part {i} is DEFINED!");
            }
        }
    }
}
