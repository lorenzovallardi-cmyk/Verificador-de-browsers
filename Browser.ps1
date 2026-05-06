# ===========================================================================
#   VERIFICADOR CHROME - VERSÃO OTIMIZADA COM MULTITHREADING (CORRIGIDA)
# ===========================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Management.Automation

$form = New-Object System.Windows.Forms.Form
$form.Text = "Verificador Chrome (Paralelo)"
$form.Size = "650,550"
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"

# Componentes da Interface
$label = New-Object System.Windows.Forms.Label
$label.Text = "Nomes dos PCs (um por linha):"
$label.Location = "20,10"
$label.AutoSize = $true
$form.Controls.Add($label)

$txtPCs = New-Object System.Windows.Forms.TextBox
$txtPCs.Multiline = $true
$txtPCs.Location = "20,30"
$txtPCs.Size = "250,150"
$txtPCs.ScrollBars = "Vertical"
$form.Controls.Add($txtPCs)

$btn = New-Object System.Windows.Forms.Button
$btn.Text = "VERIFICAR CHROME"
$btn.Location = "20,190"
$btn.Size = "250,40"
$btn.BackColor = "LightGreen"
$form.Controls.Add($btn)

$grid = New-Object System.Windows.Forms.ListView
$grid.View = "Details"
$grid.Location = "290,30"
$grid.Size = "330,430"
$grid.FullRowSelect = $true
$grid.GridLines = $true
$grid.Columns.Add("PC", 100) | Out-Null
$grid.Columns.Add("WinRM", 80) | Out-Null
$grid.Columns.Add("Chrome", 130) | Out-Null
$form.Controls.Add($grid)

$log = New-Object System.Windows.Forms.TextBox
$log.Multiline = $true
$log.Location = "20,240"
$log.Size = "250,220"
$log.ReadOnly = $true
$log.BackColor = "Black"
$log.ForeColor = "White"
$form.Controls.Add($log)

$btn.Add_Click({
    $lista = $txtPCs.Text.Split("`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    if ($lista.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show("Digite ao menos um PC"); return }

    $grid.Items.Clear()
    $btn.Enabled = $false
    $log.Clear()
    $log.AppendText("Iniciando verificação paralela...`r`n")

    # Configurações para RunspacePool (Processamento Paralelo)
    $maxThreads = 5 # Quantidade de PCs verificados simultaneamente
    $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $runspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $maxThreads, $sessionState, $Host)
    $runspacePool.Open()

    $jobs = @()

    foreach ($pc in $lista) {
        $item = New-Object System.Windows.Forms.ListViewItem($pc)
        $item.SubItems.Add("Pendente") 
        $item.SubItems.Add("...")     
        $grid.Items.Add($item)
        $form.Refresh()

        $scriptBlock = [ScriptBlock]::Create({
            param($computer, $logControl)

            function Enable-RemoteWinRM ($comp) {
                try {
                    $logControl.Invoke([Action[string]]{ param($text) $logControl.AppendText($text) }, "[$comp] Ativando WinRM...`r`n")
                    $cmd = 'powershell.exe -Command "Enable-PSRemoting -Force -SkipNetworkProfileCheck; winrm quickconfig -quiet -force"'
                    $process = ([WMICLASS]"\\$comp\ROOT\CIMV2:Win32_Process").Create($cmd)
                    return ($process.ReturnValue -eq 0)
                } catch { return $false }
            }

            function Disable-RemoteWinRM ($comp) {
                try {
                    $logControl.Invoke([Action[string]]{ param($text) $logControl.AppendText($text) }, "[$comp] Desativando WinRM...`r`n")
                    $cmd = 'powershell.exe -Command "winrm quickconfig -remover -force"'
                    $process = ([WMICLASS]"\\$comp\ROOT\CIMV2:Win32_Process").Create($cmd)
                    return ($process.ReturnValue -eq 0)
                } catch { return $false }
            }

            $res = @{ PC = $computer; WinRM = "Falha"; Chrome = "Erro"; Activated = $false }

            if (Test-Connection -ComputerName $computer -Count 1 -Quiet) {
                if (Enable-RemoteWinRM -comp $computer) {
                    $res.WinRM = "Ativado"
                    $res.Activated = $true
                    Start-Sleep -Seconds 3
                    try {
                        $v = Invoke-Command -ComputerName $computer -ScriptBlock {
                            $reg = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe" -ErrorAction SilentlyContinue
                            if ($reg) { return (Get-Item $reg."(Default)").VersionInfo.ProductVersion }
                            return "Não instalado"
                        } -ErrorAction Stop
                        $res.Chrome = $v
                    } catch { $res.Chrome = "Erro de Conexão" }
                    
                    Disable-RemoteWinRM -comp $computer
                } else { $res.WinRM = "Falha WMI" }
            } else { $res.WinRM = "Offline"; $res.Chrome = "---" }
            return $res
        })

        $ps = [System.Management.Automation.PowerShell]::Create().AddScript($scriptBlock).AddArgument($pc).AddArgument($log)
        $ps.RunspacePool = $runspacePool
        $jobs += New-Object PSObject -Property @{
            PC = $pc; PS = $ps; Async = $ps.BeginInvoke(); Index = $grid.Items.Count - 1; Processed = $false
        }
    }

    while ($jobs.Where({!$_.Processed}).Count -gt 0) {
        foreach ($job in $jobs.Where({$_.Async.IsCompleted -and !$_.Processed})) {
            $result = $job.PS.EndInvoke($job.Async)
            $grid.Items[$job.Index].SubItems[1].Text = $result.WinRM
            $grid.Items[$job.Index].SubItems[2].Text = $result.Chrome
            $job.PS.Dispose()
            $job.Processed = $true
            $form.Refresh()
        }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }

    $runspacePool.Close()
    $runspacePool.Dispose()
    $btn.Enabled = $true
    $log.AppendText("Concluído!`r`n")
})

$form.ShowDialog()
