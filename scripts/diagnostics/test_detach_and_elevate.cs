using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Threading;

class TestDetachAndElevate {
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateWindowExW(
        uint dwExStyle, string lpClassName, string lpWindowName, uint dwStyle,
        int X, int Y, int nWidth, int nHeight, IntPtr hWndParent, IntPtr hMenu,
        IntPtr hInstance, IntPtr lpParam);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern ushort RegisterClassExW([In] ref WNDCLASSEX lpwcx);

    [DllImport("user32.dll")]
    static extern IntPtr DefWindowProcW(IntPtr hWnd, uint uMsg, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr GetModuleHandleW(string lpModuleName);

    [DllImport("user32.dll")]
    static extern IntPtr GetDesktopWindow();

    [DllImport("user32.dll")]
    static extern int SetWindowLongW(IntPtr hWnd, int nIndex, int dwNewLong);

    [DllImport("user32.dll")]
    static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    static extern bool DestroyWindow(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WNDCLASSEX {
        public uint cbSize;
        public uint style;
        public IntPtr lpfnWndProc;
        public int cbClsExtra;
        public int cbWndExtra;
        public IntPtr hInstance;
        public IntPtr hIcon;
        public IntPtr hCursor;
        public IntPtr hbrBackground;
        public string lpszMenuName;
        public string lpszClassName;
        public IntPtr hIconSm;
    }

    delegate IntPtr WndProcDelegate(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    static WndProcDelegate staticWndProc = DefWindowProcW;

    const int GWL_STYLE = -16;
    const int GWL_EXSTYLE = -20;
    const int GWLP_HWNDPARENT = -8;

    const uint WS_POPUP = 0x80000000;
    const uint WS_VISIBLE = 0x10000000;
    const uint WS_CAPTION = 0x00C00000;
    const uint WS_THICKFRAME = 0x00040000;
    const uint WS_CLIPSIBLINGS = 0x04000000;

    const int WS_EX_TOOLWINDOW = 0x00000080;
    const int WS_EX_TOPMOST = 0x00000008;

    static readonly IntPtr HWND_TOPMOST = (IntPtr)(-1);
    const uint SWP_FRAMECHANGED = 0x0020;
    const uint SWP_SHOWWINDOW = 0x0040;

    static void Main() {
        IntPtr swHwnd = IntPtr.Zero;
        EnumWindows((h, l) => {
            StringBuilder sb = new StringBuilder(256);
            GetWindowTextW(h, sb, 256);
            if (sb.ToString().Contains("SOLIDWORKS")) {
                swHwnd = h;
                return false;
            }
            return true;
        }, IntPtr.Zero);

        Console.WriteLine("Target SW HWND: 0x" + swHwnd.ToString("X"));

        IntPtr hInst = GetModuleHandleW(null);
        string clsName = "WineSwFloatingClass_" + Environment.TickCount;

        WNDCLASSEX wc = new WNDCLASSEX();
        wc.cbSize = (uint)Marshal.SizeOf(typeof(WNDCLASSEX));
        wc.style = 3; // CS_HREDRAW | CS_VREDRAW
        wc.lpfnWndProc = Marshal.GetFunctionPointerForDelegate(staticWndProc);
        wc.hInstance = hInst;
        wc.hbrBackground = (IntPtr)6; // COLOR_WINDOW
        wc.lpszClassName = clsName;

        ushort atom = RegisterClassExW(ref wc);
        Console.WriteLine("RegisterClassExW atom: " + atom + ", Error: " + Marshal.GetLastWin32Error());

        IntPtr hDesk = GetDesktopWindow();

        IntPtr hFloating = CreateWindowExW(
            (uint)(WS_EX_TOOLWINDOW | WS_EX_TOPMOST),
            clsName,
            "WineSW 路径1 独立原生悬浮窗口",
            WS_POPUP | WS_VISIBLE | WS_CAPTION | WS_THICKFRAME | WS_CLIPSIBLINGS,
            700, 350, 450, 250,
            hDesk, IntPtr.Zero, hInst, IntPtr.Zero);

        Console.WriteLine("Created Top-Level Window: 0x" + hFloating.ToString("X") + ", Error: " + Marshal.GetLastWin32Error());
        if (hFloating == IntPtr.Zero) return;

        SetWindowPos(hFloating, HWND_TOPMOST, 700, 350, 450, 250, SWP_FRAMECHANGED | SWP_SHOWWINDOW);

        Console.WriteLine("Window is up and floating! Sleeping 12s for Swift check...");
        Thread.Sleep(12000);

        DestroyWindow(hFloating);
        Console.WriteLine("Destroyed window.");
    }
}
