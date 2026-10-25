using System;
using System.Runtime.InteropServices;
using System.Threading;

class TestElevatePopup {
    [DllImport("user32.dll")]
    static extern IntPtr CreateWindowExW(
        uint dwExStyle, string lpClassName, string lpWindowName, uint dwStyle,
        int X, int Y, int nWidth, int nHeight, IntPtr hWndParent, IntPtr hMenu,
        IntPtr hInstance, IntPtr lpParam);

    [DllImport("user32.dll")]
    static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    static extern bool UpdateWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    static extern bool DestroyWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    static extern IntPtr DefWindowProcW(IntPtr hWnd, uint uMsg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    static extern ushort RegisterClassW(ref WNDCLASS lpWndClass);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WNDCLASS {
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
    }

    delegate IntPtr WndProcDelegate(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    static WndProcDelegate wndProc;

    const uint WS_POPUP = 0x80000000;
    const uint WS_VISIBLE = 0x10000000;
    const uint WS_CAPTION = 0x00C00000;
    const uint WS_THICKFRAME = 0x00040000;
    const uint WS_EX_TOOLWINDOW = 0x00000080;
    const uint WS_EX_TOPMOST = 0x00000008;

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int GetWindowTextW(IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);

    static IntPtr swHwnd = IntPtr.Zero;

    static IntPtr CustomWndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam) {
        if (msg == 0x000F) { // WM_PAINT
            PAINTSTRUCT ps;
            IntPtr hdc = BeginPaint(hWnd, out ps);
            RECT r = new RECT(10, 10, 380, 180);
            IntPtr br = CreateSolidBrush(0x002B2B2B); // dark gray
            FillRect(hdc, ref r, br);
            DeleteObject(br);

            SetTextColor(hdc, 0x0000FFFF); // yellow text
            SetBkMode(hdc, 1); // transparent
            DrawTextW(hdc, "【原生独立 NSWindow 悬浮面板】\n成功浮于 3D 视口上方！\n不受 Metal 硬件图层遮挡！", -1, ref r, 0);

            EndPaint(hWnd, ref ps);
            return IntPtr.Zero;
        }
        return DefWindowProcW(hWnd, msg, wParam, lParam);
    }

    [DllImport("user32.dll")]
    static extern IntPtr BeginPaint(IntPtr hWnd, out PAINTSTRUCT lpPaint);

    [DllImport("user32.dll")]
    static extern bool EndPaint(IntPtr hWnd, ref PAINTSTRUCT lpPaint);

    [DllImport("gdi32.dll")]
    static extern IntPtr CreateSolidBrush(uint crColor);

    [DllImport("gdi32.dll")]
    static extern bool DeleteObject(IntPtr hObject);

    [DllImport("user32.dll")]
    static extern int FillRect(IntPtr hDC, ref RECT lprc, IntPtr hbr);

    [DllImport("gdi32.dll")]
    static extern uint SetTextColor(IntPtr hdc, uint crColor);

    [DllImport("gdi32.dll")]
    static extern int SetBkMode(IntPtr hdc, int iBkMode);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int DrawTextW(IntPtr hdc, string lpchText, int cchText, ref RECT lprc, uint format);

    [StructLayout(LayoutKind.Sequential)]
    struct PAINTSTRUCT {
        public IntPtr hdc;
        public bool fErase;
        public RECT rcPaint;
        public bool fRestore;
        public bool fIncUpdate;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)]
        public byte[] rgbReserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct RECT {
        public int Left, Top, Right, Bottom;
        public RECT(int l, int t, int r, int b) { Left = l; Top = t; Right = r; Bottom = b; }
    }


    static void Main() {
        EnumWindows((h, l) => {
            System.Text.StringBuilder sb = new System.Text.StringBuilder(256);
            GetWindowTextW(h, sb, 256);
            if (sb.ToString().Contains("SOLIDWORKS")) {
                swHwnd = h;
                return false;
            }
            return true;
        }, IntPtr.Zero);

        Console.WriteLine("SolidWorks Main Window: " + swHwnd.ToString("X"));

        wndProc = new WndProcDelegate(CustomWndProc);
        WNDCLASS wc = new WNDCLASS();
        wc.lpszClassName = "ElevatedPopupWindowClass";
        wc.lpfnWndProc = Marshal.GetFunctionPointerForDelegate(wndProc);
        wc.hbrBackground = (IntPtr)6; // COLOR_WINDOW
        RegisterClassW(ref wc);

        // Create a POPUP window right in the middle of SolidWorks 3D viewport (X=600, Y=300, W=400, H=200)
        // With Parent = swHwnd (Owned window) or NULL
        IntPtr hPop = CreateWindowExW(
            WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
            "ElevatedPopupWindowClass",
            "WineSW 浮动悬浮面板测试",
            WS_POPUP | WS_VISIBLE | WS_CAPTION | WS_THICKFRAME,
            600, 300, 400, 200,
            swHwnd, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

        Console.WriteLine("Created Popup Window: " + hPop.ToString("X"));
        ShowWindow(hPop, 5); // SW_SHOW
        UpdateWindow(hPop);

        // Keep alive for 15 seconds to let Swift and screencapture verify
        Console.WriteLine("Window visible, sleeping 15s...");
        Thread.Sleep(15000);

        DestroyWindow(hPop);
        Console.WriteLine("Done.");
    }
}
