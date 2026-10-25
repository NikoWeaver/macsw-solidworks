using System;
using System.Runtime.InteropServices;
using System.Threading;

class ClickSketchBtn {
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    const uint WM_LBUTTONDOWN = 0x0201;
    const uint WM_LBUTTONUP = 0x0202;

    static void Main() {
        IntPtr cmdMgr = (IntPtr)0xB0844; // swCmdMgr
        // "草图绘制" button is roughly at X=25, Y=30 inside swCmdMgr
        int clickX = 25;
        int clickY = 30;
        IntPtr lPos = (IntPtr)((clickY << 16) | (clickX & 0xFFFF));
        Console.WriteLine("Clicking '草图绘制' at ({0}, {1})...", clickX, clickY);
        SendMessage(cmdMgr, WM_LBUTTONDOWN, (IntPtr)1, lPos);
        SendMessage(cmdMgr, WM_LBUTTONUP, IntPtr.Zero, lPos);
    }
}
