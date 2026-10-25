using System;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;

class FixComposited {
    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll")]
    static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

    [DllImport("user32.dll")]
    static extern bool RedrawWindow(IntPtr hWnd, IntPtr lprcUpdate, IntPtr hrgnUpdate, uint flags);

    const int GWL_EXSTYLE = -20;
    const int WS_EX_COMPOSITED = 0x02000000;
    const uint RDW_INVALIDATE = 0x0001;
    const uint RDW_ERASE = 0x0004;
    const uint RDW_ALLCHILDREN = 0x0080;
    const uint RDW_FRAME = 0x0400;
    const uint RDW_UPDATENOW = 0x0100;

    static int scanCount = 0;

    static void FixWindow(IntPtr hwnd) {
        int exstyle = GetWindowLong(hwnd, GWL_EXSTYLE);
        if ((exstyle & WS_EX_COMPOSITED) != 0) {
            StringBuilder cls = new StringBuilder(256);
            GetClassName(hwnd, cls, 256);
            StringBuilder title = new StringBuilder(256);
            GetWindowText(hwnd, title, 256);

            Console.WriteLine(string.Format("[FIX] Stripping WS_EX_COMPOSITED from 0x{0:X8} ({1}) '{2}'",
                hwnd.ToInt64(), cls.ToString(), title.ToString()));

            int newExStyle = exstyle & ~WS_EX_COMPOSITED;
            SetWindowLong(hwnd, GWL_EXSTYLE, newExStyle);
            RedrawWindow(hwnd, IntPtr.Zero, IntPtr.Zero, RDW_INVALIDATE | RDW_ERASE | RDW_FRAME | RDW_ALLCHILDREN | RDW_UPDATENOW);
            scanCount++;
        }
    }

    static bool EnumChild(IntPtr hwnd, IntPtr lParam) {
        FixWindow(hwnd);
        return true;
    }

    static bool EnumTop(IntPtr hwnd, IntPtr lParam) {
        FixWindow(hwnd);
        EnumChildWindows(hwnd, EnumChild, IntPtr.Zero);
        return true;
    }

    static void Main(string[] args) {
        bool watch = (args.Length > 0 && (args[0] == "--watch" || args[0] == "-w"));
        Console.WriteLine(watch ? "[FixComposited] Watch mode enabled (polling every 1000ms)..." : "[FixComposited] Single scan mode...");
        
        do {
            EnumWindows(EnumTop, IntPtr.Zero);
            if (watch) {
                Thread.Sleep(1000);
            }
        } while (watch);
        
        Console.WriteLine(string.Format("[FixComposited] Done. Fixed {0} windows.", scanCount));
    }
}
