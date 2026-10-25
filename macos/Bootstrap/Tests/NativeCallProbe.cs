using System;
using System.Runtime.InteropServices;

// Compare x86/x64 and default/interpreter execution without UI or database access.
class NativeCallProbe
{
    [DllImport("kernel32.dll")]
    static extern uint GetCurrentProcessId();

    [DllImport("kernel32.dll", EntryPoint = "CreateActCtxW")]
    static extern IntPtr CreateActCtx(IntPtr context);

    [DllImport("kernelbase.dll", EntryPoint = "CreateActCtxW")]
    static extern IntPtr CreateActCtxBase(IntPtr context);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr GetModuleHandleW(string name);

    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, ExactSpelling = true)]
    static extern IntPtr GetProcAddress(IntPtr module, string name);

    static void Main(string[] args)
    {
        Console.WriteLine("MAIN pointer=" + IntPtr.Size);
        Console.Out.Flush();
        Console.WriteLine("PID=" + GetCurrentProcessId());
        Console.WriteLine("PINVOKE OK");
        IntPtr module = GetModuleHandleW("kernel32.dll");
        IntPtr address = GetProcAddress(module, "CreateActCtxW");
        Console.WriteLine("CreateActCtx export=0x" + address.ToInt64().ToString("x"));
        Console.Out.Flush();
        // Invalid input intentionally tests the API boundary without creating an activation context.
        IntPtr result = args.Length > 0 && args[0] == "kernelbase"
            ? CreateActCtxBase(IntPtr.Zero) : CreateActCtx(IntPtr.Zero);
        Console.WriteLine("CreateActCtx(NULL)=" + result);
    }
}
