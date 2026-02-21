# WSL Health Monitor

A lightweight PowerShell daemon that continuously monitors WSL2 health and logs structured data for troubleshooting. Built to diagnose intermittent WSL2 zombie states where the VM becomes unresponsive while Windows still reports it as "Running."

## Background

WSL2 runs Linux inside a lightweight Hyper-V virtual machine. Under certain conditions — sleep/wake cycles, network adapter changes, memory pressure — the VM can enter a zombie state. Windows processes (`vmmemWSL`, `wslhost`) keep running, `wsl --list` still shows the distro as "Running," but all commands hang indefinitely with error `Wsl/Service/0x8007274c` (WSAETIMEDOUT). The only fix is `wsl --shutdown` followed by a restart.

This monitor runs silently in the background, sampling WSL health every 30 seconds. It detects these zombie states as they happen and logs a timeline of metrics so you can correlate failures with system events (sleep, network changes, memory spikes).

## What It Monitors

Every 30 seconds, the monitor collects:

| Metric | How | Why |
|---|---|---|
| **WslService status** | `Get-Service WslService` | Detects if the WSL service itself has stopped |
| **Distro states** | `wsl --list --verbose` (UTF-16LE decoded) | Tracks which distros are Running/Stopped |
| **Connectivity probe** | `wsl -d Ubuntu-24.04 -- echo ok` with 8s timeout | The core zombie detector — if this times out, the VM is hung |
| **VM memory** | `Get-Process vmmem*` working set | Tracks memory pressure on the WSL VM |
| **Network adapter** | `Get-NetAdapter *WSL*` | Detects if the Hyper-V virtual NIC goes down |

## Health States

The monitor classifies each sample into one of three states:

- **healthy** — Service running, probe succeeds quickly, network adapter up
- **degraded** — Probe succeeds but slowly (>3s), or network adapter has issues
- **zombie** — Probe timed out (8s), or WslService has stopped

State transitions are logged separately as events for quick scanning.

## Log Format

All logs are written to the same directory as the scripts (`~\.claude\wsl-monitor\`).

### `health-YYYY-MM-DD.jsonl`

One JSON object per line, one line every 30 seconds. Daily rotation, 7-day retention.

```json
{
  "ts": "2026-02-21T14:30:00.1234567-06:00",
  "state": "healthy",
  "service": { "name": "WslService", "status": "Running", "startType": "Automatic" },
  "distros": [
    { "name": "Ubuntu-24.04", "state": "Running", "version": 2, "isDefault": true },
    { "name": "docker-desktop", "state": "Running", "version": 2, "isDefault": false }
  ],
  "probe": { "success": true, "durationMs": 105, "timedOut": false, "error": "" },
  "vmmem": [
    { "name": "vmmem", "pid": 18300, "workingSetMB": 204.3 },
    { "name": "vmmemWSL", "pid": 23924, "workingSetMB": 3005.0 }
  ],
  "network": { "name": "vEthernet (WSL (Hyper-V firewall))", "status": "Up", "linkSpeed": "10 Gbps", "macAddress": "..." }
}
```

### `events.jsonl`

Append-only log of state transitions and monitor lifecycle events. Not date-rotated — trimmed at 10 MB. This is the first file to check when diagnosing issues.

```json
{"timestamp": "2026-02-21T14:30:00-06:00", "type": "state_transition", "from": "healthy", "to": "zombie", "reason": "WSL probe timed out", "probeMs": 8003, "probeTimedOut": true, "serviceStatus": "Running", "adapterStatus": "Up"}
```

Event types: `monitor_start`, `state_transition`, `monitor_error`

## Installation

```powershell
# Install and start (registers a Task Scheduler task that runs at logon)
.\WslMonitorSetup.ps1 -Install

# Check current status
.\WslMonitorSetup.ps1 -Status

# Stop and remove the scheduled task (logs are preserved)
.\WslMonitorSetup.ps1 -Uninstall
```

The monitor runs as a hidden PowerShell process under Task Scheduler (`\Claude\WSL Health Monitor`). It starts automatically at logon, restarts up to 3 times on failure, and prevents duplicate instances.

## Resource Usage

Designed to be invisible:

- **Memory**: ~30-40 MB (PowerShell 5.1 runtime + script)
- **CPU**: Negligible — mostly sleeping, each sample takes <200ms
- **Disk**: ~5-10 MB/day of health logs, auto-rotated at 7 days
- **No accumulation**: Each loop iteration creates fresh variables that are garbage-collected. No arrays or buffers grow over time.

## Configuration

Edit the constants at the top of `WslHealthMonitor.ps1`:

```powershell
$SampleInterval = 30          # Seconds between samples
$ProbeTimeout   = 8           # Seconds before declaring WSL hung
$RetentionDays  = 7           # Days of health logs to keep
$TargetDistro   = 'Ubuntu-24.04'  # Distro to probe
$AdapterPattern = '*WSL*'     # Network adapter name pattern
```

## Using the Logs for Troubleshooting

**Quick check** — scan `events.jsonl` for state transitions:
```powershell
Get-Content events.jsonl | ConvertFrom-Json | Where-Object type -eq 'state_transition'
```

**Find zombie episodes** — filter health samples:
```powershell
Get-Content health-2026-02-21.jsonl | ConvertFrom-Json | Where-Object state -eq 'zombie'
```

**Memory trend** — extract vmmemWSL working set over time:
```powershell
Get-Content health-2026-02-21.jsonl | ConvertFrom-Json | ForEach-Object {
    [PSCustomObject]@{ Time = $_.ts; MB = ($_.vmmem | Where-Object name -eq 'vmmemWSL').workingSetMB }
}
```

## Technical Notes

- **UTF-16LE handling**: `wsl.exe --list --verbose` outputs UTF-16LE which PowerShell 5.1 misinterprets. The monitor uses `System.Diagnostics.ProcessStartInfo` with explicit `StandardOutputEncoding = [System.Text.Encoding]::Unicode` to decode it correctly.
- **Timeout safety**: The connectivity probe uses `Process.WaitForExit(timeout)` with async stdout/stderr reads (`ReadToEndAsync`) to prevent both hanging and buffer deadlocks. Timed-out processes are killed with `$proc.Kill()`.
- **Atomic writes**: `Add-Content` opens, writes, and closes the file per sample. No persistent file locks — safe for concurrent reads by other tools.
- **JSONL format**: Each line is a self-contained JSON object. Partial file reads always yield complete, parseable lines.

## License

MIT
