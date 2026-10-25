using System;
using System.Runtime.InteropServices;
using System.Threading;

class ClickTreePlane {
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

    const uint WM_LBUTTONDOWN = 0x0201;
    const uint WM_LBUTTONUP = 0x0202;

    static void Main() {
        IntPtr tree = (IntPtr)0xD0052; // SysTreeView32
        // Click on "前视基准面" which is item 3 (Y ~ 70 inside tree)
        int clickX = 50;
        int clickY = 70;
        IntPtr lPos = (IntPtr)((clickY << 16) | (clickX & 0xFFFF));
        Console.WriteLine("Clicking '前视基准面' at ({0}, {1})...", clickX, clickY);
        SendMessage(tree, WM_LBUTTONDOWN, (IntPtr)1, lPos);
        SendMessage(tree, WM_LBUTTONUP, IntPtr.Zero, lPos);
    }
}
