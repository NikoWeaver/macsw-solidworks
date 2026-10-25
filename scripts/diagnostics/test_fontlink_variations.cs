using System;
using System.Text;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using Microsoft.Win32;

class TestFontLinkVariations {
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFontW(
        int nHeight, int nWidth, int nEscapement, int nOrientation, int fnWeight,
        uint fdwItalic, uint fdwUnderline, uint fdwStrikeOut, uint fdwCharSet,
        uint fdwOutputPrecision, uint fdwClipPrecision, uint fdwQuality,
        uint fdwPitchAndFamily, string lpszFace);

    [DllImport("gdi32.dll")]
    static extern IntPtr SelectObject(IntPtr hdc, IntPtr hgdiobj);

    [DllImport("gdi32.dll")]
    static extern bool DeleteObject(IntPtr hObject);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int DrawTextW(IntPtr hdc, string lpchText, int cchText, ref RECT lprc, uint format);

    [DllImport("gdi32.dll")]
    static extern IntPtr CreateCompatibleDC(IntPtr hdc);

    [DllImport("gdi32.dll")]
    static extern IntPtr CreateCompatibleBitmap(IntPtr hdc, int nWidth, int nHeight);

    [DllImport("gdi32.dll")]
    static extern bool DeleteDC(IntPtr hdc);

    [DllImport("user32.dll")]
    static extern IntPtr GetDC(IntPtr hWnd);

    [DllImport("user32.dll")]
    static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left, Top, Right, Bottom;
        public RECT(int l, int t, int r, int b) { Left = l; Top = t; Right = r; Bottom = b; }
    }

    static void Main() {
        IntPtr screenDC = GetDC(IntPtr.Zero);
        IntPtr memDC = CreateCompatibleDC(screenDC);
        IntPtr bmp = CreateCompatibleBitmap(screenDC, 600, 200);
        SelectObject(memDC, bmp);

        // Fill white
        using (Graphics g = Graphics.FromHdc(memDC)) {
            g.Clear(Color.White);
        }

        IntPtr fTahoma = CreateFontW(-16, 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, "Tahoma");
        IntPtr oldF = SelectObject(memDC, fTahoma);
        RECT r1 = new RECT(20, 20, 580, 60);
        DrawTextW(memDC, "Tahoma: SOLIDWORKS 正忙于运行某命令 (Fallback 测试)", -1, ref r1, 0);

        IntPtr fSegoe = CreateFontW(-16, 0, 0, 0, 600, 0, 0, 0, 1, 0, 0, 5, 0, "Segoe UI Semibold");
        SelectObject(memDC, fSegoe);
        RECT r2 = new RECT(20, 60, 580, 95);
        DrawTextW(memDC, "Segoe UI Semibold (600): 切换到 SOLIDWORKS(C)", -1, ref r2, 0);

        IntPtr fSegoeNormal = CreateFontW(-16, 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, "Segoe UI");
        SelectObject(memDC, fSegoeNormal);
        RECT r2b = new RECT(20, 95, 580, 130);
        DrawTextW(memDC, "Segoe UI (400): 切换到 SOLIDWORKS(C)", -1, ref r2b, 0);

        IntPtr fYaHei = CreateFontW(-16, 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, "Microsoft YaHei UI");
        SelectObject(memDC, fYaHei);
        RECT r3 = new RECT(20, 130, 580, 165);
        DrawTextW(memDC, "Microsoft YaHei UI: 原始微软雅黑显示正常", -1, ref r3, 0);

        SelectObject(memDC, oldF);
        DeleteObject(fTahoma);
        DeleteObject(fSegoe);
        DeleteObject(fSegoeNormal);
        DeleteObject(fYaHei);

        using (Bitmap managedBmp = Image.FromHbitmap(bmp)) {
            managedBmp.Save("scratch/fontlink_direct_test.png", ImageFormat.Png);
        }
        DeleteObject(bmp);
        DeleteDC(memDC);
        ReleaseDC(IntPtr.Zero, screenDC);
        Console.WriteLine("Saved scratch/fontlink_direct_test.png");
    }
}
