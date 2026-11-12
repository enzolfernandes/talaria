$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repository = Split-Path $PSScriptRoot -Parent
. (Join-Path $repository 'build/setup/Setup-Core.ps1')

function Assert-Setup([bool]$Value, [string]$Description) {
    if (!$Value) { throw ('FALHOU: ' + $Description) }
    Write-Output ('PASS ' + $Description)
}

Assert-Setup ((Get-HermesInstall (Join-Path $PSScriptRoot 'nao-existe.exe') '').Code -eq 'Missing') 'Hermes ausente'

$tag = [Guid]::NewGuid().ToString('N').Substring(0,8)
$script:SetupRoot = Join-Path (Join-Path $repository 'build') ('setup-fixture-' + $tag)
$script:TrayDir = Join-Path $script:SetupRoot 'tray'
$script:ServerDir = Join-Path $script:SetupRoot 'server'
$script:Pending = Join-Path $script:SetupRoot 'pending.json'
$script:TrayTask = 'Hermes_Installer_Canary_' + $tag
$custom = Join-Path $script:SetupRoot 'Instalacao com espaco'
$bin = Join-Path $custom 'bin'
New-Item -ItemType Directory -Path $bin -Force | Out-Null
$mock = Join-Path $bin 'hermes.exe'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& $compiler /nologo /reference:System.Web.Extensions.dll ('/out:'+$mock) (Join-Path $PSScriptRoot 'Test-SetupHermesFixture.cs')
if ($LASTEXITCODE -ne 0) { throw 'Falha compilando o servidor de teste.' }
Assert-Setup ((Get-HermesInstall $mock '').Data -eq $custom) 'caminho personalizado com espacos'

$reserve = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$reserve.Start()
$testPort = $reserve.LocalEndpoint.Port
$script:TestServerTask = 'Hermes_Remote_' + $testPort
if (Get-SetupTask $script:TestServerTask) { $reserve.Stop(); throw 'Porta de teste ja tem tarefa.' }

# Real Task Scheduler writes are restricted to the two fixture names. The HTTP and
# task lifecycle use the production code. Only Tailscale detection is simulated.
function Get-ScheduledTask {
    param($TaskName,$TaskPath,$ErrorAction)
    if ($TaskName -and $TaskName -notin @($script:TrayTask,$script:TestServerTask)) { return }
    if ($TaskName) { ScheduledTasks\Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue }
    else { ScheduledTasks\Get-ScheduledTask -TaskPath '\' | Where-Object { $_.TaskName -in @($script:TrayTask,$script:TestServerTask) } }
}

$script:Network = 'Disconnected'
function Get-TailscaleInstall {
    if ($script:Network -eq 'Ready') { return @{ Code='Ready'; Address='127.0.0.1'; Message='Fixture' } }
    return @{ Code=$script:Network; Message='Fixture' }
}

try {
    Assert-Setup ((Get-SetupDiagnosis $mock $custom $testPort $false).Server.Code -eq 'Pending') 'Tailscale desconectado bloqueia instalacao'
    $script:Network = 'Missing'
    Assert-Setup ((Get-SetupDiagnosis $mock $custom $testPort $false).Tailscale.Code -eq 'Missing') 'Tailscale ausente sinalizado'
    $script:Network = 'Ready'
    $reserve.Stop()
    $conflict = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$testPort)
    $conflict.Start()
    # Avoid an HTTP timeout on the fixture: the port is occupied but not serving Hermes.
    try { Assert-Setup ((Get-SetupDiagnosis $mock $custom $testPort $false).Server.Code -eq 'Conflict') 'porta ocupada detectada' }
    finally { $conflict.Stop() }

    New-Item -ItemType File -Path (Join-Path $bin 'unknown-version') | Out-Null
    $missingLogin = Start-SetupServer $mock $custom $testPort '' ''
    Assert-Setup ($missingLogin.Code -eq 'NeedsLogin' -and !(Get-SetupTask $script:TestServerTask)) 'autenticacao ausente oferece login e desfaz tentativa'
    $password = [Guid]::NewGuid().ToString('N')
    $configured = Start-SetupServer $mock $custom $testPort 'teste-hermes' $password
    Assert-Setup ($configured.Code -eq 'Ready' -and (Get-SetupTask $script:TestServerTask).State -eq 'Running') 'novo servidor com versao indefinida, senha protegida e login no fixture'
    $settingsPath = Join-Path $script:ServerDir 'config.json'
    $secretPath = Join-Path $script:ServerDir 'credentials.local.json'
    $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    $secretRaw = Get-Content -LiteralPath $secretPath -Raw
    $secret = $secretRaw | ConvertFrom-Json
    Assert-Setup (!$settings.Auth -and $secret.Version -eq 1 -and !$secretRaw.Contains($password) -and !$secretRaw.Contains('teste-hermes')) 'credenciais protegidas em arquivo separado'

    $first = Install-SetupTray $mock $custom $testPort
    $fixtureEndpoint = 'http://127.0.0.1:' + $testPort
    $before = Get-TrayStatus $fixtureEndpoint
    Assert-Setup ($first.Code -eq 'Ready' -and $before.ShellRegistered) 'primeira instalacao registra bandeja no Windows'
    $again = Install-SetupTray $mock $custom $testPort
    Assert-Setup ($again.Code -eq 'Ready' -and (Get-TrayStatus $fixtureEndpoint).ProcessId -eq $before.ProcessId) 'repeticao nao cria outro indicador'
    Disable-ScheduledTask -TaskName $script:TrayTask -TaskPath '\' | Out-Null
    $repair = Install-SetupTray $mock $custom $testPort
    Assert-Setup ($repair.Code -eq 'Ready' -and (Test-SetupSchedule (Get-SetupTask $script:TrayTask))) 'reparo recupera tarefa de logon desativada'
    # Recreate the old on-disk representation while the fixture keeps serving.
    $settings | Add-Member NoteProperty Auth @{ Username='teste-hermes'; Password=$secret.Password; SigningSecret=$secret.SigningSecret }
    Write-SetupJson $settingsPath $settings
    Remove-Item -LiteralPath $secretPath
    $ownerBefore = (Get-NetTCPConnection -LocalPort $testPort -State Listen).OwningProcess
    $savedPayload = $script:Payload
    $script:Payload = Join-Path $script:SetupRoot 'missing-payload'
    $failed = $false
    try { Update-SetupCredentials $fixtureEndpoint } catch { $failed = $true } finally { $script:Payload = $savedPayload }
    Assert-Setup ($failed -and !(Test-Path -LiteralPath $secretPath) -and (Get-ManagedServer).Auth) 'rollback de migracao de credenciais'
    $null = Install-SetupTray $mock $custom $testPort $true
    Assert-Setup (!(Get-ManagedServer).Auth -and (Test-Path -LiteralPath $secretPath) -and
        (Get-NetTCPConnection -LocalPort $testPort -State Listen).OwningProcess -eq $ownerBefore) 'migracao no reparo mantem servidor ativo'
    Stop-SetupTask $script:TestServerTask
    Start-ScheduledTask -TaskName $script:TestServerTask -TaskPath '\'
    $deadline = [DateTime]::UtcNow.AddSeconds(55)
    do { $healthy = (Test-HermesEndpoint $fixtureEndpoint).Code -eq 'Ready'; if(!$healthy){Start-Sleep -Milliseconds 500} }
    while (!$healthy -and [DateTime]::UtcNow -lt $deadline)
    if (!$healthy) { throw 'O servidor de teste não voltou a responder após iniciar a tarefa.' }
    Assert-Setup (Test-NewHermesLogin $fixtureEndpoint 'teste-hermes' $password) 'credenciais migradas funcionam apos iniciar a tarefa'
    $password = $null
    $null = Remove-SetupTray
    Assert-Setup (!(Get-SetupTask $script:TrayTask) -and (Test-HermesEndpoint $fixtureEndpoint).Code -eq 'Ready') 'remover indicador mantem servidor'
    $null = Remove-SetupServer
    Assert-Setup (!(Get-SetupTask $script:TestServerTask) -and (Test-HermesEndpoint $fixtureEndpoint).Code -eq 'Unavailable') 'reverter servidor encerra a arvore da tarefa'

    New-Item -ItemType File -Path (Join-Path $custom 'existing-auth') | Out-Null
    New-Item -ItemType File -Path (Join-Path $custom 'unprotected') | Out-Null
    $refused = $false
    try { $null = Start-SetupServer $mock $custom $testPort '' '' } catch { $refused = $_.Exception.Message -match 'anonymous access check' }
    Assert-Setup ($refused -and !(Get-SetupTask $script:TestServerTask) -and !(Test-Path -LiteralPath $script:Pending)) 'recusa de autenticacao incompleta e reversao da tarefa'
} finally {
    $reserve.Stop()
    if (Test-Path -LiteralPath $script:Pending) { Undo-SetupTransaction }
    if (Get-SetupTask $script:TrayTask) { $null = Remove-SetupTray }
    if (Get-SetupTask $script:TestServerTask) { $null = Remove-SetupServer }
}
