using System;
using System.Runtime.InteropServices;
using System.Text;

class TestSplit {
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
    static extern IntPtr GetParent(IntPtr hWnd);

    [DllImport("user32.dll")]
    static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    static extern bool RedrawWindow(IntPtr hWnd, IntPtr lprcUpdate, IntPtr hrgnUpdate, uint flags);

    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int Left, Top, Right, Bottom; }

    const uint SWP_NOZORDER = 0x0004;
    const uint SWP_NOACTIVATE = 0x0010;
    const uint RDW_INVALIDATE = 0x0001;
    const uint RDW_ERASE = 0x0004;
    const uint RDW_ALLCHILDREN = 0x0080;
    const uint RDW_UPDATENOW = 0x0100;

    static void Main() {
        IntPtr treeHwnd = IntPtr.Zero;
        IntPtr mdiDoc = IntPtr.Zero;

        EnumWindows(delegate(IntPtr top, IntPtr l) {
            StringBuilder t = new StringBuilder(256);
            GetWindowText(top, t, 256);
            if (t.ToString().Contains("SOLIDWORKS")) {
                EnumChildWindows(top, delegate(IntPtr child, IntPtr l2) {
                    StringBuilder ct = new StringBuilder(256);
                    GetWindowText(child, ct, 256);
                    if (ct.ToString() == "Tree Container Wnd") {
                        treeHwnd = child;
                        mdiDoc = GetParent(child);
                        return false;
                    }
                    return true;
                }, IntPtr.Zero);
            }
            return true;
        }, IntPtr.Zero);

        if (treeHwnd == IntPtr.Zero || mdiDoc == IntPtr.Zero) {
            Console.WriteLine("Tree Container Wnd not found");
            return;
        }

        RECT rDoc, rTree;
        GetWindowRect(mdiDoc, out rDoc);
        GetWindowRect(treeHwnd, out rTree);
        int treeWidth = rTree.Right - rTree.Left;
        Console.WriteLine(string.Format("Doc: 0x{0:X8} ({1},{2}) {3}x{4}", mdiDoc.ToInt64(), rDoc.Left, rDoc.Top, rDoc.Right-rDoc.Left, rDoc.Bottom-rDoc.Top));
        Console.WriteLine(string.Format("Tree: 0x{0:X8} ({1},{2}) {3}x{4}", treeHwnd.ToInt64(), rTree.Left, rTree.Top, treeWidth, rTree.Bottom-rTree.Top));

        // Find sibling windows of Tree Container under mdiDoc that overlap with tree
        EnumChildWindows(mdiDoc, delegate(IntPtr sibling, IntPtr l) {
            if (GetParent(sibling) == mdiDoc && sibling != treeHwnd) {
                RECT rSib;
                GetWindowRect(sibling, out rSib);
                int sibW = rSib.Right - rSib.Left;
                int sibH = rSib.Bottom - rSib.Top;
                if (sibW > 500 && sibH > 500 && rSib.Left <= rTree.Left + 10) {
                    StringBuilder cls = new StringBuilder(256);
                    GetClassName(sibling, cls, 256);
                    Console.WriteLine(string.Format("Found overlapping viewport container: 0x{0:X8} ({1}) ({2},{3}) {4}x{5}",
                        sibling.ToInt64(), cls.ToString(), rSib.Left, rSib.Top, sibW, sibH));

                    // Shift it to the right
                    int newX = rTree.Right;
                    int newW = rDoc.Right - newX - 4; // leave margin
                    Console.WriteLine(string.Format("Moving sibling to: ({0},{1}) {2}x{3}", newX, rSib.Top, newW, sibH));
                    SetWindowPos(sibling, IntPtr.Zero, newX - rDoc.Left, rSib.Top - rDoc.Top, newW, sibH, SWP_NOZORDER | SWP_NOACTIVATE);
                    RedrawWindow(sibling, IntPtr.Zero, IntPtr.Zero, RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_UPDATENOW);
                }
            }
            return true;
        }, IntPtr.Zero);

        RedrawWindow(treeHwnd, IntPtr.Zero, IntPtr.Zero, RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_UPDATENOW);
        Console.WriteLine("Done adjusting layout!");
    }
}
