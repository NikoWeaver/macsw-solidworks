using System;
using System.Runtime.InteropServices;
using System.Text;

class InspectDoc {
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

    static void PrintTree(IntPtr hwnd, IntPtr docHwnd, int indent) {
        EnumChildWindows(hwnd, delegate(IntPtr child, IntPtr l) {
            if (GetParent(child) == hwnd) {
                StringBuilder cls = new StringBuilder(256);
                GetClassName(child, cls, 256);
                StringBuilder title = new StringBuilder(256);
                GetWindowText(child, title, 256);
                RECT r;
                GetWindowRect(child, out r);
                POINT ptTL = new POINT { X = r.Left, Y = r.Top };
                ScreenToClient(docHwnd, ref ptTL);
                bool vis = IsWindowVisible(child);
                int style = GetWindowLong(child, -16);
                int exstyle = GetWindowLong(child, -20);
                string pad = new string(' ', indent * 2);
                Console.WriteLine(string.Format("{0}[0x{1:X}] Vis={2} ClientPos=({3},{4}) Size=({5}x{6}) Rect=({7},{8},{9},{10}) Cls='{11}' Title='{12}'",
                    pad, child.ToInt64(), vis, ptTL.X, ptTL.Y, r.Right - r.Left, r.Bottom - r.Top, r.Left, r.Top, r.Right, r.Bottom, cls, title));
                PrintTree(child, docHwnd, indent + 1);
            }
            return true;
        }, IntPtr.Zero);
    }

    static void Main() {
        IntPtr doc = (IntPtr)0x150946;
        RECT rDoc;
        GetClientRect(doc, out rDoc);
        Console.WriteLine(string.Format("Document 0x{0:X} ClientRect=({1},{2},{3},{4}) W={5} H={6}",
            doc.ToInt64(), rDoc.Left, rDoc.Top, rDoc.Right, rDoc.Bottom, rDoc.Right - rDoc.Left, rDoc.Bottom - rDoc.Top));
        PrintTree(doc, doc, 1);
    }
}
