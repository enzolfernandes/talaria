param([switch]$CheckControls,[switch]$CheckLive,[string]$PreviewFile,[int]$PreviewWidth,[ValidateSet('System','Light','Dark')][string]$PreviewTheme='System')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
[Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
$script:CoreFile = Join-Path $PSScriptRoot 'Setup-Core.ps1'
$script:Diagnosis = $null
$script:ExeOverride = ''
$script:DataOverride = ''
$script:Job = $null
$script:NeedsLogin = $false
$script:IgnorePortChange = $false
$script:Finished = $false
$appearance = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue
$dark = $PreviewTheme -eq 'Dark' -or ($PreviewTheme -eq 'System' -and $appearance -and $appearance.AppsUseLightTheme -eq 0)
if ([Windows.Forms.SystemInformation]::HighContrast -and $PreviewTheme -eq 'System') {
    $palette = @{ Surface=[Drawing.SystemColors]::Window; Panel=[Drawing.SystemColors]::Control; Ink=[Drawing.SystemColors]::WindowText
        Border=[Drawing.SystemColors]::ControlText; Accent=[Drawing.SystemColors]::Highlight; OnAccent=[Drawing.SystemColors]::HighlightText }
} else {
    $tokens = if ($dark) { '#0d2f86','#12378f','#ffe6cb','#5475bb','#ffe6cb','#0d2f86' }
        else { '#f8faff','#ffffff','#17171a','#c5cfe2','#0053fd','#ffffff' }
    $palette = @{}
    $names = 'Surface','Panel','Ink','Border','Accent','OnAccent'
    for ($index = 0; $index -lt $names.Count; $index++) {
        $palette[$names[$index]] = [Drawing.ColorTranslator]::FromHtml($tokens[$index])
    }
}

function New-Text([string]$Text, [int]$Size = 10, [bool]$Bold = $false) {
    $label = New-Object Windows.Forms.Label
    $label.Text = $Text
    $label.AutoSize = $true
    $style = if ($Bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }
    $label.Font = [Drawing.Font]::new('Segoe UI',[single]$Size,$style)
    $label.ForeColor = $palette.Ink
    $label.Margin = [Windows.Forms.Padding]::new(0,0,0,5)
    return $label
}

function New-Button([string]$Text, [scriptblock]$Action, [bool]$Prominent = $false) {
    $button = New-Object Windows.Forms.Button
    $button.Text = $Text
    $button.AutoSize = $true
    $button.MinimumSize = [Drawing.Size]::new(100,36)
    $button.Margin = [Windows.Forms.Padding]::new(0,0,8,0)
    $button.Padding = [Windows.Forms.Padding]::new(9,0,9,0)
    $button.FlatStyle = 'Flat'
    $button.BackColor = $palette.Panel
    $button.ForeColor = $palette.Ink
    $button.FlatAppearance.BorderColor = $palette.Border
    if ($Prominent) {
        $button.FlatAppearance.BorderSize = 0
        $button.BackColor = $palette.Accent
        $button.ForeColor = $palette.OnAccent
    }
    $button.Add_Click($Action)
    return $button
}

function New-Flow([bool]$Vertical = $false) {
    $flow = New-Object Windows.Forms.FlowLayoutPanel
    $flow.AutoSize = $true
    $flow.AutoSizeMode = 'GrowAndShrink'
    $flow.FlowDirection = if($Vertical){'TopDown'}else{'LeftToRight'}
    $flow.WrapContents = $false
    $flow.Margin = [Windows.Forms.Padding]::new(0)
    return $flow
}

$form = New-Object Windows.Forms.Form
$form.Text = 'Instalar Talaria'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = [Drawing.Size]::new(740,510)
$form.MinimumSize = [Drawing.Size]::new(605,470)
$form.AutoScaleMode = 'Dpi'
$form.Font = [Drawing.Font]::new('Segoe UI',10)
$form.BackColor = $palette.Surface
$form.ForeColor = $palette.Ink
$form.AutoScaleDimensions = [Drawing.SizeF]::new(96,96)
$form.KeyPreview = $true

$footer = New-Object Windows.Forms.TableLayoutPanel
$footer.Dock = 'Bottom'
$footer.Height = 70
$footer.Padding = [Windows.Forms.Padding]::new(20,14,12,12)
$footer.ColumnCount = 2
$null = $footer.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent',100))
$null = $footer.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('AutoSize'))
$footer.BackColor = $palette.Panel
$secondary = New-Flow
$verify = New-Button 'Verificar novamente' { Start-Work 'Diagnose' 'Verificando a instalação…' }
$maintenance = New-Button 'Manutenção' { Show-Maintenance }
$secondary.Controls.AddRange(@($verify,$maintenance))
$primary = New-Button 'Verificando…' { Invoke-Primary } $true
$footer.Controls.Add($secondary,0,0)
$footer.Controls.Add($primary,1,0)

$scroll = New-Object Windows.Forms.Panel
$scroll.Dock = 'Fill'
$scroll.AutoScroll = $true
$body = New-Object Windows.Forms.TableLayoutPanel
$body.Dock = 'Top'
$body.AutoSize = $true
$body.AutoSizeMode = 'GrowAndShrink'
$body.ColumnCount = 1
$body.Padding = [Windows.Forms.Padding]::new(24,18,24,12)
$header = New-Flow
$installer = Join-Path $PSScriptRoot 'Hermes.SetupLauncher.exe'
if (Test-Path -LiteralPath $installer) {
    $assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($installer))
    $stream = $assembly.GetManifestResourceStream('brand-64.png')
    if ($stream) {
        $brand = New-Object Windows.Forms.PictureBox
        $brand.Size = [Drawing.Size]::new(54,54)
        $brand.Margin = [Windows.Forms.Padding]::new(0,1,12,0)
        $brand.SizeMode = 'Zoom'
        try {
            $image = [Drawing.Image]::FromStream($stream)
            try { $brand.Image = [Drawing.Bitmap]::new($image) } finally { $image.Dispose() }
        } finally { $stream.Dispose() }
        $header.Controls.Add($brand)
        $brand.Add_Disposed({ if ($this.Image) { $this.Image.Dispose() } })
    }
}
$heading = New-Flow $true
$title = New-Text 'TALARIA' 25 $true
$title.ForeColor = $palette.Accent
$title.Margin = [Windows.Forms.Padding]::new(0,0,0,2)
$heading.Controls.Add($title)
$heading.Controls.Add((New-Text 'Indicador do servidor Hermes'))
$header.Controls.Add($heading)
$header.Margin = [Windows.Forms.Padding]::new(0,3,0,11)
$body.Controls.Add($header)

function Add-StatusRow([string]$Title, [Windows.Forms.Label]$Detail, [Windows.Forms.Control]$Actions) {
    $row = New-Object Windows.Forms.TableLayoutPanel
    $row.Dock = 'Top'
    $row.AutoSize = $true
    $row.AutoSizeMode = 'GrowAndShrink'
    $row.ColumnCount = 2
    $row.Padding = [Windows.Forms.Padding]::new(13,10,12,8)
    $row.Margin = [Windows.Forms.Padding]::new(0,8,0,0)
    $row.BackColor = $palette.Panel
    $null = $row.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Absolute',115))
    $null = $row.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent',100))
    $row.Controls.Add((New-Text $Title 11 $true),0,0)
    $content = New-Flow $true
    $content.Controls.Add($Detail)
    if ($Actions) { $content.Controls.Add($Actions) }
    $row.Controls.Add($content,1,0)
    $body.Controls.Add($row)
}

function Open-Link([string]$Url) {
    try { Start-Process -FilePath $Url }
    catch { $message.Text = "Abra o endereço $Url" }
}

function Select-Hermes([bool]$Data) {
    if ($Data) {
        $dialog = New-Object Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Selecione a pasta de dados do Hermes.'
        $dialog.ShowNewFolderButton = $false
        try { if ($dialog.ShowDialog($form) -eq 'OK') { $script:DataOverride=$dialog.SelectedPath; Start-Work 'Diagnose' 'Verificando a pasta de dados…' } }
        finally { $dialog.Dispose() }
    } else {
        $dialog = New-Object Windows.Forms.OpenFileDialog
        $dialog.Title = 'Selecione o executável do Hermes'
        $dialog.Filter = 'Executável do Hermes (hermes.exe)|hermes.exe|Executáveis (*.exe)|*.exe'
        try {
            if ($dialog.ShowDialog($form) -eq 'OK') {
                $script:ExeOverride=$dialog.FileName
                $script:DataOverride=''
                Start-Work 'Diagnose' 'Verificando o Hermes selecionado…'
            }
        } finally { $dialog.Dispose() }
    }
}

function Open-Tailscale {
    if ($script:Diagnosis.Tailscale.App) {
        try { Start-Process -FilePath $script:Diagnosis.Tailscale.App -WindowStyle Normal }
        catch { $message.Text = 'Abra o Tailscale pelo menu Iniciar e tente novamente.' }
    } else { $message.Text = 'Abra o Tailscale pelo menu Iniciar, entre na conta e verifique novamente.' }
}

$hermesStatus = New-Text 'Aguardando diagnóstico'
$hermesActions = New-Flow
$locate = New-Button 'Localizar Hermes' { Select-Hermes $false }
$dataFolder = New-Button 'Pasta de dados' { Select-Hermes $true }
$getHermes = New-Button 'Guia de instalação' { Open-Link 'https://hermes-agent.nousresearch.com/docs/user-guide/windows-native' }
$hermesActions.Controls.AddRange(@($locate,$dataFolder,$getHermes))
Add-StatusRow 'Hermes' $hermesStatus $hermesActions
$tailscaleStatus = New-Text 'Aguardando diagnóstico'
Add-StatusRow 'Tailscale' $tailscaleStatus $null

$serverStatus = New-Text 'Aguardando diagnóstico'
$connectionActions = New-Flow
$portLabel = New-Text 'Porta'
$portLabel.Margin = [Windows.Forms.Padding]::new(0,7,8,0)
$port = New-Object Windows.Forms.NumericUpDown
$port.Minimum = 1
$port.Maximum = 65535
$port.Value = 9119
$port.Width = 88
$port.BackColor = $palette.Surface
$port.ForeColor = $palette.Ink
$port.Margin = [Windows.Forms.Padding]::new(0,5,12,0)
$port.AccessibleName = 'Porta do servidor Hermes'
$authGuide = New-Button 'Guia de autenticação' { Open-Link 'https://hermes-agent.nousresearch.com/docs/user-guide/desktop#connecting-to-a-remote-backend' }
$connectionActions.Controls.AddRange(@($portLabel,$port,$authGuide))
Add-StatusRow 'Conexão' $serverStatus $connectionActions

$message = New-Text ''
$message.ForeColor = $palette.Accent
$message.Margin = [Windows.Forms.Padding]::new(0,14,0,3)
$body.Controls.Add($message)
$scroll.Controls.Add($body)
$form.Controls.Add($scroll)
$form.Controls.Add($footer)
$form.AcceptButton = $primary
$form.Add_Resize({
    $width = [Math]::Max(300,$form.ClientSize.Width-195)
    foreach ($label in @($hermesStatus,$tailscaleStatus,$serverStatus,$message)) { $label.MaximumSize = [Drawing.Size]::new($width,0) }
})

function Get-PrimaryAction {
    $d = $script:Diagnosis
    if ($script:Job) { return @{ Name='Busy'; Label='Aguarde…' } }
    if (!$d) { return @{ Name='Diagnose'; Label='Testar conexão' } }
    if ($d.Hermes.Code -eq 'Missing') { return @{ Name='Locate'; Label='Localizar Hermes' } }
    if ($d.Hermes.Code -ne 'Ready') { return @{ Name='Data'; Label='Selecionar pasta de dados' } }
    if ($d.Tailscale.Code -eq 'Missing') { return @{ Name='GetTailscale'; Label='Instalar Tailscale' } }
    if ($d.Tailscale.Code -ne 'Ready') { return @{ Name='OpenTailscale'; Label='Abrir Tailscale' } }
    if ($d.Server.Code -eq 'Unavailable') { return @{ Name='Server'; Label=$(if($script:NeedsLogin){'Configurar login'}else{'Configurar e iniciar'}) } }
    if ($d.Server.Code -eq 'Ready') {
        if ($script:Finished) { return @{ Name='Close'; Label='Concluir' } }
        return @{ Name='Install'; Label=$(if($d.HasTray){'Atualizar indicador'}else{'Instalar indicador'}) }
    }
    return @{ Name='Diagnose'; Label='Testar conexão' }
}

function Invoke-Primary {
    switch ((Get-PrimaryAction).Name) {
        Locate { Select-Hermes $false }
        Data { Select-Hermes $true }
        GetTailscale { Open-Link 'https://tailscale.com/docs/install/windows' }
        OpenTailscale { Open-Tailscale }
        Server {
            if ($script:NeedsLogin) {
                $login = Show-Login
                if ($login) { Start-Work 'Server' 'Testando o novo login…' $false $login.Username $login.Password }
            } else { Start-Work 'Server' 'Iniciando o servidor e verificando o login…' }
        }
        Install { Start-Work 'Install' 'Instalando o indicador na bandeja…' }
        Close { $form.Close() }
        Diagnose { Start-Work 'Diagnose' 'Testando a conexão…' }
    }
}

function Show-Login {
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = 'Configurar login do Hermes'
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.ClientSize = [Drawing.Size]::new(480,255)
    $dialog.Font = $form.Font
    $dialog.BackColor = $palette.Surface
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $layout = New-Object Windows.Forms.TableLayoutPanel
    $layout.Dock = 'Fill'
    $layout.Padding = [Windows.Forms.Padding]::new(18)
    $layout.ColumnCount = 2
    $null = $layout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Absolute',130))
    $null = $layout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent',100))
    $boxes = @()
    foreach ($name in @('Usuário','Senha','Confirmar senha')) {
        $label = New-Text $name
        $box = New-Object Windows.Forms.TextBox
        $box.Dock = 'Top'
        $box.BackColor = $palette.Panel
        $box.ForeColor = $palette.Ink
        $box.UseSystemPasswordChar = $boxes.Count -gt 0
        $box.MaxLength = if ($boxes.Count -eq 0) { 64 } else { 256 }
        $box.AccessibleName = $name
        $layout.Controls.Add($label,0,$boxes.Count)
        $layout.Controls.Add($box,1,$boxes.Count)
        $boxes += $box
    }
    $note = New-Text 'Use pelo menos 12 caracteres. A senha fica protegida nesta conta.'
    $note.MaximumSize = [Drawing.Size]::new(420,0)
    $layout.Controls.Add($note,0,3)
    $layout.SetColumnSpan($note,2)
    $actions = New-Flow
    $ok = New-Button 'Configurar' { $dialog.DialogResult='OK' } $true
    $cancel = New-Button 'Cancelar' { $dialog.DialogResult='Cancel' }
    $actions.Controls.AddRange(@($ok,$cancel))
    $layout.Controls.Add($actions,0,4)
    $layout.SetColumnSpan($actions,2)
    $dialog.Controls.Add($layout)
    $dialog.AcceptButton = $ok
    $dialog.CancelButton = $cancel
    try {
        while ($dialog.ShowDialog($form) -eq 'OK') {
            if ($boxes[0].Text -match '^[a-zA-Z0-9_.@-]{1,64}$' -and $boxes[1].Text.Length -ge 12 -and
                $boxes[1].Text -ceq $boxes[2].Text -and $boxes[1].Text -ceq $boxes[1].Text.Trim()) {
                return @{ Username=$boxes[0].Text; Password=$boxes[1].Text }
            }
            $dialog.DialogResult = 'None'
            $note.Text = 'Confira o usuário e confirme uma senha de pelo menos 12 caracteres.'
        }
    } finally { foreach ($box in $boxes) { $box.Clear() }; $dialog.Dispose() }
}

function Show-Maintenance {
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = 'Manutenção do Talaria'
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.Font = $form.Font
    $dialog.BackColor = $palette.Surface
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.AutoSize = $true
    $dialog.AutoSizeMode = 'GrowAndShrink'
    $layout = New-Flow $true
    $layout.Padding = [Windows.Forms.Padding]::new(17)
    $script:MaintenanceAction = ''
    $layout.Controls.Add((New-Text 'Manutenção' 16 $true))
    $repair = New-Button 'Reparar indicador' { $script:MaintenanceAction='Repair'; $dialog.Close() }
    $remove = New-Button 'Remover indicador' { $script:MaintenanceAction='RemoveTray'; $dialog.Close() }
    $revert = New-Button 'Reverter servidor' { $script:MaintenanceAction='RemoveServer'; $dialog.Close() }
    $repair.Enabled = $script:Diagnosis.HasTray -and $script:Diagnosis.Server.Code -eq 'Ready'
    $remove.Enabled = [bool]$script:Diagnosis.HasTray
    $revert.Enabled = [bool]$script:Diagnosis.ManagedServer
    foreach ($button in @($repair,$remove,$revert)) { $button.Margin = [Windows.Forms.Padding]::new(0,3,0,4) }
    $layout.Controls.AddRange(@($repair,$remove,$revert))
    $dialog.Controls.Add($layout)
    try { $null=$dialog.ShowDialog($form) } finally { $dialog.Dispose() }
    switch ($script:MaintenanceAction) {
        Repair { Start-Work 'Repair' 'Verificando e reparando o indicador…' }
        RemoveTray {
            if ([Windows.Forms.MessageBox]::Show($form,'Remover o indicador e sua inicialização no Windows?','Remover indicador','YesNo','Question') -eq 'Yes') {
                Start-Work 'RemoveTray' 'Removendo o indicador…'
            }
        }
        RemoveServer {
            if ([Windows.Forms.MessageBox]::Show($form,'Reverter a configuração encerra o servidor criado pelo Talaria e interrompe conexões ativas.','Reverter servidor','YesNo','Warning') -eq 'Yes') {
                Start-Work 'RemoveServer' 'Revertendo o servidor…'
            }
        }
    }
}

function Update-Controls {
    $busy = [bool]$script:Job
    $d = $script:Diagnosis
    foreach ($control in @($locate,$dataFolder,$getHermes,$verify,$port,$authGuide)) { $control.Enabled = !$busy }
    $getHermes.Visible = !$d -or $d.Hermes.Code -ne 'Ready'
    $authGuide.Visible = $d.Server.Code -in @('NoProvider','Unprotected') -or $script:NeedsLogin
    $maintenance.Enabled = !$busy -and ($d.HasTray -or $d.ManagedServer)
    $primary.Enabled = !$busy
    $primary.Text = (Get-PrimaryAction).Label
    $form.UseWaitCursor = $busy
}

function Show-Diagnosis($Result) {
    $script:Diagnosis = $Result
    $script:IgnorePortChange = $true
    try { $port.Value = $Result.Port } finally { $script:IgnorePortChange = $false }
    $hermesStatus.Text = if ($Result.Hermes.Code -eq 'Ready') { $Result.Hermes.Message + "`n" + $Result.Hermes.Data } else { $Result.Hermes.Message }
    $tailscaleStatus.Text = $Result.Tailscale.Message
    $serverStatus.Text = if ($Result.Endpoint) { $Result.Endpoint + "`n" + $Result.Server.Message } else { $Result.Server.Message }
    Update-Controls
}

function Start-Work([string]$Operation,[string]$Progress,[bool]$Suggest=$false,[string]$Username='',[string]$Password='') {
    if ($script:Job) { return }
    $script:Finished = $false
    $message.Text = $Progress
    $worker = [PowerShell]::Create()
    $null = $worker.AddScript({
        param($Core,$Op,$SelectedExe,$SelectedData,$SelectedPort,$SuggestPort,$LoginUser,$LoginPassword)
        . $Core
        if (Test-Path -LiteralPath $script:Pending) { Undo-SetupTransaction }
        $result = switch ($Op) {
            Server { Start-SetupServer $SelectedExe $SelectedData $SelectedPort $LoginUser $LoginPassword }
            Install { Install-SetupTray $SelectedExe $SelectedData $SelectedPort }
            Repair { Install-SetupTray $SelectedExe $SelectedData $SelectedPort $true }
            RemoveTray { Remove-SetupTray }
            RemoveServer { Remove-SetupServer }
            Diagnose { @{ Code='Diagnosis'; Message='' } }
        }
        $LoginPassword = $null
        @{ Result=$result; Diagnosis=(Get-SetupDiagnosis $SelectedExe $SelectedData $SelectedPort $SuggestPort) }
    }).AddArgument($script:CoreFile).AddArgument($Operation).AddArgument($script:ExeOverride).AddArgument($script:DataOverride).
        AddArgument([int]$port.Value).AddArgument($Suggest).AddArgument($Username).AddArgument($Password)
    $script:Job = @{ Worker=$worker; Operation=$Operation; Result=$worker.BeginInvoke() }
    $Password = $null
    Update-Controls
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 200
$timer.Add_Tick({
    if (!$script:Job -or !$script:Job.Result.IsCompleted) { return }
    $job = $script:Job
    $script:Job = $null
    try {
        $output = @($job.Worker.EndInvoke($job.Result))
        if (!$output.Count -or !$output[-1].Diagnosis) { throw 'O diagnóstico não foi concluído.' }
        $result = $output[-1]
        if ($job.Operation -eq 'Server') { $script:NeedsLogin = $result.Result.Code -eq 'NeedsLogin' }
        $script:Finished = $job.Operation -in @('Install','Repair') -and $result.Result.Code -eq 'Ready'
        Show-Diagnosis $result.Diagnosis
        if ($result.Result.Message) { $message.Text = $result.Result.Message }
        elseif ($result.Diagnosis.Server.Code -eq 'Ready') { $message.Text = 'Conexão e proteção verificadas. Você já pode instalar o indicador.' }
        else { $message.Text = 'Resolva a pendência indicada e verifique novamente.' }
    } catch {
        $errorMessage = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
        if ($errorMessage -match '(?i)password|secret|token') { $errorMessage = 'Confira a configuração de login e tente novamente.' }
        $message.Text = $errorMessage
        $script:Diagnosis = $null
    } finally { $job.Worker.Dispose(); Update-Controls }
})

$port.Add_ValueChanged({
    if ($script:IgnorePortChange -or $script:Job) { return }
    $script:Diagnosis = $null
    $script:NeedsLogin = $false
    $script:Finished = $false
    $serverStatus.Text = 'Porta alterada. Teste a conexão novamente.'
    Update-Controls
})
$form.Add_FormClosing({ param($sender,$eventArgs); if ($script:Job) { $eventArgs.Cancel=$true } })
$form.Add_KeyDown({ param($sender,$eventArgs); if ($eventArgs.KeyCode -eq 'Escape' -and !$script:Job) { $form.Close() } })
if (!$CheckControls) { $form.Add_Shown({ Start-Work 'Diagnose' 'Localizando o Hermes e o Tailscale…' $true }) }

try {
    if ($CheckControls) {
        foreach ($case in @(@('Missing','Missing','Pending','Locate'),@('MissingData','Ready','Pending','Data'),
            @('Ready','Missing','Pending','GetTailscale'),@('Ready','Disconnected','Pending','OpenTailscale'),
            @('Ready','Ready','Conflict','Diagnose'),@('Ready','Ready','Unprotected','Diagnose'),
            @('Ready','Ready','NoProvider','Diagnose'),@('Ready','Ready','Unavailable','Server'),@('Ready','Ready','Ready','Install'))) {
            Show-Diagnosis @{
                Hermes=@{ Code=$case[0]; Message='Hermes localizado.'; Data='C:\Apps\Hermes' }
                Tailscale=@{ Code=$case[1]; Message='Tailscale conectado.' }
                Server=@{ Code=$case[2]; Message='Conexão protegida verificada.' }
                Endpoint='http://100.64.0.10:9119'; Port=9119; HasTray=$false; ManagedServer=$false
            }
            if ((Get-PrimaryAction).Name -ne $case[3]) { throw "Unexpected primary action in $($case -join '/')." }
        }
        if ($form.AcceptButton -ne $primary -or $port.AccessibleName -eq '') { throw 'Keyboard entry points are missing.' }
        if ($PreviewWidth -gt 0) { $form.Width = $PreviewWidth }
        if ($CheckLive -or $PreviewFile) { $form.Show(); [Windows.Forms.Application]::DoEvents() }
        if ($CheckLive) {
            $timer.Start()
            Start-Work 'Diagnose' 'Verificando a instalação atual…' $true
            $deadline = [DateTime]::UtcNow.AddSeconds(18)
            while ($script:Job -and [DateTime]::UtcNow -lt $deadline) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
            if ($script:Job -or (Get-PrimaryAction).Name -ne 'Install' -or !$script:Diagnosis.HasTray) { throw 'O diagnóstico real não foi confirmado.' }
            Write-Output 'PASS live diagnostic and upgrade action'
        }
        if ($PreviewFile) {
            $bitmap = [Drawing.Bitmap]::new($form.Width,$form.Height)
            try { $form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$bitmap.Width,$bitmap.Height)); $bitmap.Save($PreviewFile) }
            finally { $bitmap.Dispose() }
        }
        Write-Output 'PASS diagnostic actions and keyboard entry points'
        return
    }
    Update-Controls
    $timer.Start()
    [Windows.Forms.Application]::Run($form)
} finally { $timer.Dispose(); $form.Dispose() }
