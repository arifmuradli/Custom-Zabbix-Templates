# veeam_tape.ps1 - Veeam tape job status for Zabbix (UserParameter veeam.tape.status[*])
# Run locally by the Zabbix agent on the VBR server. Prints one line of JSON to stdout.
param([int]$WaitMinutes = 30)

$ErrorActionPreference = 'Stop'
$WarningPreference     = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

function Write-Json($obj) {
    [Console]::Out.Write(($obj | ConvertTo-Json -Compress -Depth 4))
}

function Join-Names($list) {
    if ($list.Count -eq 0) { return 'none' }
    return ($list -join '; ')
}

try {
    Import-Module Veeam.Backup.PowerShell -DisableNameChecking -WarningAction SilentlyContinue

    $now     = Get-Date
    $jobs    = @()
    $waiting = @()
    $failed  = @()
    $warning = @()
    $maxWait = 0

    foreach ($j in @(Get-VBRTapeJob)) {
        $state  = [string]$j.LastState
        $result = [string]$j.LastResult
        $mins   = 0

        if ($state -eq 'WaitingTape') {
            try {
                $s = Get-VBRSession -Job $j -Last -WarningAction SilentlyContinue
                if ($s -and $s.CreationTime) {
                    $mins = [int][math]::Floor(($now - $s.CreationTime).TotalMinutes)
                }
            } catch { }
            if ($mins -gt $maxWait) { $maxWait = $mins }
            # Names only (no minutes), so the value changes only when the set of jobs changes
            if ($mins -ge $WaitMinutes) { $waiting += $j.Name }
        }

        if ($j.Enabled) {
            if     ($result -eq 'Failed')  { $failed  += $j.Name }
            elseif ($result -eq 'Warning') { $warning += $j.Name }
        }

        $jobs += [ordered]@{
            name        = $j.Name
            enabled     = [bool]$j.Enabled
            state       = $state
            result      = $result
            waiting_min = $mins
        }
    }

    Write-Json ([ordered]@{
        error           = ''
        jobs_total      = $jobs.Count
        waiting         = $waiting.Count
        waiting_names   = Join-Names $waiting
        waiting_max_min = $maxWait
        failed          = $failed.Count
        failed_names    = Join-Names $failed
        warning         = $warning.Count
        warning_names   = Join-Names $warning
        jobs            = $jobs
    })
}
catch {
    Write-Json ([ordered]@{ error = [string]$_.Exception.Message })
}
