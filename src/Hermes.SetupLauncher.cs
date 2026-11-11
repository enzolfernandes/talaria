using System;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Talaria.UI;

[assembly: AssemblyTitle("Talaria Setup")]
[assembly: AssemblyVersion("0.2.0.0")]

internal static class SetupLauncher
{
    private static readonly string[] Payload = {
        "Setup-Hermes.ps1", "Setup-Core.ps1", "Setup-Dependencies.ps1", "PortableSupervisor.ps1", "Hermes.ServerTray.exe"
    };

    [STAThread]
    private static int Main(string[] args)
    {
        bool server = args.Length == 1 && args[0] == "--server";
        try
        {
            if (server)
            {
                string folder = AppDomain.CurrentDomain.BaseDirectory;
                return RunPowerShell(folder, "PortableSupervisor.ps1", true);
            }
            if (args.Length != 0) return 2;

            bool created;
            using (Mutex setup = new Mutex(true, "Local\\Hermes.ServerSetup." + WindowsIdentity.GetCurrent().User.Value, out created))
            {
                if (!created) return 0;
                try { return RunSetup(); }
                finally { setup.ReleaseMutex(); }
            }
        }
        catch (Exception)
        {
            if (!server) ChromeForm.Prompt(new Palette("System"), null, "Talaria Setup", "Could not open Talaria Setup.", "OK", false);
            return 1;
        }
    }

    private static int RunSetup()
    {
        string folder = Path.Combine(Path.GetTempPath(), "HermesServidor-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        try
        {
            foreach (string file in Payload)
            using (Stream resource = Assembly.GetExecutingAssembly().GetManifestResourceStream(file))
            using (FileStream target = File.Create(Path.Combine(folder, file)))
                resource.CopyTo(target);
            File.Copy(Assembly.GetExecutingAssembly().Location, Path.Combine(folder, "Hermes.SetupLauncher.exe"));
            return RunPowerShell(folder, "Setup-Hermes.ps1", false);
        }
        finally
        {
            foreach (string file in Payload) File.Delete(Path.Combine(folder, file));
            File.Delete(Path.Combine(folder, "Hermes.SetupLauncher.exe"));
            Directory.Delete(folder, false);
        }
    }

    private static int RunPowerShell(string folder, string script, bool supervise)
    {
        string shell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell\\v1.0\\powershell.exe");
        string path = Path.Combine(folder, script);
        var command = new StringBuilder("\"" + shell + "\" -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File \"" + path + "\"");
        var startup = new StartupInfo { Size = (uint)Marshal.SizeOf(typeof(StartupInfo)), Flags = supervise ? 1u : 0u, Show = 0 };
        ProcessInfo process;
        const uint NewConsole = 0x10, Suspended = 0x4, NoConsole = 0x08000000;
        uint flags = supervise ? NewConsole | Suspended : NoConsole;
        if (!CreateProcess(shell, command, IntPtr.Zero, IntPtr.Zero, false,
            flags, IntPtr.Zero, folder, ref startup, out process))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());

        IntPtr job = IntPtr.Zero;
        try
        {
            if (supervise)
            {
                job = CreateJobObject(IntPtr.Zero, null);
                JobLimits limits = new JobLimits();
                limits.Basic.Flags = 0x2000; // Kill the supervised tree when the launcher exits.
                if (job == IntPtr.Zero || !SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf(typeof(JobLimits))) ||
                    !AssignProcessToJobObject(job, process.Process) || ResumeThread(process.Thread) == UInt32.MaxValue)
                {
                    TerminateProcess(process.Process, 1);
                    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                }
            }
            WaitForSingleObject(process.Process, UInt32.MaxValue);
            uint result;
            return GetExitCodeProcess(process.Process, out result) ? unchecked((int)result) : 1;
        }
        finally
        {
            if (job != IntPtr.Zero) CloseHandle(job);
            CloseHandle(process.Thread);
            CloseHandle(process.Process);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct StartupInfo
    {
        public uint Size;
        public IntPtr Reserved, Desktop, Title;
        public uint X, Y, Width, Height, CountX, CountY, Fill, Flags;
        public ushort Show, ReservedBytes;
        public IntPtr ReservedData, StandardInput, StandardOutput, StandardError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInfo { public IntPtr Process, Thread; public uint ProcessId, ThreadId; }

    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimits
    {
        public long PerProcessTime, PerJobTime;
        public uint Flags;
        public UIntPtr MinimumWorkingSet, MaximumWorkingSet;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobLimits
    {
        public BasicLimits Basic;
        public ulong ReadCount, WriteCount, OtherCount, ReadBytes, WriteBytes, OtherBytes;
        public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcess(string app, StringBuilder command, IntPtr processAttributes, IntPtr threadAttributes,
        bool inherit, uint flags, IntPtr environment, string directory, ref StartupInfo startup, out ProcessInfo process);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetInformationJobObject(IntPtr job, int kind, ref JobLimits limits, uint size);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll")] private static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll")] private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll")] private static extern bool GetExitCodeProcess(IntPtr handle, out uint code);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
}
