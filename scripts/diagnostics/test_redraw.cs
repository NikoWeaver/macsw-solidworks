using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

class TestRedraw {
    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool RedrawWindow(IntPtr hWnd, IntPtr lprcUpdate, IntPtr hrgnUpdate, uint flags);

    [DllImport("user32.dll")]
    static extern bool PrintWindow(IntPtr hwnd, IntPtr hdcBlt, uint nFlags);

    [DllImport("user32.dll")]
    static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [StructLayout(LayoutKind.Sequential)]
    struct RECT {
        public int Left, Top, Right, Bottom;
    }

    const uint WM_SETREDRAW = 0x000B;
    const uint RDW_INVALIDATE = 0x0001;
    const uint RDW_ERASE = 0x0004;
    const uint RDW_ALLCHILDREN = 0x0080;
    const uint RDW_UPDATENOW = 0x0100;
    const uint TVM_SETBKCOLOR = 0x1100 + 29;
    const uint TVM_SETTEXTCOLOR = 0x1100 + 30;

    static bool EnumChild(IntPtr hwnd, IntPtr lParam) {
        StringBuilder cls = new StringBuilder(256);
        GetClassName(hwnd, cls, 256);
        if (cls.ToString() == "SysTreeView32") {
            RECT r;
            GetWindowRect(hwnd, out r);
            int w = r.Right - r.Left;
            int h = r.Bottom - r.Top;
            if (w > 100 && h > 100) {
                Console.WriteLine(string.Format("Tree: 0x{0:X8} ({1}x{2})", hwnd.ToInt64(), w, h));
                SendMessage(hwnd, WM_SETREDRAW, (IntPtr)1, IntPtr.Zero);
                SendMessage(hwnd, TVM_SETBKCOLOR, IntPtr.Zero, (IntPtr)0x00FFFFFF);
                SendMessage(hwnd, TVM_SETTEXTCOLOR, IntPtr.Zero, (IntPtr)0x00000000);
                RedrawWindow(hwnd, IntPtr.Zero, IntPtr.Zero, RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_UPDATENOW);

                using (Bitmap bmp = new Bitmap(w, h)) {
                    using (Graphics g = Graphics.FromImage(bmp)) {
                        IntPtr hdc = g.GetHdc();
                        PrintWindow(hwnd, hdc, 0);
                        g.ReleaseHdc(hdc);
                    }
                    string fname = string.Format("Z:\\Volumes\\Data\\Workspace\\WineSW\\scratch\\tree_0x{0:X8}.png", hwnd.ToInt64());
                    bmp.Save(fname, ImageFormat.Png);
                    Console.WriteLine("Saved: " + fname);
                }
            }
        }
        return true;
    }

    static bool EnumTop(IntPtr hwnd, IntPtr lParam) {
        StringBuilder title = new StringBuilder(256);
        GetWindowText(hwnd, title, 256);
        if (title.ToString().Contains("SOLIDWORKS")) {
            EnumChildWindows(hwnd, EnumChild, IntPtr.Zero);
        }
        return true;
    }

    static void Main(string[] args) {
        EnumWindows(EnumTop, IntPtr.Zero);
    }
}
