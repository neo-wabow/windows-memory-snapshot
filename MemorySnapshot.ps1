[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'snapshots'),
    [switch]$Once,
    [switch]$NoRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:PendingCommands = @{}

function Get-Config {
    param([string]$Path)
    $config = [ordered]@{
        checkIntervalSeconds = 30
        warningPercent = 15
        criticalPercent = 10
        criticalAvailableGB = 4
        severePercent = 5
        recoveryPercent = 20
        snapshotCooldownMinutes = 10
    }
    if (Test-Path -LiteralPath $Path) {
        $custom = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        foreach ($name in $config.Keys) {
            if ($null -ne $custom.PSObject.Properties[$name]) { $config[$name] = $custom.$name }
        }
    }
    foreach ($name in $config.Keys) {
        $value = $config[$name]
        if ($null -eq $value -or $value -is [bool] -or $value -is [string] -or
            -not ($value -is [int] -or $value -is [long] -or $value -is [double] -or $value -is [decimal]) -or
            [double]::IsNaN([double]$value) -or [double]::IsInfinity([double]$value) -or [double]$value -le 0) {
            throw "Invalid positive numeric setting: $name"
        }
    }
    if ($config.severePercent -ge $config.criticalPercent -or
        $config.criticalPercent -ge $config.warningPercent -or
        $config.warningPercent -ge $config.recoveryPercent -or
        $config.recoveryPercent -gt 100) {
        throw 'Expected severePercent < criticalPercent < warningPercent < recoveryPercent <= 100.'
    }
    return [pscustomobject]$config
}

function ConvertTo-GB {
    param([double]$Bytes)
    return [math]::Round($Bytes / 1GB, 2)
}

function Get-MemorySample {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $total = [double]$os.TotalVisibleMemorySize * 1KB
    $available = [double]$os.FreePhysicalMemory * 1KB
    if ($total -le 0) { throw 'Windows did not report total physical memory.' }
    $commitUsed = $null
    $commitLimit = $null
    try {
        $performance = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Memory
        if ($null -ne $performance.PSObject.Properties['AvailableBytes'] -and $null -ne $performance.AvailableBytes) {
            $available = [double]$performance.AvailableBytes
        }
        $commitUsed = [double]$performance.CommittedBytes
        $commitLimit = [double]$performance.CommitLimit
    } catch {
        # Basic RAM monitoring still works when performance counters are unavailable.
    }
    return [pscustomobject]@{
        Time = Get-Date
        TotalBytes = $total
        AvailableBytes = $available
        AvailablePercent = 100 * $available / $total
        UsedPercent = 100 * ($total - $available) / $total
        CommitUsedBytes = $commitUsed
        CommitLimitBytes = $commitLimit
    }
}

function New-MonitorState {
    return [pscustomobject]@{
        InEpisode = $false
        SnapshottedInEpisode = @{}
        LastSnapshotAt = @{}
    }
}

function Get-DueSnapshots {
    param($Sample, $Config, $State)
    $due = New-Object System.Collections.Generic.List[string]
    $now = [datetime]$Sample.Time
    $availableGB = [double]$Sample.AvailableBytes / 1GB
    $warning = $Sample.AvailablePercent -le $Config.warningPercent
    $critical = $Sample.AvailablePercent -le $Config.criticalPercent -or $availableGB -le $Config.criticalAvailableGB
    $severe = $Sample.AvailablePercent -le $Config.severePercent

    if (($warning -or $critical) -and -not $State.InEpisode) {
        $State.InEpisode = $true
        $State.SnapshottedInEpisode = @{}
    }
    $levels = @()
    if ($critical) { $levels += 'critical' }
    if ($severe) { $levels += 'severe' }
    $endEpisode = $false
    if ($State.InEpisode -and -not $critical -and $Sample.AvailablePercent -ge $Config.recoveryPercent) {
        $levels += 'recovery'
        $endEpisode = $true
    }
    foreach ($level in $levels) {
        if (-not $State.SnapshottedInEpisode.ContainsKey($level) -and
            (-not $State.LastSnapshotAt.ContainsKey($level) -or
             ($now - [datetime]$State.LastSnapshotAt[$level]).TotalMinutes -ge $Config.snapshotCooldownMinutes)) {
            $due.Add($level)
            $State.LastSnapshotAt[$level] = $now
            $State.SnapshottedInEpisode[$level] = $true
        }
    }
    if ($endEpisode) {
        $State.InEpisode = $false
        $State.SnapshottedInEpisode = @{}
    }
    return [pscustomobject]@{ Warning = $warning; Levels = @($due.ToArray()) }
}

function Write-WarningSample {
    param($Sample, [string]$Directory)
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $path = Join-Path $Directory 'warning-memory.csv'
    # Bound the low-memory log while keeping the most recent samples.
    if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -ge 10MB) {
        Move-Item -LiteralPath $path -Destination (Join-Path $Directory 'warning-memory.previous.csv') -Force
    }
    $row = [pscustomobject]@{
        Time = $Sample.Time.ToString('yyyy-MM-dd HH:mm:ss')
        AvailablePercent = [math]::Round($Sample.AvailablePercent, 2)
        AvailableGB = ConvertTo-GB $Sample.AvailableBytes
        CommitUsedGB = $(if ($null -eq $Sample.CommitUsedBytes) { $null } else { ConvertTo-GB $Sample.CommitUsedBytes })
        CommitLimitGB = $(if ($null -eq $Sample.CommitLimitBytes) { $null } else { ConvertTo-GB $Sample.CommitLimitBytes })
    }
    if (Test-Path -LiteralPath $path) { $row | Export-Csv -LiteralPath $path -NoTypeInformation -Append -Encoding UTF8 }
    else { $row | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8 }
}

function Quote-Argument {
    param([string]$Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    $result = '"'
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            $result += ('\' * (2 * $slashes + 1)) + '"'
            $slashes = 0
            continue
        }
        $result += ('\' * $slashes) + $character
        $slashes = 0
    }
    return $result + ('\' * (2 * $slashes)) + '"'
}

function Invoke-LocalCommand {
    param([string]$FileName, [string[]]$Arguments, [int]$TimeoutSeconds = 8, [System.Text.Encoding]$OutputEncoding = $null)
    $key = $FileName + '|' + ($Arguments -join '|')
    foreach ($pendingKey in @($script:PendingCommands.Keys)) {
        $pending = $script:PendingCommands[$pendingKey]
        if ($pending.HasExited) {
            $pending.Dispose()
            $script:PendingCommands.Remove($pendingKey)
        }
    }
    if ($script:PendingCommands.ContainsKey($key)) {
        return [pscustomobject]@{ Ok = $false; Output = ''; Error = 'Previous command is still running after timeout.' }
    }
    if ($script:PendingCommands.Count -ge 4) {
        return [pscustomobject]@{ Ok = $false; Output = ''; Error = 'Too many timed out commands remain active.' }
    }
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $FileName
    $info.Arguments = (($Arguments | ForEach-Object { Quote-Argument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    if ($null -ne $OutputEncoding) { $info.StandardOutputEncoding = $OutputEncoding }
    if ($FileName -eq 'docker.exe') {
        # Docker's ambient context can point to a remote host. Never inherit it.
        $info.EnvironmentVariables.Remove('DOCKER_CONTEXT')
        $info.EnvironmentVariables.Remove('DOCKER_HOST')
    }
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw 'Process did not start.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            # Do not terminate any process. Keep one outstanding invocation per command.
            $script:PendingCommands[$key] = $process
            return [pscustomobject]@{ Ok = $false; Output = ''; Error = 'Command timed out.' }
        }
        $output = $stdout.GetAwaiter().GetResult()
        $errorText = $stderr.GetAwaiter().GetResult()
        return [pscustomobject]@{ Ok = ($process.ExitCode -eq 0); Output = $output; Error = $errorText }
    } catch {
        return [pscustomobject]@{ Ok = $false; Output = ''; Error = $_.Exception.Message }
    } finally {
        if (-not $script:PendingCommands.ContainsKey($key)) { $process.Dispose() }
    }
}

function Get-Processes {
    return @(Get-Process | Sort-Object -Property WorkingSet64 -Descending | Select-Object -First 20 |
        ForEach-Object {
            [pscustomobject]@{
                Name = $_.ProcessName
                PID = $_.Id
                WorkingSetGB = ConvertTo-GB $_.WorkingSet64
                PrivateMemoryGB = ConvertTo-GB $_.PrivateMemorySize64
            }
        })
}

function Get-Pagefiles {
    return @(Get-CimInstance -ClassName Win32_PageFileUsage | ForEach-Object {
        [pscustomobject]@{
            # Deliberately omit the pagefile path.
            AllocatedGB = [math]::Round([double]$_.AllocatedBaseSize / 1024, 2)
            CurrentUsedGB = [math]::Round([double]$_.CurrentUsage / 1024, 2)
            PeakUsedGB = [math]::Round([double]$_.PeakUsage / 1024, 2)
        }
    })
}

function Get-WslData {
    $result = [ordered]@{ Status = 'Unavailable'; MemoryUsedGB = $null; MemoryAvailableGB = $null; SwapTotalGB = $null; SwapUsedGB = $null; VmmemWSLGB = $null; OomCheck = 'Unavailable'; OomEntries = @() }
    $vmmem = @(Get-Process -Name 'vmmemWSL' -ErrorAction SilentlyContinue)
    if ($vmmem.Count -gt 0) { $result.VmmemWSLGB = ConvertTo-GB (($vmmem | Measure-Object WorkingSet64 -Sum).Sum) }
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return [pscustomobject]$result }
    $running = Invoke-LocalCommand 'wsl.exe' @('--list', '--running', '--quiet') 8 ([System.Text.Encoding]::Unicode)
    if (-not $running.Ok) { $result.Status = 'No running distribution or WSL unavailable'; return [pscustomobject]$result }
    $names = @($running.Output.Replace([string][char]0, '').Replace([string][char]0xFEFF, '') -split "`r?`n" | Where-Object { $_.Trim() })
    if ($names.Count -eq 0) { $result.Status = 'No running distribution'; return [pscustomobject]$result }
    $distro = $names[0].Trim()
    $free = Invoke-LocalCommand 'wsl.exe' @('--distribution', $distro, '--exec', 'free', '-b')
    if (-not $free.Ok) { $result.Status = 'free unavailable or timed out'; return [pscustomobject]$result }
    $memoryLine = @($free.Output -split "`r?`n" | Where-Object { $_ -match '^Mem:\s+' } | Select-Object -First 1)
    $swapLine = @($free.Output -split "`r?`n" | Where-Object { $_ -match '^Swap:\s+' } | Select-Object -First 1)
    if ($memoryLine.Count -eq 0 -or $swapLine.Count -eq 0) { $result.Status = 'Could not parse free output'; return [pscustomobject]$result }
    $mem = @($memoryLine[0].Trim() -split '\s+')
    $swap = @($swapLine[0].Trim() -split '\s+')
    if ($mem.Count -lt 4 -or $swap.Count -lt 4) { $result.Status = 'Could not parse free output'; return [pscustomobject]$result }
    try {
        $result.MemoryUsedGB = ConvertTo-GB ([double]::Parse($mem[2], [cultureinfo]::InvariantCulture))
        $result.MemoryAvailableGB = ConvertTo-GB ([double]::Parse($mem[$mem.Count - 1], [cultureinfo]::InvariantCulture))
        $result.SwapTotalGB = ConvertTo-GB ([double]::Parse($swap[1], [cultureinfo]::InvariantCulture))
        $result.SwapUsedGB = ConvertTo-GB ([double]::Parse($swap[2], [cultureinfo]::InvariantCulture))
        $result.Status = 'Available'
    } catch { $result.Status = 'Could not parse free output' }
    if ($result.Status -eq 'Available') {
        $dmesg = Invoke-LocalCommand 'wsl.exe' @('--distribution', $distro, '--exec', 'dmesg', '--since', '30 minutes ago') 5
        if ($dmesg.Ok) {
            $result.OomCheck = 'Checked'
            $entries = New-Object System.Collections.Generic.List[string]
            foreach ($line in ($dmesg.Output -split "`r?`n")) {
                if ($line -match 'Killed process\s+(\d+)\s+\(([^)]+)\)') {
                    $entries.Add(('Killed PID {0} ({1})' -f $Matches[1], $Matches[2]))
                }
            }
            $result.OomEntries = @($entries | Select-Object -Last 20)
        }
    }
    return [pscustomobject]$result
}

function Get-DockerData {
    $result = [ordered]@{ Status = 'Unavailable'; Stats = @(); Containers = @() }
    if (-not (Get-Command docker.exe -ErrorAction SilentlyContinue)) { return [pscustomobject]$result }
    $ps = $null
    $localHost = $null
    foreach ($candidate in @('npipe:////./pipe/docker_engine', 'npipe:////./pipe/dockerDesktopLinuxEngine')) {
        $attempt = Invoke-LocalCommand 'docker.exe' @('--host', $candidate, 'ps', '-a', '--format', '{{.ID}}|{{.Names}}|{{.Status}}')
        if ($attempt.Ok) { $ps = $attempt; $localHost = $candidate; break }
    }
    if ($null -eq $ps) { $result.Status = 'Local Docker unavailable or timed out'; return [pscustomobject]$result }
    $containers = New-Object System.Collections.Generic.List[object]
    foreach ($line in ($ps.Output -split "`r?`n")) {
        if (-not $line.Trim()) { continue }
        try {
            $item = @($line -split '\|', 3)
            if ($item.Count -ne 3) { continue }
            $containers.Add([pscustomobject]@{ Name = $item[1]; ShortID = $item[0]; Status = $item[2]; RestartCount = $null; OOMKilled = $null })
        } catch { continue }
    }
    $result.Containers = @($containers.ToArray())
    if ($containers.Count -gt 0) {
        $ids = @($containers | ForEach-Object { $_.ShortID })
        $inspectArgs = @('--host', $localHost, 'inspect', '--format', '{{.Id}}|{{.RestartCount}}|{{.State.OOMKilled}}') + $ids
        $detail = Invoke-LocalCommand 'docker.exe' $inspectArgs
        if ($detail.Ok) {
            foreach ($line in ($detail.Output -split "`r?`n")) {
                if ($line -match '^([0-9a-f]+)\|(\d+)\|(true|false)') {
                    $id = $Matches[1]; $restart = [int]$Matches[2]; $oom = [bool]::Parse($Matches[3])
                    foreach ($container in $containers) {
                        if ($id.StartsWith($container.ShortID)) {
                            $container.RestartCount = $restart
                            $container.OOMKilled = $oom
                        }
                    }
                }
            }
        }
    }
    $stats = Invoke-LocalCommand 'docker.exe' @('--host', $localHost, 'stats', '--no-stream', '--format', '{{.ID}}|{{.Name}}|{{.MemUsage}}|{{.MemPerc}}|{{.CPUPerc}}')
    if ($stats.Ok) {
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($line in ($stats.Output -split "`r?`n")) {
            if (-not $line.Trim()) { continue }
            try {
                $item = @($line -split '\|', 5)
                if ($item.Count -ne 5) { continue }
                $usage = @([string]$item[2] -split '\s*/\s*')
                $rows.Add([pscustomobject]@{ Name = $item[1]; ShortID = $item[0]; MemoryUsage = $usage[0]; MemoryLimit = $(if ($usage.Count -gt 1) { $usage[1] } else { $null }); MemoryPercent = $item[3]; CPUPercent = $item[4] })
            } catch { continue }
        }
        $result.Stats = @($rows.ToArray())
        $result.Status = 'Available'
    } else { $result.Status = 'Container list available; stats unavailable or timed out' }
    return [pscustomobject]$result
}

function Format-GB {
    param($Bytes)
    if ($null -eq $Bytes) { return 'Unavailable' }
    return ('{0:N2} GB' -f (ConvertTo-GB $Bytes))
}

function Write-CsvTable {
    param([string]$Path, [object[]]$Rows, [string[]]$Columns)
    if ($Rows.Count -gt 0) { $Rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8 }
    else { (($Columns | ForEach-Object { '"' + $_ + '"' }) -join ',') | Set-Content -LiteralPath $Path -Encoding UTF8 }
}

function Save-Snapshot {
    param($Sample, [string]$Level, [string]$Directory)
    $stamp = $Sample.Time.ToString('yyyy-MM-dd_HH-mm-ss-fff')
    $path = Join-Path $Directory ($stamp + '_' + $Level)
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    $errors = New-Object System.Collections.Generic.List[string]
    $processes = @(); $pagefiles = @(); $wsl = $null; $docker = $null

    try { $processes = @(Get-Processes); Write-CsvTable (Join-Path $path 'processes.csv') $processes @('Name', 'PID', 'WorkingSetGB', 'PrivateMemoryGB') }
    catch { $errors.Add('Processes: unavailable') }
    try { $pagefiles = @(Get-Pagefiles) }
    catch { $errors.Add('Pagefile: unavailable') }
    try { $wsl = Get-WslData } catch { $errors.Add('WSL: unavailable') }
    try { $docker = Get-DockerData } catch { $errors.Add('Docker: unavailable') }

    [pscustomobject]@{
        Time = $Sample.Time.ToString('yyyy-MM-dd HH:mm:ss')
        TotalGB = ConvertTo-GB $Sample.TotalBytes
        AvailableGB = ConvertTo-GB $Sample.AvailableBytes
        AvailablePercent = [math]::Round($Sample.AvailablePercent, 2)
        UsedPercent = [math]::Round($Sample.UsedPercent, 2)
        CommitUsedGB = $(if ($null -eq $Sample.CommitUsedBytes) { $null } else { ConvertTo-GB $Sample.CommitUsedBytes })
        CommitLimitGB = $(if ($null -eq $Sample.CommitLimitBytes) { $null } else { ConvertTo-GB $Sample.CommitLimitBytes })
    } | Export-Csv -LiteralPath (Join-Path $path 'windows-memory.csv') -NoTypeInformation -Encoding UTF8
    try { Write-CsvTable (Join-Path $path 'pagefile.csv') $pagefiles @('AllocatedGB', 'CurrentUsedGB', 'PeakUsedGB') }
    catch { $errors.Add('Pagefile output: unavailable') }

    $wslLines = @('WSL', ('Status: ' + $(if ($null -eq $wsl) { 'Unavailable' } else { $wsl.Status })))
    if ($null -ne $wsl -and $wsl.Status -eq 'Available') {
        $wslLines += "Memory used: $($wsl.MemoryUsedGB) GB"
        $wslLines += "Memory available: $($wsl.MemoryAvailableGB) GB"
        $wslLines += "Swap total: $($wsl.SwapTotalGB) GB"
        $wslLines += "Swap used: $($wsl.SwapUsedGB) GB"
    }
    if ($null -ne $wsl -and $null -ne $wsl.VmmemWSLGB) {
        $wslLines += "vmmemWSL working set: $($wsl.VmmemWSLGB) GB"
    }
    try { $wslLines | Set-Content -LiteralPath (Join-Path $path 'wsl.txt') -Encoding UTF8 }
    catch { $errors.Add('WSL output: unavailable') }
    $statsRows = @()
    $containerRows = @()
    if ($null -ne $docker) {
        $statsRows = @($docker.Stats)
        $containerRows = @($docker.Containers)
    }
    try { Write-CsvTable (Join-Path $path 'docker-stats.csv') $statsRows @('Name', 'ShortID', 'MemoryUsage', 'MemoryLimit', 'MemoryPercent', 'CPUPercent') }
    catch { $errors.Add('Docker stats output: unavailable') }
    try { Write-CsvTable (Join-Path $path 'docker-containers.csv') $containerRows @('Name', 'ShortID', 'Status', 'RestartCount', 'OOMKilled') }
    catch { $errors.Add('Docker containers output: unavailable') }
    $oomEntries = @()
    $dockerOom = @()
    if ($null -ne $wsl) { $oomEntries = @($wsl.OomEntries) }
    if ($null -ne $docker) { $dockerOom = @($docker.Containers | Where-Object { $_.OOMKilled -eq $true }) }
    $dockerOomUnknown = $null -ne $docker -and @($docker.Containers | Where-Object { $null -eq $_.OOMKilled }).Count -gt 0
    $oomStatus = if ($oomEntries.Count -gt 0 -or $dockerOom.Count -gt 0) { 'Yes' } elseif ($null -eq $wsl -or $wsl.OomCheck -ne 'Checked' -or $dockerOomUnknown) { 'Unknown' } else { 'No evidence found in accessible sources' }
    $oomLines = @("OOM detected: $oomStatus") + $oomEntries + @($dockerOom | ForEach-Object { "Container $($_.Name) ($($_.ShortID)): OOMKilled" })
    try { $oomLines | Set-Content -LiteralPath (Join-Path $path 'oom.txt') -Encoding UTF8 }
    catch { $errors.Add('OOM output: unavailable') }

    $summary = New-Object System.Collections.Generic.List[string]
    $summary.Add('Memory Snapshot')
    $summary.Add("Time: $($Sample.Time.ToString('yyyy-MM-dd HH:mm:ss'))")
    $summary.Add("Level: $Level")
    $summary.Add('')
    $summary.Add('Windows')
    $summary.Add("Total RAM: $(Format-GB $Sample.TotalBytes)")
    $summary.Add("Available: $(Format-GB $Sample.AvailableBytes) ($([math]::Round($Sample.AvailablePercent, 1))%)")
    $summary.Add("Used: $([math]::Round($Sample.UsedPercent, 1))%")
    $summary.Add("Commit: $(Format-GB $Sample.CommitUsedBytes) / $(Format-GB $Sample.CommitLimitBytes)")
    foreach ($pf in $pagefiles) { $summary.Add("Pagefile: $($pf.CurrentUsedGB) / $($pf.AllocatedGB) GB") }
    $summary.Add('')
    $summary.Add('WSL')
    $summary.Add("Status: $(if ($null -eq $wsl) { 'Unavailable' } else { $wsl.Status })")
    if ($null -ne $wsl -and $wsl.Status -eq 'Available') {
        $summary.Add("Memory used: $($wsl.MemoryUsedGB) GB; available: $($wsl.MemoryAvailableGB) GB")
        $summary.Add("Swap used: $($wsl.SwapUsedGB) / $($wsl.SwapTotalGB) GB")
    }
    if ($null -ne $wsl -and $null -ne $wsl.VmmemWSLGB) { $summary.Add("vmmemWSL working set: $($wsl.VmmemWSLGB) GB") }
    $summary.Add('')
    $summary.Add('Top processes by working set')
    foreach ($p in @($processes | Select-Object -First 5)) { $summary.Add("$($p.Name) (PID $($p.PID)): $($p.WorkingSetGB) GB") }
    $summary.Add('')
    $summary.Add('Docker')
    $summary.Add("Status: $(if ($null -eq $docker) { 'Unavailable' } else { $docker.Status })")
    if ($null -ne $docker) { foreach ($c in @($docker.Stats | Select-Object -First 5)) { $summary.Add("$($c.Name): $($c.MemoryUsage) / $($c.MemoryLimit), CPU $($c.CPUPercent)") } }
    $summary.Add('')
    $summary.Add("OOM detected: $oomStatus")
    foreach ($message in $errors) { $summary.Add($message) }
    $summary | Set-Content -LiteralPath (Join-Path $path 'summary.txt') -Encoding UTF8
    return $path
}

function Start-Monitor {
    param($Config, [string]$Directory, [switch]$SingleCheck)
    $state = New-MonitorState
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    Write-Host 'Monitoring Windows available memory. Press Ctrl+C to stop.'
    while ($true) {
        $checkStarted = Get-Date
        try {
            $sample = Get-MemorySample
            $decision = Get-DueSnapshots $sample $Config $state
            if ($decision.Warning) {
                try { Write-WarningSample $sample $Directory }
                catch { Write-Warning "Warning sample could not be saved: $($_.Exception.Message)" }
            }
            foreach ($level in $decision.Levels) {
                try {
                    $saved = Save-Snapshot $sample $level $Directory
                    Write-Host "Saved $level snapshot: $saved"
                } catch {
                    Write-Warning "Snapshot $level could not be saved: $($_.Exception.Message)"
                }
            }
        } catch {
            if ($SingleCheck) { throw }
            Write-Warning "Memory check failed: $($_.Exception.Message)"
        }
        if ($SingleCheck) {
            Write-Host 'Memory check completed.'
            break
        }
        $remainingMs = [math]::Ceiling(([double]$Config.checkIntervalSeconds - ((Get-Date) - $checkStarted).TotalSeconds) * 1000)
        if ($remainingMs -gt 0) { Start-Sleep -Milliseconds ([int]$remainingMs) }
    }
}

if (-not $NoRun) {
    if ($env:OS -ne 'Windows_NT') { throw 'This tool runs on Windows only.' }
    $config = Get-Config $ConfigPath
    Start-Monitor $config $OutputDirectory -SingleCheck:$Once
}
