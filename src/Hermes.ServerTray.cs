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
using Talaria.UI;
using Timer = System.Windows.Forms.Timer;

[assembly: System.Reflection.AssemblyTitle("Talaria")]
[assembly: System.Reflection.AssemblyVersion("0.3.2.0")]
[assembly: System.Runtime.CompilerServices.InternalsVisibleTo("Test-ServerTray")]

namespace HermesServerTray
{
    public enum ProbeKind { Healthy, MissingAddress, Failed }
    public enum TrayState { Online, Waiting, Offline }

    public sealed class ProbeResult
    {
        public ProbeKind Kind { get; private set; }
        public string Detail { get; private set; }
        public string Network { get; internal set; }

        public ProbeResult(ProbeKind kind, string detail)
        {
            Kind = kind;
            Detail = detail;
        }
    }

    public static class HealthProbe
    {
        internal static bool IsSupportedEndpoint(Uri endpoint)
        {
            if (endpoint == null || !endpoint.IsAbsoluteUri || endpoint.Port < 1 || endpoint.AbsolutePath != "/" ||
                !String.IsNullOrEmpty(endpoint.UserInfo) || !String.IsNullOrEmpty(endpoint.Query) ||
                !String.IsNullOrEmpty(endpoint.Fragment)) return false;

            return (endpoint.Scheme == Uri.UriSchemeHttp && endpoint.HostNameType == UriHostNameType.IPv4) ||
                (endpoint.Scheme == Uri.UriSchemeHttps && endpoint.HostNameType == UriHostNameType.Dns &&
                endpoint.IdnHost.EndsWith(".ts.net", StringComparison.OrdinalIgnoreCase));
        }

        public static ProbeResult Check(Uri endpoint)
        {
            try
            {
                if (endpoint.Scheme == Uri.UriSchemeHttp && !AddressIsPresent(IPAddress.Parse(endpoint.Host)))
                    return new ProbeResult(ProbeKind.MissingAddress, "Waiting for the Tailscale address.");

                if (endpoint.Scheme == Uri.UriSchemeHttps)
                    ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
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
                    object authRequired;
                    if (endpoint.Scheme == Uri.UriSchemeHttps &&
                        (!json.TryGetValue("auth_required", out authRequired) || !Object.Equals(authRequired, true)))
                        return new ProbeResult(ProbeKind.Failed, "The HTTPS gateway did not report sign-in protection.");
                    return new ProbeResult(ProbeKind.Healthy, "Hermes " + (string)version + " passed the health check.");
                }
            }
            catch (WebException error)
            {
                using (var response = error.Response as HttpWebResponse)
                    if (response != null && (response.StatusCode == HttpStatusCode.Unauthorized || response.StatusCode == HttpStatusCode.Forbidden))
                        return new ProbeResult(ProbeKind.Failed, "Hermes responded but access to its health endpoint was denied.");
                if (error.Status == WebExceptionStatus.TrustFailure || error.Status == WebExceptionStatus.SecureChannelFailure)
                    return new ProbeResult(ProbeKind.Failed, "Could not establish a trusted HTTPS connection to the gateway.");
                return new ProbeResult(ProbeKind.Failed, "The server did not respond to the health check.");
            }
            catch (IOException) { return InvalidResponse(); }
            catch (ArgumentException) { return InvalidResponse(); }
            catch (InvalidOperationException) { return InvalidResponse(); }
            catch (NetworkInformationException)
            {
                return new ProbeResult(ProbeKind.Failed, "Could not check the local network.");
            }
        }

        internal static bool AddressIsPresent(IPAddress address)
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
            return new ProbeResult(ProbeKind.Failed, "The response did not match the expected Hermes health response.");
        }

        internal static string TailscaleApp(string name)
        {
            foreach (string root in new[] { Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86) })
            {
                if (String.IsNullOrEmpty(root)) continue;
                string path = Path.Combine(root, "Tailscale", name);
                if (File.Exists(path)) return path;
            }
            return null;
        }

        internal static string ReadTailscale(Uri endpoint)
        {
            IPAddress expected = endpoint.Scheme == Uri.UriSchemeHttp ? IPAddress.Parse(endpoint.Host) : null;
            if (expected != null && IPAddress.IsLoopback(expected)) return null;
            string path = TailscaleApp("tailscale.exe");
            if (path == null) return "Tailscale is not installed.";
            try
            {
                using (var process = Process.Start(new ProcessStartInfo(path, "status --json") {
                    UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true
                }))
                {
                    var output = process.StandardOutput.ReadToEndAsync();
                    var errors = process.StandardError.ReadToEndAsync();
                    if (!process.WaitForExit(2500)) { process.Kill(); return "Tailscale status is unavailable."; }
                    if (!Task.WaitAll(new Task[] { output, errors }, 500) || String.IsNullOrWhiteSpace(output.Result)) return "Tailscale status is unavailable.";
                    var serializer = new JavaScriptSerializer { MaxJsonLength = Int32.MaxValue };
                    var result = serializer.Deserialize<Dictionary<string, object>>(output.Result);
                    object backend, addresses;
                    if (result == null || !result.TryGetValue("BackendState", out backend) || !Object.Equals(backend, "Running")) return "Tailscale is disconnected.";
                    if (expected == null) return "Tailscale is connected.";
                    if (result.TryGetValue("TailscaleIPs", out addresses) && addresses is System.Collections.IEnumerable)
                    {
                        bool otherAddress = false;
                        foreach (object value in (System.Collections.IEnumerable)addresses)
                        {
                            IPAddress ip;
                            if (!IPAddress.TryParse(value as string, out ip) || ip.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork || !AddressIsPresent(ip)) continue;
                            if (ip.Equals(expected)) return "Tailscale is connected.";
                            otherAddress = true;
                        }
                        if (otherAddress) return "Tailscale IPv4 changed. Review the configured address.";
                    }
                    return "Waiting for the configured Tailscale IPv4.";
                }
            }
            catch (System.ComponentModel.Win32Exception) { return "Tailscale status is unavailable."; }
            catch (InvalidOperationException) { return "Tailscale status is unavailable."; }
            catch (ArgumentException) { return "Tailscale status is unavailable."; }
            catch (AggregateException) { return "Tailscale status is unavailable."; }
        }
    }

    public sealed class StatusTracker
    {
        public TrayState State { get; private set; }
        public string Label { get; private set; }
        public string Detail { get; private set; }
        public int Failures { get; private set; }
        public DateTimeOffset? CheckedAt { get; private set; }
        internal int CheckIntervalSeconds { get { return State == TrayState.Online ? 300 : 15; } }

        public StatusTracker()
        {
            State = TrayState.Waiting;
            Label = "Checking";
            Detail = "Running the first check.";
        }

        public void Apply(ProbeResult result)
        {
            CheckedAt = DateTimeOffset.Now;
            Detail = result.Detail;
            if (result.Kind == ProbeKind.Healthy)
            {
                State = TrayState.Online;
                Label = "Online";
                Failures = 0;
            }
            else if (result.Kind == ProbeKind.MissingAddress)
            {
                State = TrayState.Waiting;
                Label = "Waiting for Tailscale";
                Failures = 0;
            }
            else
            {
                Failures = Math.Min(Failures + 1, 3);
                State = Failures == 3 ? TrayState.Offline : TrayState.Waiting;
                Label = State == TrayState.Offline ? "Offline" : "Retrying";
            }
        }
    }

    internal enum IconCommand : uint { Add = 0, Modify = 1, Delete = 2, SetVersion = 4 }

    internal sealed class TrayWindow : NativeWindow, IDisposable
    {
        private const int Callback = 0x8001;
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
            state = nextState;
            tooltip = nextTooltip;
            iconSize = TaskbarIconSize();
            Registered = PublishIcon(Notify, Registered, ref version4);
        }

        internal static bool PublishIcon(Func<IconCommand, bool> notify, bool registered, ref bool version4)
        {
            // Explorer can still own the icon after an earlier update returned false.
            if (notify(IconCommand.Modify))
            {
                if (!registered) version4 = notify(IconCommand.SetVersion);
                return true;
            }

            bool added = notify(IconCommand.Add);
            if (!added && notify(IconCommand.Delete)) added = notify(IconCommand.Add);
            version4 = added && notify(IconCommand.SetVersion);
            return added;
        }

        private bool Notify(IconCommand command)
        {
            NotificationData data = Data();
            if (command == IconCommand.SetVersion) data.TimeoutOrVersion = 4;
            return Shell_NotifyIcon((uint)command, ref data);
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
            if (Handle != IntPtr.Zero && tooltip != null) Notify(IconCommand.Delete);
            Registered = false;
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
        private readonly string desktopExe;
        private readonly string desktopAppId;
        private readonly TrayWindow window;
        private readonly Timer timer;
        private readonly ContextMenuStrip menu;
        private readonly ChromeForm panel;
        private readonly Label panelStatus, panelTime, panelDetail, panelNetwork, panelRecovery;
        private readonly Palette palette;
        private readonly StatusTracker tracker = new StatusTracker();
        private readonly Stopwatch clock = Stopwatch.StartNew();
        private Task<ProbeResult> pending;
        private TimeSpan probeStartedAt;
        private TimeSpan nextProbe;
        private TimeSpan nextIconRetry;
        private string networkStatus;

        public TrayContext(Uri endpoint, string folder, string logPath, string setupPath, string desktopExe = null, string desktopAppId = null)
        {
            this.endpoint = endpoint;
            this.folder = folder;
            this.logPath = logPath;
            this.setupPath = setupPath;
            this.desktopExe = desktopExe;
            this.desktopAppId = desktopAppId;
            palette = new Palette("System");
            window = new TrayWindow();
            menu = new ContextMenuStrip();
            menu.Items.Add("Check now", null, delegate { VerifyNow(); });
            menu.Items.Add("Copy address", null, delegate { CopyAddress(); });
            menu.Items.Add("Open Hermes Gateways", null, delegate { OpenHermesGateways(); });
            menu.Items.Add("Open Tailscale", null, delegate { OpenTailscale(); });
            menu.Items.Add("Open logs", null, delegate { OpenLogs(); });
            menu.Items.Add("Open setup", null, delegate { OpenInstaller(); });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Exit indicator", null, delegate { ExitThread(); });
            panel = new ChromeForm(false) {
                Text = "Talaria", ShowInTaskbar = false, TopMost = true,
                StartPosition = FormStartPosition.Manual, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
                BackColor = palette.Surface, ForeColor = palette.Ink
            };
            var layout = new FlowLayoutPanel {
                AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, FlowDirection = FlowDirection.TopDown,
                WrapContents = false, Padding = new Padding(16, 8, 16, 16), Dock = DockStyle.Fill
            };
            panelStatus = PanelLabel("Checking", true);
            panelTime = PanelLabel("First check", false);
            panelDetail = PanelLabel("", false);
            panelNetwork = PanelLabel("", false);
            panelRecovery = PanelLabel("", false);
            panelNetwork.Visible = panelRecovery.Visible = false;
            layout.Controls.Add(panelStatus);
            layout.Controls.Add(PanelLabel(endpoint.GetLeftPart(UriPartial.Authority), false));
            layout.Controls.Add(panelTime);
            layout.Controls.Add(panelDetail);
            layout.Controls.Add(panelNetwork);
            layout.Controls.Add(panelRecovery);
            var refresh = new RoundedButton(palette, true) { Text = "Check now", Margin = new Padding(0, 10, 0, 0) };
            refresh.Click += delegate { VerifyNow(); };
            layout.Controls.Add(refresh);
            panel.Controls.Add(layout);
            panel.Controls.Add(panel.Caption(palette, "Talaria", panel.Hide));
            panel.AcceptButton = refresh;
            panel.Deactivate += delegate { panel.Hide(); };
            panel.KeyDown += delegate(object sender, KeyEventArgs e) { if (e.KeyCode == Keys.Escape) panel.Hide(); };
            panel.FormClosing += delegate(object sender, FormClosingEventArgs e) {
                if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; panel.Hide(); }
            };
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
                    new ProbeResult(ProbeKind.Failed, "The check could not finish.");
                pending = null;
                tracker.Apply(result);
                networkStatus = result.Network;
                nextProbe = probeStartedAt + TimeSpan.FromSeconds(tracker.CheckIntervalSeconds);
                RefreshIcon();
            }
            else if (!window.Registered && clock.Elapsed >= nextIconRetry)
            {
                PublishStatus();
            }
            if (pending == null && clock.Elapsed >= nextProbe)
            {
                probeStartedAt = clock.Elapsed;
                pending = Task.Factory.StartNew(delegate {
                    ProbeResult result = HealthProbe.Check(endpoint);
                    result.Network = HealthProbe.ReadTailscale(endpoint);
                    return result;
                });
            }
        }

        private void RefreshIcon()
        {
            panelStatus.Text = tracker.Label;
            panelTime.Text = tracker.CheckedAt.HasValue ? "Last checked " + tracker.CheckedAt.Value.ToString("HH:mm:ss") : "Running the first check";
            panelDetail.Text = tracker.Detail;
            panelNetwork.Text = networkStatus ?? "";
            panelNetwork.Visible = !String.IsNullOrEmpty(networkStatus);
            panelRecovery.Text = RecoveryMessage();
            panelRecovery.Visible = panelRecovery.Text.Length > 0;
            PublishStatus();
        }

        private string RecoveryMessage()
        {
            if (tracker.State == TrayState.Online || String.IsNullOrEmpty(logPath)) return "";
            try
            {
                string path = Path.Combine(Path.GetDirectoryName(logPath), "recovery.json");
                var data = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(path));
                object status, address;
                if (data == null || !data.TryGetValue("Endpoint", out address) || !Object.Equals(address, endpoint.GetLeftPart(UriPartial.Authority)) ||
                    !data.TryGetValue("State", out status)) return "";
                if (Object.Equals(status, "limited")) return "Automatic restart is waiting for the recovery limit.";
                if (Object.Equals(status, "restarting")) return "Restarting the Hermes server.";
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            catch (ArgumentException) { }
            catch (InvalidOperationException) { }
            return "";
        }

        private void OpenTailscale()
        {
            string path = HealthProbe.TailscaleApp("tailscale-ipn.exe");
            if (path != null)
            {
                try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); return; }
                catch (System.ComponentModel.Win32Exception) { }
            }
            ChromeForm.Prompt(palette, null, "Talaria", "Open Tailscale from the Windows Start menu or install it from Talaria Setup.", "OK", false);
        }

        private void OpenHermesGateways()
        {
            try
            {
                using (var protocol = Microsoft.Win32.Registry.ClassesRoot.OpenSubKey(@"hermes\shell\open\command"))
                    if (protocol != null && !String.IsNullOrWhiteSpace(protocol.GetValue(null) as string))
                    {
                        Process.Start(new ProcessStartInfo("hermes://open/settings?tab=gateway") { UseShellExecute = true });
                        return;
                    }
            }
            catch (System.ComponentModel.Win32Exception) { }

            if (!String.IsNullOrEmpty(desktopAppId) && System.Text.RegularExpressions.Regex.IsMatch(desktopAppId, @"^[\w.]+![\w.]+$"))
            {
                try { Process.Start(new ProcessStartInfo(@"shell:AppsFolder\" + desktopAppId) { UseShellExecute = true }); }
                catch (System.ComponentModel.Win32Exception) { }
                ChromeForm.Prompt(palette, null, "Talaria", "In Hermes Desktop, open Settings > Gateways to select your connection.", "OK", false);
                return;
            }

            if (!String.IsNullOrEmpty(desktopExe) && Path.IsPathRooted(desktopExe) &&
                String.Equals(Path.GetFileName(desktopExe), "Hermes.exe", StringComparison.OrdinalIgnoreCase) && File.Exists(desktopExe))
            {
                try { Process.Start(new ProcessStartInfo(desktopExe) { UseShellExecute = true }); }
                catch (System.ComponentModel.Win32Exception) { }
                ChromeForm.Prompt(palette, null, "Talaria", "In Hermes Desktop, open Settings > Gateways to select your connection.", "OK", false);
                return;
            }

            foreach (string menuRoot in new[] { Environment.GetFolderPath(Environment.SpecialFolder.Programs),
                Environment.GetFolderPath(Environment.SpecialFolder.CommonPrograms) })
            {
                string shortcut = Path.Combine(menuRoot, "Hermes.lnk");
                if (!File.Exists(shortcut)) continue;
                try { Process.Start(new ProcessStartInfo(shortcut) { UseShellExecute = true }); break; }
                catch (System.ComponentModel.Win32Exception) { }
            }
            ChromeForm.Prompt(palette, null, "Talaria", "In Hermes Desktop, open Settings > Gateways to select your connection.", "OK", false);
        }

        private void PublishStatus()
        {
            window.Display(tracker.State, "Talaria · " + tracker.Label + "\n" + endpoint.Authority);
            nextIconRetry = clock.Elapsed + TimeSpan.FromSeconds(2);
            Rectangle bounds;
            string json = new JavaScriptSerializer().Serialize(new
            {
                State = tracker.State.ToString(), tracker.Label, tracker.Detail, tracker.Failures,
                Network = networkStatus, Recovery = panelRecovery.Text,
                Endpoint = endpoint.GetLeftPart(UriPartial.Authority),
                CheckedAt = tracker.CheckedAt.HasValue ? tracker.CheckedAt.Value.ToString("o") : null,
                tracker.CheckIntervalSeconds,
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
                MinimumSize = new Size(245, 0), Margin = new Padding(0, 0, 0, 5), ForeColor = palette.Ink,
                Font = new Font("Segoe UI", title ? 15 : 10, title ? FontStyle.Bold : FontStyle.Regular) };
        }

        private void VerifyNow()
        {
            if (pending == null) nextProbe = TimeSpan.Zero;
            panelTime.Text = "Checking…";
        }

        private void CopyAddress()
        {
            try { Clipboard.SetText(endpoint.GetLeftPart(UriPartial.Authority)); }
            catch (ExternalException) { ChromeForm.Prompt(palette, null, "Talaria", "The clipboard is busy. Try again.", "OK", false); }
        }

        private void OpenInstaller()
        {
            try { Process.Start(new ProcessStartInfo(setupPath) { UseShellExecute = true }); }
            catch (Exception) { ChromeForm.Prompt(palette, null, "Talaria", "Open the downloaded setup to manage Talaria.", "OK", false); }
        }

        private void OpenLogs()
        {
            try { Process.Start(new ProcessStartInfo(File.Exists(logPath) ? logPath : Path.GetDirectoryName(logPath)) { UseShellExecute = true }); }
            catch (Exception) { ChromeForm.Prompt(palette, null, "Talaria", "Could not open the logs.", "OK", false); }
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
                if (!HealthProbe.IsSupportedEndpoint(endpoint))
                    throw new InvalidDataException("Use an HTTP IPv4 address or a Tailscale HTTPS URL.");

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
                        string desktopExe, desktopAppId;
                        config.TryGetValue("DesktopExe", out desktopExe);
                        config.TryGetValue("DesktopAppId", out desktopAppId);
                        using (TrayContext context = new TrayContext(endpoint, folder, config["RemoteLog"], setupPath, desktopExe, desktopAppId))
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
