using System;
using System.Windows.Forms;

// Compile the identical source with /platform:x86 and /platform:x64.
// This probe deliberately does not open databases or create a window.
class FormsStartupProbe
{
    [STAThread]
    static void Main()
    {
        Console.WriteLine("MAIN reached, pointer size=" + IntPtr.Size);
        Application.EnableVisualStyles();
        Console.WriteLine("EnableVisualStyles passed");
        Application.SetCompatibleTextRenderingDefault(false);
        Console.WriteLine("WinForms initialization passed");
    }
}
