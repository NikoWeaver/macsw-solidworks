
using System;
using System.Runtime.InteropServices;

class TestHitTestButtons {
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

    static void Main() {
        IntPtr hDoc = new IntPtr(0x100DD0);
        RECT r;
        GetWindowRect(hDoc, out r);
        int w = r.Right - r.Left;
        int h = r.Bottom - r.Top;
        Console.WriteLine($"Doc: ({r.Left},{r.Top},{r.Right},{r.Bottom}) {w}x{h}");

        // Scan across the top row (e.g. Y = r.Top + 10) from X = r.Right - 150 to r.Right
        int y = r.Top + 10;
        int lastHit = -1;
        int startX = -1;

        for (int x = r.Right - 150; x <= r.Right; x++) {
            IntPtr lparam = (IntPtr)((y << 16) | (x & 0xFFFF));
            int hit = (int)SendMessage(hDoc, 0x0084 /* WM_NCHITTEST */, IntPtr.Zero, lparam);
            if (hit != lastHit) {
                if (lastHit != -1) {
                    Console.WriteLine($"Hit {lastHit} from X={startX} to X={x-1} (Rel X: {startX - r.Left} to {x - 1 - r.Left}, W={x - startX})");
                }
                lastHit = hit;
                startX = x;
            }
        }
        Console.WriteLine($"Hit {lastHit} from X={startX} to X={r.Right} (Rel X: {startX - r.Left} to {r.Right - r.Left}, W={r.Right - startX + 1})");
    }
}
