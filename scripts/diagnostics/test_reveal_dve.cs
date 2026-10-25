using System;
using System.Text;
using System.Runtime.InteropServices;

class TestRevealDve {
    [DllImport("user32.dll")]
    static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    static extern bool ScreenToClient(IntPtr hWnd, ref POINT lpPoint);

    [DllImport("user32.dll")]
    static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    static extern bool RedrawWindow(IntPtr hWnd, IntPtr lprcUpdate, IntPtr hrgnUpdate, uint flags);

    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    struct POINT { public int X, Y; }

    static void Main() {
        IntPtr hDve = (IntPtr)0x30D66;
        IntPtr hMdiDoc = (IntPtr)0x60D8A;
        IntPtr hViewport = (IntPtr)0xF0D60;

        Console.WriteLine("Making DVE Visible...");
        ShowWindow(hDve, 5); // SW_SHOW

        RECT rDoc;
        GetClientRect(hMdiDoc, out rDoc);

        RECT rDve;
        GetWindowRect(hDve, out rDve);

        POINT ptDveRight = new POINT { X = rDve.Right, Y = rDve.Top };
        ScreenToClient(hMdiDoc, ref ptDveRight);

        Console.WriteLine("DVE Right in MDI Client: " + ptDveRight.X);

        int newX = ptDveRight.X;
        int newY = 0;
        int newW = rDoc.Right - newX;
        int newH = rDoc.Bottom;

        Console.WriteLine(string.Format("Resizing Viewport to X={0}, Y={1}, W={2}, H={3}", newX, newY, newW, newH));
        SetWindowPos(hViewport, IntPtr.Zero, newX, newY, newW, newH, 0x0004 | 0x0010); // SWP_NOZORDER | SWP_NOACTIVATE

        RedrawWindow(hDve, IntPtr.Zero, IntPtr.Zero, 0x0100 | 0x0001 | 0x0004 | 0x0080);
        RedrawWindow(hViewport, IntPtr.Zero, IntPtr.Zero, 0x0100 | 0x0001 | 0x0004 | 0x0080);
        Console.WriteLine("Done.");
    }
}
