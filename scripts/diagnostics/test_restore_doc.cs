using System;
using System.Runtime.InteropServices;

class TestRestoreDoc {
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    const int SW_RESTORE = 9;
    const uint WM_MDIRESTORE = 0x0223;

    static void Main() {
        IntPtr mdiClient = (IntPtr)0x401D0; // swMdiClient
        IntPtr doc = (IntPtr)0x90734; // 零件1
        Console.WriteLine("Sending WM_MDIRESTORE to mdiClient for doc 0x90734...");
        SendMessage(mdiClient, WM_MDIRESTORE, doc, IntPtr.Zero);
    }
}
