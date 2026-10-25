using System;
using System.Runtime.InteropServices;
using MacSW.Tests;

public static class ComActivationProbe
{
    public static int Main()
    {
        object instance = null;
        try
        {
            var type = Type.GetTypeFromCLSID(new Guid("BE67992A-4495-4422-9A48-08F37C0D7A6B"), true);
            instance = Activator.CreateInstance(type);
            string result = ((IRegistrationProbe)instance).Ping();
            Console.WriteLine(result);
            return result == "MacSW COM OK" ? 0 : 2;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error);
            return 1;
        }
        finally
        {
            if (instance != null && Marshal.IsComObject(instance))
                Marshal.FinalReleaseComObject(instance);
        }
    }
}
