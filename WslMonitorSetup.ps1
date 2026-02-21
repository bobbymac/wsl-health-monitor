# WslMonitorSetup.ps1 — Install, uninstall, or check status of the WSL Health Monitor
#
# Usage:
#   .\WslMonitorSetup.ps1 -Install     Register and start the monitor
#   .\WslMonitorSetup.ps1 -Uninstall   Stop and remove the scheduled task
#   .\WslMonitorSetup.ps1 -Status      Show current monitor status

[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Status
)

$TaskName   = 'WSL Health Monitor'
$TaskPath   = '\Claude\'
$ScriptPath = Join-Path $env:USERPROFILE '.claude\wsl-monitor\WslHealthMonitor.ps1'
$LogDir     = Join-Path $env:USERPROFILE '.claude\wsl-monitor'

function Install-Monitor {
    if (-not (Test-Path $ScriptPath)) {
        Write-Error "Monitor script not found at: $ScriptPath"
        return
    }

    $action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument "-NoProfile -NoLogo -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`""

    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew

    $principal = New-ScheduledTaskPrincipal `
        -UserId $env:USERNAME `
        -LogonType Interactive `
        -RunLevel Limited

    Register-ScheduledTask `
        -TaskName $TaskName `
        -TaskPath $TaskPath `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $principal `
        -Description 'Monitors WSL2 health, connectivity, and VM memory. Logs to ~/.claude/wsl-monitor/' `
        -Force | Out-Null

    Write-Host "Installed '$TaskName' in Task Scheduler under $TaskPath"
    Write-Host 'Starting monitor now...'

    Start-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath
    Start-Sleep -Seconds 2

    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if ($task -and $task.State -eq 'Running') {
        Write-Host "Monitor is running. Logs: $LogDir"
    }
    else {
        Write-Warning "Task registered but state is: $($task.State). Check Task Scheduler for details."
    }
}

function Uninstall-Monitor {
    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if (-not $task) {
        Write-Host "Task '$TaskName' is not registered. Nothing to uninstall."
        return
    }

    Stop-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false

    Write-Host "Uninstalled '$TaskName'."
    Write-Host "Log files remain in: $LogDir"
    Write-Host "To remove logs: Remove-Item '$LogDir' -Recurse -Force"
}

function Show-Status {
    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if (-not $task) {
        Write-Host "Task '$TaskName' is not registered."
        Write-Host "Run: .\WslMonitorSetup.ps1 -Install"
        return
    }

    $info = $task | Get-ScheduledTaskInfo
    Write-Host "Task:       $TaskName"
    Write-Host "State:      $($task.State)"
    Write-Host "Last run:   $($info.LastRunTime)"
    Write-Host "Result:     $($info.LastTaskResult)"

    $today = Get-Date -Format 'yyyy-MM-dd'
    $healthFile = Join-Path $LogDir "health-$today.jsonl"
    if (Test-Path $healthFile) {
        $lastLine = Get-Content $healthFile -Tail 1 -Encoding UTF8
        if ($lastLine) {
            $last = $lastLine | ConvertFrom-Json
            Write-Host "Last sample: $($last.ts) — state: $($last.state)"
            Write-Host "  Probe: $($last.probe.durationMs)ms, success=$($last.probe.success)"
        }

        $lineCount = (Get-Content $healthFile -Encoding UTF8).Count
        Write-Host "Samples today: $lineCount"
    }
    else {
        Write-Host 'No health log for today yet.'
    }

    $eventsFile = Join-Path $LogDir 'events.jsonl'
    if (Test-Path $eventsFile) {
        $lastEvent = Get-Content $eventsFile -Tail 1 -Encoding UTF8
        if ($lastEvent) {
            $evt = $lastEvent | ConvertFrom-Json
            Write-Host "Last event:  $($evt.timestamp) — $($evt.type)"
        }
    }
}

# Dispatch
if ($Install)       { Install-Monitor }
elseif ($Uninstall) { Uninstall-Monitor }
elseif ($Status)    { Show-Status }
else {
    Write-Host 'WSL Health Monitor Setup'
    Write-Host ''
    Write-Host 'Usage:'
    Write-Host '  .\WslMonitorSetup.ps1 -Install     Register and start the monitor'
    Write-Host '  .\WslMonitorSetup.ps1 -Uninstall   Stop and remove the scheduled task'
    Write-Host '  .\WslMonitorSetup.ps1 -Status      Show current monitor status'
}
