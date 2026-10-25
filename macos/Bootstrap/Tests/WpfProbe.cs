using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;

public static class WpfProbe
{
    [STAThread]
    public static int Main()
    {
        try
        {
            Console.WriteLine("CLR: " + typeof(object).Assembly.Location);
            var app = new Application();
            var window = new Window {
                Title = "MacSW native .NET WPF test",
                Width = 420, Height = 180,
                Content = new Button { Content = "WPF layout test" }
            };
            var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
            bool rendered = false;
            window.ContentRendered += delegate {
                rendered = true;
                Console.WriteLine("WPF ContentRendered");
                timer.Start();
            };
            timer.Tick += delegate { timer.Stop(); window.Close(); };
            app.Run(window);
            return rendered ? 0 : 2;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error);
            return 1;
        }
    }
}
