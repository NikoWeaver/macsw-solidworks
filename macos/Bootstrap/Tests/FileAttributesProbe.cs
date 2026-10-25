using System;
using System.Runtime.InteropServices;

class FileAttributesProbe
{
    enum InfoLevel { Standard = 0 }

    [DllImport("kernel32.dll", EntryPoint = "GetFileAttributesExW", CharSet = CharSet.Unicode,
        SetLastError = true)]
    static extern bool EnumCall(string path, InfoLevel level, ref AttributeData data);

    [StructLayout(LayoutKind.Sequential)]
    struct AttributeData
    {
        public uint Attributes;
        public uint CreationLow, CreationHigh, AccessLow, AccessHigh;
        public uint WriteLow, WriteHigh, SizeHigh, SizeLow;
    }

    [DllImport("kernel32.dll", EntryPoint = "GetFileAttributesExW", CharSet = CharSet.Unicode,
        SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool MarshaledCall(string path, int level, out AttributeData data);

    [DllImport("kernel32.dll", EntryPoint = "GetFileAttributesExW", SetLastError = true)]
    static extern int DefaultCall(IntPtr path, int level, IntPtr data);

    [DllImport("kernel32.dll", EntryPoint = "GetFileAttributesExW", SetLastError = true,
        CallingConvention = CallingConvention.StdCall)]
    static extern int Stdcall(IntPtr path, int level, IntPtr data);

    static void Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "enum")
        {
            Console.WriteLine("Before enum/ref GetFileAttributesExW");
            Console.Out.Flush();
            AttributeData attributes = new AttributeData();
            bool success = EnumCall(@"C:\windows", InfoLevel.Standard, ref attributes);
            Console.WriteLine("RESULT=" + success);
            Console.WriteLine("ATTRIBUTES=" + attributes.Attributes);
            return;
        }
        if (args.Length > 0 && args[0] == "marshaled")
        {
            Console.WriteLine("Before marshaled GetFileAttributesExW");
            Console.Out.Flush();
            AttributeData attributes;
            bool success = MarshaledCall(@"C:\windows", 0, out attributes);
            Console.WriteLine("RESULT=" + success);
            Console.WriteLine("ATTRIBUTES=" + attributes.Attributes);
            return;
        }
        IntPtr path = Marshal.StringToHGlobalUni(@"C:\windows");
        IntPtr data = Marshal.AllocHGlobal(36);
        try
        {
            Console.WriteLine("Before GetFileAttributesExW");
            Console.Out.Flush();
            int result = args.Length > 0 && args[0] == "stdcall"
                ? Stdcall(path, 0, data) : DefaultCall(path, 0, data);
            Console.WriteLine("RESULT=" + result);
            Console.WriteLine("ERROR=" + Marshal.GetLastWin32Error());
        }
        finally
        {
            Marshal.FreeHGlobal(data);
            Marshal.FreeHGlobal(path);
        }
    }
}
