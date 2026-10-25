using System;
using System.Runtime.InteropServices;
using System.Text;

class InspectDveStyles {
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

    static void Check(string name, IntPtr h) {
        RECT r;
        GetWindowRect(h, out r);
        int style = GetWindowLong(h, -16);
        int exstyle = GetWindowLong(h, -20);
        bool vis = IsWindowVisible(h);
        Console.WriteLine(string.Format("{0} [0x{1:X}]: Vis={2} Rect=({3},{4},{5},{6}) W={7} H={8} Style=0x{9:X8} ExStyle=0x{10:X8}",
            name, h.ToInt64(), vis, r.Left, r.Top, r.Right, r.Bottom, r.Right - r.Left, r.Bottom - r.Top, style, exstyle));
    }

    static void Main() {
        Check("uiVisualSketchEditorView_c", (IntPtr)0x608FE);
        Check("Dve sheet", (IntPtr)0x708EE);
        Check("dvePage ScrollView", (IntPtr)0x1C072A);
        Check("SysTabControl32", (IntPtr)0x10005A);
        Check("Tree Container Wnd", (IntPtr)0x16092E);
        Check("AfxMDIFrame (3D)", (IntPtr)0x19008A);
    }
}
