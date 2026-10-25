using System;
using System.Drawing;

class TestFontRender {
    static void Main() {
        string[] fonts = new string[] {
            "Microsoft YaHei UI",
            "微软雅黑",
            "PingFang SC",
            "SimSun",
            "STSong",
            "STHeiti"
        };
        string testText = "零件 装配体 工程图 确定 取消";
        foreach (string fn in fonts) {
            try {
                using (Font f = new Font(fn, 12)) {
                    using (Bitmap b = new Bitmap(200, 50)) {
                        using (Graphics g = Graphics.FromImage(b)) {
                            SizeF s = g.MeasureString(testText, f);
                            Console.WriteLine(string.Format("Font '{0}' -> Actual: '{1}', Width={2}", fn, f.Name, s.Width));
                        }
                    }
                }
            } catch (Exception ex) {
                Console.WriteLine("Font '" + fn + "' error: " + ex.Message);
            }
        }
    }
}
