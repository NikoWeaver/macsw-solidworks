using System;
using System.Runtime.InteropServices;

class CheckMetrics {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public struct LOGFONT {
        public int lfHeight;
        public int lfWidth;
        public int lfEscapement;
        public int lfOrientation;
        public int lfWeight;
        public byte lfItalic;
        public byte lfUnderline;
        public byte lfStrikeOut;
        public byte lfCharSet;
        public byte lfOutPrecision;
        public byte lfClipPrecision;
        public byte lfQuality;
        public byte lfPitchAndFamily;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string lfFaceName;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public struct NONCLIENTMETRICS {
        public int cbSize;
        public int iBorderWidth;
        public int iScrollWidth;
        public int iScrollHeight;
        public int iCaptionWidth;
        public int iCaptionHeight;
        public LOGFONT lfCaptionFont;
        public int iSmCaptionWidth;
        public int iSmCaptionHeight;
        public LOGFONT lfSmCaptionFont;
        public int iMenuWidth;
        public int iMenuHeight;
        public LOGFONT lfMenuFont;
        public LOGFONT lfStatusFont;
        public LOGFONT lfMessageFont;
    }

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern bool SystemParametersInfo(int nAction, int nParam, ref NONCLIENTMETRICS rc, int nUpdate);

    static void Main() {
        NONCLIENTMETRICS ncm = new NONCLIENTMETRICS();
        ncm.cbSize = Marshal.SizeOf(typeof(NONCLIENTMETRICS));
        if (SystemParametersInfo(41 /* SPI_GETNONCLIENTMETRICS */, ncm.cbSize, ref ncm, 0)) {
            Console.WriteLine("CaptionFont: " + ncm.lfCaptionFont.lfFaceName + ", CharSet=" + ncm.lfCaptionFont.lfCharSet);
            Console.WriteLine("MenuFont: " + ncm.lfMenuFont.lfFaceName + ", CharSet=" + ncm.lfMenuFont.lfCharSet);
            Console.WriteLine("StatusFont: " + ncm.lfStatusFont.lfFaceName + ", CharSet=" + ncm.lfStatusFont.lfCharSet);
            Console.WriteLine("MessageFont: " + ncm.lfMessageFont.lfFaceName + ", CharSet=" + ncm.lfMessageFont.lfCharSet);
        } else {
            Console.WriteLine("SystemParametersInfo failed with error: " + Marshal.GetLastWin32Error());
        }
    }
}
