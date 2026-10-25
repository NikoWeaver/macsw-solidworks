using System;
using System.Runtime.InteropServices;

[assembly: ComVisible(true)]
namespace MacSW.Tests
{
    [Guid("DF4239F1-86B3-4531-B892-8666D6C45D71")]
    [InterfaceType(ComInterfaceType.InterfaceIsDual)]
    public interface IRegistrationProbe { string Ping(); }

    [Guid("BE67992A-4495-4422-9A48-08F37C0D7A6B")]
    [ClassInterface(ClassInterfaceType.None)]
    public class RegistrationProbe : IRegistrationProbe
    {
        public string Ping() { return "MacSW COM OK"; }
    }
}
