
using System;
using System.Runtime.InteropServices;
using System.Text;

class FindTabs {
    [DllImport("user32.dll")]
    static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);
    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int Left, Top, Right, Bottom; }

    const uint TCM_GETITEMCOUNT = 0x1304;
    const uint TCM_GETCURSEL = 0x130B;

    static void Main() {
        IntPtr treeHwnd = new IntPtr(0x00040BB6);
        EnumChildWindows(treeHwnd, delegate(IntPtr child, IntPtr l) {
            StringBuilder cls = new StringBuilder(256);
            GetClassName(child, cls, 256);
            if (cls.ToString() == "SysTabControl32") {
                int count = SendMessage(child, TCM_GETITEMCOUNT, IntPtr.Zero, IntPtr.Zero).ToInt32();
                int cur = SendMessage(child, TCM_GETCURSEL, IntPtr.Zero, IntPtr.Zero).ToInt32();
                Console.WriteLine(string.Format("TabControl 0x{0:X8}: ItemCount={1}, CurSel={2}", child.ToInt64(), count, cur));
            }
            return true;
        }, IntPtr.Zero);
    }
}
