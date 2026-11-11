using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Microsoft.Win32;

namespace Talaria.UI
{
    public sealed class Palette
    {
        public readonly Color Surface, Panel, Ink, Border, Accent, OnAccent, Muted;

        public Palette(string theme)
        {
            if (SystemInformation.HighContrast && theme == "System")
            {
                Surface = SystemColors.Window;
                Panel = SystemColors.Control;
                Ink = SystemColors.WindowText;
                Border = SystemColors.WindowText;
                Accent = SystemColors.Highlight;
                OnAccent = SystemColors.HighlightText;
                Muted = SystemColors.GrayText;
                return;
            }
            bool dark = theme == "Dark" || (theme == "System" && object.Equals(Registry.GetValue(
                @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1), 0));
            Surface = Read(dark ? "#0d2f86" : "#f8faff");
            Panel = Read(dark ? "#173b8e" : "#ffffff");
            Ink = Read(dark ? "#ffe6cb" : "#17171a");
            Border = Read(dark ? "#4f6eb1" : "#c5cfe2");
            Accent = Read(dark ? "#ffe6cb" : "#0053fd");
            OnAccent = Read(dark ? "#0d2f86" : "#ffffff");
            Muted = Read(dark ? "#b6c8f2" : "#58657a");
        }

        private static Color Read(string hex) { return ColorTranslator.FromHtml(hex); }
    }

    public sealed class RoundedButton : Button
    {
        private readonly Palette palette;
        private readonly bool prominent;
        private bool hovered, pressed;

        public RoundedButton(Palette palette, bool prominent)
        {
            this.palette = palette;
            this.prominent = prominent;
            FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 0;
            BackColor = palette.Surface;
            ForeColor = palette.Ink;
            AutoSize = true;
            MinimumSize = new Size(36, 36);
            Padding = new Padding(10, 2, 10, 2);
            SetStyle(ControlStyles.OptimizedDoubleBuffer, true);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.Clear(palette.Surface);
            Color fill = Enabled && prominent ? palette.Accent : palette.Panel;
            Color text = !Enabled ? palette.Muted : prominent ? palette.OnAccent : palette.Ink;
            if (Enabled && (pressed || hovered)) fill = Mix(fill, text, pressed ? 0.20 : 0.10);
            float inset = Math.Max(1f, e.Graphics.DpiX / 96f);
            var bounds = new RectangleF(inset, inset, Width - 2 * inset, Height - 2 * inset);
            if (bounds.Width <= 0 || bounds.Height <= 0) return;
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            float diameter = Math.Min(18 * inset, Math.Min(bounds.Width, bounds.Height));
            using (var path = new GraphicsPath())
            using (var brush = new SolidBrush(fill))
            {
                path.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180, 90);
                path.AddArc(bounds.Right - diameter, bounds.Top, diameter, diameter, 270, 90);
                path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
                path.AddArc(bounds.Left, bounds.Bottom - diameter, diameter, diameter, 90, 90);
                path.CloseFigure();
                e.Graphics.FillPath(brush, path);
                if (!prominent || !Enabled || Focused)
                    using (var outline = new Pen(Focused ? palette.Ink : palette.Border, Focused ? inset * 2 : inset))
                        e.Graphics.DrawPath(outline, path);
            }
            TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, text,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine |
                (ShowKeyboardCues ? TextFormatFlags.Default : TextFormatFlags.HidePrefix));
        }

        private static Color Mix(Color from, Color to, double amount)
        {
            return Color.FromArgb((int)(from.R + (to.R - from.R) * amount),
                (int)(from.G + (to.G - from.G) * amount), (int)(from.B + (to.B - from.B) * amount));
        }

        protected override void OnMouseEnter(EventArgs e) { base.OnMouseEnter(e); hovered = true; Invalidate(); }
        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); hovered = false; Invalidate(); }
        protected override void OnMouseDown(MouseEventArgs e) { base.OnMouseDown(e); pressed = e.Button == MouseButtons.Left; Invalidate(); }
        protected override void OnMouseUp(MouseEventArgs e) { base.OnMouseUp(e); pressed = false; Invalidate(); }
        protected override void OnMouseCaptureChanged(EventArgs e) { base.OnMouseCaptureChanged(e); pressed = false; Invalidate(); }
        protected override void OnKeyDown(KeyEventArgs e) { base.OnKeyDown(e); if (e.KeyCode == Keys.Space) { pressed = true; Invalidate(); } }
        protected override void OnKeyUp(KeyEventArgs e) { base.OnKeyUp(e); pressed = false; Invalidate(); }
        protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
        protected override void OnLostFocus(EventArgs e) { base.OnLostFocus(e); pressed = false; Invalidate(); }
    }

    public sealed class ChromeForm : Form
    {
        private const int NcCalcSize = 0x83, NcHitTest = 0x84, GetMinMaxInfo = 0x24;
        private readonly bool resizable;
        private Control dragArea;

        public ChromeForm(bool resizable)
        {
            this.resizable = resizable;
            FormBorderStyle = FormBorderStyle.None;
            AutoScaleDimensions = new SizeF(96, 96);
            AutoScaleMode = AutoScaleMode.Dpi;
            Padding = new Padding(resizable ? 7 : 0);
            KeyPreview = true;
        }

        public static void EnablePerMonitorDpi()
        {
            try { SetThreadDpiAwarenessContext((IntPtr)(-4)); }
            catch (EntryPointNotFoundException) { }
        }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams options = base.CreateParams;
                if (resizable) options.Style |= 0x00040000 | 0x00080000 | 0x00020000 | 0x00010000;
                return options;
            }
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            uint noBorder = 0xfffffffe;
            DwmSetWindowAttribute(Handle, 34, ref noBorder, sizeof(uint));
        }

        protected override void WndProc(ref Message message)
        {
            if (resizable && message.Msg == NcCalcSize)
            {
                message.Result = IntPtr.Zero;
                return;
            }
            base.WndProc(ref message);
            if (resizable && message.Msg == NcHitTest)
            {
                Point screen = ScreenPoint(message.LParam);
                if (WindowState == FormWindowState.Normal)
                {
                    Point point = PointToClient(screen);
                    bool left = point.X < Padding.Left, right = point.X >= ClientSize.Width - Padding.Right;
                    bool top = point.Y < Padding.Top, bottom = point.Y >= ClientSize.Height - Padding.Bottom;
                    if (top || bottom)
                    {
                        message.Result = (IntPtr)(top ? (left ? 13 : right ? 14 : 12) : (left ? 16 : right ? 17 : 15));
                        return;
                    }
                    if (left || right) { message.Result = (IntPtr)(left ? 10 : 11); return; }
                }
                if (ContainsScreenPoint(dragArea, screen)) message.Result = (IntPtr)2;
            }
            if (resizable && message.Msg == GetMinMaxInfo)
            {
                Screen screen = Screen.FromHandle(message.HWnd);
                var info = (MinMax)Marshal.PtrToStructure(message.LParam, typeof(MinMax));
                info.MaxPosition = new Point(screen.WorkingArea.Left - screen.Bounds.Left, screen.WorkingArea.Top - screen.Bounds.Top);
                info.MaxSize = screen.WorkingArea.Size;
                Marshal.StructureToPtr(info, message.LParam, false);
            }
        }

        public Panel Caption(Palette palette, string title, Action dismiss)
        {
            var caption = new CaptionPanel { Dock = DockStyle.Top, Height = 42, BackColor = palette.Surface };
            Label label = resizable ? new DragLabel() : new Label();
            label.Text = title;
            label.Dock = DockStyle.Fill;
            label.TextAlign = ContentAlignment.MiddleLeft;
            label.ForeColor = palette.Muted;
            label.Padding = new Padding(12, 0, 0, 0);
            if (resizable) caption.DragArea = dragArea = label;
            var controls = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Right, WrapContents = false,
                FlowDirection = FlowDirection.LeftToRight, Padding = new Padding(0, 3, 5, 0) };
            if (resizable)
            {
                controls.Controls.Add(CaptionButton(palette, "−", "Minimize", delegate { WindowState = FormWindowState.Minimized; }));
                RoundedButton maximize = CaptionButton(palette, "□", "Maximize", ToggleMaximized);
                controls.Controls.Add(maximize);
                Resize += delegate
                {
                    bool maximized = WindowState == FormWindowState.Maximized;
                    maximize.Text = maximized ? "❐" : "□";
                    maximize.AccessibleName = maximized ? "Restore" : "Maximize";
                };
            }
            controls.Controls.Add(CaptionButton(palette, "×", "Close", dismiss ?? (Action)Close));
            caption.Controls.Add(label);
            caption.Controls.Add(controls);
            return caption;
        }

        public static bool Prompt(Palette palette, IWin32Window owner, string title, string message, string action, bool cancel)
        {
            using (var dialog = new ChromeForm(false))
            {
                dialog.Text = title;
                dialog.StartPosition = owner == null ? FormStartPosition.CenterScreen : FormStartPosition.CenterParent;
                dialog.ShowInTaskbar = false;
                dialog.BackColor = palette.Surface;
                dialog.Font = new Font("Segoe UI", 10);
                dialog.ClientSize = new Size(450, 192);
                var body = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown,
                    WrapContents = false, Padding = new Padding(16, 8, 16, 16) };
                var text = new Label { Text = message, ForeColor = palette.Ink, AutoSize = true,
                    MaximumSize = new Size(416, 0), Margin = new Padding(0, 0, 0, 12) };
                var actions = new FlowLayoutPanel { AutoSize = true, WrapContents = false };
                var confirm = new RoundedButton(palette, true) { Text = action, DialogResult = DialogResult.OK };
                actions.Controls.Add(confirm);
                dialog.AcceptButton = confirm;
                if (cancel)
                {
                    var back = new RoundedButton(palette, false) { Text = "Cancel", DialogResult = DialogResult.Cancel };
                    actions.Controls.Add(back);
                    dialog.CancelButton = back;
                    dialog.AcceptButton = back;
                    dialog.ActiveControl = back;
                }
                else dialog.CancelButton = confirm;
                body.Controls.Add(text);
                body.Controls.Add(actions);
                dialog.Controls.Add(body);
                dialog.Controls.Add(dialog.Caption(palette, title, null));
                return dialog.ShowDialog(owner) == DialogResult.OK;
            }
        }

        private static RoundedButton CaptionButton(Palette palette, string symbol, string name, Action action)
        {
            var button = new RoundedButton(palette, false) { Text = symbol, AccessibleName = name, AutoSize = false,
                Padding = Padding.Empty, Size = new Size(36, 36), Margin = new Padding(3, 0, 0, 0) };
            button.Click += delegate { action(); };
            return button;
        }

        private void ToggleMaximized()
        {
            WindowState = WindowState == FormWindowState.Maximized ? FormWindowState.Normal : FormWindowState.Maximized;
        }

        private static Point ScreenPoint(IntPtr position)
        {
            long raw = position.ToInt64();
            return new Point((short)raw, (short)(raw >> 16));
        }

        private static bool ContainsScreenPoint(Control control, Point position)
        {
            return control != null && control.RectangleToScreen(control.ClientRectangle).Contains(position);
        }

        private sealed class CaptionPanel : Panel
        {
            public Control DragArea;
            protected override void WndProc(ref Message message)
            {
                if (message.Msg == NcHitTest && ContainsScreenPoint(DragArea, ScreenPoint(message.LParam)))
                    message.Result = (IntPtr)(-1);
                else base.WndProc(ref message);
            }
        }

        private sealed class DragLabel : Label
        {
            protected override void WndProc(ref Message message)
            {
                if (message.Msg == NcHitTest) message.Result = (IntPtr)(-1);
                else base.WndProc(ref message);
            }
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MinMax { public Point Reserved; public Size MaxSize; public Point MaxPosition; public Size MinTrack, MaxTrack; }

        [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref uint value, int size);
        [DllImport("user32.dll")] private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    }
}
