using System;
using System.Runtime.InteropServices;
using System.Text;

class TestHitAt130 {
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT Point);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr hWnd);

    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

    static void Main() {
        int[] xs = new int[] { 2720, 2750, 2850, 2880, 2900, 2930 };
        foreach (int x in xs) {
            // Note: WindowFromPoint takes screen coordinates!
            // In sw_main_window_verified: X offset is 53, Y offset is 25.
            // So screen X = 53 + x, screen Y = 25 + 130 = 155!
            POINT pt = new POINT { X = 53 + x, Y = 25 + 130 };
            IntPtr h = WindowFromPoint(pt);
            StringBuilder cls = new StringBuilder(256);
            GetClassName(h, cls, 256);
            StringBuilder txt = new StringBuilder(256);
            GetWindowText(h, txt, 256);
            RECT r;
            GetWindowRect(h, out r);
            Console.WriteLine($"Point ({53+x}, 155) -> HWND [0x{h.ToInt64():X}] Cls='{cls}' Title='{txt}' Rect=({r.Left},{r.Top},{r.Right},{r.Bottom}) Parent=0x{GetParent(h).ToInt64():X}");
        }
    }
}
