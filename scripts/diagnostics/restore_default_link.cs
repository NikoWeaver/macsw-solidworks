using System;
using Microsoft.Win32;

class RestoreDefaultLink {
    static void Main() {
        string sysLinkPath = @"Software\Microsoft\Windows NT\CurrentVersion\FontLink\SystemLink";
        using (RegistryKey key = Registry.LocalMachine.CreateSubKey(sysLinkPath)) {
            if (key != null) {
                string[] defaultTargets = new string[] {
                    "SIMSUN.TTC,SimSun",
                    "MINGLIU.TTC,PMingLiu",
                    "MSGOTHIC.TTC,MS UI Gothic",
                    "BATANG.TTC,Batang",
                    "MSYH.TTC,Microsoft YaHei UI",
                    "MSJH.TTC,Microsoft JhengHei UI",
                    "YUGOTHM.TTC,Yu Gothic UI",
                    "MALGUN.TTF,Malgun Gothic",
                    "SEGUISYM.TTF,Segoe UI Symbol"
                };

                string[] fonts = new string[] {
                    "Tahoma",
                    "Segoe UI",
                    "Segoe UI Semibold",
                    "Segoe UI Bold",
                    "Microsoft Sans Serif",
                    "Lucida Sans Unicode"
                };

                foreach (string f in fonts) {
                    key.SetValue(f, defaultTargets, RegistryValueKind.MultiString);
                    Console.WriteLine("Reset " + f + " to default targets.");
                }
            }
        }
    }
}
