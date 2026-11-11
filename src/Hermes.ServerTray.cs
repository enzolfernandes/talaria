using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Timer = System.Windows.Forms.Timer;

[assembly: System.Reflection.AssemblyTitle("Talaria")]
[assembly: System.Reflection.AssemblyVersion("0.1.0.0")]

namespace HermesServerTray
{
    public enum ProbeKind { Healthy, MissingAddress, Failed }
    public enum TrayState { Online, Waiting, Offline }

    public sealed class ProbeResult
    {
        public ProbeKind Kind { get; private set; }
        public string Detail { get; private set; }

        public ProbeResult(ProbeKind kind, string detail)
        {
            Kind = kind;
            Detail = detail;
        }
    }

    public static class HealthProbe
    {
        public static ProbeResult Check(Uri endpoint)
        {
            IPAddress address = IPAddress.Parse(endpoint.Host);
            try
            {
                if (!AddressIsPresent(address))
                    return new ProbeResult(ProbeKind.MissingAddress, "Aguardando o endereço Tailscale.");

                HttpWebRequest request = (HttpWebRequest)WebRequest.Create(new Uri(endpoint, "/api/health"));
                request.Proxy = null;
                request.AllowAutoRedirect = false;
                request.Timeout = 2500;
                request.ReadWriteTimeout = 2500;
                request.MaximumResponseHeadersLength = 8;
                request.Accept = "application/json";

                using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
                using (StreamReader body = new StreamReader(response.GetResponseStream(), Encoding.UTF8))
                {
                    char[] buffer = new char[4097];
                    int count = body.ReadBlock(buffer, 0, buffer.Length);
                    if (response.StatusCode != HttpStatusCode.OK || count == buffer.Length)
                        return InvalidResponse();
                    Dictionary<string, object> json = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(
                        new string(buffer, 0, count));
                    object ok;
                    object version;
                    if (json == null || !json.TryGetValue("ok", out ok) || !Object.Equals(ok, true) ||
                        !json.TryGetValue("version", out version) || !(version is string) ||
                        String.IsNullOrWhiteSpace((string)version))
                        return InvalidResponse();
                    return new ProbeResult(ProbeKind.Healthy, "Hermes " + (string)version + " respondeu à verificação local.");
                }
            }
            catch (WebException error)
            {
                if (error.Response != null) error.Response.Dispose();
                return new ProbeResult(ProbeKind.Failed, "O servidor não respondeu à verificação de saúde.");
            }
            catch (IOException) { return InvalidResponse(); }
            catch (ArgumentException) { return InvalidResponse(); }
            catch (InvalidOperationException) { return InvalidResponse(); }
            catch (NetworkInformationException)
            {
                return new ProbeResult(ProbeKind.Failed, "Não foi possível consultar a rede local.");
            }
        }

        private static bool AddressIsPresent(IPAddress address)
        {
            if (IPAddress.IsLoopback(address)) return true;
            foreach (NetworkInterface network in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (network.OperationalStatus != OperationalStatus.Up) continue;
                foreach (UnicastIPAddressInformation item in network.GetIPProperties().UnicastAddresses)
                    if (address.Equals(item.Address)) return true;
            }
            return false;
        }

        private static ProbeResult InvalidResponse()
        {
            return new ProbeResult(ProbeKind.Failed, "A resposta recebida não é a resposta de saúde esperada do Hermes.");
        }
    }

    public sealed class StatusTracker
    {
        public TrayState State { get; private set; }
        public string Label { get; private set; }
        public string Detail { get; private set; }
        public int Failures { get; private set; }
        public DateTimeOffset? CheckedAt { get; private set; }

        public StatusTracker()
        {
            State = TrayState.Waiting;
            Label = "Verificando";
            Detail = "Primeira verificação em andamento.";
        }

        public void Apply(ProbeResult result)
        {
            CheckedAt = DateTimeOffset.Now;
            Detail = result.Detail;
            if (result.Kind == ProbeKind.Healthy)
            {
                State = TrayState.Online;
                Label = "Respondendo";
                Failures = 0;
            }
            else if (result.Kind == ProbeKind.MissingAddress)
            {
                State = TrayState.Waiting;
                Label = "Aguardando Tailscale";
                Failures = 0;
            }
            else
            {
                Failures = Math.Min(Failures + 1, 3);
                State = Failures == 3 ? TrayState.Offline : TrayState.Waiting;
                Label = State == TrayState.Offline ? "Indisponível" : "Tentando novamente";
            }
        }
    }

    internal sealed class TrayWindow : NativeWindow, IDisposable
    {
        private const int Callback = 0x8001;
        private const uint Add = 0, Modify = 1, Delete = 2, SetVersion = 4;
        private const uint IconId = 1;
        private readonly int taskbarCreated;
        private readonly Dictionary<string, IntPtr> icons = new Dictionary<string, IntPtr>();
        private TrayState state;
        private string tooltip;
        private int iconSize = 16;
        private bool version4;

        public bool Registered { get; private set; }
        public event Action ShowMenu;
        public event Action ShowStatus;

        public TrayWindow()
        {
            taskbarCreated = RegisterWindowMessage("TaskbarCreated");
            CreateHandle(new CreateParams { Caption = "Talaria", Style = unchecked((int)0x80000000), ExStyle = 0x80 });
            try
            {
                foreach (int size in new[] { 16, 20, 24, 32 })
                    foreach (TrayState value in Enum.GetValues(typeof(TrayState)))
                        icons.Add(IconKey(value, size), LoadIcon(IconKey(value, size), size));
            }
            catch { Dispose(); throw; }
        }

        private static string IconKey(TrayState state, int size) { return state.ToString().ToLowerInvariant() + "-" + size; }

        private static IntPtr LoadIcon(string name, int size)
        {
            using (Stream stream = typeof(TrayWindow).Assembly.GetManifestResourceStream(name + ".png"))
            using (Bitmap bitmap = new Bitmap(stream))
            {
                if (bitmap.Width != size || bitmap.Height != size) throw new InvalidDataException("Invalid tray icon dimensions.");
                return bitmap.GetHicon();
            }
        }

        public void Display(TrayState nextState, string nextTooltip)
        {
            int size = TaskbarIconSize();
            if (Registered && state == nextState && tooltip == nextTooltip && size == iconSize) return;
            state = nextState;
            tooltip = nextTooltip;
            iconSize = size;
            NotificationData data = Data();
            if (Registered && Shell_NotifyIcon(Modify, ref data)) return;
            Registered = Shell_NotifyIcon(Add, ref data);
            version4 = false;
            if (Registered)
            {
                data.TimeoutOrVersion = 4;
                version4 = Shell_NotifyIcon(SetVersion, ref data);
            }
        }

        private static int TaskbarIconSize()
        {
            uint dpi = 96;
            try
            {
                IntPtr bar = FindWindow("Shell_TrayWnd", null);
                if (bar != IntPtr.Zero) dpi = GetDpiForWindow(bar);
            }
            catch (EntryPointNotFoundException) { }
            if (dpi <= 108) return 16;
            if (dpi <= 132) return 20;
            return dpi <= 168 ? 24 : 32;
        }

        public int IconRect(out Rectangle rectangle)
        {
            Identifier item = new Identifier { Size = (uint)Marshal.SizeOf(typeof(Identifier)), Window = Handle, Id = IconId };
            Rect bounds;
            int result = Shell_NotifyIconGetRect(ref item, out bounds);
            rectangle = Rectangle.FromLTRB(bounds.Left, bounds.Top, bounds.Right, bounds.Bottom);
            return result;
        }

        protected override void WndProc(ref Message message)
        {
            if (message.Msg == taskbarCreated && tooltip != null)
            {
                Registered = false;
                Display(state, tooltip);
            }
            else if (message.Msg == Callback)
            {
                int action = (int)(message.LParam.ToInt64() & 0xffff);
                bool menu = version4 ? action == 0x007b : action == 0x0205;
                bool select = version4 ? action == 0x0400 || action == 0x0401 : action == 0x0202;
                if (menu && ShowMenu != null) { SetForegroundWindow(Handle); ShowMenu(); }
                if (select && ShowStatus != null) ShowStatus();
            }
            base.WndProc(ref message);
        }

        public void Dispose()
        {
            if (Registered)
            {
                NotificationData data = Data();
                Shell_NotifyIcon(Delete, ref data);
                Registered = false;
            }
            if (Handle != IntPtr.Zero) DestroyHandle();
            foreach (IntPtr icon in icons.Values) DestroyIcon(icon);
            icons.Clear();
        }

        private NotificationData Data()
        {
            return new NotificationData
            {
                Size = (uint)Marshal.SizeOf(typeof(NotificationData)), Window = Handle, Id = IconId,
                Flags = 0x01 | 0x02 | 0x04 | 0x80, CallbackMessage = Callback, Icon = icons[IconKey(state, iconSize)],
                Tip = tooltip, Info = "", InfoTitle = ""
            };
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct NotificationData
        {
            public uint Size;
            public IntPtr Window;
            public uint Id, Flags, CallbackMessage;
            public IntPtr Icon;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Tip;
            public uint State, StateMask;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Info;
            public uint TimeoutOrVersion;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string InfoTitle;
            public uint InfoFlags;
            public Guid Guid;
            public IntPtr BalloonIcon;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct Identifier { public uint Size; public IntPtr Window; public uint Id; public Guid Guid; }
        [StructLayout(LayoutKind.Sequential)]
        private struct Rect { public int Left, Top, Right, Bottom; }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern bool Shell_NotifyIcon(uint message, ref NotificationData data);
        [DllImport("shell32.dll")]
        private static extern int Shell_NotifyIconGetRect(ref Identifier identifier, out Rect bounds);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int RegisterWindowMessage(string name);
        [DllImport("user32.dll")]
        private static extern bool DestroyIcon(IntPtr icon);
        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr window);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr FindWindow(string className, string title);
        [DllImport("user32.dll")] private static extern uint GetDpiForWindow(IntPtr window);
    }

    internal sealed class TrayContext : ApplicationContext
    {
        private readonly Uri endpoint;
        private readonly string folder;
        private readonly string logPath;
        private readonly string setupPath;
        private readonly TrayWindow window;
        private readonly Timer timer;
        private readonly ContextMenuStrip menu;
        private readonly Form panel;
        private readonly Label panelStatus, panelTime, panelDetail;
        private readonly Color ink;
        private readonly StatusTracker tracker = new StatusTracker();
        private Task<ProbeResult> pending;
        private DateTime nextProbe = DateTime.MinValue;

        public TrayContext(Uri endpoint, string folder, string logPath, string setupPath)
        {
            this.endpoint = endpoint;
            this.folder = folder;
            this.logPath = logPath;
            this.setupPath = setupPath;
            bool highContrast = SystemInformation.HighContrast;
            bool dark = !highContrast && object.Equals(Microsoft.Win32.Registry.GetValue(
                @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1), 0);
            Color surface = highContrast ? SystemColors.Window : dark ? Color.FromArgb(13, 47, 134) : Color.FromArgb(248, 250, 255);
            ink = highContrast ? SystemColors.WindowText : dark ? Color.FromArgb(255, 230, 203) : Color.FromArgb(23, 23, 26);
            Color accent = highContrast ? SystemColors.Highlight : dark ? ink : Color.FromArgb(0, 83, 253);
            window = new TrayWindow();
            menu = new ContextMenuStrip();
            menu.Items.Add("Verificar agora", null, delegate { VerifyNow(); });
            menu.Items.Add("Copiar endereço", null, delegate { CopyAddress(); });
            menu.Items.Add("Abrir logs", null, delegate { OpenLogs(); });
            menu.Items.Add("Abrir instalador", null, delegate { OpenInstaller(); });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Sair do indicador", null, delegate { ExitThread(); });
            panel = new Form {
                Text = "Talaria", ShowInTaskbar = false, FormBorderStyle = FormBorderStyle.FixedToolWindow,
                StartPosition = FormStartPosition.Manual, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
                AutoScaleMode = AutoScaleMode.Dpi, BackColor = surface, ForeColor = ink, KeyPreview = true
            };
            var layout = new FlowLayoutPanel {
                AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, FlowDirection = FlowDirection.TopDown,
                WrapContents = false, Padding = new Padding(16), Dock = DockStyle.Fill
            };
            panelStatus = PanelLabel("Verificando", true);
            if (!highContrast) panelStatus.ForeColor = accent;
            panelTime = PanelLabel("Primeira verificação", false);
            panelDetail = PanelLabel("", false);
            layout.Controls.Add(panelStatus);
            layout.Controls.Add(PanelLabel(endpoint.Authority, false));
            layout.Controls.Add(panelTime);
            layout.Controls.Add(panelDetail);
            var refresh = new Button { Text = "Verificar agora", AutoSize = true, Margin = new Padding(0, 10, 0, 0),
                FlatStyle = FlatStyle.Flat, BackColor = accent,
                ForeColor = highContrast ? SystemColors.HighlightText : dark ? surface : Color.White };
            refresh.FlatAppearance.BorderSize = 0;
            refresh.Click += delegate { VerifyNow(); };
            layout.Controls.Add(refresh);
            panel.Controls.Add(layout);
            panel.Deactivate += delegate { panel.Hide(); };
            panel.KeyDown += delegate(object sender, KeyEventArgs e) { if (e.KeyCode == Keys.Escape) panel.Hide(); };
            window.ShowMenu += delegate { panel.Hide(); menu.Show(Anchor()); };
            window.ShowStatus += ShowStatus;
            RefreshIcon();
            timer = new Timer { Interval = 250 };
            timer.Tick += Tick;
            timer.Start();
        }

        private void Tick(object sender, EventArgs args)
        {
            if (pending != null && pending.IsCompleted)
            {
                ProbeResult result = pending.Status == TaskStatus.RanToCompletion ? pending.Result :
                    new ProbeResult(ProbeKind.Failed, "A verificação não pôde ser concluída.");
                pending = null;
                tracker.Apply(result);
                RefreshIcon();
            }
            if (pending == null && DateTime.UtcNow >= nextProbe)
            {
                nextProbe = DateTime.UtcNow.AddSeconds(5);
                pending = Task.Factory.StartNew(delegate { return HealthProbe.Check(endpoint); });
            }
        }

        private void RefreshIcon()
        {
            window.Display(tracker.State, "Talaria · " + tracker.Label + "\n" + endpoint.Authority);
            panelStatus.Text = tracker.Label;
            panelTime.Text = tracker.CheckedAt.HasValue ? "Última verificação " + tracker.CheckedAt.Value.ToString("HH:mm:ss") : "Primeira verificação em andamento";
            panelDetail.Text = tracker.Detail;
            Rectangle bounds;
            string json = new JavaScriptSerializer().Serialize(new
            {
                State = tracker.State.ToString(), tracker.Label, tracker.Detail, tracker.Failures,
                Endpoint = endpoint.GetLeftPart(UriPartial.Authority),
                CheckedAt = tracker.CheckedAt.HasValue ? tracker.CheckedAt.Value.ToString("o") : null,
                ShellRegistered = window.Registered, ShellIconRectResult = window.IconRect(out bounds),
                ProcessId = Process.GetCurrentProcess().Id
            });
            string status = Path.Combine(folder, "status.json");
            try
            {
                File.WriteAllText(status + ".tmp", json, new UTF8Encoding(false));
                if (File.Exists(status)) File.Replace(status + ".tmp", status, null);
                else File.Move(status + ".tmp", status);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }

        private void ShowStatus()
        {
            if (panel.Visible) { panel.Hide(); return; }
            Point anchor = Anchor();
            Rectangle screen = Screen.FromPoint(anchor).WorkingArea;
            panel.PerformLayout();
            panel.Location = new Point(Math.Max(screen.Left, Math.Min(anchor.X - panel.Width, screen.Right - panel.Width)),
                Math.Max(screen.Top, Math.Min(anchor.Y - panel.Height, screen.Bottom - panel.Height)));
            panel.Show();
            panel.Activate();
        }

        private Point Anchor()
        {
            Rectangle bounds;
            return window.IconRect(out bounds) == 0 ? new Point(bounds.Right, bounds.Top) : Cursor.Position;
        }

        private Label PanelLabel(string text, bool title)
        {
            return new Label { Text = text, AutoSize = true, MaximumSize = new Size(330, 0),
                MinimumSize = new Size(245, 0), Margin = new Padding(0, 0, 0, 5), ForeColor = ink,
                Font = new Font("Segoe UI", title ? 15 : 10, title ? FontStyle.Bold : FontStyle.Regular) };
        }

        private void VerifyNow()
        {
            if (pending == null) nextProbe = DateTime.MinValue;
            panelTime.Text = "Verificação em andamento";
        }

        private void CopyAddress()
        {
            try { Clipboard.SetText(endpoint.GetLeftPart(UriPartial.Authority)); }
            catch (ExternalException) { MessageBox.Show("A área de transferência está ocupada. Tente novamente.", "Talaria"); }
        }

        private void OpenInstaller()
        {
            try { Process.Start(new ProcessStartInfo(setupPath) { UseShellExecute = true }); }
            catch (Exception) { MessageBox.Show("Abra o instalador baixado para fazer a manutenção.", "Talaria"); }
        }

        private void OpenLogs()
        {
            try { Process.Start(new ProcessStartInfo(File.Exists(logPath) ? logPath : Path.GetDirectoryName(logPath)) { UseShellExecute = true }); }
            catch (Exception) { MessageBox.Show("Não foi possível abrir os logs.", "Talaria"); }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                timer.Dispose();
                panel.Dispose();
                menu.Dispose();
                window.Dispose();
            }
            base.Dispose(disposing);
        }
    }

    internal static class Program
    {
        [DllImport("user32.dll")] private static extern bool SetProcessDpiAwarenessContext(IntPtr context);
        [STAThread]
        private static int Main()
        {
            string folder = AppDomain.CurrentDomain.BaseDirectory;
            try
            {
                Dictionary<string, string> config = new JavaScriptSerializer().Deserialize<Dictionary<string, string>>(
                    File.ReadAllText(Path.Combine(folder, "config.json")));
                string setupPath;
                if (!config.TryGetValue("SetupPath", out setupPath) || String.IsNullOrWhiteSpace(setupPath))
                    setupPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "HermesServidor", "Instalar-Talaria.exe");
                Uri endpoint = new Uri(config["Endpoint"]);
                IPAddress address;
                if (endpoint.Scheme != "http" || !IPAddress.TryParse(endpoint.Host, out address) ||
                    address.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork ||
                    endpoint.AbsolutePath != "/" || !String.IsNullOrEmpty(endpoint.UserInfo) ||
                    !String.IsNullOrEmpty(endpoint.Query) || !String.IsNullOrEmpty(endpoint.Fragment))
                    throw new InvalidDataException("Endpoint must be an HTTP IPv4 address and port.");

                string sid = WindowsIdentity.GetCurrent().User.Value;
                bool created;
                using (Mutex singleton = new Mutex(true, "Local\\Hermes.ServerTray." + sid + "." + endpoint.Port, out created))
                {
                    if (!created) return 0;
                    try
                    {
                        try { SetProcessDpiAwarenessContext(new IntPtr(-4)); }
                        catch (EntryPointNotFoundException) { }
                        Application.EnableVisualStyles();
                        Application.SetCompatibleTextRenderingDefault(false);
                        using (TrayContext context = new TrayContext(endpoint, folder, config["RemoteLog"], setupPath))
                            Application.Run(context);
                    }
                    finally { singleton.ReleaseMutex(); }
                }
                return 0;
            }
            catch (Exception error)
            {
                try { File.WriteAllText(Path.Combine(folder, "startup-error.txt"), error.ToString()); }
                catch (Exception) { }
                return 1;
            }
        }
    }
}
