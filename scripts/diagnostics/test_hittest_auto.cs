using System;
using System.Runtime.InteropServices;
using System.Text;

class TestHitTestAuto {
    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

    static void Main() {
        IntPtr hDoc = IntPtr.Zero;
        EnumWindows((top, l) => {
            StringBuilder t = new StringBuilder(256);
            GetWindowText(top, t, 256);
            if (t.ToString().Contains("SOLIDWORKS")) {
                EnumChildWindows(top, (c, lc) => {
                    if (!IsWindowVisible(c)) return true;
                    int style = GetWindowLong(c, -16);
                    if ((style & 0x00C00000) == 0x00C00000) { // WS_CAPTION
                        hDoc = c;
                        return false;
                    }
                    return true;
                }, IntPtr.Zero);
            }
            return true;
        }, IntPtr.Zero);

        Console.WriteLine($"Found Doc: 0x{hDoc.ToInt64():X}");
        if (hDoc == IntPtr.Zero) return;

        RECT r;
        GetWindowRect(hDoc, out r);
        int w = r.Right - r.Left;
        int h = r.Bottom - r.Top;
        Console.WriteLine($"Rect: ({r.Left},{r.Top},{r.Right},{r.Bottom}) {w}x{h}");

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
