using System;
using System.Runtime.InteropServices;
using System.Threading;

class TestEnterSketch {
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    const uint WM_LBUTTONDOWN = 0x0201;
    const uint WM_LBUTTONUP = 0x0202;

    static void Click(IntPtr hwnd, int x, int y) {
        IntPtr lPos = (IntPtr)((y << 16) | (x & 0xFFFF));
        SendMessage(hwnd, WM_LBUTTONDOWN, (IntPtr)1, lPos);
        SendMessage(hwnd, WM_LBUTTONUP, IntPtr.Zero, lPos);
    }

    static void Main() {
        IntPtr tree = (IntPtr)0xD0052;
        IntPtr cmdMgr = (IntPtr)0xD0818;

        Console.WriteLine("Step 1: Selecting 前视基准面...");
        Click(tree, 50, 70);
        Thread.Sleep(500);

        Console.WriteLine("Step 2: Clicking 草图绘制...");
        Click(cmdMgr, 25, 45);
        Thread.Sleep(500);
        Console.WriteLine("Done.");
    }
}
