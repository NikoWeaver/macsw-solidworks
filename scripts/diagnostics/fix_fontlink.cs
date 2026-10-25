using System;
using Microsoft.Win32;

class FixFontLink {
    static void Main() {
        string sysLinkPath = @"Software\Microsoft\Windows NT\CurrentVersion\FontLink\SystemLink";
        using (RegistryKey key = Registry.LocalMachine.CreateSubKey(sysLinkPath)) {
            if (key != null) {
                string[] linkTargets = new string[] {
                    "msyh.ttc,Microsoft YaHei UI",
                    "simsun.ttc,SimSun"
                };

                string[] fontsToLink = new string[] {
                    "Tahoma",
                    "Segoe UI",
                    "Segoe UI Semibold",
                    "Segoe UI Bold",
                    "Microsoft Sans Serif",
                    "Arial",
                    "Arial Black",
                    "Lucida Sans Unicode",
                    "MS Sans Serif",
                    "Calibri"
                };

                foreach (string f in fontsToLink) {
                    key.SetValue(f, linkTargets, RegistryValueKind.MultiString);
                    Console.WriteLine("Configured FontLink for: " + f);
                }
            }
        }

        string fontSubPath = @"Software\Microsoft\Windows NT\CurrentVersion\FontSubstitutes";
        using (RegistryKey subKey = Registry.LocalMachine.CreateSubKey(fontSubPath)) {
            if (subKey != null) {
                subKey.SetValue("MS Shell Dlg", "Microsoft YaHei UI");
                subKey.SetValue("MS Shell Dlg 2", "Microsoft YaHei UI");
                subKey.SetValue("SimSun", "Microsoft YaHei UI");
                subKey.SetValue("NSimSun", "Microsoft YaHei UI");
                subKey.SetValue("宋体", "Microsoft YaHei UI");
                subKey.SetValue("新宋体", "Microsoft YaHei UI");
                subKey.SetValue("Tahoma", "Microsoft YaHei UI");
                subKey.SetValue("Segoe UI", "Microsoft YaHei UI");
                Console.WriteLine("Configured FontSubstitutes to Microsoft YaHei UI");
            }
        }

        string wineRepPath = @"Software\Wine\Fonts\Replacements";
        using (RegistryKey repKey = Registry.CurrentUser.CreateSubKey(wineRepPath)) {
            if (repKey != null) {
                string target = "Microsoft YaHei UI";
                repKey.SetValue("Tahoma", target);
                repKey.SetValue("Segoe UI", target);
                repKey.SetValue("Segoe UI Semibold", target);
                repKey.SetValue("Segoe UI Bold", target);
                repKey.SetValue("Arial", target);
                repKey.SetValue("SimSun", target);
                repKey.SetValue("NSimSun", target);
                repKey.SetValue("@SimSun", "@" + target);
                repKey.SetValue("@NSimSun", "@" + target);
                repKey.SetValue("STSong", target);
                repKey.SetValue("@STSong", "@" + target);
                Console.WriteLine("Configured Wine Fonts Replacements to Microsoft YaHei UI");
            }
        }

        Console.WriteLine("FontLink and FontSubstitutes fix applied successfully!");
    }
}
