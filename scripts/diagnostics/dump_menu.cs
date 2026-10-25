using System;
using System.Runtime.InteropServices;
using System.Text;

class DumpMenu {
    [DllImport("user32.dll")] static extern IntPtr GetMenu(IntPtr hWnd);
    [DllImport("user32.dll")] static extern int GetMenuItemCount(IntPtr hMenu);
    [DllImport("user32.dll")] static extern IntPtr GetSubMenu(IntPtr hMenu, int nPos);
    [DllImport("user32.dll")] static extern uint GetMenuItemID(IntPtr hMenu, int nPos);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetMenuString(IntPtr hMenu, uint uID, StringBuilder lpString, int nMaxCount, uint uFlag);

    const uint MF_BYPOSITION = 0x0400;

    static void Dump(IntPtr hMenu, int depth) {
        if (hMenu == IntPtr.Zero) return;
        int count = GetMenuItemCount(hMenu);
        string pad = new string(' ', depth * 2);
        for (int i = 0; i < count; i++) {
            uint id = GetMenuItemID(hMenu, i);
            StringBuilder sb = new StringBuilder(256);
            GetMenuString(hMenu, (uint)i, sb, 256, MF_BYPOSITION);
            Console.WriteLine(string.Format("{0}[{1}] ID={2} Text='{3}'", pad, i, id, sb));
            IntPtr sub = GetSubMenu(hMenu, i);
            if (sub != IntPtr.Zero) {
                Dump(sub, depth + 1);
            }
        }
    }

    static void Main() {
        IntPtr top = (IntPtr)0x401DC;
        IntPtr hMenu = GetMenu(top);
        Console.WriteLine("Menu handle: 0x{0:X}", hMenu.ToInt64());
        Dump(hMenu, 1);
    }
}
