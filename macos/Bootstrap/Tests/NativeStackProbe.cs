using System;
using System.Runtime.InteropServices;

class NativeStackProbe
{
    [DllImport("kernel32.dll")]
    static extern void DebugBreak();
    [DllImport("kernel32.dll", EntryPoint = "CreateActCtxW")]
    static extern IntPtr CreateActCtx(IntPtr context);
    static void Main()
    {
        Console.WriteLine("Ready for debugger");
        DebugBreak();
        Console.WriteLine("Result=" + CreateActCtx(IntPtr.Zero));
    }
}
