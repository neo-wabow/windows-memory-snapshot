$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $root 'MemorySnapshot.ps1'
$script:Count = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:Count++
}

function New-Sample {
    param([double]$Percent, [double]$TotalGB = 32, [datetime]$Time = [datetime]'2026-09-24T12:00:00')
    $total = $TotalGB * 1GB
    return [pscustomobject]@{
        Time = $Time
        TotalBytes = $total
        AvailableBytes = $total * $Percent / 100
        AvailablePercent = $Percent
        UsedPercent = 100 - $Percent
        CommitUsedBytes = 20GB
        CommitLimitBytes = 40GB
    }
}

$tokens = $null; $parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'PowerShell source parses without errors'

. $scriptPath -NoRun
$config = Get-Config (Join-Path $root 'missing-config.json')
Assert-True ($config.checkIntervalSeconds -eq 30) 'Default interval is 30 seconds'
$state = New-MonitorState
$normal = Get-DueSnapshots (New-Sample 30) $config $state
Assert-True ($normal.Levels.Count -eq 0 -and -not $normal.Warning) 'Normal sample does not write'
$warning = Get-DueSnapshots (New-Sample 14) $config $state
Assert-True ($warning.Warning -and $warning.Levels.Count -eq 0) 'Warning records samples without snapshot'
$critical = Get-DueSnapshots (New-Sample 9 32 ([datetime]'2026-09-24T12:00:30')) $config $state
Assert-True ($critical.Levels.Count -eq 1 -and $critical.Levels[0] -eq 'critical') 'Critical threshold triggers'
$repeat = Get-DueSnapshots (New-Sample 8 32 ([datetime]'2026-09-24T12:05:00')) $config $state
Assert-True ($repeat.Levels.Count -eq 0) 'Critical cooldown prevents repeats'
$severe = Get-DueSnapshots (New-Sample 4 32 ([datetime]'2026-09-24T12:05:30')) $config $state
Assert-True ($severe.Levels.Count -eq 1 -and $severe.Levels[0] -eq 'severe') 'Severe gets its own snapshot'
$again = Get-DueSnapshots (New-Sample 4 32 ([datetime]'2026-09-24T12:06:00')) $config $state
Assert-True ($again.Levels.Count -eq 0) 'Sustained severe does not fill the disk'
$longEvent = Get-DueSnapshots (New-Sample 4 32 ([datetime]'2026-09-24T12:16:00')) $config $state
Assert-True ($longEvent.Levels.Count -eq 0) 'One episode stays bounded after cooldown expires'
$recovered = Get-DueSnapshots (New-Sample 20 32 ([datetime]'2026-09-24T12:17:00')) $config $state
Assert-True ($recovered.Levels.Count -eq 1 -and $recovered.Levels[0] -eq 'recovery') 'Recovery makes final snapshot'
$recoveredAgain = Get-DueSnapshots (New-Sample 25 32 ([datetime]'2026-09-24T12:17:30')) $config $state
Assert-True ($recoveredAgain.Levels.Count -eq 0) 'Recovery only happens once per episode'
$quickState = New-MonitorState
[void](Get-DueSnapshots (New-Sample 9) $config $quickState)
[void](Get-DueSnapshots (New-Sample 25 32 ([datetime]'2026-09-24T12:01:00')) $config $quickState)
$secondEpisode = Get-DueSnapshots (New-Sample 9 32 ([datetime]'2026-09-24T12:02:00')) $config $quickState
Assert-True ($secondEpisode.Levels.Count -eq 0) 'Cooldown also applies across quick episodes'
$fourGB = Get-DueSnapshots (New-Sample 18 16) $config (New-MonitorState)
Assert-True ($fourGB.Levels.Count -eq 1 -and $fourGB.Levels[0] -eq 'critical') '4 GB absolute threshold triggers independently'
$smallState = New-MonitorState
[void](Get-DueSnapshots (New-Sample 18 16) $config $smallState)
$notRecovered = Get-DueSnapshots (New-Sample 20 16 ([datetime]'2026-09-24T12:02:00')) $config $smallState
Assert-True ($notRecovered.Levels.Count -eq 0 -and $smallState.InEpisode) 'Recovery waits until absolute critical threshold clears'
$both = Get-DueSnapshots (New-Sample 4) $config (New-MonitorState)
Assert-True ($both.Levels.Count -eq 2 -and $both.Levels[0] -eq 'critical' -and $both.Levels[1] -eq 'severe') 'First severe sample preserves both levels'

function Get-CimInstance {
    param([string]$ClassName)
    if ($ClassName -eq 'Win32_OperatingSystem') {
        return [pscustomobject]@{ TotalVisibleMemorySize = 32MB; FreePhysicalMemory = 8MB }
    }
    return [pscustomobject]@{ AvailableBytes = 4GB; CommittedBytes = 20GB; CommitLimit = 40GB }
}
$liveSample = Get-MemorySample
Assert-True ($liveSample.AvailableBytes -eq 4GB -and $liveSample.AvailablePercent -eq 12.5) 'Windows available performance counter drives trigger'

$source = Get-Content -LiteralPath $scriptPath -Raw
Assert-True ($source -notmatch '(?i)Invoke-WebRequest|Invoke-RestMethod|Start-BitsTransfer|System\.Net\.|WebClient|HttpClient|\b(?:curl|wget)\b') 'No network API or HTTP client in source'
Assert-True ($source -notmatch '(?i)function\s+[^\r\n]*(?:telemetry|upload)') 'No telemetry or upload function'
Assert-True ($source -notmatch '(?i)\.Kill\s*\(|Stop-Process|Restart-Service|Stop-Service|docker\s+restart|wsl\s+--shutdown') 'No process or service termination command'
Assert-True ($source -match 'npipe:////\./pipe/docker_engine' -and $source -match "Remove\('DOCKER_CONTEXT'\)") 'Docker access is restricted to a local named pipe'

$engine = (Get-Process -Id $PID).Path
$timed = Invoke-LocalCommand $engine @('-NoProfile', '-Command', 'Start-Sleep -Seconds 3') 1
Assert-True (-not $timed.Ok -and $timed.Error -match 'timed out') 'External command returns after timeout'
foreach ($key in @($script:PendingCommands.Keys)) {
    $child = $script:PendingCommands[$key]
    Assert-True ($child.WaitForExit(5000)) 'Timed-out test child eventually exits without termination'
    $child.Dispose()
    $script:PendingCommands.Remove($key)
}

# A missing optional CLI must return a status rather than fail the snapshot.
function Get-Command {
    [CmdletBinding()]
    param([string]$Name)
    if ($Name -eq 'docker.exe' -or $Name -eq 'wsl.exe') { return $null }
    return Microsoft.PowerShell.Core\Get-Command $Name
}
Assert-True ((Get-WslData).Status -eq 'Unavailable') 'Missing WSL is optional'
Assert-True ((Get-DockerData).Status -eq 'Unavailable') 'Missing Docker is optional'

function Get-Command {
    [CmdletBinding()]
    param([string]$Name)
    return [pscustomobject]@{ Name = $Name }
}
function Invoke-LocalCommand {
    param([string]$FileName, [string[]]$Arguments, [int]$TimeoutSeconds = 8, [System.Text.Encoding]$OutputEncoding = $null)
    if ($FileName -eq 'wsl.exe' -and $Arguments[0] -eq '--list') {
        return [pscustomobject]@{ Ok = $true; Output = ''; Error = '' }
    }
    return [pscustomobject]@{ Ok = $false; Output = ''; Error = 'offline' }
}
Assert-True ((Get-WslData).Status -eq 'No running distribution') 'Stopped WSL distribution is optional'
Assert-True ((Get-DockerData).Status -match 'unavailable') 'Stopped Docker daemon is optional'

$script:DockerCalls = New-Object System.Collections.Generic.List[string]
function Invoke-LocalCommand {
    param([string]$FileName, [string[]]$Arguments, [int]$TimeoutSeconds = 8, [System.Text.Encoding]$OutputEncoding = $null)
    if ($FileName -eq 'wsl.exe') {
        if ($Arguments[0] -eq '--list') { $output = 'Ubuntu' + [char]10 }
        elseif ($Arguments -contains 'free') { $output = 'Mem: 17179869184 8589934592 0 0 0 8589934592' + [char]10 + 'Swap: 4294967296 1073741824 0' }
        else { $output = 'Out of memory: Killed process 123 (python)' }
    } else {
        $script:DockerCalls.Add(($Arguments -join ' '))
        if ($Arguments -contains 'ps') { $output = 'abcdef123456|mysql|Up 2 hours' + [char]10 }
        elseif ($Arguments -contains 'inspect') { $output = 'abcdef1234567890|2|false' + [char]10 }
        else { $output = 'abcdef123456|mysql|6.2GiB / 8GiB|77.5%|1.2%' + [char]10 }
    }
    return [pscustomobject]@{ Ok = $true; Output = $output; Error = '' }
}
$wslData = Get-WslData
Assert-True ($wslData.Status -eq 'Available' -and $wslData.MemoryUsedGB -eq 8 -and $wslData.SwapUsedGB -eq 1) 'WSL free output is parsed'
Assert-True ($wslData.OomEntries.Count -eq 1 -and $wslData.OomEntries[0] -match 'PID 123') 'OOM output stores only PID and process name'
$dockerData = Get-DockerData
Assert-True ($dockerData.Stats.Count -eq 1 -and $dockerData.Containers[0].RestartCount -eq 2) 'Docker memory and restart count are parsed'
Assert-True (@($script:DockerCalls | Where-Object { $_ -notmatch '^--host npipe:' }).Count -eq 0) 'Every Docker command is bound to a local pipe'

# Fail two collectors deliberately; Windows, Docker CSV, and summary still need to be saved.
function Get-Processes { throw 'simulated access denied' }
function Get-Pagefiles { throw 'simulated access denied' }
function Get-WslData { throw 'simulated WSL failure' }
function Get-DockerData { return [pscustomobject]@{ Status = 'Unavailable'; Stats = @(); Containers = @() } }
$testDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('MemorySnapshotTests-' + [guid]::NewGuid().ToString('N'))
try {
    $snapshot = Save-Snapshot (New-Sample 9) 'critical' $testDirectory
    Assert-True (Test-Path -LiteralPath (Join-Path $snapshot 'windows-memory.csv')) 'Windows CSV survives optional collector failures'
    Assert-True (Test-Path -LiteralPath (Join-Path $snapshot 'docker-containers.csv')) 'Docker CSV is present when Docker is missing'
    $summary = Get-Content -LiteralPath (Join-Path $snapshot 'summary.txt') -Raw
    Assert-True ($summary -match 'Processes: unavailable' -and $summary -match 'WSL: unavailable') 'Partial failures appear in summary'
} finally {
    if (Test-Path -LiteralPath $testDirectory) { Remove-Item -LiteralPath $testDirectory -Recurse -Force }
}

function Get-MemorySample { throw 'simulated memory check failure' }
$failedOnce = $false
$testDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('MemorySnapshotOnce-' + [guid]::NewGuid().ToString('N'))
try {
    try { Start-Monitor $config $testDirectory -SingleCheck }
    catch { $failedOnce = $true }
    Assert-True $failedOnce 'Single-check mode reports a failed memory check'
} finally {
    if (Test-Path -LiteralPath $testDirectory) { Remove-Item -LiteralPath $testDirectory -Recurse -Force }
}

Write-Host "PASS: $script:Count assertions"
