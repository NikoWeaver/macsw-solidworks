using System;
using System.Runtime.InteropServices;
using System.Threading;

class ClickSwPopup {
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    const uint WM_LBUTTONDOWN = 0x0201;
    const uint WM_LBUTTONUP = 0x0202;

    static void Main() {
        IntPtr popup = (IntPtr)0xE0D92;
        int clickX = 15;
        int clickY = 19;
        IntPtr lPos = (IntPtr)((clickY << 16) | (clickX & 0xFFFF));
        Console.WriteLine("Clicking swPopup first button at ({0},{1})...", clickX, clickY);
        SendMessage(popup, WM_LBUTTONDOWN, (IntPtr)1, lPos);
        SendMessage(popup, WM_LBUTTONUP, IntPtr.Zero, lPos);
        Console.WriteLine("Done.");
    }
}
