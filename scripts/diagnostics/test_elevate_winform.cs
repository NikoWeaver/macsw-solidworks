using System;
using System.Drawing;
using System.Windows.Forms;
using System.Threading;

class ElevatedToolWindow : Form {
    public ElevatedToolWindow() {
        this.Text = "WineSW 独立悬浮面板 POC";
        this.FormBorderStyle = FormBorderStyle.SizableToolWindow;
        this.TopMost = true;
        this.StartPosition = FormStartPosition.Manual;
        // Place it right over the 3D viewport (X=600, Y=300)
        this.Location = new Point(600, 300);
        this.Size = new Size(420, 220);
        this.BackColor = Color.FromArgb(40, 40, 40);

        Label lbl = new Label {
            Text = "【路径 1 验证成功】\n独立原生 NSWindow 悬浮窗\n浮于 SolidWorks 3D 视口上方\n不受 CAMetalLayer 硬件图层遮挡！",
            Font = new Font("Microsoft YaHei UI", 12, FontStyle.Bold),
            ForeColor = Color.Gold,
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.MiddleCenter
        };
        this.Controls.Add(lbl);
    }

    [STAThread]
    static void Main() {
        Application.EnableVisualStyles();
        ElevatedToolWindow win = new ElevatedToolWindow();
        win.Show();
        Application.DoEvents();

        Console.WriteLine("ToolWindow Created & Shown, Handle: " + win.Handle.ToString("X"));
        DateTime end = DateTime.Now.AddSeconds(12);
        while (DateTime.Now < end) {
            Application.DoEvents();
            Thread.Sleep(50);
        }
        win.Close();
        Console.WriteLine("Done.");
    }
}
