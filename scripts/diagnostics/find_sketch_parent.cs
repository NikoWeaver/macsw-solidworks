using System;
using System.Runtime.InteropServices;
using System.Text;

class FindParentChain {
    [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

    static void PrintChain(IntPtr h) {
        Console.WriteLine(string.Format("Parent chain for 0x{0:X}:", h.ToInt64()));
        IntPtr cur = h;
        while (cur != IntPtr.Zero) {
            StringBuilder cls = new StringBuilder(256);
            GetClassName(cur, cls, 256);
            StringBuilder title = new StringBuilder(256);
            GetWindowText(cur, title, 256);
            RECT r;
            GetWindowRect(cur, out r);
            bool vis = IsWindowVisible(cur);
            int style = GetWindowLong(cur, -16);
            int exstyle = GetWindowLong(cur, -20);
            Console.WriteLine(string.Format("  -> [0x{0:X}] Vis={1} Rect=({2},{3},{4},{5}) W={6} H={7} Style=0x{8:X8} ExStyle=0x{9:X8} Cls='{10}' Title='{11}'",
                cur.ToInt64(), vis, r.Left, r.Top, r.Right, r.Bottom, r.Right - r.Left, r.Bottom - r.Top, style, exstyle, cls, title));
            cur = GetParent(cur);
        }
    }

    static void Main() {
        PrintChain((IntPtr)0x608FE);
        PrintChain((IntPtr)0x40066);
    }
}
