param([switch]$CheckControls,[switch]$CheckLive,[string]$PreviewFile,[int]$PreviewWidth,[ValidateSet('System','Light','Dark')][string]$PreviewTheme='System')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$script:CoreFile = Join-Path $PSScriptRoot 'Setup-Core.ps1'
$script:Diagnosis = $null
$script:ExeOverride = ''
$script:DataOverride = ''
$script:Job = $null
$script:NeedsLogin = $false
$script:IgnorePortChange = $false
$script:PortEdited = $false
$script:Finished = $false
$script:SkipDesktop = $false
$script:NextTailscaleCheck = $null
$installer = Join-Path $PSScriptRoot 'Hermes.SetupLauncher.exe'
$assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($installer))
[Talaria.UI.ChromeForm]::EnablePerMonitorDpi()
[Windows.Forms.Application]::EnableVisualStyles()
[Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
$palette = [Talaria.UI.Palette]::new($PreviewTheme)

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
    $button = [Talaria.UI.RoundedButton]::new($palette,$Prominent)
    $button.Text = $Text
    $button.Margin = [Windows.Forms.Padding]::new(0,0,8,0)
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

$form = [Talaria.UI.ChromeForm]::new($true)
$form.Text = 'Talaria Setup'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = [Drawing.Size]::new(740,575)
$form.MinimumSize = [Drawing.Size]::new(555,460)
$form.Font = [Drawing.Font]::new('Segoe UI',10)
$form.BackColor = $palette.Surface
$form.ForeColor = $palette.Ink

$footer = New-Object Windows.Forms.TableLayoutPanel
$footer.Dock = 'Bottom'
$footer.Height = 70
$footer.Padding = [Windows.Forms.Padding]::new(20,14,12,12)
$footer.ColumnCount = 2
$null = $footer.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent',100))
$null = $footer.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('AutoSize'))
$footer.BackColor = $palette.Surface
$secondary = New-Flow
$verify = New-Button 'Check again' { Start-Work 'Diagnose' 'Checking the installation…' (!$script:PortEdited) }
$maintenance = New-Button 'Maintenance' { Show-Maintenance }
$secondary.Controls.AddRange(@($verify,$maintenance))
$primary = New-Button 'Checking…' { Invoke-Primary } $true
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
$body.Padding = [Windows.Forms.Padding]::new(24,6,24,12)
$header = New-Flow
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
$heading = New-Flow $true
$title = New-Text 'TALARIA' 25 $true
$title.ForeColor = $palette.Accent
$title.Margin = [Windows.Forms.Padding]::new(0,0,0,2)
$heading.Controls.Add($title)
$heading.Controls.Add((New-Text 'Hermes server indicator'))
$header.Controls.Add($heading)
$header.Margin = [Windows.Forms.Padding]::new(0,3,0,11)
$body.Controls.Add($header)

function Add-StatusRow([string]$Title, [Windows.Forms.Label]$Detail, [Windows.Forms.Control]$Actions) {
    $row = New-Object Windows.Forms.TableLayoutPanel
    $row.Dock = 'Top'
    $row.AutoSize = $true
    $row.AutoSizeMode = 'GrowAndShrink'
    $row.ColumnCount = 2
    $row.Padding = [Windows.Forms.Padding]::new(0,10,0,9)
    $row.Margin = [Windows.Forms.Padding]::new(0)
    $divider = New-Object Windows.Forms.Panel
    $divider.Dock = 'Top'
    $divider.Height = 1
    $divider.Margin = [Windows.Forms.Padding]::new(0)
    $divider.BackColor = $palette.Border
    $body.Controls.Add($divider)
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
    catch { $message.Text = "Open $Url" }
}

function Select-Hermes([bool]$Data) {
    if ($Data) {
        $dialog = New-Object Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Select the Hermes data folder.'
        $dialog.ShowNewFolderButton = $false
        try { if ($dialog.ShowDialog($form) -eq 'OK') { $script:DataOverride=$dialog.SelectedPath; Start-Work 'Diagnose' 'Checking the data folder…' } }
        finally { $dialog.Dispose() }
    } else {
        $dialog = New-Object Windows.Forms.OpenFileDialog
        $dialog.Title = 'Select the Hermes executable'
        $dialog.Filter = 'Hermes executable (hermes.exe)|hermes.exe|Executables (*.exe)|*.exe'
        try {
            if ($dialog.ShowDialog($form) -eq 'OK') {
                $script:ExeOverride=$dialog.FileName
                $script:DataOverride=''
                Start-Work 'Diagnose' 'Checking the selected Hermes installation…'
            }
        } finally { $dialog.Dispose() }
    }
}

function Open-Tailscale {
    $message.Text = 'Choose Log in in the Tailscale tray menu. Talaria will check the connection automatically.'
    if ($script:Diagnosis.Tailscale.App) {
        try { Start-Process -FilePath $script:Diagnosis.Tailscale.App -WindowStyle Normal }
        catch { $message.Text = 'Open Tailscale from the Start menu and try again.' }
    } else { $message.Text = 'Open Tailscale from the Start menu, sign in, and check again.' }
    $script:NextTailscaleCheck = [DateTime]::UtcNow.AddSeconds(4)
}

$hermesStatus = New-Text 'Waiting for checks'
$hermesActions = New-Flow
$locate = New-Button 'Locate Hermes' { Select-Hermes $false }
$dataFolder = New-Button 'Data folder' { Select-Hermes $true }
$getHermes = New-Button 'Installation guide' { Open-Link 'https://hermes-agent.nousresearch.com/docs/user-guide/windows-native' }
$hermesActions.Controls.AddRange(@($locate,$dataFolder,$getHermes))
$continueWithoutDesktop = New-Button 'Continue without Desktop' {
    $script:SkipDesktop = $true
    Update-Controls
}
$hermesOptions = New-Flow $true
$hermesOptions.Controls.AddRange(@($hermesActions,$continueWithoutDesktop))
Add-StatusRow 'Hermes' $hermesStatus $hermesOptions
$tailscaleStatus = New-Text 'Waiting for checks'
$tailscaleOptions = New-Flow
$tailscaleGuide = New-Button 'Installation guide' { Open-Link 'https://tailscale.com/docs/install/windows' }
$tailscaleOptions.Controls.Add($tailscaleGuide)
Add-StatusRow 'Tailscale' $tailscaleStatus $tailscaleOptions

$serverStatus = New-Text 'Waiting for checks'
$connectionActions = New-Flow
$portLabel = New-Text 'Port'
$portLabel.Margin = [Windows.Forms.Padding]::new(0,7,8,0)
$port = New-Object Windows.Forms.NumericUpDown
$port.Minimum = 1
$port.Maximum = 65535
$port.Value = 9119
$port.Width = 88
$port.BackColor = $palette.Surface
$port.ForeColor = $palette.Ink
$port.Margin = [Windows.Forms.Padding]::new(0,5,12,0)
$port.AccessibleName = 'Hermes server port'
$authGuide = New-Button 'Authentication guide' { Open-Link 'https://hermes-agent.nousresearch.com/docs/user-guide/desktop#connecting-to-a-remote-backend' }
$connectionActions.Controls.AddRange(@($portLabel,$port,$authGuide))
Add-StatusRow 'Connection' $serverStatus $connectionActions

$message = New-Text ''
$message.ForeColor = $palette.Accent
$message.Margin = [Windows.Forms.Padding]::new(0,14,0,3)
$body.Controls.Add($message)
$scroll.Controls.Add($body)
$form.Controls.Add($scroll)
$form.Controls.Add($footer)
$form.Controls.Add($form.Caption($palette,'Talaria Setup',$null))
$form.AcceptButton = $primary
$form.Add_Resize({
    $width = [Math]::Max(220,$form.ClientSize.Width-[int](195*$form.DeviceDpi/96))
    foreach ($label in @($hermesStatus,$tailscaleStatus,$serverStatus,$message)) { $label.MaximumSize = [Drawing.Size]::new($width,0) }
})

function Get-PrimaryAction {
    $d = $script:Diagnosis
    if ($script:Job) { return @{ Name='Busy'; Label='Please wait…' } }
    if (!$d) { return @{ Name='Diagnose'; Label='Test connection' } }
    if ($d.Hermes.Code -eq 'AliasDisabled') { return @{ Name='Alias'; Label='Open app alias settings' } }
    if ($d.Hermes.Code -eq 'MissingData') { return @{ Name='Data'; Label='Select data folder' } }
    if ($d.Hermes.Code -eq 'Missing' -and $d.Desktop.Code -eq 'Missing' -and !$script:ExeOverride) {
        return @{ Name='InstallHermes'; Label='Install Hermes Desktop' }
    }
    if ($d.Hermes.Code -ne 'Ready') { return @{ Name='Locate'; Label='Locate Hermes' } }
    if ($d.Desktop.Code -eq 'Missing' -and !$script:SkipDesktop) {
        return @{ Name='InstallHermes'; Label='Install Hermes Desktop' }
    }
    if ($d.Tailscale.Code -eq 'Missing') { return @{ Name='InstallTailscale'; Label='Install Tailscale' } }
    if ($d.Tailscale.Code -ne 'Ready') { return @{ Name='OpenTailscale'; Label='Open Tailscale' } }
    if ($d.Server.Code -eq 'Unavailable') { return @{ Name='Server'; Label=$(if($script:NeedsLogin){'Set up sign-in'}else{'Set up and start'}) } }
    if ($d.Server.Code -eq 'Ready') {
        if ($script:Finished) { return @{ Name='Close'; Label='Finish' } }
        return @{ Name='Install'; Label=$(if($d.HasTray){'Update indicator'}else{'Install indicator'}) }
    }
    return @{ Name='Diagnose'; Label='Test connection' }
}

function Invoke-Primary {
    switch ((Get-PrimaryAction).Name) {
        Locate { Select-Hermes $false }
        Data { Select-Hermes $true }
        Alias { Open-Link 'ms-settings:appsfeatures-appexecutionalias' }
        InstallHermes {
            $progress = if ($script:Diagnosis.Hermes.Code -eq 'Ready') { 'Building Hermes Desktop…' } else { 'Opening the official Hermes installer…' }
            Start-Work 'InstallHermes' $progress (!$script:PortEdited)
        }
        InstallTailscale { Start-Work 'InstallTailscale' 'Opening the official Tailscale installer…' (!$script:PortEdited) }
        OpenTailscale { Open-Tailscale }
        Server {
            if ($script:NeedsLogin) {
                $login = Show-Login
                if ($login) { Start-Work 'Server' 'Testing the new sign-in…' $false $login.Username $login.Password }
            } else { Start-Work 'Server' 'Starting the server and checking sign-in…' }
        }
        Install { Start-Work 'Install' 'Installing the tray indicator…' }
        Close { $form.Close() }
        Diagnose { Start-Work 'Diagnose' 'Testing the connection…' (!$script:PortEdited) }
    }
}

function Show-Login {
    $dialog = [Talaria.UI.ChromeForm]::new($false)
    $dialog.Text = 'Set up Hermes sign-in'
    $dialog.StartPosition = 'CenterParent'
    $dialog.ShowInTaskbar = $false
    $dialog.ClientSize = [Drawing.Size]::new(480,275)
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
    foreach ($name in @('Username','Password','Confirm password')) {
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
    $note = New-Text 'Use at least 12 characters. The password is protected for this Windows account.'
    $note.MaximumSize = [Drawing.Size]::new(420,0)
    $layout.Controls.Add($note,0,3)
    $layout.SetColumnSpan($note,2)
    $actions = New-Flow
    $ok = New-Button 'Set up' { $dialog.DialogResult='OK' } $true
    $cancel = New-Button 'Cancel' { $dialog.DialogResult='Cancel' }
    $actions.Controls.AddRange(@($ok,$cancel))
    $layout.Controls.Add($actions,0,4)
    $layout.SetColumnSpan($actions,2)
    $dialog.Controls.Add($layout)
    $dialog.Controls.Add($dialog.Caption($palette,$dialog.Text,$null))
    $dialog.AcceptButton = $ok
    $dialog.CancelButton = $cancel
    try {
        while ($dialog.ShowDialog($form) -eq 'OK') {
            if ($boxes[0].Text -match '^[a-zA-Z0-9_.@-]{1,64}$' -and $boxes[1].Text.Length -ge 12 -and
                $boxes[1].Text -ceq $boxes[2].Text -and $boxes[1].Text -ceq $boxes[1].Text.Trim()) {
                return @{ Username=$boxes[0].Text; Password=$boxes[1].Text }
            }
            $dialog.DialogResult = 'None'
            $note.Text = 'Check the username and confirm a password of at least 12 characters.'
        }
    } finally { foreach ($box in $boxes) { $box.Clear() }; $dialog.Dispose() }
}

function Show-Maintenance {
    $dialog = [Talaria.UI.ChromeForm]::new($false)
    $dialog.Text = 'Talaria Maintenance'
    $dialog.StartPosition = 'CenterParent'
    $dialog.ShowInTaskbar = $false
    $dialog.Font = $form.Font
    $dialog.BackColor = $palette.Surface
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ClientSize = [Drawing.Size]::new(350,225)
    $layout = New-Flow $true
    $layout.Dock = 'Fill'
    $layout.Padding = [Windows.Forms.Padding]::new(17)
    $script:MaintenanceAction = ''
    $repair = New-Button 'Repair indicator' { $script:MaintenanceAction='Repair'; $dialog.Close() }
    $remove = New-Button 'Remove indicator' { $script:MaintenanceAction='RemoveTray'; $dialog.Close() }
    $revert = New-Button 'Revert server setup' { $script:MaintenanceAction='RemoveServer'; $dialog.Close() }
    $repair.Enabled = $script:Diagnosis.HasTray -and $script:Diagnosis.Server.Code -eq 'Ready'
    $remove.Enabled = [bool]$script:Diagnosis.HasTray
    $revert.Enabled = [bool]$script:Diagnosis.ManagedServer
    foreach ($button in @($repair,$remove,$revert)) { $button.Margin = [Windows.Forms.Padding]::new(0,3,0,4) }
    $layout.Controls.AddRange(@($repair,$remove,$revert))
    $dialog.Controls.Add($layout)
    $dialog.Controls.Add($dialog.Caption($palette,$dialog.Text,$null))
    try { $null=$dialog.ShowDialog($form) } finally { $dialog.Dispose() }
    switch ($script:MaintenanceAction) {
        Repair { Start-Work 'Repair' 'Checking and repairing the indicator…' }
        RemoveTray {
            if ([Talaria.UI.ChromeForm]::Prompt($palette,$form,'Remove indicator','Remove the indicator and stop it from starting with Windows?','Remove',$true)) {
                Start-Work 'RemoveTray' 'Removing the indicator…'
            }
        }
        RemoveServer {
            if ([Talaria.UI.ChromeForm]::Prompt($palette,$form,'Revert server setup','Reverting setup stops the server created by Talaria and disconnects active clients.','Revert',$true)) {
                Start-Work 'RemoveServer' 'Reverting server setup…'
            }
        }
    }
}

function Update-Controls {
    $busy = [bool]$script:Job
    $d = $script:Diagnosis
    foreach ($control in @($locate,$dataFolder,$getHermes,$continueWithoutDesktop,$tailscaleGuide,$verify,$port,$authGuide)) {
        $control.Enabled = !$busy
    }
    $getHermes.Visible = $d -and ($d.Hermes.Code -ne 'Ready' -or ($d.Desktop.Code -eq 'Missing' -and !$script:SkipDesktop))
    $continueWithoutDesktop.Visible = $d.Hermes.Code -eq 'Ready' -and $d.Desktop.Code -eq 'Missing' -and !$script:SkipDesktop
    $tailscaleGuide.Visible = $d.Tailscale.Code -eq 'Missing'
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
    $hermesStatus.Text = if ($Result.Desktop.Code -eq 'Ready' -and $Result.Hermes.Code -eq 'Ready') {
        'Hermes Desktop and command line found.'
    } else { $Result.Desktop.Message + "`n" + $Result.Hermes.Message }
    if ($Result.Hermes.Code -eq 'Ready') { $hermesStatus.Text += "`n" + $Result.Hermes.Data }
    $tailscaleStatus.Text = $Result.Tailscale.Message
    $serverStatus.Text = if ($Result.Endpoint) { $Result.Endpoint + "`n" + $Result.Server.Message } else { $Result.Server.Message }
    Update-Controls
}

function Start-Work([string]$Operation,[string]$Progress,[bool]$Suggest=$false,[string]$Username='',[string]$Password='') {
    if ($script:Job) { return }
    $script:Finished = $false
    if ($Progress) { $message.Text = $Progress }
    $worker = [PowerShell]::Create()
    $null = $worker.AddScript({
        param($Core,$Op,$SelectedExe,$SelectedData,$SelectedPort,$SuggestPort,$LoginUser,$LoginPassword)
        . $Core
        if ($Op -eq 'CheckTailscale') {
            if ((Get-TailscaleInstall).Code -ne 'Ready') { return @{ WaitingForTailscale=$true } }
        }
        if (Test-Path -LiteralPath $script:Pending) { Undo-SetupTransaction }
        if ($Op -in @('InstallHermes','InstallTailscale')) {
            . (Join-Path (Split-Path $Core -Parent) 'Setup-Dependencies.ps1')
            $name = if ($Op -eq 'InstallHermes') { 'HermesDesktop' } else { 'Tailscale' }
            $label = if ($Op -eq 'InstallHermes') { 'Hermes Desktop' } else { 'Tailscale' }
            $before = Get-SetupDiagnosis $SelectedExe $SelectedData $SelectedPort $false
            $errorMessage = $null
            $result = $null
            try { $result = Install-SetupDependency $name $before }
            catch [ApplicationException] { $errorMessage = $_.Exception.Message }
            $after = Get-SetupDiagnosis $SelectedExe $SelectedData $SelectedPort $SuggestPort
            $available = if ($Op -eq 'InstallHermes') { $after.Desktop.Code -eq 'Ready' } else { $after.Tailscale.Code -ne 'Missing' }
            $messageText = if ($errorMessage) { $errorMessage }
                elseif ($result.ExitCode -in @(1641,3010)) { 'Windows needs to restart. Reopen Talaria after restarting and select Check again.' }
                elseif ($available -and $after.Tailscale.Code -eq 'Disconnected' -and $Op -eq 'InstallTailscale') { 'Open Tailscale and sign in. Talaria will check the connection automatically.' }
                elseif ($available) { "$label is available. Continue with the next step." }
                else { "$label is still missing. If you cancelled setup or it did not finish, you can try again." }
            return @{ Result=@{ Code='Dependency'; Message=$messageText }; Diagnosis=$after }
        }
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
    if (!$script:Job) {
        if ($script:NextTailscaleCheck -and [DateTime]::UtcNow -ge $script:NextTailscaleCheck) {
            $script:NextTailscaleCheck = $null
            Start-Work 'CheckTailscale' '' (!$script:PortEdited)
        }
        return
    }
    if (!$script:Job.Result.IsCompleted) { return }
    $job = $script:Job
    $script:Job = $null
    try {
        $output = @($job.Worker.EndInvoke($job.Result))
        if ($output.Count -and $output[-1].WaitingForTailscale) {
            $script:NextTailscaleCheck = [DateTime]::UtcNow.AddSeconds(4)
            return
        }
        if (!$output.Count -or !$output[-1].Diagnosis) { throw [ApplicationException]::new('The diagnosis did not finish.') }
        $result = $output[-1]
        if ($job.Operation -eq 'Server') { $script:NeedsLogin = $result.Result.Code -eq 'NeedsLogin' }
        $script:Finished = $job.Operation -in @('Install','Repair') -and $result.Result.Code -eq 'Ready'
        Show-Diagnosis $result.Diagnosis
        if ($result.Diagnosis.Tailscale.Code -ne 'Disconnected') { $script:NextTailscaleCheck = $null }
        elseif ($job.Operation -eq 'InstallTailscale') { $script:NextTailscaleCheck = [DateTime]::UtcNow.AddSeconds(4) }
        if ($result.Result.Message) { $message.Text = $result.Result.Message }
        elseif ($result.Diagnosis.Server.Code -eq 'Ready') { $message.Text = 'Connection and sign-in protection verified. The indicator is ready to install.' }
        else { $message.Text = 'Resolve the issue shown above and check again.' }
    } catch {
        $message.Text = 'An unexpected error occurred. Check that Hermes and Tailscale are available, then try again.'
        for ($failure = $_.Exception; $failure; $failure = $failure.InnerException) {
            if ($failure -is [ApplicationException]) { $message.Text = $failure.Message; break }
        }
        $script:Diagnosis = $null
    } finally { $job.Worker.Dispose(); Update-Controls }
})

$port.Add_ValueChanged({
    if ($script:IgnorePortChange -or $script:Job) { return }
    $script:PortEdited = $true
    $script:Diagnosis = $null
    $script:NeedsLogin = $false
    $script:Finished = $false
    $serverStatus.Text = 'Port changed. Test the connection again.'
    Update-Controls
})
$form.Add_FormClosing({ param($sender,$eventArgs); if ($script:Job) { $eventArgs.Cancel=$true } })
$form.Add_KeyDown({ param($sender,$eventArgs); if ($eventArgs.KeyCode -eq 'Escape' -and !$script:Job) { $form.Close() } })
if (!$CheckControls) { $form.Add_Shown({ Start-Work 'Diagnose' 'Looking for Hermes and Tailscale…' $true }) }

try {
    if ($CheckControls) {
        foreach ($case in @(@('Missing','Missing','Missing','Pending','InstallHermes'),@('AliasDisabled','Ready','Ready','Pending','Alias'),
            @('MissingData','Ready','Ready','Pending','Data'),@('Ready','Missing','Ready','Ready','InstallHermes'),
            @('Ready','Ready','Missing','Pending','InstallTailscale'),@('Ready','Ready','Disconnected','Pending','OpenTailscale'),
            @('Ready','Ready','Ready','Conflict','Diagnose'),@('Ready','Ready','Ready','Unprotected','Diagnose'),
            @('Ready','Ready','Ready','NoProvider','Diagnose'),@('Ready','Ready','Ready','Unavailable','Server'),@('Ready','Ready','Ready','Ready','Install'))) {
            Show-Diagnosis @{
                Hermes=@{ Code=$case[0]; Message='Hermes found.'; Data='C:\Apps\Hermes' }
                Desktop=@{ Code=$case[1]; Message='Hermes Desktop found.' }
                Tailscale=@{ Code=$case[2]; Message='Tailscale connected.' }
                Server=@{ Code=$case[3]; Message='Protected connection verified.' }
                Endpoint='http://100.64.0.10:9119'; Port=9119; HasTray=$false; ManagedServer=$false
            }
            if ((Get-PrimaryAction).Name -ne $case[4]) { throw "Unexpected primary action in $($case -join '/')." }
            if ($case[0] -eq 'Ready' -and $case[1] -eq 'Missing') {
                $script:SkipDesktop = $true
                if ((Get-PrimaryAction).Name -ne 'Install') { throw 'CLI-only setup could not continue.' }
                $script:SkipDesktop = $false
            }
        }
        if ($form.AcceptButton -ne $primary -or $port.AccessibleName -eq '') { throw 'Keyboard entry points are missing.' }
        $message.Text = 'Connection and sign-in protection verified. The indicator is ready to install.'
        if ($PreviewWidth -gt 0) { $form.Width = $PreviewWidth }
        if ($CheckLive -or $PreviewFile) { $form.Show(); [Windows.Forms.Application]::DoEvents() }
        if ($CheckLive) {
            $timer.Start()
            Start-Work 'Diagnose' 'Checking the current installation…' $true
            $deadline = [DateTime]::UtcNow.AddSeconds(18)
            while ($script:Job -and [DateTime]::UtcNow -lt $deadline) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
            if ($script:Job -or (Get-PrimaryAction).Name -ne 'Install' -or !$script:Diagnosis.HasTray) { throw 'The live diagnosis could not be verified.' }
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
