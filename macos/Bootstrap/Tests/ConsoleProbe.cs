using System;

// Compile the same source with /platform:x86 and /platform:x64.
// No WinForms, database, or SOLIDWORKS dependencies.
class ConsoleProbe
{
    static void Main()
    {
        Console.WriteLine("CONSOLE OK pointer=" + IntPtr.Size);
    }
}
