using System;
using System.Text;
using System.Runtime.InteropServices;

class InspectDialogState {
    [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr hWnd);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);
    [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr hWnd);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    static void Main() {
        IntPtr dlg = (IntPtr)1442086;
        IntPtr mainWnd = (IntPtr)328316;
        Console.WriteLine("Dialog (1442086) Enabled: " + IsWindowEnabled(dlg));
        Console.WriteLine("MainWnd (328316) Enabled: " + IsWindowEnabled(mainWnd));
        Console.WriteLine("Dialog Parent: " + GetParent(dlg));
        Console.WriteLine("Dialog Owner: " + GetWindow(dlg, 4)); // GW_OWNER = 4
    }
}
