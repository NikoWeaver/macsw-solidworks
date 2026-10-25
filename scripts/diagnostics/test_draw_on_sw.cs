
using System;
using System.Drawing;
using System.Runtime.InteropServices;

class TestDrawOnSW {
    [DllImport("user32.dll")] static extern IntPtr GetWindowDC(IntPtr hWnd);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

    static void Main() {
        IntPtr hDoc = new IntPtr(0x100DD0);
        RECT r;
        GetWindowRect(hDoc, out r);
        int w = r.Right - r.Left;
        int h = r.Bottom - r.Top;
        Console.WriteLine($"Doc Rect: ({r.Left},{r.Top},{r.Right},{r.Bottom}) {w}x{h}");

        IntPtr hdc = GetWindowDC(hDoc);
        Console.WriteLine("hdc: " + hdc);
        if (hdc != IntPtr.Zero) {
            using (Graphics g = Graphics.FromHdc(hdc)) {
                // In Window DC coordinates:
                // (0, 0) is top-left of the entire window (including border and caption)
                // Width = w, Height = h
                // Caption is at the top: Y = 4 to 26 approx
                // Top-right buttons are near X = w - 80 to w - 5, Y = 4 to 26
                using (Brush b = new SolidBrush(Color.FromArgb(255, 255, 0, 0))) {
                    g.FillRectangle(b, w - 85, 4, 80, 20);
                }
            }
            ReleaseDC(hDoc, hdc);
            Console.WriteLine("Drawn red test rectangle on caption!");
        }
    }
}
