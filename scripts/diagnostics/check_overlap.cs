using System;
using System.Runtime.InteropServices;
using System.Text;

class CheckOverlap {
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
    static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    static extern bool ScreenToClient(IntPtr hWnd, ref POINT lpPoint);

    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    struct POINT { public int X, Y; }

    static void Main() {
        EnumWindows(delegate(IntPtr top, IntPtr l) {
            StringBuilder t = new StringBuilder(256);
            GetWindowText(top, t, 256);
            if (t.ToString().Contains("SOLIDWORKS")) {
                EnumChildWindows(top, delegate(IntPtr child, IntPtr l2) {
                    StringBuilder title = new StringBuilder(256);
                    GetWindowText(child, title, 256);
                    if (title.ToString() == "Tree Container Wnd") {
                        IntPtr mdiDoc = GetParent(child);
                        RECT rDocClient;
                        GetClientRect(mdiDoc, out rDocClient);
                        Console.WriteLine(string.Format("mdiDoc client rect: {0}x{1}", rDocClient.Right, rDocClient.Bottom));

                        RECT rTree;
                        GetWindowRect(child, out rTree);
                        POINT ptTreeTL = new POINT { X = rTree.Left, Y = rTree.Top };
                        POINT ptTreeBR = new POINT { X = rTree.Right, Y = rTree.Bottom };
                        ScreenToClient(mdiDoc, ref ptTreeTL);
                        ScreenToClient(mdiDoc, ref ptTreeBR);
                        Console.WriteLine(string.Format("Tree Container Client: ({0},{1}) to ({2},{3}) [{4}x{5}]",
                            ptTreeTL.X, ptTreeTL.Y, ptTreeBR.X, ptTreeBR.Y, ptTreeBR.X-ptTreeTL.X, ptTreeBR.Y-ptTreeTL.Y));

                        // Check Tab control
                        EnumChildWindows(child, delegate(IntPtr tc, IntPtr l3) {
                            StringBuilder cls = new StringBuilder(256);
                            GetClassName(tc, cls, 256);
                            if (cls.ToString() == "SysTabControl32") {
                                RECT rTab;
                                GetWindowRect(tc, out rTab);
                                POINT ptTabTL = new POINT { X = rTab.Left, Y = rTab.Top };
                                POINT ptTabBR = new POINT { X = rTab.Right, Y = rTab.Bottom };
                                ScreenToClient(mdiDoc, ref ptTabTL);
                                ScreenToClient(mdiDoc, ref ptTabBR);
                                Console.WriteLine(string.Format("SysTabControl32 Client: ({0},{1}) to ({2},{3}) [{4}x{5}]",
                                    ptTabTL.X, ptTabTL.Y, ptTabBR.X, ptTabBR.Y, ptTabBR.X-ptTabTL.X, ptTabBR.Y-ptTabTL.Y));
                            }
                            return true;
                        }, IntPtr.Zero);

                        // Check siblings
                        EnumChildWindows(mdiDoc, delegate(IntPtr sib, IntPtr l3) {
                            if (GetParent(sib) == mdiDoc && sib != child) {
                                StringBuilder scls = new StringBuilder(256);
                                GetClassName(sib, scls, 256);
                                RECT rSib;
                                GetWindowRect(sib, out rSib);
                                POINT ptSibTL = new POINT { X = rSib.Left, Y = rSib.Top };
                                POINT ptSibBR = new POINT { X = rSib.Right, Y = rSib.Bottom };
                                ScreenToClient(mdiDoc, ref ptSibTL);
                                ScreenToClient(mdiDoc, ref ptSibBR);
                                Console.WriteLine(string.Format("Sibling 0x{0:X8} ({1}) Client: ({2},{3}) to ({4},{5}) [{6}x{7}]",
                                    sib.ToInt64(), scls.ToString(), ptSibTL.X, ptSibTL.Y, ptSibBR.X, ptSibBR.Y, ptSibBR.X-ptSibTL.X, ptSibBR.Y-ptSibTL.Y));
                            }
                            return true;
                        }, IntPtr.Zero);
                    }
                    return true;
                }, IntPtr.Zero);
            }
            return true;
        }, IntPtr.Zero);
    }
}
