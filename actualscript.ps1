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
        Log "Machine Name: $($env:COMPUTERNAME)"
        Log "User: $($env:USERNAME)"
        Log "Domain: $($env:USERDOMAIN)"
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
    Log "Creating restore point"

    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description "Pre-PrivacyScript" -RestorePointType "MODIFY_SETTINGS"
        Log "Restore point success" "INFO" "Green"
    } catch {
        Log "Restore point failed: $_" "ERROR" "Red"
    }
}

function Apply-Hosts {
    Log "Hosts operation start"

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

    foreach ($d in $domains) {
        Log-Debug "Domain check: $d"

        try {
            $hosts = Get-Content "$env:windir\System32\drivers\etc\hosts"
            if ($hosts -match $d) {
                Log "Exists: $d" "INFO" "Green"
            } else {
                Add-Content "$env:windir\System32\drivers\etc\hosts" "0.0.0.0`t$d"
                Log "Added: $d" "INFO" "Green"
            }
        } catch {
            Log "Hosts error ($d): $_" "ERROR" "Red"
        }
    }
}

function Apply-Services {
    $svcs = @("DiagTrack","dmwappushservice")

    foreach ($s in $svcs) {
        Log-Debug "Service check: $s"

        try {
            $svc = Get-Service $s -ErrorAction Stop
            Log "Before: $s = $($svc.Status)"

            Stop-Service $s -Force -ErrorAction SilentlyContinue
            Set-Service $s -StartupType Disabled

            $svc2 = Get-Service $s
            $ok = ($svc2.StartType -eq "Disabled")

            if ($ok) { $color = "Green" } else { $color = "Red" }
            Log "After: $s Disabled=$ok" "INFO" $color

        } catch {
            Log "Service error ($s): $_" "ERROR" "Red"
        }
    }
}

function Apply-Registry {
    $items = @(
        @{P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection";N="AllowTelemetry";V=0},
        @{P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo";N="DisabledByGroupPolicy";V=1}
    )

    foreach ($i in $items) {
        Log-Debug "Registry op: $($i.N)"

        try {
            if (-not (Test-Path $i.P)) {
                New-Item $i.P -Force | Out-Null
            }

            $before = (Get-ItemProperty $i.P -Name $i.N -ErrorAction SilentlyContinue).$($i.N)
            Log "Before: $($i.N)=$before"

            Set-ItemProperty $i.P $i.N $i.V -Type DWord

            $after = (Get-ItemProperty $i.P -Name $i.N).$($i.N)
            $ok = ($after -eq $i.V)

            if ($ok) { $color = "Green" } else { $color = "Red" }
            Log "After: $($i.N)=$after OK=$ok" "INFO" $color

        } catch {
            Log "Registry error ($($i.N)): $_" "ERROR" "Red"
        }
    }
}

function Apply-Tasks {
    $tasks = @(
        @{Path="\Microsoft\Windows\Application Experience\";Name="Microsoft Compatibility Appraiser"}
    )

    foreach ($t in $tasks) {
        Log-Debug "Task check: $($t.Name)"

        try {
            Disable-ScheduledTask -TaskName $t.Name -TaskPath $t.Path

            $task2 = Get-ScheduledTask -TaskName $t.Name -TaskPath $t.Path
            $ok = ($task2.State -ne "Ready")

            if ($ok) { $color = "Green" } else { $color = "Red" }
            Log "Task Disabled=$ok ($($t.Name))" "INFO" $color

        } catch {
            Log "Task error ($($t.Name)): $_" "ERROR" "Red"
        }
    }
}

function Apply-Firewall {
    $ips = @("134.170.30.202")

    foreach ($ip in $ips) {
        Log-Debug "Firewall check: $ip"

        try {
            $name = "$FirewallTag-$ip"
            $exists = Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue

            if ($exists) {
                Log "Exists: $name" "INFO" "Green"
            } else {
                New-NetFirewallRule -DisplayName $name -Direction Outbound -Action Block -RemoteAddress $ip | Out-Null
                Log "Created: $name" "INFO" "Green"
            }

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
Pause
