
using System;
using System.Runtime.InteropServices;

class TestHitTestY {
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

    static void Main() {
        IntPtr hDoc = new IntPtr(0x100DD0);
        RECT r;
        GetWindowRect(hDoc, out r);
        int x = 2650; // Close button X
        int lastHit = -1;
        int startY = -1;
        for (int y = r.Top; y <= r.Top + 40; y++) {
            IntPtr lparam = (IntPtr)((y << 16) | (x & 0xFFFF));
            int hit = (int)SendMessage(hDoc, 0x0084, IntPtr.Zero, lparam);
            if (hit != lastHit) {
                if (lastHit != -1) {
                    Console.WriteLine($"Hit {lastHit} from Y={startY} to Y={y-1} (Rel Y: {startY - r.Top} to {y - 1 - r.Top}, H={y - startY})");
                }
                lastHit = hit;
                startY = y;
            }
        }
        Console.WriteLine($"Hit {lastHit} from Y={startY} to Y={r.Top+40} (Rel Y: {startY - r.Top} to {40}, H={r.Top + 41 - startY})");
    }
}
