param(
    [string]$HermesHome = (Join-Path $env:LOCALAPPDATA 'hermes'),
    [string]$ListenAddress,
    [int]$Port = 9119,
    [int]$RetrySeconds = 30,
    [switch]$CheckOnly,
    [string]$LogDirectory,
    [string]$HermesExecutable,
    [string]$SettingsPath
)
$ErrorActionPreference = 'Stop'
if (!$SettingsPath -and $MyInvocation.MyCommand.Name -eq 'PortableSupervisor.ps1') {
    $SettingsPath = Join-Path $PSScriptRoot 'config.json'
}
if ($SettingsPath) {
    $settings = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
    if ($settings.OwnerSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) { throw 'The server is running under a different Windows account.' }
    $HermesHome = $settings.HermesHome
    $HermesExecutable = $settings.HermesExecutable
    $ListenAddress = $settings.Address
    $Port = [int]$settings.Port
    $LogDirectory = $settings.LogDirectory
    $parsed = $null
    if (![Net.IPAddress]::TryParse($ListenAddress,[ref]$parsed) -or $parsed.AddressFamily -ne 'InterNetwork' -or
        $Port -lt 1 -or $Port -gt 65535 -or ![IO.Path]::IsPathRooted($HermesHome) -or ![IO.Path]::IsPathRooted($HermesExecutable)) {
        throw 'Invalid server configuration.'
    }
}
if (!$HermesExecutable) { $HermesExecutable = Join-Path $HermesHome 'bin\hermes.exe' }
if (!$ListenAddress) { throw 'Specify the local server address.' }
if (!$LogDirectory) { $LogDirectory = Join-Path $HermesHome 'logs\remote-9119' }
New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Diagnostics;
using System.Threading;
using System.Net;
using System.Linq;
public static class HermesRemoteRunner {
    static readonly object Gate = new object();
    public static string LogPath;
    public static string[] Secrets = new string[0];
    public static bool RecoveryAllowed(DateTimeOffset now, DateTimeOffset[] previous) {
        return previous.Count(time => time > now.AddMinutes(-30)) < 3 &&
            !previous.Any(time => time > now.AddMinutes(-5));
    }
    public static void Log(string source, string text) {
        if (String.IsNullOrEmpty(text)) return;
        foreach(string secret in Secrets) if (!String.IsNullOrEmpty(secret)) text = text.Replace(secret, "[REDACTED]");
        text = Regex.Replace(text, @"(?i)(authorization\s*[:=]\s*|bearer\s+|(?:password|secret|access_token|session_token|ticket|token)\s*[:=]\s*)[^\s,;]+", "$1[REDACTED]");
        text = Regex.Replace(text, @"(https?://)[^/@\s]+:[^/@\s]+@", "$1[REDACTED]@");
        if (text.Length > 16384) text = text.Substring(0,16384) + " [truncated]";
        string line = DateTimeOffset.Now.ToString("o") + " [" + source + "] " + text + Environment.NewLine;
        lock (Gate) {
            if (File.Exists(LogPath) && new FileInfo(LogPath).Length + Encoding.UTF8.GetByteCount(line) > 5L*1024*1024) {
                if (File.Exists(LogPath+".4")) File.Delete(LogPath+".4");
                for (int i=3;i>=1;i--) if(File.Exists(LogPath+"."+i)) File.Move(LogPath+"."+i,LogPath+"."+(i+1));
                File.Move(LogPath,LogPath+".1");
            }
            File.AppendAllText(LogPath,line,new UTF8Encoding(false));
        }
    }
    public static bool HasTransportFailure(string endpoint) {
        var request = (HttpWebRequest)WebRequest.Create(endpoint + "/api/health");
        request.Proxy = null;
        request.AllowAutoRedirect = false;
        request.Timeout = 2500;
        request.ReadWriteTimeout = 2500;
        int expired = 0;
        using (var deadline = new Timer(_ => { Interlocked.Exchange(ref expired, 1); request.Abort(); }, null, 2500, Timeout.Infinite)) {
            try {
                using (var response = request.GetResponse())
                using (var body = response.GetResponseStream()) {
                    var buffer = new byte[4097];
                    for (int total = 0, read; total < buffer.Length; total += read) {
                        read = body.Read(buffer, total, buffer.Length - total);
                        if (read == 0) break;
                    }
                }
                return false;
            } catch (WebException error) {
                if (error.Response != null) { error.Response.Dispose(); return false; }
                return expired != 0 || error.Status == WebExceptionStatus.Timeout ||
                    error.Status == WebExceptionStatus.ConnectFailure || error.Status == WebExceptionStatus.ReceiveFailure ||
                    error.Status == WebExceptionStatus.ConnectionClosed;
            } catch (IOException) { return true; }
        }
    }
    public static bool Run(string exe, string args, string cwd, Func<int, bool> shouldRecover, int graceSeconds, int probeSeconds) {
        using (Process p = new Process()) {
            p.StartInfo = new ProcessStartInfo(exe,args) {
                WorkingDirectory=cwd, UseShellExecute=false,
                // Inherit the supervisor's console, created hidden by WScript.
                // Do not request a detached process or allocate a new console.
                CreateNoWindow=false, WindowStyle=ProcessWindowStyle.Hidden,
                RedirectStandardOutput=true, RedirectStandardError=true,
                RedirectStandardInput=true, StandardOutputEncoding=Encoding.UTF8,
                StandardErrorEncoding=Encoding.UTF8
            };
            p.OutputDataReceived += (s,e) => { if(e.Data!=null) Log("stdout",e.Data); };
            p.ErrorDataReceived += (s,e) => { if(e.Data!=null) Log("stderr",e.Data); };
            p.Start(); p.StandardInput.Close();
            Log("supervisor","Started CLI PID="+p.Id);
            p.BeginOutputReadLine(); p.BeginErrorReadLine();
            if (shouldRecover == null) p.WaitForExit();
            else if (!p.WaitForExit(graceSeconds * 1000)) {
                do {
                    if (shouldRecover(p.Id)) return true;
                } while (!p.WaitForExit(probeSeconds * 1000));
            }
            p.WaitForExit();
            Log("supervisor","CLI exited code="+p.ExitCode);
            return false;
        }
    }
}
'@
[HermesRemoteRunner]::LogPath = Join-Path $LogDirectory 'remote.log'
function Write-RemoteLog([string]$Message) { [HermesRemoteRunner]::Log('supervisor',$Message) }
function Test-RemoteLocalAddress {
    return [bool](Get-NetIPAddress -AddressFamily IPv4 -IPAddress $ListenAddress -ErrorAction SilentlyContinue |
        Where-Object AddressState -eq 'Preferred')
}

function Test-RemoteProcessTree([int]$ListenerId, [int]$RootId, [datetime]$RootStart) {
    for ($depth = 0; $ListenerId -and $depth -lt 16; $depth++) {
        $process = Get-CimInstance Win32_Process -Filter "ProcessId=$ListenerId" -ErrorAction SilentlyContinue
        if (!$process -or $process.CreationDate -lt $RootStart) { return $false }
        if ($ListenerId -eq $RootId) { return $true }
        $ListenerId = $process.ParentProcessId
    }
    return $false
}

function Write-RecoveryState([string]$State, [datetimeoffset[]]$Restarts) {
    $temp = "$recoveryFile.tmp"
    [IO.File]::WriteAllText($temp, (@{ State=$State; Endpoint=$endpoint; Restarts=@($Restarts | ForEach-Object { $_.ToString('o') }); UpdatedAt=[DateTimeOffset]::UtcNow.ToString('o') } | ConvertTo-Json -Compress))
    if (Test-Path -LiteralPath $recoveryFile) { [IO.File]::Replace($temp,$recoveryFile,[NullString]::Value) }
    else { [IO.File]::Move($temp,$recoveryFile) }
}

function Get-Readiness {
    if (!(Test-RemoteLocalAddress)) { return 'network-wait' }
    $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { $_.LocalPort -eq $Port })
    foreach ($listener in $listeners) {
        $p = Get-CimInstance Win32_Process -Filter ('ProcessId='+$listener.OwningProcess) -ErrorAction Stop
        $expected = $p -and $p.ExecutablePath -and $p.ExecutablePath.StartsWith($HermesHome+'\',[StringComparison]::OrdinalIgnoreCase) -and
            $p.CommandLine -match '(?i)(?:hermes_cli\.main|hermes\.exe|main\.py)' -and
            $p.CommandLine -match '(?i)\bserve\b' -and $p.CommandLine -match [regex]::Escape($ListenAddress) -and
            $p.CommandLine -match ('--port\s+'+$Port+'(?:\s|$)') -and $listener.LocalAddress -eq $ListenAddress
        if (!$expected) { return 'port-conflict' }
    }
    if ($listeners.Count) { return 'existing-server' }
    $pending = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
        $_.ExecutablePath -and $_.ExecutablePath.StartsWith($HermesHome+'\',[StringComparison]::OrdinalIgnoreCase) -and
        $_.CommandLine -match '(?i)\bserve\b' -and $_.CommandLine -match [regex]::Escape($ListenAddress) -and
        $_.CommandLine -match ('--port\s+'+$Port+'(?:\s|$)')
    })
    if ($pending.Count) { return 'server-starting' }
    return 'ready'
}
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$mutexName='Local\Hermes_Remote_'+$Port+'_'+$sid
if($CheckOnly){$mutexName+='_probe_'+$PID}
$mutex = [Threading.Mutex]::new($false,$mutexName)
$held = $false
try {
    try { $held=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held=$true }
    if (!$held) { Write-RemoteLog 'Another supervisor owns the mutex; exiting.'; exit 0 }
    $env:HERMES_HOME=$HermesHome
    $env:HERMES_NONINTERACTIVE='1'
    $env:PYTHONIOENCODING='utf-8'
    $env:PYTHONUTF8='1'
    $localAuth = if ($SettingsPath) { Join-Path (Split-Path $SettingsPath -Parent) 'credentials.local.json' }
    if ($settings -and ($settings.Auth -or ($localAuth -and (Test-Path -LiteralPath $localAuth)))) {
        Add-Type -AssemblyName System.Security
        function Unlock-LocalSecret([string]$Ciphertext) {
            $bytes = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Ciphertext), $null,
                [Security.Cryptography.DataProtectionScope]::CurrentUser)
            try { [Text.Encoding]::UTF8.GetString($bytes) } finally { [Array]::Clear($bytes, 0, $bytes.Length) }
        }
        if (Test-Path -LiteralPath $localAuth) {
            $auth = Get-Content -LiteralPath $localAuth -Raw | ConvertFrom-Json
            if ($auth.Version -ne 1) { throw 'Unrecognized local credentials format.' }
            $env:HERMES_DASHBOARD_BASIC_AUTH_USERNAME = Unlock-LocalSecret $auth.Username
        } else {
            $auth = $settings.Auth
            $env:HERMES_DASHBOARD_BASIC_AUTH_USERNAME = $auth.Username
        }
        $env:HERMES_DASHBOARD_BASIC_AUTH_PASSWORD = Unlock-LocalSecret $auth.Password
        $env:HERMES_DASHBOARD_BASIC_AUTH_SECRET = Unlock-LocalSecret $auth.SigningSecret
        [HermesRemoteRunner]::Secrets = @($env:HERMES_DASHBOARD_BASIC_AUTH_PASSWORD, $env:HERMES_DASHBOARD_BASIC_AUTH_SECRET)
    }
    Write-RemoteLog ('Supervisor started PID='+$PID+' address='+$ListenAddress+':'+$Port+' user='+[Security.Principal.WindowsIdentity]::GetCurrent().Name)
    $endpoint = "http://${ListenAddress}:$Port"
    $recoveryFile = Join-Path $LogDirectory 'recovery.json'
    $watchdog = if ($SettingsPath -and !$CheckOnly) {
        [Func[int,bool]]{
            param([int]$rootId)
            try {
                if (!(Test-RemoteLocalAddress) -or ![HermesRemoteRunner]::HasTransportFailure($endpoint)) {
                    $script:failedChecks = 0
                    if ($script:recoveryState -eq 'limited') {
                        Write-RecoveryState 'monitoring' $script:restarts
                        $script:recoveryState = 'monitoring'
                    }
                    return $false
                }
                $script:failedChecks = [Math]::Min(3,$script:failedChecks + 1)
                if ($script:failedChecks -lt 3) { return $false }
                $root = Get-CimInstance Win32_Process -Filter "ProcessId=$rootId" -ErrorAction SilentlyContinue
                if (!$root -or $root.ParentProcessId -ne $PID -or $root.ExecutablePath -ine $HermesExecutable) { return $false }
                $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
                foreach ($listener in $listeners) {
                    if ($listener.LocalAddress -ne $ListenAddress -or !(Test-RemoteProcessTree $listener.OwningProcess $rootId $root.CreationDate)) {
                        $script:failedChecks = 0
                        Write-RemoteLog 'Watchdog deferred: port is occupied outside the supervised server tree.'
                        return $false
                    }
                }
                if (!(Test-RemoteLocalAddress)) { $script:failedChecks = 0; return $false }
                if (![HermesRemoteRunner]::HasTransportFailure($endpoint)) { $script:failedChecks = 0; return $false }
                $now = [DateTimeOffset]::UtcNow
                $script:restarts = @($script:restarts | Where-Object { $_ -gt $now.AddMinutes(-30) })
                if (![HermesRemoteRunner]::RecoveryAllowed($now,$script:restarts)) {
                    if ($script:recoveryState -ne 'limited') {
                        Write-RecoveryState 'limited' $script:restarts
                        $script:recoveryState = 'limited'
                        Write-RemoteLog 'Watchdog delayed by the automatic recovery limit.'
                    }
                    return $false
                }
                $script:restarts += $now
                Write-RecoveryState 'restarting' $script:restarts
                Write-RemoteLog 'Watchdog restarting the managed task after three transport failures.'
                return $true
            } catch {
                $script:failedChecks = 0
                Write-RemoteLog ('Watchdog deferred: '+$_.Exception.Message)
                return $false
            }
        }
    }
    $script:restarts = @()
    if ($watchdog -and (Test-Path -LiteralPath $recoveryFile)) {
        try {
            $saved = Get-Content -LiteralPath $recoveryFile -Raw | ConvertFrom-Json
            if ($saved.Endpoint -eq $endpoint) { $script:restarts = @($saved.Restarts | ForEach-Object { [DateTimeOffset]::Parse($_) }) }
        } catch {
            $script:restarts = @([DateTimeOffset]::UtcNow)
            Write-RemoteLog 'Recovery history was unreadable. Automatic restart will wait at least five minutes.'
        }
    }
    $previous=''
    do {
        try {
            $state=Get-Readiness
            if($state -ne $previous) { Write-RemoteLog ('Readiness='+$state); $previous=$state }
            if($CheckOnly) { Write-Output $state; break }
            if($state -eq 'ready') {
                $exe=$HermesExecutable
                if(!(Test-Path -LiteralPath $exe)){throw 'Hermes CLI executable missing'}
                $script:failedChecks = 0
                $script:recoveryState = 'monitoring'
                if ($watchdog) { Write-RecoveryState 'monitoring' $script:restarts }
                if ([HermesRemoteRunner]::Run($exe,('serve --host '+$ListenAddress+' --port '+$Port),$HermesHome,$watchdog,180,15)) {
                    # The launcher closes the job and starts a fresh supervisor after the retry delay.
                    exit 75
                }
                $previous=''
            }
        } catch {
            Write-RemoteLog ('Retryable error: '+$_.Exception.Message)
            if($CheckOnly){throw}
        }
        if(!$CheckOnly){Write-RemoteLog ('Retry/check in '+$RetrySeconds+' seconds');Start-Sleep -Seconds $RetrySeconds}
    } while(!$CheckOnly)
} finally {
    if($held){$mutex.ReleaseMutex()}
    $mutex.Dispose()
}
