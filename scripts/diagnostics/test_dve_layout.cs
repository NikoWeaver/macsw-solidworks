using System;
using System.Runtime.InteropServices;
using System.Text;

class TestDveLayout {
    [DllImport("user32.dll")]
    static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    static extern bool ScreenToClient(IntPtr hWnd, ref POINT lpPoint);

    [DllImport("user32.dll")]
    static extern IntPtr GetParent(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    struct POINT { public int X, Y; }

    const int SW_SHOW = 5;
    const uint SWP_NOZORDER = 0x0004;
    const uint SWP_NOACTIVATE = 0x0010;

    static void Main() {
        IntPtr dve = new IntPtr(0x00030BA4);
        IntPtr mdiDoc = new IntPtr(0x00070718);
        IntPtr tree = new IntPtr(0x00040BB6);

        RECT rTree, rDocClient, rDve;
        GetWindowRect(tree, out rTree);
        GetClientRect(mdiDoc, out rDocClient);
        GetWindowRect(dve, out rDve);

        Console.WriteLine(string.Format("Tree: ({0},{1}) {2}x{3}", rTree.Left, rTree.Top, rTree.Right - rTree.Left, rTree.Bottom - rTree.Top));
        Console.WriteLine(string.Format("DVE:  ({0},{1}) {2}x{3}", rDve.Left, rDve.Top, rDve.Right - rDve.Left, rDve.Bottom - rDve.Top));
        Console.WriteLine(string.Format("Doc:  0,0 {0}x{1}", rDocClient.Right, rDocClient.Bottom));

        // If DVE is shown, where SHOULD DVE be?
        // DVE is the PropertyManager panel! In SolidWorks, when PropertyManager is active, it typically occupies the left panel width (DESIRED_PANEL_WIDTH, e.g. 310px),
        // or it is docked in the tree container area (0, 0, 310, docHeight).
        // Let's see what happens if we set DVE to (0, 0, 310, docHeight):
        POINT ptTreeTL = new POINT { X = rTree.Left, Y = rTree.Top };
        ScreenToClient(mdiDoc, ref ptTreeTL);
        Console.WriteLine(string.Format("Tree relative to Doc: ({0},{1})", ptTreeTL.X, ptTreeTL.Y));
    }
}
