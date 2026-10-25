using System;
using System.Runtime.InteropServices;

class CheckStyles {
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

    static void Print(string name, IntPtr h) {
        int s = GetWindowLong(h, -16);
        int es = GetWindowLong(h, -20);
        RECT r;
        GetWindowRect(h, out r);
        Console.WriteLine(string.Format("{0} [0x{1:X}]: Rect=({2},{3},{4},{5}) W={6} H={7} Style=0x{8:X8} ExStyle=0x{9:X8}",
            name, h.ToInt64(), r.Left, r.Top, r.Right, r.Bottom, r.Right - r.Left, r.Bottom - r.Top, s, es));
    }

    static void Main() {
        Print("TreeContainer", (IntPtr)0x16092E);
        Print("TabControl", (IntPtr)0x10005A);
        Print("uiVisualSketch", (IntPtr)0x608FE);
        Print("DveSheet", (IntPtr)0x708EE);
        Print("dvePage", (IntPtr)0x1C072A);
        Print("Dialog", (IntPtr)0x80914);
    }
}
