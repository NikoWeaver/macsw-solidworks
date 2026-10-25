using System;
using System.Runtime.InteropServices;

class NativeBridgeProbe
{
    [DllImport("NativeBridge.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr bridge_cdecl(IntPtr context);
    [DllImport("NativeBridge.dll", CallingConvention = CallingConvention.StdCall)]
    static extern IntPtr bridge_stdcall(IntPtr context);

    static void Main(string[] args)
    {
        bool stdcall = args.Length > 0 && args[0] == "stdcall";
        Console.WriteLine("Bridge=" + (stdcall ? "stdcall" : "cdecl"));
        Console.Out.Flush();
        IntPtr value = stdcall ? bridge_stdcall(IntPtr.Zero) : bridge_cdecl(IntPtr.Zero);
        Console.WriteLine("RESULT=" + value);
    }
}
