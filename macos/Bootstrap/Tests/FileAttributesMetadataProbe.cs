using System;
using System.Reflection;
using System.Runtime.InteropServices;

class FileAttributesMetadataProbe
{
    static void Main(string[] args)
    {
        foreach (Type type in typeof(object).Assembly.GetTypes())
        {
            foreach (MethodInfo method in type.GetMethods(BindingFlags.Public |
                BindingFlags.NonPublic | BindingFlags.Static | BindingFlags.DeclaredOnly))
            {
                if (method.Name != "GetFileAttributesExPrivate")
                    continue;
                Console.WriteLine(type.FullName + ": " + method);
                DllImportAttribute import = (DllImportAttribute)Attribute.GetCustomAttribute(
                    method, typeof(DllImportAttribute));
                if (import != null)
                    Console.WriteLine("DLL=" + import.Value + " EntryPoint=" + import.EntryPoint +
                        " Convention=" + import.CallingConvention + " Charset=" + import.CharSet +
                        " LastError=" + import.SetLastError + " Exact=" + import.ExactSpelling);
                foreach (ParameterInfo parameter in method.GetParameters())
                    Console.WriteLine(parameter.Name + " Type=" + parameter.ParameterType +
                        " Attributes=" + parameter.Attributes);
                if (args.Length > 0 && (args[0] == "invoke" || args[0] == "directory"))
                {
                    ParameterInfo[] parameters = method.GetParameters();
                    object[] values = {
                        @"C:\windows",
                        Enum.ToObject(parameters[1].ParameterType, 0),
                        Activator.CreateInstance(parameters[2].ParameterType.GetElementType())
                    };
                    Console.WriteLine("Before internal invocation");
                    Console.Out.Flush();
                    Console.WriteLine("RESULT=" + method.Invoke(null, values));
                    if (args[0] == "directory")
                    {
                        Console.WriteLine("Before Directory.Exists after internal invocation");
                        Console.Out.Flush();
                        Console.WriteLine("DIRECTORY=" + System.IO.Directory.Exists(@"C:\windows"));
                    }
                }
            }
        }
    }
}
