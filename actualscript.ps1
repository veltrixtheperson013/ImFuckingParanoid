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
    param($msg,$level="INFO")
    $line = "[$(Get-Date -Format 'HH:mm:ss')] [$level] $msg"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
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

function Apply-Hosts {
    Log "Applying hosts rules"

    try {
        Copy-Item "$env:windir\System32\drivers\etc\hosts" $BackupHosts -Force
        Log "Backup created"
    } catch {
        Log "Backup failed: $_" "ERROR"
    }

    $domains = @(
        "vortex.data.microsoft.com",
        "settings-win.data.microsoft.com"
    )

    foreach ($d in $domains) {
        if ($DryRun) { Log "[DRY] Would add $d"; continue }

        try {
            $hosts = Get-Content "$env:windir\System32\drivers\etc\hosts"
            if ($hosts -match $d) {
                Log "Exists: $d"
            } else {
                Add-Content "$env:windir\System32\drivers\etc\hosts" "0.0.0.0`t$d"
                Log "Added: $d"
            }
        } catch {
            Log "Hosts error: $_" "ERROR"
        }
    }
}

function Apply-Services {
    $svcs = @("DiagTrack","dmwappushservice")

    foreach ($s in $svcs) {
        if ($DryRun) { Log "[DRY] Would disable $s"; continue }

        try {
            if (Get-Service $s -ErrorAction Stop) {
                Stop-Service $s -Force -ErrorAction SilentlyContinue
                Set-Service $s -StartupType Disabled
                Log "Disabled $s"
            }
        } catch {
            Log "Service error: $s" "ERROR"
        }
    }
}

function Apply-Registry {
    $items = @(
        @{P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection";N="AllowTelemetry";V=0},
        @{P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo";N="DisabledByGroupPolicy";V=1}
    )

    foreach ($i in $items) {
        if ($DryRun) { Log "[DRY] Reg $($i.N)"; continue }

        try {
            if (-not (Test-Path $i.P)) { New-Item $i.P -Force | Out-Null }
            Set-ItemProperty $i.P $i.N $i.V -Type DWord
            Log "Set $($i.N)"
        } catch {
            Log "Reg error $($i.N)" "ERROR"
        }
    }
}

function Apply-Tasks {
    $tasks = @(
        @{Path="\Microsoft\Windows\Application Experience\";Name="Microsoft Compatibility Appraiser"}
    )

    foreach ($t in $tasks) {
        if ($DryRun) { Log "[DRY] Task $($t.Name)"; continue }

        try {
            Disable-ScheduledTask -TaskName $t.Name -TaskPath $t.Path -ErrorAction Stop
            Log "Disabled task $($t.Name)"
        } catch {
            Log "Task error $($t.Name)" "ERROR"
        }
    }
}

function Apply-Firewall {
    $ips = @("134.170.30.202")

    foreach ($ip in $ips) {
        if ($DryRun) { Log "[DRY] Firewall $ip"; continue }

        try {
            $name = "$FirewallTag-$ip"
            if (-not (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -DisplayName $name -Direction Outbound -Action Block -RemoteAddress $ip | Out-Null
                Log "Blocked $ip"
            }
        } catch {
            Log "FW error $ip" "ERROR"
        }
    }
}

$choice = Show-Menu

if (-not (Confirm-Action)) {
    Log "User cancelled"
    exit
}

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
