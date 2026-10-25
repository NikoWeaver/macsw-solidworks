using System;
using System.Runtime.InteropServices;
using System.Text;

class ListDocChildren {
    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool ScreenToClient(IntPtr hWnd, ref POINT lpPoint);

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }

    static void Main(string[] args) {
        // Find the MDI child window '零件1'
        IntPtr doc = (IntPtr)0x90734;
        RECT rDoc;
        GetClientRect(doc, out rDoc);
        Console.WriteLine(string.Format("MdiDoc 0x{0:X}: ClientRect=({1},{2},{3},{4})", doc.ToInt64(), rDoc.Left, rDoc.Top, rDoc.Right, rDoc.Bottom));

        EnumChildWindows(doc, delegate(IntPtr child, IntPtr l) {
            if (GetParent(child) == doc) {
                StringBuilder cls = new StringBuilder(256);
                GetClassName(child, cls, 256);
                StringBuilder title = new StringBuilder(256);
                GetWindowText(child, title, 256);
                RECT r;
                GetWindowRect(child, out r);
                POINT pt = new POINT { X = r.Left, Y = r.Top };
                ScreenToClient(doc, ref pt);
                bool vis = IsWindowVisible(child);
                int style = GetWindowLong(child, -16);
                int exstyle = GetWindowLong(child, -20);
                Console.WriteLine(string.Format("  Immediate Child: [0x{0:X}] Vis={1} ClientPos=({2},{3}) Size=({4}x{5}) Style=0x{6:X8} ExStyle=0x{7:X8} Cls='{8}' Title='{9}'",
                    child.ToInt64(), vis, pt.X, pt.Y, r.Right - r.Left, r.Bottom - r.Top, style, exstyle, cls, title));
            }
            return true;
        }, IntPtr.Zero);
    }
}
