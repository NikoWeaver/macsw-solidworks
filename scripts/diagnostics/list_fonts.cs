using System;
using System.Drawing;
using System.Drawing.Text;

class ListFonts {
    static void Main() {
        InstalledFontCollection ifc = new InstalledFontCollection();
        foreach (FontFamily ff in ifc.Families) {
            string name = ff.Name;
            if (name.Contains("YaHei") || name.Contains("黑") || name.Contains("Song") || name.Contains("Sim") || name.Contains("宋")) {
                Console.WriteLine("Font family: " + name);
            }
        }
    }
}
