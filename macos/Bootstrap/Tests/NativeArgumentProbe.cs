using System;
using System.Runtime.InteropServices;

class NativeArgumentProbe
{
    [DllImport("kernel32.dll")]
    static extern uint GetCurrentProcessId();
    [DllImport("kernel32.dll")]
    static extern uint GetFileType(IntPtr handle);
    [DllImport("kernel32.dll", EntryPoint = "CreateActCtxW")]
    static extern uint CreateActCtx32(IntPtr context);

    static void Main()
    {
        Console.WriteLine("PID=" + GetCurrentProcessId());
        Console.Out.Flush();
        Console.WriteLine("GetFileType(NULL)=" + GetFileType(IntPtr.Zero));
        // x86-only ABI diagnostic: preserve the 32-bit return bits without IntPtr marshalling.
        if (IntPtr.Size == 4)
            Console.WriteLine("CreateActCtx uint=0x" + CreateActCtx32(IntPtr.Zero).ToString("x"));
    }
}
