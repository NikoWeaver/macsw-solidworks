using System;
using System.Runtime.InteropServices;
using System.Text;

class FindSketchCmd {
    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] static extern IntPtr GetMenu(IntPtr hWnd);
    [DllImport("user32.dll")] static extern int GetMenuItemCount(IntPtr hMenu);
    [DllImport("user32.dll")] static extern IntPtr GetSubMenu(IntPtr hMenu, int nPos);
    [DllImport("user32.dll")] static extern uint GetMenuItemID(IntPtr hMenu, int nPos);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetMenuString(IntPtr hMenu, uint uID, StringBuilder lpString, int nMaxCount, uint uFlag);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    const uint MF_BYPOSITION = 0x0400;
    const uint WM_COMMAND = 0x0111;

    static void SearchMenu(IntPtr topHwnd, IntPtr hMenu, string path) {
        if (hMenu == IntPtr.Zero) return;
        int count = GetMenuItemCount(hMenu);
        for (int i = 0; i < count; i++) {
            uint id = GetMenuItemID(hMenu, i);
            StringBuilder sb = new StringBuilder(256);
            GetMenuString(hMenu, (uint)i, sb, 256, MF_BYPOSITION);
            string itemPath = path + " -> " + sb.ToString();
            if (sb.ToString().Contains("草图") || sb.ToString().Contains("Sketch")) {
                Console.WriteLine(string.Format("Found Sketch Item: ID={0} Path='{1}'", id, itemPath));
            }
            IntPtr sub = GetSubMenu(hMenu, i);
            if (sub != IntPtr.Zero) {
                SearchMenu(topHwnd, sub, itemPath);
            }
        }
    }

    static void Main() {
        EnumWindows(delegate(IntPtr top, IntPtr l) {
            StringBuilder sb = new StringBuilder(256);
            GetWindowText(top, sb, 256);
            string title = sb.ToString();
            if (title.Contains("SOLIDWORKS") && title.Contains("零件1")) {
                Console.WriteLine("Searching menus for: " + title);
                IntPtr hMenu = GetMenu(top);
                SearchMenu(top, hMenu, "Root");
            }
            return true;
        }, IntPtr.Zero);
    }
}
