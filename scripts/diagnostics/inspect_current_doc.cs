using System;
using System.Runtime.InteropServices;
using System.Text;

class InspectCurrentDoc {
    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
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
                Console.WriteLine(string.Format("{0}[0x{1:X}] Vis={2} ClientPos=({3},{4}) Size=({5}x{6}) Rect=({7},{8},{9},{10}) Cls='{11}' Title='{12}' Style=0x{13:X8} ExStyle=0x{14:X8}",
                    pad, child.ToInt64(), vis, ptTL.X, ptTL.Y, r.Right - r.Left, r.Bottom - r.Top, r.Left, r.Top, r.Right, r.Bottom, cls, title, style, exstyle));
                PrintTree(child, docHwnd, indent + 1);
            }
            return true;
        }, IntPtr.Zero);
    }

    static void Main() {
        IntPtr foundDoc = IntPtr.Zero;
        EnumWindows(delegate(IntPtr top, IntPtr l) {
            StringBuilder title = new StringBuilder(256);
            GetWindowText(top, title, 256);
            if (title.ToString().Contains("零件1") || title.ToString().Contains("SOLIDWORKS")) {
                EnumChildWindows(top, delegate(IntPtr child, IntPtr l2) {
                    StringBuilder t = new StringBuilder(256);
                    GetWindowText(child, t, 256);
                    if (t.ToString().Contains("零件1")) {
                        foundDoc = child;
                        return false;
                    }
                    return true;
                }, IntPtr.Zero);
            }
            return true;
        }, IntPtr.Zero);

        if (foundDoc != IntPtr.Zero) {
            RECT rDoc;
            GetClientRect(foundDoc, out rDoc);
            Console.WriteLine(string.Format("Found Doc 0x{0:X} ClientRect=({1},{2},{3},{4}) W={5} H={6}",
                foundDoc.ToInt64(), rDoc.Left, rDoc.Top, rDoc.Right, rDoc.Bottom, rDoc.Right - rDoc.Left, rDoc.Bottom - rDoc.Top));
            PrintTree(foundDoc, foundDoc, 1);
        } else {
            Console.WriteLine("Doc window not found!");
        }
    }
}
