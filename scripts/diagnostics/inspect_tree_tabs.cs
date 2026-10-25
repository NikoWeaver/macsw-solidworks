using System;
using System.Runtime.InteropServices;
using System.Text;

class InspectTreeTabs {
    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

    const uint TCM_GETITEMCOUNT = 0x1304;
    const uint TCM_GETCURSEL = 0x130B;

    static void Main() {
        IntPtr treeHwnd = (IntPtr)0x16092E;
        Console.WriteLine("Inspecting Tree Container Wnd 0x16092E:");

        EnumChildWindows(treeHwnd, delegate(IntPtr child, IntPtr l) {
            StringBuilder cls = new StringBuilder(256);
            GetClassName(child, cls, 256);
            StringBuilder title = new StringBuilder(256);
            GetWindowText(child, title, 256);
            RECT r;
            GetWindowRect(child, out r);
            bool vis = IsWindowVisible(child);
            int style = GetWindowLong(child, -16);
            int exstyle = GetWindowLong(child, -20);

            if (cls.ToString() == "SysTabControl32") {
                int count = SendMessage(child, TCM_GETITEMCOUNT, IntPtr.Zero, IntPtr.Zero).ToInt32();
                int cur = SendMessage(child, TCM_GETCURSEL, IntPtr.Zero, IntPtr.Zero).ToInt32();
                Console.WriteLine(string.Format("TabControl [0x{0:X}]: Count={1}, CurSel={2}, Vis={3}, Rect=({4},{5},{6},{7})",
                    child.ToInt64(), count, cur, vis, r.Left, r.Top, r.Right, r.Bottom));
            } else if (title.ToString().Length > 0 || r.Right - r.Left > 50) {
                Console.WriteLine(string.Format("  Child [0x{0:X}]: Cls='{1}' Title='{2}' Vis={3} Rect=({4},{5},{6},{7}) W={8} H={9} Style=0x{10:X8}",
                    child.ToInt64(), cls, title, vis, r.Left, r.Top, r.Right, r.Bottom, r.Right - r.Left, r.Bottom - r.Top, style));
            }
            return true;
        }, IntPtr.Zero);
    }
}
