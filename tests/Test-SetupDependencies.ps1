param([Parameter(Mandatory)][string]$Stage)
$ErrorActionPreference = 'Stop'
. (Join-Path $Stage 'Setup-Core.ps1')
. (Join-Path $Stage 'Setup-Dependencies.ps1')

function Assert-Dependency([bool]$Condition, [string]$Description) {
    if (!$Condition) { throw $Description }
    "PASS $Description"
}

function Get-AppxPackage {
    param($Name,$ErrorAction)
    @(
        @{ Name='NousResearch.HermesBundled'; Publisher='CN=Other Publisher' }
        $script:Package
    ) | Where-Object { $_ }
}

$script:Package = @{ Name='NousResearch.HermesBundled'; Publisher='CN=Nous Research Inc., O=Nous Research Inc.' }
Assert-Dependency ((Get-HermesDesktopPackage).Publisher -eq $script:Package.Publisher) 'signed Hermes MSIX identity recognized'
$script:Package = @{ Name='NousResearchInc.HermesAgent'; Publisher='CN=EE6D86E4-606F-4E38-B940-AD7248C9D519' }
$storePackage = Get-HermesDesktopPackage
Assert-Dependency ((Get-HermesDesktop @{ Data=$null } $storePackage).Code -eq 'Ready') 'Hermes Desktop recognized from Microsoft Store'
$script:Package = $null
Assert-Dependency (!(Get-HermesDesktopPackage)) 'foreign Windows app publisher ignored'

$workspace = Join-Path ([IO.Path]::GetTempPath()) ('Talaria-test-' + [Guid]::NewGuid().ToString('N'))
$path = Join-Path $workspace 'hermes-agent/apps/desktop/release/win-unpacked/Hermes.exe'
New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
try {
    New-Item -ItemType File -Path $path | Out-Null
    Assert-Dependency ((Get-HermesDesktop @{ Data=$workspace } $null).Code -eq 'Ready') 'native Desktop recognized in selected Hermes home'
    Assert-Dependency (!(Test-OfficialSetupSignature $path 'Nous Research Inc.')) 'unsigned installer rejected by Authenticode'
} finally {
    $resolved = (Resolve-Path -LiteralPath $workspace).Path
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

function Get-ExeCandidate { }
Assert-Dependency ((Get-HermesInstall '' '' $storePackage).Code -eq 'AliasDisabled') 'missing CLI alias leaves the installed Desktop in place'

$script:DownloadFails = $true
$script:SignatureValid = $false
$script:LaunchCount = 0
$script:BuildCount = 0
function Save-OfficialSetup([uri]$Url,[string]$Destination) {
    if ($script:DownloadFails) { throw [Net.WebException]::new('Fixture download failed.') }
    $script:VendorUrl = $Url
    New-Item -ItemType File -Path $Destination | Out-Null
}
function Test-OfficialSetupSignature([string]$Path,[string]$Publisher) {
    $script:Publisher = $Publisher
    return $script:SignatureValid
}
function Invoke-DependencyInstaller([string]$Path,[bool]$Msi) {
    $script:LaunchCount++
    $script:LaunchedMsi = $Msi
    return 1602
}
function Invoke-HermesDesktopBuild($Hermes) {
    $script:BuildCount++
    $script:BuildHome = $Hermes.Data
    return 0
}

$clean = @{ Hermes=@{Code='Missing'}; Desktop=@{Code='Missing'}; Tailscale=@{Code='Missing'} }
$rejected = $false
try { $null = Install-SetupDependency 'HermesDesktop' $clean }
catch [ApplicationException] { $rejected = $_.Exception.Message -like '*download*' }
Assert-Dependency ($rejected -and $script:LaunchCount -eq 0) 'failed download cannot launch an installer'

$script:DownloadFails = $false
$rejected = $false
try { $null = Install-SetupDependency 'Tailscale' $clean }
catch [ApplicationException] { $rejected = $_.Exception.Message -like '*signature*' }
Assert-Dependency ($rejected -and $script:LaunchCount -eq 0) 'invalid vendor signature cannot launch an installer'

$script:SignatureValid = $true
$cancelled = Install-SetupDependency 'Tailscale' $clean
Assert-Dependency ($cancelled.ExitCode -eq 1602 -and $script:LaunchCount -eq 1 -and $script:LaunchedMsi -and
    $script:VendorUrl.Host -eq 'pkgs.tailscale.com' -and $script:Publisher -eq 'Tailscale Inc.') 'retry after failure runs the signed Tailscale MSI and returns cancellation'
$clean.Tailscale.Code = 'Disconnected'
Assert-Dependency ((Install-SetupDependency 'Tailscale' $clean).Code -eq 'AlreadyPresent' -and $script:LaunchCount -eq 1) 'installed Tailscale waits for sign-in without reinstalling'

$null = Install-SetupDependency 'HermesDesktop' $clean
Assert-Dependency ($script:LaunchCount -eq 2 -and !$script:LaunchedMsi -and
    $script:VendorUrl.Host -eq 'hermes-assets.nousresearch.com' -and $script:Publisher -eq 'Nous Research Inc.') 'missing Hermes uses the signed official Desktop bootstrapper'
$clean.Hermes = @{ Code='Ready'; Data=$workspace }
$null = Install-SetupDependency 'HermesDesktop' $clean
Assert-Dependency ($script:BuildCount -eq 1 -and $script:BuildHome -eq $workspace -and $script:LaunchCount -eq 2) 'CLI-only setup builds Desktop in the existing Hermes home'
$clean.Desktop.Code = 'Ready'
Assert-Dependency ((Install-SetupDependency 'HermesDesktop' $clean).Code -eq 'AlreadyPresent' -and
    $script:BuildCount -eq 1 -and $script:LaunchCount -eq 2) 'installed Desktop skips all installers'
