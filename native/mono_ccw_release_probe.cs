using System;
using System.Runtime.InteropServices;

// Run in a separate process: unpatched Wine-Mono aborts on the excess Release.
// Require the completion marker as well as exit zero; abort can report exit zero.
[ComVisible(true), ClassInterface(ClassInterfaceType.AutoDual)]
public sealed class CcwReleaseProbeObject
{
    public int Value() { return 42; }
}

public static class CcwReleaseProbe
{
    private static void Expect(string name, int actual, int expected)
    {
        Console.WriteLine(name + "=" + actual);
        if (actual != expected)
            throw new Exception(name + ": expected " + expected + ", got " + actual);
    }

    public static int Main()
    {
        object value = new CcwReleaseProbeObject();
        IntPtr unknown = Marshal.GetIUnknownForObject(value);
        Expect("initial-addref", Marshal.AddRef(unknown), 2);
        Expect("balance-addref", Marshal.Release(unknown), 1);
        Expect("release-to-zero", Marshal.Release(unknown), 0);
        Expect("over-release", Marshal.Release(unknown), -1);
        Expect("repeated-over-release", Marshal.Release(unknown), -1);
        Expect("reacquire", Marshal.AddRef(unknown), 1);
        Expect("release-reacquired", Marshal.Release(unknown), 0);
        GC.KeepAlive(value); // Do not invoke COM through a collected object's CCW.
        Console.WriteLine("CCW_RELEASE_PROBE_PASS");
        return 0;
    }
}
