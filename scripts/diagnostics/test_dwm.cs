using System;
using System.Runtime.InteropServices;

class TestDwm {
    [DllImport("dwmapi.dll")]
    static extern int DwmIsCompositionEnabled(out bool pfEnabled);

    static void Main() {
        bool enabled;
        int hr = DwmIsCompositionEnabled(out enabled);
        Console.WriteLine($"DwmIsCompositionEnabled: hr=0x{hr:X8}, enabled={enabled}");
    }
}
