param([string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (!$OutputDirectory) { $OutputDirectory = Join-Path $repo 'dist' }
$build = Join-Path $repo 'build'
$stage = Join-Path $build 'setup'
New-Item -ItemType Directory -Path $stage,$OutputDirectory -Force | Out-Null
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (!(Test-Path -LiteralPath $compiler)) { throw 'Windows .NET Framework compiler not found.' }
Add-Type -AssemblyName WindowsBase,PresentationCore
[xml]$design = Get-Content -LiteralPath (Join-Path $repo 'assets/sandal.svg') -Raw
$colors = [ordered]@{ online='#008A42'; waiting='#C27800'; offline='#CA2737' }
$icons = @()
foreach ($size in @(16,20,24,32,64)) {
    $states = if ($size -eq 64) { @('brand') } else { $colors.Keys }
    foreach ($state in $states) {
        $visual = New-Object Windows.Media.DrawingVisual
        $drawing = $visual.RenderOpen()
        try {
            $drawing.PushTransform([Windows.Media.ScaleTransform]::new($size/64.0,$size/64.0))
            foreach ($part in $design.DocumentElement.ChildNodes) {
                if ($part.LocalName -ne 'path') { continue }
                $color = [Windows.Media.ColorConverter]::ConvertFromString($part.GetAttribute('fill'))
                $brush = [Windows.Media.SolidColorBrush]::new($color)
                $drawing.DrawGeometry($brush,$null,[Windows.Media.Geometry]::Parse($part.GetAttribute('d')))
            }
            if ($state -ne 'brand') {
                $drawing.DrawEllipse([Windows.Media.Brushes]::White,$null,[Windows.Point]::new(54,54),10,10)
                $badge = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString($colors[$state]))
                $drawing.DrawEllipse($badge,$null,[Windows.Point]::new(54,54),7,7)
            }
            $drawing.Pop()
        } finally { $drawing.Close() }
        $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new($size,$size,96,96,[Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($visual)
        $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $name = "$state-$size.png"
        $path = Join-Path $build $name
        $stream = [IO.File]::Create($path)
        try { $encoder.Save($stream) } finally { $stream.Dispose() }
        if ($state -ne 'brand') { $icons += "/resource:$path,$name" }
    }
}

$tray = Join-Path $stage 'Hermes.ServerTray.exe'
$arguments = @('/nologo','/target:winexe','/platform:x64','/optimize+','/codepage:65001',('/out:'+$tray),
    '/reference:System.Windows.Forms.dll','/reference:System.Drawing.dll','/reference:System.Web.Extensions.dll')
& $compiler @arguments @icons (Join-Path $repo 'src/Hermes.ServerTray.cs')
if ($LASTEXITCODE -ne 0) { throw 'Talaria tray compilation failed.' }

$scripts = [ordered]@{ 'Setup-Hermes.ps1'='Setup-Hermes.ps1'; 'Setup-Core.ps1'='Setup-Core.ps1'; 'PortableSupervisor.ps1'='RemoteSupervisor.ps1' }
$brand = Join-Path $build 'brand-64.png'
$resources = @("/resource:$tray,Hermes.ServerTray.exe","/resource:$brand,brand-64.png")
foreach ($name in $scripts.Keys) {
    $path = Join-Path $stage $name
    [IO.File]::WriteAllText($path,[IO.File]::ReadAllText((Join-Path $repo ('src/'+$scripts[$name]))),[Text.UTF8Encoding]::new($true))
    $tokens=$null; $errors=$null
    [Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors) { throw ($errors | Out-String) }
    $resources += "/resource:$path,$name"
}
$installer = Join-Path $OutputDirectory 'Instalar-Talaria.exe'
$arguments = @('/nologo','/target:winexe','/platform:x64','/optimize+','/codepage:65001',('/out:'+$installer),'/reference:System.Windows.Forms.dll')
& $compiler @arguments @resources (Join-Path $repo 'src/Hermes.SetupLauncher.cs')
if ($LASTEXITCODE -ne 0) { throw 'Talaria installer compilation failed.' }
Copy-Item -LiteralPath $installer -Destination (Join-Path $stage 'Hermes.SetupLauncher.exe') -Force
"$((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant())  Instalar-Talaria.exe" |
    Set-Content -LiteralPath (Join-Path $OutputDirectory 'SHA256SUMS.txt') -Encoding ASCII
Get-Item -LiteralPath $installer
