using System;
using System.IO;
using System.Net;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography.X509Certificates;

// Optional developer/CI diagnostic; never shipped in the runtime App.
// Pass a local certificate fixture. This proves provider initialization and
// native certificate parsing, not a remote TLS handshake or trust policy.
public static class MonoBtlsProbe
{
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)]
    private static extern IntPtr GetModuleHandle(string module);

    public static int Main(string[] arguments)
    {
        if (arguments.Length != 1) throw new ArgumentException("certificate fixture path required");
        Type factory = typeof(HttpWebRequest).Assembly.GetType("Mono.Net.Security.MonoTlsProviderFactory", true);
        MethodInfo getProvider = factory.GetMethod("GetProvider", BindingFlags.Static | BindingFlags.NonPublic,
                                                  null, Type.EmptyTypes, null);
        if (getProvider == null) throw new MissingMethodException("GetProvider");
        object provider = getProvider.Invoke(null, null);
        string name = (string)provider.GetType().GetProperty("Name").GetValue(provider, null);
        Console.WriteLine("tls-provider=" + name);
        if (name != "btls") throw new Exception("BTLS provider unavailable");
        using (var certificate = new X509Certificate2(File.ReadAllBytes(arguments[0])))
        {
            if (String.IsNullOrEmpty(certificate.Subject) || String.IsNullOrEmpty(certificate.Thumbprint))
                throw new Exception("certificate parse failed");
            Console.WriteLine("certificate-subject=" + certificate.Subject);
        }
        if (GetModuleHandle("libmono-btls-shared.dll") == IntPtr.Zero)
            throw new Exception("native BTLS module did not load");
        Console.WriteLine("MONO_BTLS_PROBE_PASS");
        return 0;
    }
}
