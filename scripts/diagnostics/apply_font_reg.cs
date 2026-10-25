using System;
using Microsoft.Win32;
using System.Runtime.InteropServices;

class ApplyFontRegistry {
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
        uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);

    static readonly IntPtr HWND_BROADCAST = (IntPtr)0xffff;
    const uint WM_SETTINGCHANGE = 0x001A;
    const uint WM_FONTCHANGE = 0x001D;
    const uint SMTO_ABORTIFHUNG = 0x0002;

    static void Main() {
        string fontsPath = @"Software\Microsoft\Windows NT\CurrentVersion\Fonts";
        using (RegistryKey key = Registry.LocalMachine.OpenSubKey(fontsPath, true)) {
            if (key != null) {
                try { key.DeleteValue("Tahoma (TrueType)"); } catch {}
                try { key.DeleteValue("Tahoma Bold (TrueType)"); } catch {}
                key.SetValue("Tahoma (TrueType)", "tahoma.ttf");
                key.SetValue("Tahoma Bold (TrueType)", "tahomabd.ttf");
                Console.WriteLine("Reg updated Tahoma (TrueType) -> tahoma.ttf in HKLM");
            }
        }

        string userFontsPath = @"Software\Microsoft\Windows NT\CurrentVersion\Fonts";
        using (RegistryKey ukey = Registry.CurrentUser.OpenSubKey(userFontsPath, true)) {
            if (ukey != null) {
                try { ukey.DeleteValue("Tahoma (TrueType)"); } catch {}
                try { ukey.DeleteValue("Tahoma Bold (TrueType)"); } catch {}
                ukey.SetValue("Tahoma (TrueType)", "tahoma.ttf");
                ukey.SetValue("Tahoma Bold (TrueType)", "tahomabd.ttf");
                Console.WriteLine("Reg updated Tahoma (TrueType) -> tahoma.ttf in HKCU");
            }
        }

        UIntPtr res;
        SendMessageTimeout(HWND_BROADCAST, WM_FONTCHANGE, UIntPtr.Zero, null, SMTO_ABORTIFHUNG, 1000, out res);
        SendMessageTimeout(HWND_BROADCAST, WM_SETTINGCHANGE, UIntPtr.Zero, "WindowMetrics", SMTO_ABORTIFHUNG, 1000, out res);
        Console.WriteLine("Broadcasted WM_FONTCHANGE & WM_SETTINGCHANGE");
    }
}
