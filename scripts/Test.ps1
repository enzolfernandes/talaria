param([switch]$Integration)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$build = Join-Path $repo 'build'
$stage = Join-Path $build 'setup'
$tray = Join-Path $stage 'Hermes.ServerTray.exe'
if (!(Test-Path -LiteralPath $tray)) { throw 'Build Talaria first.' }
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$test = Join-Path $stage 'Test-ServerTray.exe'
& $compiler /nologo /codepage:65001 /reference:System.Windows.Forms.dll ('/reference:'+$tray) ('/out:'+$test) (Join-Path $repo 'tests/Test-ServerTray.cs')
if ($LASTEXITCODE -ne 0) { throw 'Tray test compilation failed.' }
& $test
if ($LASTEXITCODE -ne 0) { throw 'Tray health test failed.' }

Add-Type -AssemblyName System.Drawing
foreach ($size in @(16,20,24,32)) {
    foreach ($state in @('online','waiting','offline')) {
        $bitmap = [Drawing.Bitmap]::new((Join-Path $build "$state-$size.png"))
        try {
            if ($bitmap.Width -ne $size -or $bitmap.Height -ne $size -or $bitmap.GetPixel(0,0).A -gt 16) {
                throw "Invalid icon dimensions or alpha for $state-$size."
            }
        } finally { $bitmap.Dispose() }
    }
}
Write-Output 'PASS all tray icon sizes and states'

$shell = Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
& $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $repo 'tests/Test-SetupDependencies.ps1') -Stage $stage
if ($LASTEXITCODE -ne 0) { throw 'Dependency installation tests failed.' }
& $shell -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File (Join-Path $stage 'Setup-Hermes.ps1') -CheckControls
if ($LASTEXITCODE -ne 0) { throw 'Installer UI test failed.' }

if ($Integration) {
    $runner = Join-Path $repo 'tests/.integration-run.local.ps1'
    try {
        [IO.File]::WriteAllText($runner,[IO.File]::ReadAllText((Join-Path $repo 'tests/Test-HermesSetup.ps1')),[Text.UTF8Encoding]::new($true))
        & $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $runner
        if ($LASTEXITCODE -ne 0) { throw 'Installer integration test failed.' }
    } finally { if (Test-Path -LiteralPath $runner) { Remove-Item -LiteralPath $runner -Force } }
}
