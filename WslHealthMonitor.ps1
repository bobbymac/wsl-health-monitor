# WslHealthMonitor.ps1 — Lightweight WSL2 health monitor
# Runs in an infinite loop, sampling every 30 seconds.
# Writes JSONL logs to the same directory as this script.

#region Configuration
$LogDir         = Join-Path $env:USERPROFILE '.claude\wsl-monitor'
$SampleInterval = 30
$ProbeTimeout   = 8
$RetentionDays  = 7
$TargetDistro   = 'Ubuntu-24.04'
$AdapterPattern = '*WSL*'
$EventsMaxBytes = 10MB
#endregion

#region Functions

function Get-WslServiceStatus {
    $svc = Get-Service -Name 'WslService' -ErrorAction SilentlyContinue
    if ($svc) {
        return @{
            name      = 'WslService'
            status    = $svc.Status.ToString()
            startType = $svc.StartType.ToString()
        }
    }
    return @{ name = 'WslService'; status = 'NotFound'; startType = '' }
}

function Get-WslDistroStates {
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'wsl.exe'
        $psi.Arguments = '--list --verbose'
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow  = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::Unicode

        $proc = [System.Diagnostics.Process]::Start($psi)
        $output = $proc.StandardOutput.ReadToEnd()
        [void]$proc.WaitForExit(5000)
        if (-not $proc.HasExited) { try { $proc.Kill() } catch {} }

        $distros = @()
        $lines = $output -split "`r?`n" | Where-Object { $_.Trim() }
        if ($lines.Count -gt 1) {
            foreach ($line in $lines[1..($lines.Count - 1)]) {
                $isDefault = $line.TrimStart().StartsWith('*')
                $clean = $line -replace '^\s*\*?\s*', ''
                $parts = $clean -split '\s{2,}'
                if ($parts.Count -ge 3) {
                    $distros += @{
                        name      = $parts[0].Trim()
                        state     = $parts[1].Trim()
                        version   = $parts[2].Trim() -as [int]
                        isDefault = $isDefault
                    }
                }
            }
        }
        return $distros
    }
    catch {
        return @(@{ name = 'ERROR'; state = $_.Exception.Message; version = 0; isDefault = $false })
    }
}

function Test-WslConnectivity {
    $result = @{
        success    = $false
        durationMs = 0
        output     = ''
        error      = ''
        timedOut   = $false
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName  = 'wsl.exe'
        $psi.Arguments = "-d $TargetDistro -- echo ok"
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow  = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        $exited = $proc.WaitForExit($ProbeTimeout * 1000)
        $sw.Stop()
        $result.durationMs = [int]$sw.ElapsedMilliseconds

        if (-not $exited) {
            $result.timedOut = $true
            $result.error = "Probe timed out after ${ProbeTimeout}s"
            try { $proc.Kill() } catch {}
        }
        else {
            $result.output = $stdoutTask.Result.Trim()
            $result.error  = $stderrTask.Result.Trim()
            $result.success = ($proc.ExitCode -eq 0 -and $result.output -match 'ok')
        }
    }
    catch {
        $sw.Stop()
        $result.durationMs = [int]$sw.ElapsedMilliseconds
        $result.error = $_.Exception.Message
    }
    return $result
}

function Get-VmMemUsage {
    $procs = Get-Process -Name 'vmmem*' -ErrorAction SilentlyContinue
    $items = @()
    foreach ($p in $procs) {
        $items += @{
            name         = $p.Name
            pid          = $p.Id
            workingSetMB = [math]::Round($p.WorkingSet64 / 1MB, 1)
        }
    }
    return $items
}

function Get-WslNetworkStatus {
    $adapter = Get-NetAdapter | Where-Object { $_.Name -like $AdapterPattern } |
               Select-Object -First 1
    if ($adapter) {
        return @{
            name       = $adapter.Name
            status     = $adapter.Status.ToString()
            linkSpeed  = $adapter.LinkSpeed
            macAddress = $adapter.MacAddress
        }
    }
    return @{ name = 'NOT_FOUND'; status = 'Missing'; linkSpeed = ''; macAddress = '' }
}

function Resolve-HealthState {
    param($Service, $Distros, $Probe, $Network)

    if ($Probe.timedOut) { return 'zombie' }
    if ($Service.status -ne 'Running') { return 'zombie' }

    if (-not $Probe.success) { return 'degraded' }
    if ($Probe.durationMs -gt 3000) { return 'degraded' }
    if ($Network.status -ne 'Up') { return 'degraded' }

    return 'healthy'
}

function Write-HealthSample {
    param([hashtable]$Sample)
    $dateStr = Get-Date -Format 'yyyy-MM-dd'
    $path = Join-Path $LogDir "health-$dateStr.jsonl"
    $line = $Sample | ConvertTo-Json -Compress -Depth 4
    Add-Content -Path $path -Value $line -Encoding UTF8
}

function Write-EventEntry {
    param([hashtable]$Event)
    $path = Join-Path $LogDir 'events.jsonl'
    $line = $Event | ConvertTo-Json -Compress -Depth 3
    Add-Content -Path $path -Value $line -Encoding UTF8
}

function Invoke-LogRotation {
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    Get-ChildItem -Path $LogDir -Filter 'health-*.jsonl' -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -match 'health-(\d{4}-\d{2}-\d{2})\.jsonl') {
            $fileDate = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', $null)
            if ($fileDate -lt $cutoff) {
                Remove-Item $_.FullName -Force
            }
        }
    }

    $eventsPath = Join-Path $LogDir 'events.jsonl'
    if (Test-Path $eventsPath) {
        if ((Get-Item $eventsPath).Length -gt $EventsMaxBytes) {
            $lines = Get-Content $eventsPath -Tail 5000 -Encoding UTF8
            Set-Content -Path $eventsPath -Value $lines -Encoding UTF8
        }
    }
}

#endregion

#region Main

if (-not (Test-Path $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
}

# Write startup event
Write-EventEntry @{
    timestamp = (Get-Date -Format 'o')
    type      = 'monitor_start'
    message   = 'WSL Health Monitor started'
    pid       = $PID
}

$previousState = 'unknown'

while ($true) {
    try {
        Invoke-LogRotation

        $service = Get-WslServiceStatus
        $distros = Get-WslDistroStates
        $probe   = Test-WslConnectivity
        $vmmem   = Get-VmMemUsage
        $network = Get-WslNetworkStatus

        $currentState = Resolve-HealthState -Service $service -Distros $distros `
                            -Probe $probe -Network $network

        $sample = @{
            ts      = (Get-Date -Format 'o')
            state   = $currentState
            service = $service
            distros = $distros
            probe   = $probe
            vmmem   = $vmmem
            network = $network
        }

        Write-HealthSample -Sample $sample

        if ($currentState -ne $previousState -and $previousState -ne 'unknown') {
            $reason = if ($probe.timedOut) { 'WSL probe timed out' }
                      elseif ($service.status -ne 'Running') { "WslService status: $($service.status)" }
                      elseif (-not $probe.success) { "Probe failed: $($probe.error)" }
                      elseif ($network.status -ne 'Up') { "Network adapter: $($network.status)" }
                      else { 'Metrics returned to normal' }

            Write-EventEntry @{
                timestamp     = (Get-Date -Format 'o')
                type          = 'state_transition'
                from          = $previousState
                to            = $currentState
                reason        = $reason
                probeMs       = $probe.durationMs
                probeTimedOut = $probe.timedOut
                serviceStatus = $service.status
                adapterStatus = $network.status
            }
        }

        $previousState = $currentState
    }
    catch {
        Write-EventEntry @{
            timestamp = (Get-Date -Format 'o')
            type      = 'monitor_error'
            message   = $_.Exception.Message
            stack     = $_.ScriptStackTrace
        }
    }

    Start-Sleep -Seconds $SampleInterval
}

#endregion
