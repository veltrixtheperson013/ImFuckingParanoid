# Freddy Fazbear (I don't know why I added this comment.)
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole] "Administrator")) {

    Write-Host "Requesting administrator privileges..."
    Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$LogFile = "$env:SystemDrive\privacy_script_log.txt"
$BackupHosts = "$env:SystemDrive\hosts_backup_$(Get-Date -Format 'yyyyMMdd_HHmmss').bak"
$FirewallTag = "PrivacyScript"
$DryRun = $false

function Log {
    param($msg,$level="INFO",$color="White")
    $line = "[$(Get-Date -Format 'HH:mm:ss')] [$level] $msg"
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $LogFile -Value $line
}

function Log-Debug {
    param($msg)
    Log $msg "DEBUG" "DarkGray"
}

function Invoke-WithTimeout {
    param(
        [scriptblock]$Script,
        [object[]]$Arguments = @(),
        [int]$TimeoutSeconds = 10,
        [string]$OperationName = "Operation"
    )

    Log-Debug "Starting timed operation: $OperationName (timeout=${TimeoutSeconds}s)"

    $job = Start-Job -ScriptBlock $Script -ArgumentList $Arguments

    $completed = Wait-Job $job -Timeout $TimeoutSeconds

    if (-not $completed) {
        Log "Timeout exceeded for: $OperationName. Aborting." "ERROR" "Red"
        Stop-Job $job -Force | Out-Null
        Remove-Job $job | Out-Null
        return $false
    }

    try {
        Receive-Job $job -ErrorAction Stop | Out-Null
        Log-Debug "Completed: $OperationName"
    } catch {
        Log "Error in ${OperationName}: $_" "ERROR" "Red"
        Remove-Job $job | Out-Null
        return $false
    }

    Remove-Job $job | Out-Null
    return $true
}

function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  _____             ______          _    _               _____                            _     _ " -ForegroundColor Cyan
    Write-Host " |_   _|           |  ____|        | |  (_)             |  __ \                          (_)   | |" -ForegroundColor Cyan
    Write-Host "   | |  _ __ ___   | |__ _   _  ___| | ___ _ __   __ _  | |__) |_ _ _ __ __ _ _ __   ___  _  __| |" -ForegroundColor Cyan
    Write-Host "   | | | '_ ` _ \  |  __| | | |/ __| |/ / | '_ \ / _` | |  ___/ _` | '__/ _` | '_ \ / _ \| |/ _` |" -ForegroundColor Cyan
    Write-Host "  _| |_| | | | | | | |  | |_| | (__|   <| | | | | (_| | | |  | (_| | | | (_| | | | | (_) | | (_| |" -ForegroundColor Cyan
    Write-Host " |_____|_| |_| |_| |_|   \__,_|\___|_|\_\_|_| |_|\__, | |_|   \__,_|_|  \__,_|_| |_|\___/|_|\__,_|" -ForegroundColor Cyan
    Write-Host "                                                  __/ |                                           " -ForegroundColor Cyan
    Write-Host "                                                 |___/                                            " -ForegroundColor Cyan
    Write-Host ""
    Write-Host "                      by velrixtheperson013" -ForegroundColor DarkGray
    Write-Host ""
}

function Intro-Delay {
    for ($i = 1; $i -le 5; $i++) {
        Write-Host "Initializing system scan... ($i/5)" -ForegroundColor DarkGray
        Start-Sleep -Seconds 1
    }
}

function Print-SystemInfo {
    Log "==== SYSTEM CONTEXT ===="

    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $cs = Get-CimInstance Win32_ComputerSystem
        $bios = Get-CimInstance Win32_BIOS

        $build = [int]$os.BuildNumber
        $winType = if ($build -ge 22000) { "Windows 11" } else { "Windows 10" }

        Log "OS Type: $winType"
        Log "Machine Name: $env:COMPUTERNAME"
        Log "User: $env:USERNAME"
        Log "Domain: $env:USERDOMAIN"
        Log "OS: $($os.Caption) ($($os.Version))"
        Log "Build: $build"
        Log "Manufacturer: $($cs.Manufacturer)"
        Log "Model: $($cs.Model)"
        Log "BIOS Serial: $($bios.SerialNumber)"
        Log "Uptime (hrs): $([math]::Round((Get-Date - $os.LastBootUpTime).TotalHours,2))"

        $id = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Cryptography").MachineGuid
        Log "Machine GUID: $id"

    } catch {
        Log "System info failed: $_" "ERROR" "Red"
    }

    Log "========================"
}

function Show-Menu {
    $options = @(
        "Apply ALL tweaks",
        "Hosts blocking",
        "Disable telemetry services",
        "Registry tweaks",
        "Disable scheduled tasks",
        "Firewall blocks",
        "Exit"
    )

    $selected = 0

    while ($true) {
        Clear-Host
        Write-Host "Use Up/Down arrows, Enter to select`n"

        for ($i=0; $i -lt $options.Count; $i++) {
            if ($i -eq $selected) {
                Write-Host "> $($options[$i])"
            } else {
                Write-Host "  $($options[$i])"
            }
        }

        $key = [Console]::ReadKey($true)

        switch ($key.Key) {
            "UpArrow"   { if ($selected -gt 0) { $selected-- } }
            "DownArrow" { if ($selected -lt $options.Count-1) { $selected++ } }
            "Enter"     { return $selected }
        }
    }
}

function Confirm-Action {
    Write-Host "`nProceed? (Y/N)"
    $k = [Console]::ReadKey($true)
    return ($k.Key -eq "Y")
}

function Create-RestorePoint {
    Write-Host "`nCreate a system restore point before continuing? (Y/N)"
    $key = [Console]::ReadKey($true)

    if ($key.Key -ne "Y") {
        Log "User skipped restore point creation" "INFO" "DarkGray"
        return
    }

    Log "Creating restore point"
    Write-Host "Creating system rollback checkpoint before modifications" -ForegroundColor DarkGray

    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue

        Log-Debug "Invoking Checkpoint-Computer"
        Checkpoint-Computer -Description "Pre-PrivacyScript" -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop

        Log "Restore point created successfully" "INFO" "Green"

    } catch {
        if ($_.Exception.Message -match "1440") {
            Log "Restore point skipped due to 24h system limit" "INFO" "Yellow"
        } else {
            Log "Restore point failed: $_" "ERROR" "Red"
        }
    }
}

function Apply-Hosts {
    Log "Apply Hosts" "INFO" "Cyan"
    Write-Host "Blocking telemetry endpoints using hosts file" -ForegroundColor DarkGray

    try {
        Copy-Item "$env:windir\System32\drivers\etc\hosts" $BackupHosts -Force
        Log "Backup success: $BackupHosts" "INFO" "Green"
    } catch {
        Log "Backup failed: $_" "ERROR" "Red"
    }

    $domains = @(
        "vortex.data.microsoft.com",
        "settings-win.data.microsoft.com"
    )

    $hostsPath = "$env:windir\System32\drivers\etc\hosts"

    foreach ($d in $domains) {
        Log-Debug "Processing domain: $d"

        try {
            $hosts = Get-Content $hostsPath

            if ($hosts -match $d) {
                Log "Exists: $d" "INFO" "Green"
            } else {
                Add-Content $hostsPath "0.0.0.0`t$d"
                Log "Added: $d" "INFO" "Yellow"
            }

            $verify = Get-Content $hostsPath | Select-String $d
            if ($verify) {
                Log "Verified block: $d" "INFO" "Green"
            } else {
                Log "Verification failed: $d" "ERROR" "Red"
            }

        } catch {
            Log "Hosts error ($d): $_" "ERROR" "Red"
        }
    }
}

function Apply-Services {
    Log "Apply Services" "INFO" "Cyan"
    Write-Host "Disabling telemetry services" -ForegroundColor DarkGray

    $svcs = @("DiagTrack","dmwappushservice")

    foreach ($s in $svcs) {
        Log-Debug "Processing service: $s"

        try {
            $svc = Get-Service $s -ErrorAction Stop
            Log "Before: Status=$($svc.Status) StartType=$($svc.StartType)"

            Log-Debug "Attempting Stop-Service on $s"
            Stop-Service $s -Force -ErrorAction Stop

            Log-Debug "Setting StartupType Disabled for $s"
            Set-Service $s -StartupType Disabled -ErrorAction Stop

            Start-Sleep -Milliseconds 500

            Log-Debug "Re-querying service state for $s"
            $svc2 = Get-Service $s

           $ok = Invoke-WithTimeout `
    -OperationName "Service:$s" `
    -Arguments @($s) `
    -Script {
        param($name)
        Stop-Service $name -Force -ErrorAction SilentlyContinue
        Set-Service $name -StartupType Disabled -ErrorAction Stop
    }

if (-not $ok) {
    Log "Service operation failed or timed out: $s" "ERROR" "Red"
}

        } catch {
            Log "Service error ($s): $_" "ERROR" "Red"
        }
    }
}

function Apply-Registry {
    Log "Apply Registry" "INFO" "Cyan"
    Write-Host "Applying telemetry and advertising policy restrictions" -ForegroundColor DarkGray

    $items = @(
        @{P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection";N="AllowTelemetry";V=0},
        @{P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo";N="DisabledByGroupPolicy";V=1}
    )

    foreach ($i in $items) {
        Log-Debug "Processing registry: $($i.N)"

        $ok = Invoke-WithTimeout `
            -OperationName "Registry:$($i.N)" `
            -Arguments @($i.P, $i.N, $i.V) `
            -Script {
                param($path, $name, $value)

                if (-not (Test-Path $path)) {
                    New-Item $path -Force | Out-Null
                }

                Set-ItemProperty -Path $path -Name $name -Value $value -Type DWord -ErrorAction Stop
            }

        if ($ok) {
            try {
                $after = (Get-ItemProperty -Path $i.P -Name $i.N -ErrorAction Stop).$($i.N)
                Log "After: $($i.N)=$after" "INFO" "Green"
            } catch {
                Log "Verification failed: $($i.N): $_" "ERROR" "Red"
            }
        } else {
            Log "Failed or timed out: $($i.N)" "ERROR" "Red"
        }
    }
}

function Apply-Tasks {
    Log "Apply Tasks" "INFO" "Cyan"
    Write-Host "Disabling telemetry-related scheduled tasks" -ForegroundColor DarkGray

    $tasks = @(
        @{Path="\Microsoft\Windows\Application Experience\";Name="Microsoft Compatibility Appraiser"}
    )

    foreach ($t in $tasks) {
        Log-Debug "Processing task: $($t.Name)"

        $ok = Invoke-WithTimeout `
            -OperationName "Task:$($t.Name)" `
            -Arguments @($t.Name, $t.Path) `
            -Script {
                param($name, $path)

                Disable-ScheduledTask -TaskName $name -TaskPath $path -ErrorAction Stop | Out-Null
            }

        if ($ok) {
            Log "Task disable issued: $($t.Name)" "INFO" "Green"
        } else {
            Log "Task operation failed or timed out: $($t.Name)" "ERROR" "Red"
        }
    }
}

function Apply-Firewall {
    Log "Apply Firewall" "INFO" "Cyan"
    Write-Host "Blocking outbound telemetry IPs" -ForegroundColor DarkGray

    $ips = @("134.170.30.202")

    foreach ($ip in $ips) {
        Log-Debug "Processing firewall IP: $ip"

        try {
            $name = "$FirewallTag-$ip"

            if (-not (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -DisplayName $name -Direction Outbound -Action Block -RemoteAddress $ip | Out-Null
                Log "Rule created: $name"
            }

            $verify = Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue
            $ok = ($verify -ne $null)

            if ($ok) { $color = "Green" } else { $color = "Red" }
            Log "Verification: RuleExists=$ok" "INFO" $color

        } catch {
            Log "FW error $($ip): $_" "ERROR" "Red"
        }
    }
}

Show-Banner
Intro-Delay
Print-SystemInfo

$choice = Show-Menu

if (-not (Confirm-Action)) {
    Log "User cancelled"
    exit
}

Create-RestorePoint

switch ($choice) {
    0 { Apply-Hosts; Apply-Services; Apply-Registry; Apply-Tasks; Apply-Firewall }
    1 { Apply-Hosts }
    2 { Apply-Services }
    3 { Apply-Registry }
    4 { Apply-Tasks }
    5 { Apply-Firewall }
    6 { exit }
}

Log "Done. Reboot recommended."

Write-Host "`nRestart your PC now? (Y/N)"
$key = [Console]::ReadKey($true)

if ($key.Key -eq "Y") {
    Log "User opted to restart system" "INFO" "Yellow"

    $maxAttempts = 3
    $attempt = 1
    $success = $false

    while ($attempt -le $maxAttempts -and -not $success) {
        Log-Debug "Restart attempt $attempt of $maxAttempts"

        try {
            Log "Issuing Restart-Computer -Force" "INFO" "Cyan"
            Restart-Computer -Force -ErrorAction Stop

            # If execution reaches here, command was accepted by PowerShell
            $success = $true
            Log "Restart command issued successfully" "INFO" "Green"
        } catch {
            Log "Restart attempt $attempt failed: $_" "ERROR" "Red"
        }

        if (-not $success) {
            Start-Sleep -Seconds 2
            $attempt++
        }
    }

    if (-not $success) {
        Log "All restart attempts failed after $maxAttempts tries" "ERROR" "Red"
    }

} else {
    Log "User declined restart. Exiting." "INFO" "DarkGray"
    exit
}
Pause
