using System;
using System.Runtime.InteropServices;
using System.Text;

class FindWindowAtPoint {
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT Point);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr hWnd);

    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

    static void Main() {
        // Test points across that top-right bar
        for (int x = 2700; x <= 2950; x += 50) {
            POINT pt = new POINT { X = x, Y = 90 };
            IntPtr h = WindowFromPoint(pt);
            StringBuilder cls = new StringBuilder(256);
            GetClassName(h, cls, 256);
            StringBuilder txt = new StringBuilder(256);
            GetWindowText(h, txt, 256);
            RECT r;
            GetWindowRect(h, out r);
            Console.WriteLine($"Point ({x}, 90) -> HWND [0x{h.ToInt64():X}] Cls='{cls}' Title='{txt}' Rect=({r.Left},{r.Top},{r.Right},{r.Bottom}) Parent=0x{GetParent(h).ToInt64():X}");
        }
    }
}
