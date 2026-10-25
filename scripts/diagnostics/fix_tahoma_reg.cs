using System;
using Microsoft.Win32;

class FixTahomaRegistration {
    static void Main() {
        string fontsPath = @"Software\Microsoft\Windows NT\CurrentVersion\Fonts";
        using (RegistryKey key = Registry.LocalMachine.OpenSubKey(fontsPath, true)) {
            if (key != null) {
                // Delete macOS supplemental Tahoma entry or override it
                key.SetValue("Tahoma (TrueType)", "msyh.ttc");
                key.SetValue("Tahoma Bold (TrueType)", "msyhbd.ttc");
                Console.WriteLine("Successfully updated Tahoma in Fonts registry to msyh.ttc!");
            }
        }
    }
}
