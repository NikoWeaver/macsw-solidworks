using System;
using System.Runtime.InteropServices;
using System.Text;

class ParentChain {
    [DllImport("user32.dll")]
    static extern IntPtr GetParent(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int Left, Top, Right, Bottom; }

    static void Main(string[] args) {
        IntPtr hwnd = new IntPtr(0x00380B3C);
        Console.WriteLine("Parent chain for 0x00380B3C:");
        while (hwnd != IntPtr.Zero) {
            StringBuilder cls = new StringBuilder(256);
            GetClassName(hwnd, cls, 256);
            StringBuilder title = new StringBuilder(256);
            GetWindowText(hwnd, title, 256);
            RECT r;
            GetWindowRect(hwnd, out r);
            int style = GetWindowLong(hwnd, -16);
            int exstyle = GetWindowLong(hwnd, -20);
            Console.WriteLine(string.Format("HWND: 0x{0:X8} | ({1,4},{2,4}, {3,4}x{4,4}) | Style: 0x{5:X8} | Ex: 0x{6:X8} | Class: {7,-25} | Title: '{8}'",
                hwnd.ToInt64(), r.Left, r.Top, r.Right-r.Left, r.Bottom-r.Top, style, exstyle, cls.ToString(), title.ToString()));
            hwnd = GetParent(hwnd);
        }
    }
}
