using System;
using System.Text;
using System.Runtime.InteropServices;

class ElevateActiveDialog {
    [DllImport("user32.dll")]
    public static extern int GetWindowLongW(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    public static extern int SetWindowLongW(IntPtr hWnd, int nIndex, int dwNewLong);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    const int GWL_EXSTYLE = -20;
    const int WS_EX_TOPMOST = 0x00000008;
    static readonly IntPtr HWND_TOPMOST = (IntPtr)(-1);
    const uint SWP_NOMOVE = 0x0002;
    const uint SWP_NOSIZE = 0x0001;
    const uint SWP_FRAMECHANGED = 0x0020;
    const uint SWP_SHOWWINDOW = 0x0040;

    static void Main() {
        IntPtr dlg = (IntPtr)0x6039C;
        int exstyle = GetWindowLongW(dlg, GWL_EXSTYLE);
        Console.WriteLine("Old ExStyle: 0x" + exstyle.ToString("X8"));

        SetWindowLongW(dlg, GWL_EXSTYLE, exstyle | WS_EX_TOPMOST);
        SetWindowPos(dlg, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED | SWP_SHOWWINDOW);
        Console.WriteLine("Elevated dialog 0x6039C to HWND_TOPMOST!");
    }
}
