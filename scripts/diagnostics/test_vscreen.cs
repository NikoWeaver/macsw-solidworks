using System;
using System.Runtime.InteropServices;

class TestVirtScreen {
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int nIndex);
    static void Main() {
        int vx = GetSystemMetrics(76);
        int vy = GetSystemMetrics(77);
        int vcx = GetSystemMetrics(78);
        int vcy = GetSystemMetrics(79);
        Console.WriteLine(string.Format("Virtual Screen: X={0}, Y={1}, CX={2}, CY={3}", vx, vy, vcx, vcy));
    }
}
