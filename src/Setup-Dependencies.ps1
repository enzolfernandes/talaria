function Save-OfficialSetup([uri]$Url, [string]$Destination) {
    $origin = $Url.Host
    for ($hop = 0; $hop -lt 4; $hop++) {
        if ($Url.Scheme -ne 'https' -or $Url.Host -ne $origin -or !$Url.IsDefaultPort -or $Url.UserInfo) {
            throw [ApplicationException]::new('The download redirected outside the official download site.')
        }
        $request = [Net.HttpWebRequest]::Create($Url)
        $request.AllowAutoRedirect = $false
        $request.Timeout = 30000
        $request.ReadWriteTimeout = 30000
        $response = $request.GetResponse()
        try {
            if ([int]$response.StatusCode -in @(301,302,303,307,308)) {
                $location = $response.Headers['Location']
                if (!$location) { throw [ApplicationException]::new('The download site returned an invalid redirect.') }
                $Url = [uri]::new($Url,$location)
                continue
            }
            if ([int]$response.StatusCode -ne 200) {
                throw [ApplicationException]::new('The download site did not return an installer.')
            }
            $source = $response.GetResponseStream()
            $target = [IO.File]::Open($Destination,[IO.FileMode]::CreateNew)
            try { $source.CopyTo($target) } finally { $target.Dispose(); $source.Dispose() }
            return
        } finally { $response.Dispose() }
    }
    throw [ApplicationException]::new('The download site returned too many redirects.')
}

function Test-OfficialSetupSignature([string]$Path, [string]$Publisher) {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    return $signature.Status -eq 'Valid' -and $signature.SignerCertificate -and
        $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false) -eq $Publisher
}

function Invoke-DependencyInstaller([string]$Path, [bool]$Msi) {
    if ($Msi) {
        $msiexec = Join-Path ([Environment]::SystemDirectory) 'msiexec.exe'
        $process = Start-Process -FilePath $msiexec -ArgumentList ('/i "'+$Path+'" /norestart') -PassThru
    } else {
        $process = Start-Process -FilePath $Path -PassThru
    }
    try { $process.WaitForExit(); return $process.ExitCode } finally { $process.Dispose() }
}

function Invoke-HermesDesktopBuild($Hermes) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Hermes.Exe
    $start.Arguments = 'desktop --build-only'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.EnvironmentVariables['HERMES_HOME'] = $Hermes.Data
    $process = [Diagnostics.Process]::Start($start)
    try { $process.WaitForExit(); return $process.ExitCode } finally { $process.Dispose() }
}

function Install-SetupDependency([ValidateSet('HermesDesktop','Tailscale')][string]$Name, $Diagnosis) {
    if ($Name -eq 'HermesDesktop') {
        if ($Diagnosis.Desktop.Code -eq 'Ready') { return @{ Code='AlreadyPresent' } }
        if ($Diagnosis.Hermes.Code -eq 'Ready') {
            try { return @{ Code='Completed'; ExitCode=(Invoke-HermesDesktopBuild $Diagnosis.Hermes) } }
            catch { throw [ApplicationException]::new('The Hermes Desktop build could not start. Check the existing Hermes installation and try again.') }
        }
        if ($Diagnosis.Hermes.Code -ne 'Missing') { throw [ApplicationException]::new($Diagnosis.Hermes.Message) }
        $url = 'https://hermes-assets.nousresearch.com/Hermes-Setup.exe'
        $publisher = 'Nous Research Inc.'
        $nameOnDisk = 'Hermes-Setup.exe'
        $msi = $false
        $label = 'Hermes Desktop'
    } else {
        if ($Diagnosis.Tailscale.Code -ne 'Missing') { return @{ Code='AlreadyPresent' } }
        $url = 'https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi'
        $publisher = 'Tailscale Inc.'
        $nameOnDisk = 'Tailscale.msi'
        $msi = $true
        $label = 'Tailscale'
    }

    $folder = Join-Path ([IO.Path]::GetTempPath()) ('Talaria-dependency-' + [Guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $folder
    $path = Join-Path $folder $nameOnDisk
    try {
        try { Save-OfficialSetup $url $path }
        catch { throw [ApplicationException]::new("Could not download the official $label installer. Check your internet connection and try again.") }
        if (!(Test-OfficialSetupSignature $path $publisher)) {
            throw [ApplicationException]::new("Windows could not verify the $label installer signature. Try again or use the official installation guide.")
        }
        try { return @{ Code='Completed'; ExitCode=(Invoke-DependencyInstaller $path $msi) } }
        catch { throw [ApplicationException]::new("Could not open the $label installer. Check again after running the official installer.") }
    } finally {
        # Delete just the temporary file we created. Vendor installation data is independent.
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        try { [IO.Directory]::Delete($folder) } catch { }
    }
}
