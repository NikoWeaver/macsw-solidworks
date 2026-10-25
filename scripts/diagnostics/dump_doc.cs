using System;
using System.Runtime.InteropServices;
using System.Text;

class DumpDoc {
    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    static extern IntPtr GetParent(IntPtr hWnd);

    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int Left, Top, Right, Bottom; }

    static void Main(string[] args) {
        IntPtr doc = IntPtr.Zero;
        // Find document window
        EnumWindows(delegate(IntPtr top, IntPtr l) {
            StringBuilder t = new StringBuilder(256);
            GetWindowText(top, t, 256);
            if (t.ToString().Contains("SOLIDWORKS")) {
                EnumChildWindows(top, delegate(IntPtr child, IntPtr l2) {
                    StringBuilder ct = new StringBuilder(256);
                    GetWindowText(child, ct, 256);
                    if (ct.ToString().Contains("零件") || ct.ToString().Contains("Part")) {
                        doc = child;
                        return false;
                    }
                    return true;
                }, IntPtr.Zero);
            }
            return true;
        }, IntPtr.Zero);

        if (doc == IntPtr.Zero) {
            Console.WriteLine("Doc window not found");
            return;
        }

        Console.WriteLine(string.Format("Doc window: 0x{0:X8}", doc.ToInt64()));
        EnumChildWindows(doc, delegate(IntPtr child, IntPtr l) {
            IntPtr p = GetParent(child);
            StringBuilder cls = new StringBuilder(256);
            GetClassName(child, cls, 256);
            StringBuilder title = new StringBuilder(256);
            GetWindowText(child, title, 256);
            RECT r;
            GetWindowRect(child, out r);
            int w = r.Right - r.Left;
            int h = r.Bottom - r.Top;
            int style = GetWindowLong(child, -16);
            int exstyle = GetWindowLong(child, -20);
            Console.WriteLine(string.Format("Child 0x{0:X8} (Parent: 0x{1:X8}) | ({2,4},{3,4}, {4,4}x{5,4}) | Style: 0x{6:X8} | Ex: 0x{7:X8} | Class: {8,-20} | Title: '{9}'",
                child.ToInt64(), p.ToInt64(), r.Left, r.Top, w, h, style, exstyle, cls.ToString(), title.ToString()));
            return true;
        }, IntPtr.Zero);
    }
}
