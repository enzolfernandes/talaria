$ErrorActionPreference = 'Stop'
$script:Payload = $PSScriptRoot
$script:SetupRoot = Join-Path $env:LOCALAPPDATA 'HermesServidor'
$script:TrayDir = Join-Path $env:LOCALAPPDATA 'hermes\server-tray'
$script:ServerDir = Join-Path $script:SetupRoot 'server'
$script:TrayTask = 'Hermes_Remote_Tray'
$script:Account = [Security.Principal.WindowsIdentity]::GetCurrent()
$script:Pending = Join-Path $script:SetupRoot 'pending.json'

function Invoke-SetupCommand([string]$Exe, [string]$Arguments, [int]$Seconds = 8) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Exe
    $start.Arguments = $Arguments
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    try {
        $output = $process.StandardOutput.ReadToEndAsync()
        $errorOutput = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit($Seconds * 1000)) {
            $process.Kill()
            return $null
        }
        if ($process.ExitCode -eq 0 -and $output.Wait(2000)) { return $output.Result }
    } finally { $process.Dispose() }
}

function Get-ExeCandidate([string]$Command, [string[]]$Paths) {
    foreach ($path in $Paths) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { return (Resolve-Path -LiteralPath $path).Path }
    }
    if ($Command) {
        $entry = Get-Command $Command -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($entry) { return $entry.Source }
    }
}

function Get-HermesInstall([string]$ExeOverride, [string]$DataOverride) {
    $standard = Join-Path $env:LOCALAPPDATA 'hermes'
    $userSetting = [Environment]::GetEnvironmentVariable('HERMES_HOME', 'User')
    $configured = @($env:HERMES_HOME, $userSetting) | Where-Object { $_ -and [IO.Path]::IsPathRooted($_) } | Select-Object -First 1
    $candidates = @()
    if ($configured) { $candidates += Join-Path $configured 'bin\hermes.exe' }
    $candidates += Join-Path $standard 'bin\hermes.exe'
    if ($ExeOverride) { $exe = Get-ExeCandidate '' @($ExeOverride) }
    else { $exe = Get-ExeCandidate 'hermes.exe' $candidates }
    if (!$exe) { return @{ Code='Missing'; Message='Hermes was not found.' } }

    $parent = Split-Path $exe -Parent
    $inferred = if ((Split-Path $parent -Leaf) -eq 'bin') { Split-Path $parent -Parent } else { $null }
    $legacy = Join-Path $env:USERPROFILE '.hermes'
    if ($DataOverride) { $roots = @($DataOverride) }
    elseif ($ExeOverride) { $roots = @($inferred, $configured, $standard, $legacy) }
    else { $roots = @($configured, $inferred, $standard, $legacy) }
    foreach ($directory in $roots) {
        if (!$directory -or !(Test-Path -LiteralPath $directory -PathType Container)) { continue }
        if ($directory -eq $DataOverride -or (Test-Path -LiteralPath (Join-Path $directory 'config.yaml')) -or
            (Test-Path -LiteralPath (Join-Path $directory '.env')) -or
            (Test-Path -LiteralPath (Join-Path $directory 'bin\hermes.exe'))) {
            return @{ Code='Ready'; Exe=$exe; Data=(Resolve-Path -LiteralPath $directory).Path; Message='Hermes found.' }
        }
    }
    return @{ Code='MissingData'; Exe=$exe; Message='Select the Hermes data folder.' }
}

function Test-LocalSetupAddress([string]$Address) {
    $ip = $null
    if (![Net.IPAddress]::TryParse($Address,[ref]$ip) -or $ip.AddressFamily -ne 'InterNetwork') { return $false }
    $bytes = $ip.GetAddressBytes()
    if ($bytes[0] -ne 100 -or $bytes[1] -lt 64 -or $bytes[1] -gt 127) { return $false }
    foreach ($adapter in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($adapter.OperationalStatus -ne 'Up') { continue }
        foreach ($item in $adapter.GetIPProperties().UnicastAddresses) {
            if ($item.Address.Equals($ip)) { return $true }
        }
    }
    return $false
}

function Get-TailscaleInstall {
    $candidates = @()
    foreach ($directory in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($directory) { $candidates += Join-Path $directory 'Tailscale\tailscale.exe' }
    }
    $exe = Get-ExeCandidate 'tailscale.exe' $candidates
    if (!$exe) { return @{ Code='Missing'; Message='Tailscale was not found.' } }
    $app = Join-Path (Split-Path $exe -Parent) 'tailscale-ipn.exe'
    if (!(Test-Path -LiteralPath $app -PathType Leaf)) { $app = $null }
    try {
        $raw = Invoke-SetupCommand $exe 'status --json'
        if ($raw) {
            $json = $raw | ConvertFrom-Json
            if ($json.BackendState -eq 'Running') {
                foreach ($address in @($json.TailscaleIPs)) {
                    if (Test-LocalSetupAddress $address) {
                        return @{ Code='Ready'; Exe=$exe; App=$app; Address=$address; Message="Tailscale connected at $address." }
                    }
                }
            }
        }
    } catch { }
    return @{ Code='Disconnected'; Exe=$exe; App=$app; Message='Open Tailscale, then sign in or reconnect.' }
}

function Invoke-LocalHermesRequest([string]$Endpoint, [string]$Path, [Net.CookieContainer]$Cookies, [string]$Body) {
    $request = [Net.HttpWebRequest][Net.WebRequest]::Create($Endpoint + $Path)
    $request.Proxy = $null
    $request.AllowAutoRedirect = $false
    $request.Timeout = 2500
    $request.ReadWriteTimeout = 2500
    $request.MaximumResponseHeadersLength = 16
    $request.Accept = 'application/json'
    if ($Cookies) { $request.CookieContainer = $Cookies }
    $response = $null
    try {
        if ($null -ne $Body -and $Body.Length -gt 0) {
            $request.Method = 'POST'
            $request.ContentType = 'application/json; charset=utf-8'
            $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
            try {
                $request.ContentLength = $bytes.Length
                $stream = $request.GetRequestStream()
                try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
            } finally { [Array]::Clear($bytes, 0, $bytes.Length) }
        }
        $response = $request.GetResponse()
        $code = [int]$response.StatusCode
        $data = $null
        if ($response.ContentType -match 'application/json') {
            $reader = New-Object IO.StreamReader($response.GetResponseStream(), [Text.Encoding]::UTF8)
            try {
                $buffer = New-Object char[] 16385
                $count = $reader.ReadBlock($buffer, 0, $buffer.Length)
                if ($count -gt 0 -and $count -lt $buffer.Length) {
                    try { $data = [string]::new($buffer, 0, $count) | ConvertFrom-Json } catch { }
                }
            } finally { $reader.Dispose() }
        }
        return @{ Code=$code; Data=$data }
    } catch {
        for ($exception = $_.Exception; $exception; $exception = $exception.InnerException) {
            if ($exception -is [Net.WebException] -and $exception.Response) {
                $response = $exception.Response
                return @{ Code=[int]$response.StatusCode; Data=$null }
            }
        }
        return @{ Code=0; Data=$null }
    } finally { if ($response) { $response.Dispose() } }
}

function Test-HermesEndpoint([string]$Endpoint) {
    $health = Invoke-LocalHermesRequest $Endpoint '/api/health'
    if ($health.Code -ne 200 -or $health.Data.ok -isnot [bool] -or !$health.Data.ok -or !$health.Data.version) {
        return @{ Code='Unavailable'; Message='Hermes did not respond to the health check.' }
    }
    if ($health.Data.auth_required -isnot [bool] -or !$health.Data.auth_required) {
        return @{ Code='Unprotected'; Message='The server responded. Configure authentication before enabling access.' }
    }
    $providers = Invoke-LocalHermesRequest $Endpoint '/api/auth/providers'
    if ($providers.Code -ne 200 -or !@($providers.Data.providers | Where-Object { $_.name }).Count) {
        return @{ Code='NoProvider'; Message='Hermes has no sign-in provider configured.' }
    }
    $anonymous = Invoke-LocalHermesRequest $Endpoint '/api/auth/me'
    if ($anonymous.Code -notin @(401,403)) {
        return @{ Code='Unprotected'; Message='The server failed the anonymous access check.' }
    }
    return @{ Code='Ready'; Version=[string]$health.Data.version; Message="Hermes $($health.Data.version) is responding with sign-in protection." }
}

function Test-NewHermesLogin([string]$Endpoint, [string]$Username, [string]$Password) {
    $cookies = New-Object Net.CookieContainer
    $body = @{ provider='basic'; username=$Username; password=$Password } | ConvertTo-Json -Compress
    $verified = $false
    $signedOut = $false
    try {
        $login = Invoke-LocalHermesRequest $Endpoint '/auth/password-login' $cookies $body
        if ($login.Code -eq 200 -and $login.Data.ok) {
            $identity = Invoke-LocalHermesRequest $Endpoint '/api/auth/me' $cookies
            $verified = $identity.Code -eq 200 -and $identity.Data.provider -eq 'basic'
        }
    } finally {
        $logout = Invoke-LocalHermesRequest $Endpoint '/auth/logout' $cookies '{}'
        $signedOut = $logout.Code -in @(200,204,302,303)
        $body = $null
    }
    return $verified -and $signedOut -and (Invoke-LocalHermesRequest $Endpoint '/api/auth/me' $cookies).Code -in @(401,403)
}

function Get-SetupTask([string]$Name) {
    Get-ScheduledTask -TaskName $Name -TaskPath '\' -ErrorAction SilentlyContinue
}

function Resolve-SetupSid([string]$Identity) {
    if (!$Identity) { return $null }
    if ($identity -match '^S-1-') { return $identity }
    try { return ([Security.Principal.NTAccount]::new($identity)).Translate([Security.Principal.SecurityIdentifier]).Value }
    catch { return $null }
}

function Test-SetupTask($Task, [string]$Exe, [string]$Arguments = '') {
    return $Task -and @($Task.Actions).Count -eq 1 -and $Task.Actions[0].Execute -ieq $Exe -and
        ([string]$Task.Actions[0].Arguments).Trim() -eq $Arguments -and
        (Resolve-SetupSid $Task.Principal.UserId) -eq $script:Account.User.Value -and
        [string]$Task.Principal.RunLevel -eq 'Limited' -and [string]$Task.Principal.LogonType -eq 'Interactive'
}

function Test-SetupSchedule($Task) {
    if (!$Task -or @($Task.Triggers).Count -ne 1) { return $false }
    $trigger = $Task.Triggers[0]
    return $trigger.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' -and $trigger.Enabled -and
        (Resolve-SetupSid $trigger.UserId) -eq $script:Account.User.Value -and
        $Task.Settings.Enabled -and !$Task.Settings.DisallowStartIfOnBatteries -and !$Task.Settings.StopIfGoingOnBatteries -and
        $Task.Settings.ExecutionTimeLimit -eq 'PT0S' -and [int]$Task.Settings.MultipleInstances -eq 2
}

function Register-SetupTask([string]$Name, [string]$Exe, [string]$Arguments, [string]$Description, [int]$Delay, [bool]$Replace = $false) {
    if ($Arguments) { $action = New-ScheduledTaskAction -Execute $Exe -Argument $Arguments -WorkingDirectory (Split-Path $Exe -Parent) }
    else { $action = New-ScheduledTaskAction -Execute $Exe -WorkingDirectory (Split-Path $Exe -Parent) }
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $script:Account.Name
    $trigger.Delay = 'PT' + $Delay + 'S'
    $principal = New-ScheduledTaskPrincipal -UserId $script:Account.Name -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $Name -TaskPath '\' -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Description $Description -Force:$Replace -ErrorAction Stop | Out-Null
}

function Stop-SetupTask([string]$Name) {
    if ((Get-SetupTask $Name).State -eq 'Running') {
        Stop-ScheduledTask -TaskName $Name -TaskPath '\'
        $deadline = [DateTime]::UtcNow.AddSeconds(8)
        while ((Get-SetupTask $Name).State -eq 'Running' -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 200 }
        if ((Get-SetupTask $Name).State -eq 'Running') { throw [ApplicationException]::new('The scheduled task could not be stopped safely.') }
    }
}

function Write-SetupJson([string]$Path, $Object) {
    $temporary = $Path + '.tmp'
    [IO.File]::WriteAllText($temporary, ($Object | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
    else { [IO.File]::Move($temporary, $Path) }
}

function Start-SetupTransaction([string]$Name, [string]$Exe, [string]$Arguments, [string[]]$Files, [bool]$FilesOnly = $false) {
    if (Test-Path -LiteralPath $script:Pending) { throw [ApplicationException]::new('A previous operation is waiting for recovery.') }
    $directory = Join-Path (Join-Path $script:SetupRoot 'backups') ([DateTime]::Now.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $task = Get-SetupTask $Name
    if ($task -and !(Test-SetupTask $task $Exe $Arguments)) { throw [ApplicationException]::new('The existing scheduled task belongs to a different setup.') }
    if ($task -and !$FilesOnly) {
        Export-ScheduledTask -TaskName $Name -TaskPath '\' | Set-Content -LiteralPath (Join-Path $directory 'task.xml') -Encoding Unicode
    }
    $index = 0
    $records = foreach ($path in $Files) {
        $copy = 'file-' + (++$index)
        $exists = Test-Path -LiteralPath $path -PathType Leaf
        if ($exists) { Copy-Item -LiteralPath $path -Destination (Join-Path $directory $copy) }
        @{ Path=$path; Copy=$copy; Existed=$exists }
    }
    $transaction = @{ Name=$Name; Exe=$Exe; Arguments=$Arguments; Backup=$directory; Files=@($records); HadTask=[bool]$task; WasRunning=($task.State -eq 'Running'); FilesOnly=$FilesOnly }
    Write-SetupJson $script:Pending $transaction
    return $transaction
}

function Complete-SetupTransaction {
    Remove-Item -LiteralPath $script:Pending -Force
}

function Undo-SetupTransaction {
    if (!(Test-Path -LiteralPath $script:Pending -PathType Leaf)) { return }
    $journal = Get-Content -LiteralPath $script:Pending -Raw | ConvertFrom-Json
    if ($journal.Name -ne $script:TrayTask -and $journal.Name -notmatch '^Hermes_Remote_\d{1,5}$') { throw [ApplicationException]::new('Invalid recovery record.') }
    $expectedExe = if ($journal.Name -eq $script:TrayTask) { Join-Path $script:TrayDir 'Hermes.ServerTray.exe' }
        else { Join-Path $script:ServerDir 'Hermes.SetupLauncher.exe' }
    $expectedArgs = if ($journal.Name -eq $script:TrayTask) { '' } else { '--server' }
    if ($journal.Exe -ine $expectedExe -or $journal.Arguments -ne $expectedArgs) { throw [ApplicationException]::new('Invalid recovery executable.') }
    $allowedFiles = @(
        (Join-Path $script:TrayDir 'Hermes.ServerTray.exe'),(Join-Path $script:TrayDir 'config.json'),
        (Join-Path $script:ServerDir 'Hermes.SetupLauncher.exe'),(Join-Path $script:ServerDir 'PortableSupervisor.ps1'),
        (Join-Path $script:ServerDir 'config.json'),(Join-Path $script:ServerDir 'credentials.local.json'),
        (Join-Path $script:SetupRoot 'Instalar-Talaria.exe')
    )
    $backupRoot = [IO.Path]::GetFullPath((Join-Path $script:SetupRoot 'backups')) + '\'
    if (![IO.Path]::GetFullPath($journal.Backup).StartsWith($backupRoot, [StringComparison]::OrdinalIgnoreCase)) { throw [ApplicationException]::new('The backup is outside the expected folder.') }
    foreach ($record in $journal.Files) {
        if ($record.Path -notin $allowedFiles -or $record.Copy -notmatch '^file-\d+$') { throw [ApplicationException]::new('Invalid recovery file.') }
    }
    $task = Get-SetupTask $journal.Name
    if ($task -and !$journal.FilesOnly) {
        if (!(Test-SetupTask $task $journal.Exe $journal.Arguments)) { throw [ApplicationException]::new('The scheduled task changed during setup. The backup was kept.') }
        Stop-SetupTask $journal.Name
        Unregister-ScheduledTask -TaskName $journal.Name -TaskPath '\' -Confirm:$false
    }
    foreach ($record in $journal.Files) {
        if ($record.Existed) {
            New-Item -ItemType Directory -Path (Split-Path $record.Path -Parent) -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $journal.Backup $record.Copy) -Destination $record.Path -Force
        } elseif (Test-Path -LiteralPath $record.Path -PathType Leaf) { Remove-Item -LiteralPath $record.Path -Force }
    }
    if ($journal.HadTask -and !$journal.FilesOnly) {
        $xml = Get-Content -LiteralPath (Join-Path $journal.Backup 'task.xml') -Raw
        Register-ScheduledTask -TaskName $journal.Name -TaskPath '\' -Xml $xml -Force | Out-Null
        if ($journal.WasRunning) {
            $wasDisabled = !(Get-SetupTask $journal.Name).Settings.Enabled
            if ($wasDisabled) { Enable-ScheduledTask -TaskName $journal.Name -TaskPath '\' | Out-Null }
            try { Start-ScheduledTask -TaskName $journal.Name -TaskPath '\' }
            finally { if ($wasDisabled) { Disable-ScheduledTask -TaskName $journal.Name -TaskPath '\' | Out-Null } }
        }
    }
    Complete-SetupTransaction
}

function Get-ManagedServer {
    $path = Join-Path $script:ServerDir 'config.json'
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return }
    $data = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($data.OwnerSid -eq $script:Account.User.Value -and $data.Task -match '^Hermes_Remote_\d{1,5}$') { return $data }
}

function Find-SetupPort([string]$Address, [int]$Port) {
    $existing = Get-ManagedServer
    if ($existing) { return [int]$existing.Port }
    $tray = Join-Path $script:TrayDir 'config.json'
    if (Test-Path -LiteralPath $tray -PathType Leaf) {
        try {
            $uri = [uri]((Get-Content -LiteralPath $tray -Raw | ConvertFrom-Json).Endpoint)
            if ($uri.Host -eq $Address) { return $uri.Port }
        } catch { }
    }
    foreach ($listener in @(Get-NetTCPConnection -LocalAddress $Address -State Listen -ErrorAction SilentlyContinue)) {
        $process = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $listener.OwningProcess) -ErrorAction SilentlyContinue
        if ($process.CommandLine -match '(?i)\bserve\b' -and $process.CommandLine -match '(?i)hermes') { return [int]$listener.LocalPort }
    }
    return $Port
}

function Get-SetupDiagnosis([string]$ExeOverride, [string]$DataOverride, [int]$Port, [bool]$SuggestPort) {
    $hermes = Get-HermesInstall $ExeOverride $DataOverride
    $tailscale = Get-TailscaleInstall
    $server = @{ Code='Pending'; Message='Complete the Hermes and Tailscale checks.' }
    $endpoint = $null
    if ($tailscale.Code -eq 'Ready') {
        if ($SuggestPort) { $Port = Find-SetupPort $tailscale.Address $Port }
        $endpoint = 'http://' + $tailscale.Address + ':' + $Port
        if ($hermes.Code -eq 'Ready') {
            $server = Test-HermesEndpoint $endpoint
            if ($server.Code -eq 'Unavailable') {
                $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($listener) {
                    $process = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
                    $server = @{ Code='Conflict'; Message="Port $Port is in use by $($process.ProcessName) (PID $($listener.OwningProcess)). Choose another port or check the existing server." }
                }
            }
        }
    }
    $trayExe = Join-Path $script:TrayDir 'Hermes.ServerTray.exe'
    return @{ Hermes=$hermes; Tailscale=$tailscale; Server=$server; Endpoint=$endpoint; Port=$Port;
        HasTray=(Test-SetupTask (Get-SetupTask $script:TrayTask) $trayExe); ManagedServer=[bool](Get-ManagedServer) }
}

function Protect-SetupSecret([string]$Value) {
    Add-Type -AssemblyName System.Security
    $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    try {
        $encrypted = [Security.Cryptography.ProtectedData]::Protect($bytes, $null,
            [Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [Convert]::ToBase64String($encrypted)
    } finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function New-SetupAuth([string]$Username, [string]$Password) {
    if ($Username -notmatch '^[a-zA-Z0-9_.@-]{1,64}$' -or $Password.Length -lt 12 -or $Password.Length -gt 256 -or
        $Password -match '[\r\n\x00]' -or $Password -cne $Password.Trim()) {
        throw [ApplicationException]::new('Use a simple username and a password of 12 to 256 characters without leading or trailing spaces.')
    }
    $key = New-Object byte[] 32
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $random.GetBytes($key)
        return @{ Version=1; Username=(Protect-SetupSecret $Username); Password=(Protect-SetupSecret $Password); SigningSecret=(Protect-SetupSecret ([Convert]::ToBase64String($key))) }
    } finally { [Array]::Clear($key, 0, $key.Length); $random.Dispose() }
}

function Get-SetupServerFiles {
    @('Hermes.SetupLauncher.exe','PortableSupervisor.ps1','config.json','credentials.local.json') | ForEach-Object { Join-Path $script:ServerDir $_ }
}

function Convert-SetupLegacyAuth($Auth) {
    if (!$Auth.Username -or !$Auth.Password -or !$Auth.SigningSecret) { throw [ApplicationException]::new('The previous credentials are incomplete. Check the server sign-in settings.') }
    return @{ Version=1; Username=(Protect-SetupSecret $Auth.Username); Password=$Auth.Password; SigningSecret=$Auth.SigningSecret }
}

function Update-SetupCredentials([string]$Endpoint) {
    $managed = Get-ManagedServer
    if (!$managed -or !$managed.Auth) { return }
    if ($Endpoint -ne ('http://' + $managed.Address + ':' + $managed.Port)) { return }
    $credentials = Join-Path $script:ServerDir 'credentials.local.json'
    $config = Join-Path $script:ServerDir 'config.json'
    $supervisor = Join-Path $script:ServerDir 'PortableSupervisor.ps1'
    $exe = Join-Path $script:ServerDir 'Hermes.SetupLauncher.exe'
    if (!(Test-SetupTask (Get-SetupTask $managed.Task) $exe '--server')) { throw [ApplicationException]::new('The previous server task does not match the saved configuration.') }
    if (Test-Path -LiteralPath $credentials) { throw [ApplicationException]::new('Two sign-in configurations were found. Check the local files before running repair.') }
    $separated = Convert-SetupLegacyAuth $managed.Auth
    $null = Start-SetupTransaction $managed.Task $exe '--server' @($credentials,$config,$supervisor) $true
    try {
        Write-SetupJson $credentials $separated
        Copy-Item -LiteralPath (Join-Path $script:Payload 'PortableSupervisor.ps1') -Destination $supervisor -Force
        $managed.PSObject.Properties.Remove('Auth')
        Write-SetupJson $config $managed
        if ((Test-HermesEndpoint $Endpoint).Code -ne 'Ready') { throw [ApplicationException]::new('The server stopped responding during repair. The previous configuration will be restored.') }
        Complete-SetupTransaction
    } catch { Undo-SetupTransaction; throw }
}

function Start-SetupServer([string]$ExeOverride, [string]$DataOverride, [int]$Port, [string]$Username, [string]$Password) {
    $diagnosis = Get-SetupDiagnosis $ExeOverride $DataOverride $Port $false
    if ($diagnosis.Server.Code -eq 'Ready') { return @{ Code='Ready'; Message='The existing healthy server was reused.' } }
    if ($diagnosis.Hermes.Code -ne 'Ready' -or $diagnosis.Tailscale.Code -ne 'Ready') { throw [ApplicationException]::new('Complete the checks before setting up the server.') }
    if ($diagnosis.Server.Code -ne 'Unavailable') { throw [ApplicationException]::new($diagnosis.Server.Message) }

    $version = Invoke-SetupCommand $diagnosis.Hermes.Exe '--version' 25
    if ($version -notmatch '(?i)Hermes(?: Agent)?\s+v?(\d+\.\d+\.\d+)' -or [version]$Matches[1] -lt [version]'0.23.0') {
        throw [ApplicationException]::new('Setting up a new server requires Hermes Agent 0.23.0 or later with hermes serve support.')
    }
    $name = 'Hermes_Remote_' + $Port
    $exe = Join-Path $script:ServerDir 'Hermes.SetupLauncher.exe'
    $managed = Get-ManagedServer
    if ($managed -and ($managed.Task -ne $name -or $managed.Address -ne $diagnosis.Tailscale.Address -or
        $managed.HermesHome -ne $diagnosis.Hermes.Data -or $managed.HermesExecutable -ne $diagnosis.Hermes.Exe)) {
        throw [ApplicationException]::new('A Talaria server setup already exists. Use its original address or revert the setup before changing it.')
    }
    $otherTasks = @(Get-ScheduledTask -TaskPath '\' | Where-Object { $_.TaskName -match '^Hermes_Remote_\d{1,5}$' -and $_.TaskName -ne $name })
    if ($otherTasks.Count) { throw [ApplicationException]::new('A Hermes server task already uses a different port. Use that port to avoid starting a duplicate server.') }
    $currentTask = Get-SetupTask $name
    if ($currentTask -and (!$managed -or !(Test-SetupTask $currentTask $exe '--server'))) {
        throw [ApplicationException]::new('An existing server task was created outside Talaria. Start it from Task Scheduler and check again.')
    }
    $credentialPath = Join-Path $script:ServerDir 'credentials.local.json'
    $auth = if ($Password) { New-SetupAuth $Username $Password }
        elseif ($managed -and !(Test-Path -LiteralPath $credentialPath) -and $managed.Auth) { Convert-SetupLegacyAuth $managed.Auth }
        else { $null }
    $logDirectory = Join-Path (Join-Path $script:SetupRoot 'logs') ([Guid]::NewGuid().ToString('N'))
    $logPath = Join-Path $logDirectory 'remote.log'
    $transaction = Start-SetupTransaction $name $exe '--server' (Get-SetupServerFiles)
    try {
        Stop-SetupTask $name
        New-Item -ItemType Directory -Path $script:ServerDir -Force | Out-Null
        foreach ($file in @('Hermes.SetupLauncher.exe','PortableSupervisor.ps1')) {
            Copy-Item -LiteralPath (Join-Path $script:Payload $file) -Destination (Join-Path $script:ServerDir $file) -Force
        }
        if ($auth) { Write-SetupJson $credentialPath $auth }
        Write-SetupJson (Join-Path $script:ServerDir 'config.json') @{
            OwnerSid=$script:Account.User.Value; Task=$name; HermesHome=$diagnosis.Hermes.Data;
            HermesExecutable=$diagnosis.Hermes.Exe; Address=$diagnosis.Tailscale.Address; Port=$Port;
            LogDirectory=$logDirectory
        }
        if (!(Test-SetupSchedule $currentTask)) { Register-SetupTask $name $exe '--server' 'Hermes server on Tailscale' 30 ([bool]$currentTask) }
        Enable-ScheduledTask -TaskName $name -TaskPath '\' | Out-Null
        Start-ScheduledTask -TaskName $name -TaskPath '\'

        $deadline = [DateTime]::UtcNow.AddSeconds(55)
        do {
            $probe = Test-HermesEndpoint $diagnosis.Endpoint
            if ($probe.Code -eq 'Ready') {
                if ($Password -and !(Test-NewHermesLogin $diagnosis.Endpoint $Username $Password)) {
                    throw [ApplicationException]::new('The new sign-in test failed. If .env already contains sign-in settings, check the authentication guide and try again.')
                }
                if (!(Test-OwnedServerListener $Port $diagnosis.Tailscale.Address $exe)) {
                    throw [ApplicationException]::new('The address responded, but the process listening on the port belongs to a different task. The previous configuration was kept.')
                }
                Complete-SetupTransaction
                return @{ Code='Ready'; Message='Server started and authentication verified.' }
            }
            if ($probe.Code -eq 'Unprotected') { throw [ApplicationException]::new($probe.Message) }
            $missingLogin = $probe.Code -eq 'NoProvider'
            if (!$missingLogin -and (Test-Path -LiteralPath $logPath)) {
                $missingLogin = [bool](Get-Content -LiteralPath $logPath -Tail 25 -ErrorAction SilentlyContinue |
                    Select-String -Pattern 'always requires an auth provider|no auth providers registered')
            }
            if ($missingLogin) {
                if ($Password) { throw [ApplicationException]::new('Hermes rejected the new sign-in provider. Check the server diagnosis.') }
                Undo-SetupTransaction
                return @{ Code='NeedsLogin'; Message='Set up a username and password to enable access over Tailscale.' }
            }
            Start-Sleep -Milliseconds 750
        } while ([DateTime]::UtcNow -lt $deadline)
        throw [ApplicationException]::new("The server did not become ready. Check the log at $logPath.")
    } catch {
        Undo-SetupTransaction
        throw
    } finally { $Password = $null }
}

function Test-OwnedServerListener([int]$Port, [string]$Address, [string]$Launcher) {
    $listeners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalAddress -in @($Address,'0.0.0.0','::') })
    if ($listeners.Count -ne 1 -or $listeners[0].LocalAddress -ne $Address) { return $false }
    $pidToCheck = $listeners[0].OwningProcess
    for ($depth = 0; $pidToCheck -and $depth -lt 10; $depth++) {
        $process = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $pidToCheck) -ErrorAction SilentlyContinue
        if ($process.ExecutablePath -ieq $Launcher -and $process.CommandLine -match '\s--server\s*$') { return $true }
        $pidToCheck = $process.ParentProcessId
    }
    return $false
}

function Get-TrayStatus([string]$Endpoint) {
    $path = Join-Path $script:TrayDir 'status.json'
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return }
    try {
        $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($state.Endpoint -ne $Endpoint -or !$state.ShellRegistered -or $state.State -ne 'Online') { return }
        if (([DateTimeOffset]::Now - [DateTimeOffset]::Parse($state.CheckedAt)).TotalSeconds -gt 20) { return }
        $process = Get-Process -Id $state.ProcessId -ErrorAction SilentlyContinue
        if ($process.Path -ieq (Join-Path $script:TrayDir 'Hermes.ServerTray.exe') -and
            $process.SessionId -eq (Get-Process -Id $PID).SessionId) { return $state }
    } catch { }
}

function Install-SetupTray([string]$ExeOverride, [string]$DataOverride, [int]$Port, [bool]$Repair = $false) {
    $diagnosis = Get-SetupDiagnosis $ExeOverride $DataOverride $Port $false
    if ($diagnosis.Server.Code -ne 'Ready') { throw [ApplicationException]::new($diagnosis.Server.Message) }
    $exe = Join-Path $script:TrayDir 'Hermes.ServerTray.exe'
    $config = Join-Path $script:TrayDir 'config.json'
    $setupFile = Join-Path $script:SetupRoot 'Instalar-Talaria.exe'
    $setupPayload = Join-Path $script:Payload 'Hermes.SetupLauncher.exe'
    $task = Get-SetupTask $script:TrayTask
    if ($task -and !(Test-SetupTask $task $exe)) { throw [ApplicationException]::new('The indicator task belongs to a different setup.') }
    $packaged = Join-Path $script:Payload 'Hermes.ServerTray.exe'
    $matching = (Test-Path -LiteralPath $exe) -and (Get-FileHash -LiteralPath $exe).Hash -eq (Get-FileHash -LiteralPath $packaged).Hash
    $installed = if (Test-Path -LiteralPath $config) { try { Get-Content -LiteralPath $config -Raw | ConvertFrom-Json } catch { } }
    if ($Repair) { Update-SetupCredentials $diagnosis.Endpoint }
    $setupMatching = (Test-Path -LiteralPath $setupFile -PathType Leaf) -and
        (Get-FileHash -LiteralPath $setupFile).Hash -eq (Get-FileHash -LiteralPath $setupPayload).Hash
    if ((Test-SetupSchedule $task) -and $matching -and $setupMatching -and $installed.Endpoint -eq $diagnosis.Endpoint -and (Get-TrayStatus $diagnosis.Endpoint)) {
        return @{ Code='Ready'; Message='The existing indicator is responding and registered in the tray.' }
    }
    if (!$task -and (Test-Path -LiteralPath $exe) -and !$matching) { throw [ApplicationException]::new('The indicator folder contains an unrecognized executable.') }

    $managed = Get-ManagedServer
    $log = if ($managed -and $managed.Port -eq $Port) { Join-Path $managed.LogDirectory 'remote.log' }
        elseif ($installed.Endpoint -eq $diagnosis.Endpoint -and $installed.RemoteLog) { $installed.RemoteLog }
        else { Join-Path $diagnosis.Hermes.Data ('logs\remote-' + $Port + '\remote.log') }
    $null = Start-SetupTransaction $script:TrayTask $exe '' @($exe,$config,$setupFile)
    try {
        Stop-SetupTask $script:TrayTask
        New-Item -ItemType Directory -Path $script:TrayDir -Force | Out-Null
        if (!$matching) { Copy-Item -LiteralPath $packaged -Destination $exe -Force }
        if (!$setupMatching) { Copy-Item -LiteralPath $setupPayload -Destination $setupFile -Force }
        Write-SetupJson $config @{ Endpoint=$diagnosis.Endpoint; RemoteLog=$log; SetupPath=$setupFile }
        if (!(Test-SetupSchedule $task)) { Register-SetupTask $script:TrayTask $exe '' 'Talaria tray indicator for Hermes' 5 ([bool]$task) }
        Enable-ScheduledTask -TaskName $script:TrayTask -TaskPath '\' | Out-Null
        Start-ScheduledTask -TaskName $script:TrayTask -TaskPath '\'
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        do {
            if (Get-TrayStatus $diagnosis.Endpoint) {
                Complete-SetupTransaction
                return @{ Code='Ready'; Message='Indicator installed and registered in the tray.' }
            }
            Start-Sleep -Milliseconds 250
        } while ([DateTime]::UtcNow -lt $deadline)
        throw [ApplicationException]::new('Windows did not confirm registration of the tray indicator.')
    } catch { Undo-SetupTransaction; throw }
}

function Remove-SetupTray {
    $exe = Join-Path $script:TrayDir 'Hermes.ServerTray.exe'
    $config = Join-Path $script:TrayDir 'config.json'
    if (!(Test-SetupTask (Get-SetupTask $script:TrayTask) $exe)) { throw [ApplicationException]::new('There is no Talaria indicator to remove.') }
    $null = Start-SetupTransaction $script:TrayTask $exe '' @($exe,$config)
    try {
        Stop-SetupTask $script:TrayTask
        Unregister-ScheduledTask -TaskName $script:TrayTask -TaskPath '\' -Confirm:$false
        foreach ($path in @($exe,$config)) { if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force } }
        Complete-SetupTransaction
        return @{ Code='Ready'; Message='Indicator removed. The server is managed separately.' }
    } catch { Undo-SetupTransaction; throw }
}

function Remove-SetupServer {
    $managed = Get-ManagedServer
    if (!$managed) { throw [ApplicationException]::new('There is no server configured by Talaria.') }
    $exe = Join-Path $script:ServerDir 'Hermes.SetupLauncher.exe'
    if (!(Test-SetupTask (Get-SetupTask $managed.Task) $exe '--server')) { throw [ApplicationException]::new('The server task does not match the saved configuration.') }
    $paths = Get-SetupServerFiles
    $null = Start-SetupTransaction $managed.Task $exe '--server' $paths
    try {
        Stop-SetupTask $managed.Task
        Unregister-ScheduledTask -TaskName $managed.Task -TaskPath '\' -Confirm:$false
        foreach ($path in $paths) { if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force } }
        Complete-SetupTransaction
        return @{ Code='Ready'; Message='The Talaria server setup was reverted.' }
    } catch { Undo-SetupTransaction; throw }
}
