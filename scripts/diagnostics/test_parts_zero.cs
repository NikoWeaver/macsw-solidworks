using System;
using System.Runtime.InteropServices;

class TestWindowPartsZero {
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr OpenThemeData(IntPtr hWnd, string pszClassList);

    [DllImport("uxtheme.dll")]
    static extern bool IsThemePartDefined(IntPtr hTheme, int iPartId, int iStateId);

    [DllImport("uxtheme.dll")]
    static extern int CloseThemeData(IntPtr hTheme);

    static void Main() {
        IntPtr hTheme = OpenThemeData(IntPtr.Zero, "Window");
        Console.WriteLine("hTheme Window: " + hTheme);
        if (hTheme == IntPtr.Zero) return;

        string[] partNames = new string[] {
            "0", "CAPTION", "SMALLCAPTION", "MINCAPTION", "SMALLMINCAPTION",
            "MAXCAPTION", "SMALLMAXCAPTION", "FRAMELEFT", "FRAMERIGHT", "FRAMEBOTTOM",
            "SMALLFRAMELEFT", "SMALLFRAMERIGHT", "SMALLFRAMEBOTTOM", "SYSBUTTON", "MDISYSBUTTON",
            "MINBUTTON", "MDIMINBUTTON", "MAXBUTTON", "CLOSEBUTTON", "SMALLCLOSEBUTTON",
            "MDICLOSEBUTTON", "RESTOREBUTTON", "MDIRESTOREBUTTON", "HELPBUTTON", "MDIHELPBUTTON"
        };

        for (int i = 1; i < partNames.Length; i++) {
            bool def0 = IsThemePartDefined(hTheme, i, 0);
            if (def0) {
                Console.WriteLine($"Part {i} ({partNames[i]}): DEFINED with state=0!");
            }
        }

        CloseThemeData(hTheme);
    }
}
