using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

class SwitchTab {
    [DllImport("user32.dll")]
    static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
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
    static extern IntPtr PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int Left, Top, Right, Bottom; }

    const uint TCM_GETITEMCOUNT = 0x1304;
    const uint TCM_GETCURSEL = 0x130B;
    const uint TCM_SETCURSEL = 0x130C;
    const uint WM_LBUTTONDOWN = 0x0201;
    const uint WM_LBUTTONUP = 0x0202;

    static void Main(string[] args) {
        int targetTab = (args.Length > 0 ? int.Parse(args[0]) : 1); // 1 = PropertyManager, 0 = Tree

        EnumWindows(delegate(IntPtr top, IntPtr l0) {
            StringBuilder title = new StringBuilder(256);
            GetWindowText(top, title, 256);
            if (title.ToString().Contains("SOLIDWORKS")) {
                EnumChildWindows(top, delegate(IntPtr child, IntPtr l1) {
                    StringBuilder cls = new StringBuilder(256);
                    GetClassName(child, cls, 256);
                    if (cls.ToString() == "SysTabControl32") {
                        int count = SendMessage(child, TCM_GETITEMCOUNT, IntPtr.Zero, IntPtr.Zero).ToInt32();
                        int cur = SendMessage(child, TCM_GETCURSEL, IntPtr.Zero, IntPtr.Zero).ToInt32();
                        Console.WriteLine(string.Format("Found TabControl 0x{0:X8}: ItemCount={1}, CurSel={2}", child.ToInt64(), count, cur));

                        // Simulate click on tab
                        // Tabs are roughly 30px wide, starting around X=10, Y=10
                        // Tab 0: (15, 10), Tab 1: (45, 10), Tab 2: (75, 10)
                        int clickX = 15 + targetTab * 30;
                        int clickY = 10;
                        IntPtr lParamPos = (IntPtr)((clickY << 16) | (clickX & 0xFFFF));

                        SendMessage(child, WM_LBUTTONDOWN, (IntPtr)1, lParamPos);
                        SendMessage(child, WM_LBUTTONUP, IntPtr.Zero, lParamPos);

                        Console.WriteLine(string.Format("Clicked Tab {0} at ({1}, {2})", targetTab, clickX, clickY));
                    }
                    return true;
                }, IntPtr.Zero);
            }
            return true;
        }, IntPtr.Zero);
    }
}
