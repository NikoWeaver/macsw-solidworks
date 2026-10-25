using System;
using System.IO;

class DirectoryProbe
{
    static void Main()
    {
        Console.WriteLine("Before Directory.Exists");
        Console.Out.Flush();
        Console.WriteLine(Directory.Exists(@"C:\MacSW-absent-probe-directory"));
        Console.WriteLine("Directory probe completed");
    }
}
