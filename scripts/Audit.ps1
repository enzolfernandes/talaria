$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$sourceFiles = @(
    '.github/workflows/windows.yml','.gitignore','LICENSE','README.md','README.pt-BR.md',
    'assets/sandal.svg','assets/screenshots/installer.png','assets/screenshots/tray.png',
    'scripts/Audit.ps1','scripts/Build.ps1','scripts/Test.ps1',
    'src/Hermes.ServerTray.cs','src/Hermes.SetupLauncher.cs','src/RemoteSupervisor.ps1','src/Setup-Core.ps1','src/Setup-Hermes.ps1','src/Talaria.Ui.cs',
    'tests/Test-HermesSetup.ps1','tests/Test-ServerTray.cs','tests/Test-SetupHermesFixture.cs'
)
$patterns = @(
    '(?i)\b[A-Z]:[\\/]+Users[\\/]+[^\s\\/]+',
    '\b100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}\b',
    '\b(?:gh[pousr]_[a-zA-Z0-9]{30,}|github_pat_[a-zA-Z0-9_]{30,}|sk-[a-zA-Z0-9_-]{24,}|AKIA[A-Z0-9]{16})\b',
    '-----BEGIN [A-Z ]*PRIVATE KEY-----',
    '(?im)^\s*(?:HERMES_API_KEY|HERMES_API_TOKEN|HERMES_DESKTOP_REMOTE_TOKEN|HERMES_AUTH_LOCAL_PASSWORD|HERMES_AUTH_SIGNING_SECRET)\s*=\s*["'']?[A-Za-z0-9]'
)

function Test-PublicText([string]$Text,[string]$Label) {
    $Text = $Text.Replace('100.64.0.10','<example-address>')
    foreach ($pattern in $patterns) {
        if ($Text -match $pattern) { throw "Private data pattern found in $Label. Check the file locally." }
    }
    foreach ($value in @($env:TALARIA_AUDIT_PRIVATE_ADDRESS,$env:TALARIA_AUDIT_PRIVATE_PATH,$env:TALARIA_AUDIT_PRIVATE_HOST)) {
        if ($value -and $Text.IndexOf($value,[StringComparison]::OrdinalIgnoreCase) -ge 0) {
            throw "Local host data found in $Label."
        }
    }
}

function Read-EmbeddedBytes($Assembly,[string]$Name) {
    $stream = $Assembly.GetManifestResourceStream($Name)
    $buffer = [IO.MemoryStream]::new()
    try { $stream.CopyTo($buffer); return ,$buffer.ToArray() }
    finally { $stream.Dispose(); $buffer.Dispose() }
}

Push-Location $repo
try {
    $tracked = @(git ls-files)
    if ($LASTEXITCODE -ne 0 -or (Compare-Object $sourceFiles $tracked)) { throw 'Tracked files differ from the public source list.' }
    foreach ($name in $sourceFiles | Where-Object { $_ -notlike '*.png' }) {
        $staged = (git -c i18n.logOutputEncoding=utf-8 show ":$name") -join "`n"
        if ($LASTEXITCODE -ne 0) { throw "Cannot read staged file $name." }
        Test-PublicText $staged $name
    }
    foreach ($name in @('.env','config.json','credentials.local.json','backups/task.xml','logs/server.log','reports/results.json')) {
        git check-ignore -q -- $name
        if ($LASTEXITCODE -ne 0) { throw "Local path $name is not ignored." }
    }
    $package = [IO.File]::ReadAllBytes((Join-Path $repo 'dist/Talaria-Setup.exe'))
    $installer = [Reflection.Assembly]::Load($package)
    $expected = @('Hermes.ServerTray.exe','Setup-Core.ps1','Setup-Hermes.ps1','PortableSupervisor.ps1','brand-64.png')
    if (Compare-Object $expected $installer.GetManifestResourceNames()) { throw 'Unexpected installer resources.' }
    foreach ($name in $expected | Where-Object { $_ -like '*.ps1' }) {
        Test-PublicText ([Text.Encoding]::UTF8.GetString((Read-EmbeddedBytes $installer $name))) $name
    }
    $tray = [Reflection.Assembly]::Load((Read-EmbeddedBytes $installer 'Hermes.ServerTray.exe'))
    $expectedIcons = foreach ($size in @(16,20,24,32)) { foreach ($state in @('online','waiting','offline')) { "$state-$size.png" } }
    if (Compare-Object $expectedIcons $tray.GetManifestResourceNames()) { throw 'Unexpected tray resources.' }
    foreach ($encoding in @([Text.Encoding]::UTF8,[Text.Encoding]::Unicode)) {
        Test-PublicText ($encoding.GetString($package)) 'Talaria-Setup.exe'
    }
    Write-Output 'PASS tracked source, local exclusions, installer and embedded resources'
} finally { Pop-Location }
