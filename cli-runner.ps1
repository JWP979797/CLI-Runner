Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

Add-Type @"
using System;
using System.Runtime.InteropServices;

public class CueBanner {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, string lParam);
}
"@

$mutexName = "Global\SmartportCliRunnerSingleInstance"
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)

if (-not $createdNew) {
    [System.Windows.Forms.MessageBox]::Show(
        "CLI Runner is already running.",
        "CLI Runner",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
    exit
}

$dataDir = "C:\cli-runner\data"
$configPath = Join-Path $dataDir "projects.json"

if (!(Test-Path $dataDir)) {
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
}

function Set-Placeholder($textBox, $placeholder) {
    [CueBanner]::SendMessage($textBox.Handle, 0x1501, [IntPtr]1, $placeholder) | Out-Null
}

function Load-Projects {
    if (!(Test-Path $configPath)) {
        "[]" | Set-Content $configPath -Encoding UTF8
    }

    $content = Get-Content $configPath -Raw -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($content)) {
        return @()
    }

    $projects = $content | ConvertFrom-Json

    if ($null -eq $projects) {
        return @()
    }

    return @($projects)
}

function Save-Projects($projects) {
    $projectArray = @($projects)

    if ($projectArray.Count -eq 0) {
        "[]" | Set-Content $configPath -Encoding UTF8
        return
    }

    $projectArray | ConvertTo-Json -Depth 50 | Set-Content $configPath -Encoding UTF8
}

function Build-FullCommand($agent, $commandArgs) {
    if ([string]::IsNullOrWhiteSpace($agent)) {
        return ""
    }

    $agentValue = $agent.Trim()

    if ([string]::IsNullOrWhiteSpace($commandArgs)) {
        return $agentValue
    }

    return ($agentValue + " " + $commandArgs.Trim())
}

function Build-LocalRunCommand($agent, $commandArgs, $authType, $apiKey, $runner) {
    $baseCommand = Build-FullCommand $agent $commandArgs

    if ([string]::IsNullOrWhiteSpace($baseCommand)) {
        return ""
    }

    $authTypeValue = Normalize-AuthType $authType

    if ($authTypeValue -ne "api-key") {
        return $baseCommand
    }

    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        return $baseCommand
    }

    if ($runner -eq "cmd") {
        return ('set "OPENAI_API_KEY=' + (Escape-CmdEnvValue $apiKey) + '" && ' + $baseCommand)
    }

    return ("`$env:OPENAI_API_KEY='" + (Escape-PowerShellSingleQuoted $apiKey) + "'; " + $baseCommand)
}

function Normalize-ExecutionMode($executionMode) {
    if ([string]::IsNullOrWhiteSpace($executionMode)) {
        return "local"
    }

    if ($executionMode.Trim().ToLower() -eq "docker") {
        return "docker"
    }

    return "local"
}

function Normalize-Agent($agent) {
    if ([string]::IsNullOrWhiteSpace($agent)) {
        return "codex"
    }

    $value = $agent.Trim().ToLower()

    if ($value -eq "claude" -or $value -eq "claude-code" -or $value -eq "claude code") {
        return "claude"
    }

    return "codex"
}

function Normalize-AuthType($authType) {
    if ([string]::IsNullOrWhiteSpace($authType)) {
        return "saved-login"
    }

    $value = $authType.Trim().ToLower()

    if ($value -eq "api-key" -or $value -eq "apikey" -or $value -eq "api key") {
        return "api-key"
    }

    return "saved-login"
}

function Escape-PowerShellSingleQuoted($value) {
    if ($null -eq $value) {
        return ""
    }

    return $value.ToString().Replace("'", "''")
}

function Escape-CmdEnvValue($value) {
    if ($null -eq $value) {
        return ""
    }

    return $value.ToString().Replace('"', '\"')
}

function Mask-Secret($value) {
    if ([string]::IsNullOrWhiteSpace($value)) {
        return ""
    }

    $text = $value.ToString()

    if ($text.Length -le 8) {
        return "********"
    }

    return ($text.Substring(0, 4) + "..." + $text.Substring($text.Length - 4))
}

function Get-DefaultDockerImage($agent) {
    $agentValue = Normalize-Agent $agent

    if ($agentValue -eq "claude") {
        return "cli-runner-claude:latest"
    }

    return "cli-runner-codex:latest"
}

function Get-DefaultDockerWorkdir {
    return "/workspace"
}

function Get-DockerAgentDataVolumeName($agent) {
    $agentValue = Normalize-Agent $agent

    if ($agentValue -eq "claude") {
        return "cli-runner-claude-data"
    }

    return "cli-runner-codex-data"
}

function Get-DockerAgentDataContainerPath($agent) {
    $agentValue = Normalize-Agent $agent

    if ($agentValue -eq "claude") {
        return "/root/.claude"
    }

    return "/root/.codex"
}

function Get-DockerAgentDataVolumeValue($agent) {
    return (Get-DockerAgentDataVolumeName $agent) + ":" + (Get-DockerAgentDataContainerPath $agent)
}

function Should-MountDockerAgentData($agent) {
    return $true
}

function Quote-CommandValue($value) {
    if ($null -eq $value) {
        return '""'
    }

    return '"' + $value.ToString().Replace('"', '\"') + '"'
}

function Build-DockerCommand($projectPath, $agent, $commandArgs, $dockerImage, $dockerWorkdir, $dockerHost, $authType, $apiKey) {
    $localCommand = Build-FullCommand $agent $commandArgs

    if ([string]::IsNullOrWhiteSpace($localCommand)) {
        return ""
    }

    if ([string]::IsNullOrWhiteSpace($dockerImage)) {
        $dockerImage = Get-DefaultDockerImage $agent
    }

    if ([string]::IsNullOrWhiteSpace($dockerWorkdir)) {
        $dockerWorkdir = Get-DefaultDockerWorkdir
    }

    $volumeValue = $projectPath + ":" + $dockerWorkdir
    $parts = @("docker")

    if (![string]::IsNullOrWhiteSpace($dockerHost)) {
        $parts += "-H"
        $parts += (Quote-CommandValue $dockerHost.Trim())
    }

    $parts += "run"
    $parts += "--rm"
    $parts += "-it"

    if (Should-MountDockerAgentData $agent) {
        $agentDataVolumeValue = Get-DockerAgentDataVolumeValue $agent
        $parts += "-v"
        $parts += (Quote-CommandValue $agentDataVolumeValue)
    }

    if ((Normalize-AuthType $authType) -eq "api-key" -and ![string]::IsNullOrWhiteSpace($apiKey)) {
        $parts += "-e"
        $parts += (Quote-CommandValue ("OPENAI_API_KEY=" + $apiKey))
    }

    $parts += "-v"
    $parts += (Quote-CommandValue $volumeValue)
    $parts += "-w"
    $parts += (Quote-CommandValue $dockerWorkdir.Trim())
    $parts += $dockerImage.Trim()
    $parts += $localCommand

    return ($parts -join " ")
}

function Normalize-LoginMethod($loginMethod) {
    if ([string]::IsNullOrWhiteSpace($loginMethod)) {
        return "device-auth"
    }

    $value = $loginMethod.Trim().ToLower()

    if ($value -eq "browser" -or $value -eq "default" -or $value -eq "normal") {
        return "browser"
    }

    return "device-auth"
}

function Build-LoginCommand($agent, $loginMethod) {
    $agentValue = Normalize-Agent $agent

    if ($agentValue -ne "codex") {
        return ""
    }

    $methodValue = Normalize-LoginMethod $loginMethod

    if ($methodValue -eq "browser") {
        return "codex login"
    }

    return "codex login --device-auth"
}

function Build-DockerLoginCommand($agent, $dockerImage, $dockerHost, $loginMethod) {
    $loginCommand = Build-LoginCommand $agent $loginMethod

    if ([string]::IsNullOrWhiteSpace($loginCommand)) {
        return ""
    }

    if ([string]::IsNullOrWhiteSpace($dockerImage)) {
        $dockerImage = Get-DefaultDockerImage $agent
    }

    $parts = @("docker")

    if (![string]::IsNullOrWhiteSpace($dockerHost)) {
        $parts += "-H"
        $parts += (Quote-CommandValue $dockerHost.Trim())
    }

    $parts += "run"
    $parts += "--rm"
    $parts += "-it"
    $parts += "-v"
    $parts += (Quote-CommandValue (Get-DockerAgentDataVolumeValue $agent))
    $parts += $dockerImage.Trim()
    $parts += $loginCommand

    return ($parts -join " ")
}

function Build-PreviewCommand($projectPath, $commandObject) {
    if ($null -eq $commandObject) {
        return ""
    }

    $executionMode = Normalize-ExecutionMode $commandObject.executionMode
    $previewApiKey = $commandObject.apiKey

    if ((Normalize-AuthType $commandObject.authType) -eq "api-key" -and ![string]::IsNullOrWhiteSpace($previewApiKey)) {
        $previewApiKey = "********"
    }

    if ($executionMode -eq "docker") {
        return Build-DockerCommand $projectPath $commandObject.agent $commandObject.commandArgs $commandObject.dockerImage $commandObject.dockerWorkdir $commandObject.dockerHost $commandObject.authType $previewApiKey
    }

    return Build-LocalRunCommand $commandObject.agent $commandObject.commandArgs $commandObject.authType $previewApiKey $commandObject.runner
}

function Clear-Detail {
    $pathLabel.Text = "Selected path: "
    $executionModeLabelValue.Text = "Execution Mode: "
    $runnerLabel.Text = "Runner: "
    $agentLabelValue.Text = "CLI Agent: "
    $argsLabelValue.Text = "Args: "
    $authTypeLabelValue.Text = "Auth Type: "
    $apiKeyLabelValue.Text = "API Key: "
    $dockerImageLabelValue.Text = "Docker Image: "
    $authPathLabelValue.Text = "Docker Data Volume: "
    $previewLabelValue.Text = "Preview: "
}

function Show-CommandForm($title, $defaultAlias, $defaultRunner, $defaultExecutionMode, $defaultAgent, $defaultCommandArgs, $defaultAuthType, $defaultApiKey, $defaultDockerImage, $defaultDockerWorkdir, $defaultDockerHost) {
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = $title
    $dialog.Width = 680
    $dialog.Height = 750
    $dialog.StartPosition = "CenterParent"
    $dialog.FormBorderStyle = "FixedDialog"
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false

    $aliasLabel = New-Object System.Windows.Forms.Label
    $aliasLabel.Text = "Alias *"
    $aliasLabel.Left = 20
    $aliasLabel.Top = 25
    $aliasLabel.Width = 120
    $dialog.Controls.Add($aliasLabel)

    $aliasTextBox = New-Object System.Windows.Forms.TextBox
    $aliasTextBox.Left = 150
    $aliasTextBox.Top = 20
    $aliasTextBox.Width = 470
    $aliasTextBox.Text = $defaultAlias
    $dialog.Controls.Add($aliasTextBox)
    Set-Placeholder $aliasTextBox "Required. Example: SSO Resume"

    $runnerLabelForm = New-Object System.Windows.Forms.Label
    $runnerLabelForm.Text = "Runner"
    $runnerLabelForm.Left = 20
    $runnerLabelForm.Top = 70
    $runnerLabelForm.Width = 120
    $dialog.Controls.Add($runnerLabelForm)

    $runnerComboBox = New-Object System.Windows.Forms.ComboBox
    $runnerComboBox.Left = 150
    $runnerComboBox.Top = 65
    $runnerComboBox.Width = 470
    $runnerComboBox.DropDownStyle = "DropDownList"
    [void]$runnerComboBox.Items.Add("powershell")
    [void]$runnerComboBox.Items.Add("cmd")

    if ([string]::IsNullOrWhiteSpace($defaultRunner)) {
        $defaultRunner = "powershell"
    }

    $runnerComboBox.SelectedItem = $defaultRunner.ToLower()

    if ($runnerComboBox.SelectedIndex -lt 0) {
        $runnerComboBox.SelectedIndex = 0
    }

    $dialog.Controls.Add($runnerComboBox)

    $executionModeLabel = New-Object System.Windows.Forms.Label
    $executionModeLabel.Text = "Execution Mode"
    $executionModeLabel.Left = 20
    $executionModeLabel.Top = 115
    $executionModeLabel.Width = 120
    $dialog.Controls.Add($executionModeLabel)

    $executionModeComboBox = New-Object System.Windows.Forms.ComboBox
    $executionModeComboBox.Left = 150
    $executionModeComboBox.Top = 110
    $executionModeComboBox.Width = 470
    $executionModeComboBox.DropDownStyle = "DropDownList"
    [void]$executionModeComboBox.Items.Add("local")
    [void]$executionModeComboBox.Items.Add("docker")

    $defaultExecutionMode = Normalize-ExecutionMode $defaultExecutionMode
    $executionModeComboBox.SelectedItem = $defaultExecutionMode

    if ($executionModeComboBox.SelectedIndex -lt 0) {
        $executionModeComboBox.SelectedIndex = 0
    }

    $dialog.Controls.Add($executionModeComboBox)

    $agentLabelForm = New-Object System.Windows.Forms.Label
    $agentLabelForm.Text = "CLI Agent *"
    $agentLabelForm.Left = 20
    $agentLabelForm.Top = 160
    $agentLabelForm.Width = 120
    $dialog.Controls.Add($agentLabelForm)

    $agentComboBox = New-Object System.Windows.Forms.ComboBox
    $agentComboBox.Left = 150
    $agentComboBox.Top = 155
    $agentComboBox.Width = 470
    $agentComboBox.DropDownStyle = "DropDownList"

    [void]$agentComboBox.Items.Add("codex")
    [void]$agentComboBox.Items.Add("claude")

    $defaultAgent = Normalize-Agent $defaultAgent
    $agentComboBox.SelectedItem = $defaultAgent

    if ($agentComboBox.SelectedIndex -lt 0) {
        $agentComboBox.SelectedIndex = 0
    }

    $dialog.Controls.Add($agentComboBox)

    $authTypeLabel = New-Object System.Windows.Forms.Label
    $authTypeLabel.Text = "Auth Type"
    $authTypeLabel.Left = 20
    $authTypeLabel.Top = 205
    $authTypeLabel.Width = 120
    $dialog.Controls.Add($authTypeLabel)

    $authTypeComboBox = New-Object System.Windows.Forms.ComboBox
    $authTypeComboBox.Left = 150
    $authTypeComboBox.Top = 200
    $authTypeComboBox.Width = 470
    $authTypeComboBox.DropDownStyle = "DropDownList"
    [void]$authTypeComboBox.Items.Add("saved-login")
    [void]$authTypeComboBox.Items.Add("api-key")
    $defaultAuthType = Normalize-AuthType $defaultAuthType
    $authTypeComboBox.SelectedItem = $defaultAuthType
    if ($authTypeComboBox.SelectedIndex -lt 0) {
        $authTypeComboBox.SelectedIndex = 0
    }
    $dialog.Controls.Add($authTypeComboBox)

    $apiKeyLabel = New-Object System.Windows.Forms.Label
    $apiKeyLabel.Text = "OpenAI API Key"
    $apiKeyLabel.Left = 20
    $apiKeyLabel.Top = 250
    $apiKeyLabel.Width = 120
    $dialog.Controls.Add($apiKeyLabel)

    $apiKeyTextBox = New-Object System.Windows.Forms.TextBox
    $apiKeyTextBox.Left = 150
    $apiKeyTextBox.Top = 245
    $apiKeyTextBox.Width = 470
    $apiKeyTextBox.Text = $defaultApiKey
    $apiKeyTextBox.UseSystemPasswordChar = $true
    $dialog.Controls.Add($apiKeyTextBox)
    Set-Placeholder $apiKeyTextBox "Only used when Auth Type is api-key"

    $dockerImageLabel = New-Object System.Windows.Forms.Label
    $dockerImageLabel.Text = "Docker Image"
    $dockerImageLabel.Left = 20
    $dockerImageLabel.Top = 295
    $dockerImageLabel.Width = 120
    $dialog.Controls.Add($dockerImageLabel)

    $dockerImageTextBox = New-Object System.Windows.Forms.TextBox
    $dockerImageTextBox.Left = 150
    $dockerImageTextBox.Top = 290
    $dockerImageTextBox.Width = 470
    if ([string]::IsNullOrWhiteSpace($defaultDockerImage)) {
        $defaultDockerImage = Get-DefaultDockerImage $defaultAgent
    }
    $dockerImageTextBox.Text = $defaultDockerImage
    $dialog.Controls.Add($dockerImageTextBox)
    Set-Placeholder $dockerImageTextBox "Examples: cli-runner-codex:latest, cli-runner-claude:latest"

    $dockerWorkdirLabel = New-Object System.Windows.Forms.Label
    $dockerWorkdirLabel.Text = "Docker Workdir"
    $dockerWorkdirLabel.Left = 20
    $dockerWorkdirLabel.Top = 340
    $dockerWorkdirLabel.Width = 120
    $dialog.Controls.Add($dockerWorkdirLabel)

    $dockerWorkdirTextBox = New-Object System.Windows.Forms.TextBox
    $dockerWorkdirTextBox.Left = 150
    $dockerWorkdirTextBox.Top = 335
    $dockerWorkdirTextBox.Width = 470
    if ([string]::IsNullOrWhiteSpace($defaultDockerWorkdir)) {
        $defaultDockerWorkdir = Get-DefaultDockerWorkdir
    }
    $dockerWorkdirTextBox.Text = $defaultDockerWorkdir
    $dialog.Controls.Add($dockerWorkdirTextBox)
    Set-Placeholder $dockerWorkdirTextBox "Example: /workspace"

    $dockerHostLabel = New-Object System.Windows.Forms.Label
    $dockerHostLabel.Text = "Docker Host"
    $dockerHostLabel.Left = 20
    $dockerHostLabel.Top = 385
    $dockerHostLabel.Width = 120
    $dialog.Controls.Add($dockerHostLabel)

    $dockerHostTextBox = New-Object System.Windows.Forms.TextBox
    $dockerHostTextBox.Left = 150
    $dockerHostTextBox.Top = 380
    $dockerHostTextBox.Width = 470
    $dockerHostTextBox.Text = $defaultDockerHost
    $dialog.Controls.Add($dockerHostTextBox)
    Set-Placeholder $dockerHostTextBox "Optional. Blank = local Docker. Example: tcp://192.168.0.10:2375"

    $argsLabel = New-Object System.Windows.Forms.Label
    $argsLabel.Text = "Args"
    $argsLabel.Left = 20
    $argsLabel.Top = 430
    $argsLabel.Width = 120
    $dialog.Controls.Add($argsLabel)

    $argsTextBox = New-Object System.Windows.Forms.TextBox
    $argsTextBox.Left = 150
    $argsTextBox.Top = 425
    $argsTextBox.Width = 470
    $argsTextBox.Height = 80
    $argsTextBox.Multiline = $true
    $argsTextBox.ScrollBars = "Vertical"
    $argsTextBox.Text = $defaultCommandArgs
    $dialog.Controls.Add($argsTextBox)
    Set-Placeholder $argsTextBox "Optional. Example: resume xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"


    $previewLabel = New-Object System.Windows.Forms.Label
    $previewLabel.Text = "Preview: "
    $previewLabel.Left = 20
    $previewLabel.Top = 525
    $previewLabel.Width = 620
    $previewLabel.Height = 90
    $dialog.Controls.Add($previewLabel)

    $updateAgentDefaults = {
        $currentAgent = Normalize-Agent $agentComboBox.SelectedItem.ToString()
        $codexDefaultImage = Get-DefaultDockerImage "codex"
        $claudeDefaultImage = Get-DefaultDockerImage "claude"
        $agentDefaultImage = Get-DefaultDockerImage $currentAgent

        if ([string]::IsNullOrWhiteSpace($dockerImageTextBox.Text) -or $dockerImageTextBox.Text.Trim() -eq $codexDefaultImage -or $dockerImageTextBox.Text.Trim() -eq $claudeDefaultImage) {
            $dockerImageTextBox.Text = $agentDefaultImage
        }
    }

    $updateDockerFields = {
        $isDocker = ((Normalize-ExecutionMode ($executionModeComboBox.SelectedItem.ToString())) -eq "docker")
        $dockerImageTextBox.Enabled = $isDocker
        $dockerWorkdirTextBox.Enabled = $isDocker
        $dockerHostTextBox.Enabled = $isDocker
    }

    $updateAuthFields = {
        $isApiKey = ((Normalize-AuthType ($authTypeComboBox.SelectedItem.ToString())) -eq "api-key")
        $apiKeyTextBox.Enabled = $isApiKey
    }

    $updatePreview = {
        $currentAgent = Normalize-Agent $agentComboBox.SelectedItem.ToString()
        $currentCommandArgs = $argsTextBox.Text
        $currentMode = Normalize-ExecutionMode ($executionModeComboBox.SelectedItem.ToString())

        $currentAuthType = Normalize-AuthType $authTypeComboBox.SelectedItem.ToString()
        $currentApiKey = $apiKeyTextBox.Text
        $currentRunner = $runnerComboBox.SelectedItem.ToString()
        $previewApiKey = $currentApiKey

        if ($currentAuthType -eq "api-key" -and ![string]::IsNullOrWhiteSpace($previewApiKey)) {
            $previewApiKey = "********"
        }

        if ($currentMode -eq "docker") {
            $previewLabel.Text = "Preview: " + (Build-DockerCommand "{ProjectPath}" $currentAgent $currentCommandArgs $dockerImageTextBox.Text $dockerWorkdirTextBox.Text $dockerHostTextBox.Text $currentAuthType $previewApiKey)
        }
        else {
            $previewLabel.Text = "Preview: " + (Build-LocalRunCommand $currentAgent $currentCommandArgs $currentAuthType $previewApiKey $currentRunner)
        }
    }

    $executionModeComboBox.Add_SelectedIndexChanged({ & $updateDockerFields; & $updatePreview })
    $agentComboBox.Add_SelectedIndexChanged({ & $updateAgentDefaults; & $updatePreview })
    $runnerComboBox.Add_SelectedIndexChanged({ & $updatePreview })
    $authTypeComboBox.Add_SelectedIndexChanged({ & $updateAuthFields; & $updatePreview })
    $apiKeyTextBox.Add_TextChanged({ & $updatePreview })
    $argsTextBox.Add_TextChanged({ & $updatePreview })
    $dockerImageTextBox.Add_TextChanged({ & $updatePreview })
    $dockerWorkdirTextBox.Add_TextChanged({ & $updatePreview })
    $dockerHostTextBox.Add_TextChanged({ & $updatePreview })


    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = "Save"
    $okButton.Left = 410
    $okButton.Top = 650
    $okButton.Width = 100
    $dialog.Controls.Add($okButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "Cancel"
    $cancelButton.Left = 520
    $cancelButton.Top = 650
    $cancelButton.Width = 100
    $dialog.Controls.Add($cancelButton)

    $script:commandFormResult = $null

    $okButton.Add_Click({
        if ([string]::IsNullOrWhiteSpace($aliasTextBox.Text)) {
            [System.Windows.Forms.MessageBox]::Show("Alias is required.")
            return
        }

        if ($null -eq $agentComboBox.SelectedItem -or [string]::IsNullOrWhiteSpace($agentComboBox.SelectedItem.ToString())) {
            [System.Windows.Forms.MessageBox]::Show("CLI Agent is required.")
            return
        }

        $selectedMode = Normalize-ExecutionMode ($executionModeComboBox.SelectedItem.ToString())

        if ($selectedMode -eq "docker") {
            if ([string]::IsNullOrWhiteSpace($dockerImageTextBox.Text)) {
                [System.Windows.Forms.MessageBox]::Show("Docker Image is required in Docker mode.")
                return
            }

            if ([string]::IsNullOrWhiteSpace($dockerWorkdirTextBox.Text)) {
                [System.Windows.Forms.MessageBox]::Show("Docker Workdir is required in Docker mode.")
                return
            }

        }

        $script:commandFormResult = [PSCustomObject]@{
            name = $aliasTextBox.Text.Trim()
            runner = $runnerComboBox.SelectedItem.ToString()
            executionMode = $selectedMode
            agent = Normalize-Agent $agentComboBox.SelectedItem.ToString()
            commandArgs = $argsTextBox.Text.Trim()
            authType = Normalize-AuthType $authTypeComboBox.SelectedItem.ToString()
            apiKey = $apiKeyTextBox.Text.Trim()
            dockerImage = $dockerImageTextBox.Text.Trim()
            dockerWorkdir = $dockerWorkdirTextBox.Text.Trim()
            dockerHost = $dockerHostTextBox.Text.Trim()
        }

        $dialog.Close()
    })

    $cancelButton.Add_Click({
        $script:commandFormResult = $null
        $dialog.Close()
    })

    & $updateAgentDefaults
    & $updateDockerFields
    & $updateAuthFields
    & $updatePreview

    [void]$dialog.ShowDialog()

    return $script:commandFormResult
}

function Refresh-Projects {
    $projectList.Items.Clear()
    $commandList.Items.Clear()

    Clear-Detail

    $script:projects = @(Load-Projects)

    foreach ($project in $script:projects) {
        [void]$projectList.Items.Add($project.name)
    }
}

function Refresh-Commands {
    $commandList.Items.Clear()

    $executionModeLabelValue.Text = "Execution Mode: "
    $runnerLabel.Text = "Runner: "
    $agentLabelValue.Text = "CLI Agent: "
    $argsLabelValue.Text = "Args: "
    $authTypeLabelValue.Text = "Auth Type: "
    $apiKeyLabelValue.Text = "API Key: "
    $dockerImageLabelValue.Text = "Docker Image: "
    $authPathLabelValue.Text = "Docker Data Volume: "
    $previewLabelValue.Text = "Preview: "

    if ($projectList.SelectedIndex -lt 0) {
        $pathLabel.Text = "Selected path: "
        return
    }

    $selectedProject = $script:projects[$projectList.SelectedIndex]
    $pathLabel.Text = "Selected path: " + $selectedProject.path

    if ($null -eq $selectedProject.commands) {
        return
    }

    foreach ($command in @($selectedProject.commands)) {
        if ($command -is [string]) {
            [void]$commandList.Items.Add($command)
        }
        else {
            [void]$commandList.Items.Add($command.name)
        }
    }
}

function Get-SelectedCommandObject {
    if ($projectList.SelectedIndex -lt 0 -or $commandList.SelectedIndex -lt 0) {
        return $null
    }

    $selectedProject = $script:projects[$projectList.SelectedIndex]
    $selectedCommand = @($selectedProject.commands)[$commandList.SelectedIndex]

    if ($selectedCommand -is [string]) {
        return [PSCustomObject]@{
            name = $selectedCommand
            runner = "powershell"
            executionMode = "local"
            agent = Normalize-Agent $selectedCommand
            commandArgs = ""
            authType = "saved-login"
            apiKey = ""
            dockerImage = Get-DefaultDockerImage $selectedCommand
            dockerWorkdir = Get-DefaultDockerWorkdir
            dockerHost = ""
        }
    }

    $runner = $selectedCommand.runner

    if ([string]::IsNullOrWhiteSpace($runner)) {
        $runner = "powershell"
    }

    $agent = Normalize-Agent $selectedCommand.agent
    $commandArgs = $selectedCommand.commandArgs

    if ([string]::IsNullOrWhiteSpace($commandArgs) -and ![string]::IsNullOrWhiteSpace($selectedCommand.args)) {
        $commandArgs = $selectedCommand.args
    }

    if ([string]::IsNullOrWhiteSpace($agent) -and ![string]::IsNullOrWhiteSpace($selectedCommand.command)) {
        $parts = $selectedCommand.command.Trim().Split(" ", 2)
        $agent = $parts[0]

        if ($parts.Count -gt 1) {
            $commandArgs = $parts[1]
        }
        else {
            $commandArgs = ""
        }
    }

    $agent = Normalize-Agent $agent

    $authType = Normalize-AuthType $selectedCommand.authType
    $apiKey = $selectedCommand.apiKey

    if ($null -eq $apiKey) {
        $apiKey = ""
    }

    $executionMode = Normalize-ExecutionMode $selectedCommand.executionMode
    $dockerImage = $selectedCommand.dockerImage
    $dockerWorkdir = $selectedCommand.dockerWorkdir
    $dockerHost = $selectedCommand.dockerHost

    if ([string]::IsNullOrWhiteSpace($dockerImage)) {
        $dockerImage = Get-DefaultDockerImage $agent
    }

    if ([string]::IsNullOrWhiteSpace($dockerWorkdir)) {
        $dockerWorkdir = Get-DefaultDockerWorkdir
    }

    if ($null -eq $dockerHost) {
        $dockerHost = ""
    }


    return [PSCustomObject]@{
        name = $selectedCommand.name
        runner = $runner
        executionMode = $executionMode
        agent = $agent
        commandArgs = $commandArgs
        authType = $authType
        apiKey = $apiKey
        dockerImage = $dockerImage
        dockerWorkdir = $dockerWorkdir
        dockerHost = $dockerHost
    }
}

function Move-Project($direction) {
    if ($projectList.SelectedIndex -lt 0) {
        [System.Windows.Forms.MessageBox]::Show("Select a project first.")
        return
    }

    $index = $projectList.SelectedIndex
    $newIndex = $index + $direction

    $projects = @(Load-Projects)

    if ($newIndex -lt 0 -or $newIndex -ge $projects.Count) {
        return
    }

    $temp = $projects[$index]
    $projects[$index] = $projects[$newIndex]
    $projects[$newIndex] = $temp

    Save-Projects @($projects)
    Refresh-Projects

    $projectList.SelectedIndex = $newIndex
}

function Move-Command($direction) {
    if ($projectList.SelectedIndex -lt 0) {
        [System.Windows.Forms.MessageBox]::Show("Select a project first.")
        return
    }

    if ($commandList.SelectedIndex -lt 0) {
        [System.Windows.Forms.MessageBox]::Show("Select a command first.")
        return
    }

    $projectIndex = $projectList.SelectedIndex
    $commandIndex = $commandList.SelectedIndex
    $newCommandIndex = $commandIndex + $direction

    $projects = @(Load-Projects)
    $commands = @($projects[$projectIndex].commands)

    if ($newCommandIndex -lt 0 -or $newCommandIndex -ge $commands.Count) {
        return
    }

    $temp = $commands[$commandIndex]
    $commands[$commandIndex] = $commands[$newCommandIndex]
    $commands[$newCommandIndex] = $temp

    $projects[$projectIndex].commands = @($commands)

    Save-Projects @($projects)
    Refresh-Projects

    $projectList.SelectedIndex = $projectIndex
    $commandList.SelectedIndex = $newCommandIndex
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "CLI Runner"
$form.Width = 980
$form.Height = 1020
$form.MinimumSize = New-Object System.Drawing.Size(980, 1020)
$form.StartPosition = "CenterScreen"

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = "CLI Runner"
$titleLabel.Left = 20
$titleLabel.Top = 20
$titleLabel.Width = 760
$titleLabel.Height = 30
$titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($titleLabel)

$projectLabel = New-Object System.Windows.Forms.Label
$projectLabel.Text = "Projects"
$projectLabel.Left = 20
$projectLabel.Top = 65
$projectLabel.Width = 80
$form.Controls.Add($projectLabel)

$projectUpButton = New-Object System.Windows.Forms.Button
$projectUpButton.Text = "Up"
$projectUpButton.Left = 105
$projectUpButton.Top = 60
$projectUpButton.Width = 50
$projectUpButton.Height = 26
$form.Controls.Add($projectUpButton)

$projectDownButton = New-Object System.Windows.Forms.Button
$projectDownButton.Text = "Down"
$projectDownButton.Left = 160
$projectDownButton.Top = 60
$projectDownButton.Width = 60
$projectDownButton.Height = 26
$form.Controls.Add($projectDownButton)

$projectList = New-Object System.Windows.Forms.ListBox
$projectList.Left = 20
$projectList.Top = 90
$projectList.Width = 400
$projectList.Height = 300
$form.Controls.Add($projectList)

$commandTitleLabel = New-Object System.Windows.Forms.Label
$commandTitleLabel.Text = "Commands"
$commandTitleLabel.Left = 480
$commandTitleLabel.Top = 65
$commandTitleLabel.Width = 90
$form.Controls.Add($commandTitleLabel)

$commandUpButton = New-Object System.Windows.Forms.Button
$commandUpButton.Text = "Up"
$commandUpButton.Left = 575
$commandUpButton.Top = 60
$commandUpButton.Width = 50
$commandUpButton.Height = 26
$form.Controls.Add($commandUpButton)

$commandDownButton = New-Object System.Windows.Forms.Button
$commandDownButton.Text = "Down"
$commandDownButton.Left = 630
$commandDownButton.Top = 60
$commandDownButton.Width = 60
$commandDownButton.Height = 26
$form.Controls.Add($commandDownButton)

$commandList = New-Object System.Windows.Forms.ListBox
$commandList.Left = 480
$commandList.Top = 90
$commandList.Width = 420
$commandList.Height = 300
$form.Controls.Add($commandList)

$pathLabel = New-Object System.Windows.Forms.Label
$pathLabel.Left = 20
$pathLabel.Top = 410
$pathLabel.Width = 900
$pathLabel.Height = 25
$pathLabel.Text = "Selected path: "
$form.Controls.Add($pathLabel)

$executionModeLabelValue = New-Object System.Windows.Forms.Label
$executionModeLabelValue.Left = 20
$executionModeLabelValue.Top = 440
$executionModeLabelValue.Width = 900
$executionModeLabelValue.Height = 25
$executionModeLabelValue.Text = "Execution Mode: "
$form.Controls.Add($executionModeLabelValue)

$runnerLabel = New-Object System.Windows.Forms.Label
$runnerLabel.Left = 20
$runnerLabel.Top = 470
$runnerLabel.Width = 900
$runnerLabel.Height = 25
$runnerLabel.Text = "Runner: "
$form.Controls.Add($runnerLabel)

$agentLabelValue = New-Object System.Windows.Forms.Label
$agentLabelValue.Left = 20
$agentLabelValue.Top = 500
$agentLabelValue.Width = 900
$agentLabelValue.Height = 25
$agentLabelValue.Text = "CLI Agent: "
$form.Controls.Add($agentLabelValue)

$argsLabelValue = New-Object System.Windows.Forms.Label
$argsLabelValue.Left = 20
$argsLabelValue.Top = 530
$argsLabelValue.Width = 900
$argsLabelValue.Height = 25
$argsLabelValue.Text = "Args: "
$form.Controls.Add($argsLabelValue)

$authTypeLabelValue = New-Object System.Windows.Forms.Label
$authTypeLabelValue.Left = 20
$authTypeLabelValue.Top = 560
$authTypeLabelValue.Width = 900
$authTypeLabelValue.Height = 25
$authTypeLabelValue.Text = "Auth Type: "
$form.Controls.Add($authTypeLabelValue)

$apiKeyLabelValue = New-Object System.Windows.Forms.Label
$apiKeyLabelValue.Left = 20
$apiKeyLabelValue.Top = 590
$apiKeyLabelValue.Width = 900
$apiKeyLabelValue.Height = 25
$apiKeyLabelValue.Text = "API Key: "
$form.Controls.Add($apiKeyLabelValue)

$dockerImageLabelValue = New-Object System.Windows.Forms.Label
$dockerImageLabelValue.Left = 20
$dockerImageLabelValue.Top = 620
$dockerImageLabelValue.Width = 900
$dockerImageLabelValue.Height = 25
$dockerImageLabelValue.Text = "Docker Image: "
$form.Controls.Add($dockerImageLabelValue)


$authPathLabelValue = New-Object System.Windows.Forms.Label
$authPathLabelValue.Left = 20
$authPathLabelValue.Top = 650
$authPathLabelValue.Width = 900
$authPathLabelValue.Height = 25
$authPathLabelValue.Text = "Docker Data Volume: "
$form.Controls.Add($authPathLabelValue)

$previewLabelValue = New-Object System.Windows.Forms.Label
$previewLabelValue.Left = 20
$previewLabelValue.Top = 680
$previewLabelValue.Width = 900
$previewLabelValue.Height = 80
$previewLabelValue.Text = "Preview: "
$form.Controls.Add($previewLabelValue)


$addProjectButton = New-Object System.Windows.Forms.Button
$addProjectButton.Text = "Add Project"
$addProjectButton.Left = 20
$addProjectButton.Top = 795
$addProjectButton.Width = 130
$form.Controls.Add($addProjectButton)

$deleteProjectButton = New-Object System.Windows.Forms.Button
$deleteProjectButton.Text = "Delete Project"
$deleteProjectButton.Left = 160
$deleteProjectButton.Top = 795
$deleteProjectButton.Width = 130
$form.Controls.Add($deleteProjectButton)

$addCommandButton = New-Object System.Windows.Forms.Button
$addCommandButton.Text = "Add Command"
$addCommandButton.Left = 480
$addCommandButton.Top = 795
$addCommandButton.Width = 130
$form.Controls.Add($addCommandButton)

$editCommandButton = New-Object System.Windows.Forms.Button
$editCommandButton.Text = "Edit Command"
$editCommandButton.Left = 620
$editCommandButton.Top = 795
$editCommandButton.Width = 130
$form.Controls.Add($editCommandButton)

$deleteCommandButton = New-Object System.Windows.Forms.Button
$deleteCommandButton.Text = "Delete Command"
$deleteCommandButton.Left = 760
$deleteCommandButton.Top = 795
$deleteCommandButton.Width = 140
$form.Controls.Add($deleteCommandButton)

$runButton = New-Object System.Windows.Forms.Button
$runButton.Text = "Run"
$runButton.Left = 480
$runButton.Top = 870
$runButton.Width = 130
$form.Controls.Add($runButton)

$loginMethodLabel = New-Object System.Windows.Forms.Label
$loginMethodLabel.Text = "Login Method"
$loginMethodLabel.Left = 620
$loginMethodLabel.Top = 847
$loginMethodLabel.Width = 130
$form.Controls.Add($loginMethodLabel)

$loginMethodComboBox = New-Object System.Windows.Forms.ComboBox
$loginMethodComboBox.Left = 620
$loginMethodComboBox.Top = 870
$loginMethodComboBox.Width = 130
$loginMethodComboBox.DropDownStyle = "DropDownList"
[void]$loginMethodComboBox.Items.Add("device-auth")
[void]$loginMethodComboBox.Items.Add("browser")
$loginMethodComboBox.SelectedItem = "device-auth"
$form.Controls.Add($loginMethodComboBox)

$loginMethodHintLabel = New-Object System.Windows.Forms.Label
$loginMethodHintLabel.Text = "browser = local only"
$loginMethodHintLabel.Left = 620
$loginMethodHintLabel.Top = 895
$loginMethodHintLabel.Width = 130
$loginMethodHintLabel.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($loginMethodHintLabel)

$loginButton = New-Object System.Windows.Forms.Button
$loginButton.Text = "Login / Re-login"
$loginButton.Left = 760
$loginButton.Top = 870
$loginButton.Width = 130
$form.Controls.Add($loginButton)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = "Close"
$closeButton.Left = 760
$closeButton.Top = 930
$closeButton.Width = 130
$form.Controls.Add($closeButton)

$projectList.Add_SelectedIndexChanged({
    Refresh-Commands
})

$commandList.Add_SelectedIndexChanged({
    $selectedCommandObject = Get-SelectedCommandObject

    if ($null -eq $selectedCommandObject) {
        return
    }

    $selectedProject = $script:projects[$projectList.SelectedIndex]
    $fullCommand = Build-PreviewCommand $selectedProject.path $selectedCommandObject

    $executionModeLabelValue.Text = "Execution Mode: " + $selectedCommandObject.executionMode
    $runnerLabel.Text = "Runner: " + $selectedCommandObject.runner
    $agentLabelValue.Text = "CLI Agent: " + $selectedCommandObject.agent
    $argsLabelValue.Text = "Args: " + $selectedCommandObject.commandArgs
    $authTypeLabelValue.Text = "Auth Type: " + $selectedCommandObject.authType
    $apiKeyLabelValue.Text = "API Key: " + (Mask-Secret $selectedCommandObject.apiKey)
    $dockerImageLabelValue.Text = "Docker Image: " + $selectedCommandObject.dockerImage
    $authPathLabelValue.Text = "Docker Data Volume: " + (Get-DockerAgentDataVolumeValue $selectedCommandObject.agent)
    $previewLabelValue.Text = "Preview: " + $fullCommand

    if ((Normalize-ExecutionMode $selectedCommandObject.executionMode) -eq "docker" -and (Normalize-LoginMethod $loginMethodComboBox.SelectedItem.ToString()) -eq "browser") {
        $loginMethodComboBox.SelectedItem = "device-auth"
    }

})

$addProjectButton.Add_Click({
    $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderDialog.Description = "Select project folder"
    $folderDialog.ShowNewFolderButton = $false

    if ($folderDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $selectedPath = $folderDialog.SelectedPath

        $projectName = [Microsoft.VisualBasic.Interaction]::InputBox(
            "Enter project name",
            "Add Project",
            (Split-Path $selectedPath -Leaf)
        )

        if ([string]::IsNullOrWhiteSpace($projectName)) {
            return
        }

        $newProject = [PSCustomObject]@{
            name = $projectName
            path = $selectedPath
            commands = @()
        }

        $currentProjects = @(Load-Projects)
        $currentProjects += $newProject

        Save-Projects @($currentProjects)
        Refresh-Projects

        $projectList.SelectedIndex = $projectList.Items.Count - 1
    }
})

$deleteProjectButton.Add_Click({
    if ($projectList.SelectedIndex -lt 0) {
        [System.Windows.Forms.MessageBox]::Show("Select a project to delete.")
        return
    }

    $selectedIndex = $projectList.SelectedIndex
    $selectedProject = $script:projects[$selectedIndex]

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Delete project: " + $selectedProject.name + "?",
        "Confirm",
        [System.Windows.Forms.MessageBoxButtons]::YesNo
    )

    if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
        $updatedProjects = @()

        for ($i = 0; $i -lt @($script:projects).Count; $i++) {
            if ($i -ne $selectedIndex) {
                $updatedProjects += $script:projects[$i]
            }
        }

        Save-Projects @($updatedProjects)
        Refresh-Projects

        if ($projectList.Items.Count -gt 0) {
            if ($selectedIndex -ge $projectList.Items.Count) {
                $projectList.SelectedIndex = $projectList.Items.Count - 1
            }
            else {
                $projectList.SelectedIndex = $selectedIndex
            }
        }
        else {
            $projectList.ClearSelected()
            $commandList.Items.Clear()
            Clear-Detail
        }
    }
})

$projectUpButton.Add_Click({
    Move-Project -1
})

$projectDownButton.Add_Click({
    Move-Project 1
})

$addCommandButton.Add_Click({
    if ($projectList.SelectedIndex -lt 0) {
        [System.Windows.Forms.MessageBox]::Show("Select a project first.")
        return
    }

    $result = Show-CommandForm "Add Command" "" "powershell" "local" "codex" "" "saved-login" "" (Get-DefaultDockerImage "codex") (Get-DefaultDockerWorkdir) ""

    if ($null -eq $result) {
        return
    }

    $selectedProjectIndex = $projectList.SelectedIndex
    $projects = @(Load-Projects)

    if ($null -eq $projects[$selectedProjectIndex].commands) {
        $projects[$selectedProjectIndex] | Add-Member -MemberType NoteProperty -Name commands -Value @()
    }

    $commands = @($projects[$selectedProjectIndex].commands)
    $commands += $result
    $projects[$selectedProjectIndex].commands = @($commands)

    Save-Projects @($projects)
    Refresh-Projects

    $projectList.SelectedIndex = $selectedProjectIndex
    $commandList.SelectedIndex = $commandList.Items.Count - 1
})

$editCommandButton.Add_Click({
    if ($projectList.SelectedIndex -lt 0) {
        [System.Windows.Forms.MessageBox]::Show("Select a project first.")
        return
    }

    if ($commandList.SelectedIndex -lt 0) {
        [System.Windows.Forms.MessageBox]::Show("Select a command to edit.")
        return
    }

    $projectIndex = $projectList.SelectedIndex
    $commandIndex = $commandList.SelectedIndex

    $currentCommand = Get-SelectedCommandObject

    if ($null -eq $currentCommand) {
        [System.Windows.Forms.MessageBox]::Show("Command not found.")
        return
    }

    $result = Show-CommandForm "Edit Command" $currentCommand.name $currentCommand.runner $currentCommand.executionMode $currentCommand.agent $currentCommand.commandArgs $currentCommand.authType $currentCommand.apiKey $currentCommand.dockerImage $currentCommand.dockerWorkdir $currentCommand.dockerHost

    if ($null -eq $result) {
        return
    }

    $projects = @(Load-Projects)
    $commands = @($projects[$projectIndex].commands)
    $commands[$commandIndex] = $result
    $projects[$projectIndex].commands = @($commands)

    Save-Projects @($projects)
    Refresh-Projects

    $projectList.SelectedIndex = $projectIndex
    $commandList.SelectedIndex = $commandIndex
})

$deleteCommandButton.Add_Click({
    if ($projectList.SelectedIndex -lt 0) {
        [System.Windows.Forms.MessageBox]::Show("Select a project first.")
        return
    }

    if ($commandList.SelectedIndex -lt 0) {
        [System.Windows.Forms.MessageBox]::Show("Select a command to delete.")
        return
    }

    $projectIndex = $projectList.SelectedIndex
    $commandIndex = $commandList.SelectedIndex

    $projects = @(Load-Projects)
    $currentCommands = @($projects[$projectIndex].commands)
    $commands = @()

    for ($i = 0; $i -lt $currentCommands.Count; $i++) {
        if ($i -ne $commandIndex) {
            $commands += $currentCommands[$i]
        }
    }

    $projects[$projectIndex].commands = @($commands)

    Save-Projects @($projects)
    Refresh-Projects

    $projectList.SelectedIndex = $projectIndex

    if ($commandList.Items.Count -gt 0) {
        if ($commandIndex -ge $commandList.Items.Count) {
            $commandList.SelectedIndex = $commandList.Items.Count - 1
        }
        else {
            $commandList.SelectedIndex = $commandIndex
        }
    }
})

$commandUpButton.Add_Click({
    Move-Command -1
})

$commandDownButton.Add_Click({
    Move-Command 1
})

$runButton.Add_Click({
    if ($projectList.SelectedIndex -lt 0) {
        [System.Windows.Forms.MessageBox]::Show("Select a project first.")
        return
    }

    if ($commandList.SelectedIndex -lt 0) {
        [System.Windows.Forms.MessageBox]::Show("Select a command first.")
        return
    }

    $selectedProject = $script:projects[$projectList.SelectedIndex]
    $selectedCommandObject = Get-SelectedCommandObject

    if ($null -eq $selectedCommandObject) {
        [System.Windows.Forms.MessageBox]::Show("Command not found.")
        return
    }

    $path = $selectedProject.path
    $runner = $selectedCommandObject.runner
    $executionMode = Normalize-ExecutionMode $selectedCommandObject.executionMode

    if (!(Test-Path $path)) {
        [System.Windows.Forms.MessageBox]::Show("Project path does not exist: " + $path)
        return
    }

    if ($executionMode -eq "docker") {
        $fullCommand = Build-DockerCommand $path $selectedCommandObject.agent $selectedCommandObject.commandArgs $selectedCommandObject.dockerImage $selectedCommandObject.dockerWorkdir $selectedCommandObject.dockerHost $selectedCommandObject.authType $selectedCommandObject.apiKey
    }
    else {
        $fullCommand = Build-LocalRunCommand $selectedCommandObject.agent $selectedCommandObject.commandArgs $selectedCommandObject.authType $selectedCommandObject.apiKey $runner
    }

    if ([string]::IsNullOrWhiteSpace($fullCommand)) {
        [System.Windows.Forms.MessageBox]::Show("Command is empty.")
        return
    }

    if ($runner -eq "powershell") {
        if ($executionMode -eq "docker") {
            Start-Process powershell.exe -ArgumentList "-NoExit", "-Command", $fullCommand
        }
        else {
            $escapedPath = $path.Replace("'", "''")
            $escapedCommand = $fullCommand
            Start-Process powershell.exe -ArgumentList "-NoExit", "-Command", "cd '$escapedPath'; $escapedCommand"
        }

        $form.Close()
    }
    elseif ($runner -eq "cmd") {
        if ($executionMode -eq "docker") {
            $cmdArgument = "/k $fullCommand"
        }
        else {
            $cmdArgument = "/k cd /d `"$path`" && $fullCommand"
        }

        Start-Process cmd.exe -ArgumentList $cmdArgument
        $form.Close()
    }
    else {
        [System.Windows.Forms.MessageBox]::Show("Unsupported runner: " + $runner)
    }
})


$loginButton.Add_Click({
    if ($projectList.SelectedIndex -lt 0) {
        [System.Windows.Forms.MessageBox]::Show("Select a project first.")
        return
    }

    if ($commandList.SelectedIndex -lt 0) {
        [System.Windows.Forms.MessageBox]::Show("Select a command first.")
        return
    }

    $selectedProject = $script:projects[$projectList.SelectedIndex]
    $selectedCommandObject = Get-SelectedCommandObject

    if ($null -eq $selectedCommandObject) {
        [System.Windows.Forms.MessageBox]::Show("Command not found.")
        return
    }

    if ((Normalize-AuthType $selectedCommandObject.authType) -eq "api-key") {
        [System.Windows.Forms.MessageBox]::Show("API Key mode does not use Login / Re-login. Run will pass OPENAI_API_KEY automatically.")
        return
    }

    if ((Normalize-Agent $selectedCommandObject.agent) -ne "codex") {
        [System.Windows.Forms.MessageBox]::Show("Login / Re-login currently supports Codex only.")
        return
    }

    $path = $selectedProject.path
    $runner = $selectedCommandObject.runner
    $executionMode = Normalize-ExecutionMode $selectedCommandObject.executionMode

    if (!(Test-Path $path)) {
        [System.Windows.Forms.MessageBox]::Show("Project path does not exist: " + $path)
        return
    }

    $selectedLoginMethod = Normalize-LoginMethod $loginMethodComboBox.SelectedItem.ToString()

    if ($executionMode -eq "docker" -and $selectedLoginMethod -eq "browser") {
        [System.Windows.Forms.MessageBox]::Show("Browser Login / Re-login is supported only in Local mode. For Docker mode, use device-auth instead.")
        return
    }

    if ($executionMode -eq "docker") {
        $fullCommand = Build-DockerLoginCommand $selectedCommandObject.agent $selectedCommandObject.dockerImage $selectedCommandObject.dockerHost $selectedLoginMethod
    }
    else {
        $fullCommand = Build-LoginCommand $selectedCommandObject.agent $selectedLoginMethod
    }

    if ([string]::IsNullOrWhiteSpace($fullCommand)) {
        [System.Windows.Forms.MessageBox]::Show("Login command is empty.")
        return
    }

    if ($runner -eq "powershell") {
        if ($executionMode -eq "docker") {
            Start-Process powershell.exe -ArgumentList "-NoExit", "-Command", $fullCommand
        }
        else {
            $escapedPath = $path.Replace("'", "''")
            $escapedCommand = $fullCommand
            Start-Process powershell.exe -ArgumentList "-NoExit", "-Command", "cd '$escapedPath'; $escapedCommand"
        }

        $form.Close()
    }
    elseif ($runner -eq "cmd") {
        if ($executionMode -eq "docker") {
            $cmdArgument = "/k $fullCommand"
        }
        else {
            $cmdArgument = "/k cd /d `"$path`" && $fullCommand"
        }

        Start-Process cmd.exe -ArgumentList $cmdArgument
        $form.Close()
    }
    else {
        [System.Windows.Forms.MessageBox]::Show("Unsupported runner: " + $runner)
    }
})

$closeButton.Add_Click({
    $form.Close()
})

try {
    Refresh-Projects
    [void]$form.ShowDialog()
}
finally {
    if ($null -ne $mutex) {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}