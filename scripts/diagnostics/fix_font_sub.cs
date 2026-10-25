using System;
using Microsoft.Win32;

class FixFontSubstitutes {
    static void Main() {
        string subPath = @"Software\Microsoft\Windows NT\CurrentVersion\FontSubstitutes";
        using (RegistryKey key = Registry.LocalMachine.OpenSubKey(subPath, true)) {
            if (key != null) {
                key.SetValue("Tahoma", "Microsoft YaHei UI");
                key.SetValue("Tahoma,0", "Microsoft YaHei UI,134");
                key.SetValue("Tahoma,134", "Microsoft YaHei UI,134");
                key.SetValue("Segoe UI", "Microsoft YaHei UI");
                key.SetValue("Segoe UI,0", "Microsoft YaHei UI,134");
                key.SetValue("Segoe UI,134", "Microsoft YaHei UI,134");
                Console.WriteLine("FontSubstitutes updated for Tahoma and Segoe UI!");
            }
        }
    }
}
