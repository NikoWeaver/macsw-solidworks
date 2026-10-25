using System;
using System.Runtime.InteropServices;
using System.Text;

class TestResetDve {
    [DllImport("user32.dll")]
    static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    static extern bool RedrawWindow(IntPtr hWnd, IntPtr lprcUpdate, IntPtr hrgnUpdate, uint flags);

    [DllImport("user32.dll")]
    static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    static extern bool ScreenToClient(IntPtr hWnd, ref POINT lpPoint);

    [DllImport("user32.dll")]
    static extern IntPtr GetParent(IntPtr hWnd);

    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    struct POINT { public int X, Y; }

    const int SW_SHOW = 5;
    const uint SWP_NOZORDER = 0x0004;
    const uint SWP_NOACTIVATE = 0x0010;
    const uint RDW_INVALIDATE = 0x0001;
    const uint RDW_ERASE = 0x0004;
    const uint RDW_ALLCHILDREN = 0x0080;
    const uint RDW_UPDATENOW = 0x0100;

    static void Main() {
        IntPtr dve = new IntPtr(0x00030BA4);
        IntPtr mdiDoc = new IntPtr(0x00070718);
        IntPtr tree = new IntPtr(0x00040BB6);
        IntPtr viewport = new IntPtr(0x000F0B92);

        RECT rDocClient;
        GetClientRect(mdiDoc, out rDocClient);

        Console.WriteLine("Positioning DVEDockedContainer to left docking panel (0, 0, 310, docH)...");
        ShowWindow(dve, SW_SHOW);
        SetWindowPos(dve, IntPtr.Zero, 0, 0, 310, rDocClient.Bottom, SWP_NOZORDER | SWP_NOACTIVATE);

        // Viewport should be (310, 0, rDocClient.Right - 310, rDocClient.Bottom)
        SetWindowPos(viewport, IntPtr.Zero, 310, 0, rDocClient.Right - 310, rDocClient.Bottom, SWP_NOZORDER | SWP_NOACTIVATE);

        RedrawWindow(dve, IntPtr.Zero, IntPtr.Zero, RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_UPDATENOW);
        RedrawWindow(viewport, IntPtr.Zero, IntPtr.Zero, RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_UPDATENOW);

        Console.WriteLine("Done! Capturing screenshot now...");
    }
}
