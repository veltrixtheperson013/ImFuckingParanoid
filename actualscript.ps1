# ImFuckingParanoid Console
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)) {

    Write-Host "Requesting administrator privileges..."
    Start-Process powershell -Verb RunAs -ArgumentList @(
        "-NoProfile"
        "-ExecutionPolicy", "Bypass"
        "-File", "`"$PSCommandPath`""
    )
    exit
}

$script:AppName = "ImFuckingParanoid"
$script:Version = "1.0.0"
$script:LogFile = "$env:SystemDrive\privacy_script_log.txt"
$script:BackupHosts = "$env:SystemDrive\hosts_backup_$(Get-Date -Format 'yyyyMMdd_HHmmss').bak"
$script:FirewallTag = "ImFuckingParanoid"
$script:HostsPath = "$env:windir\System32\drivers\etc\hosts"
$script:HostsBackedUp = $false
$script:CriticalProcessNames = @("Idle", "System", "Registry", "smss", "csrss", "wininit", "services", "lsass", "winlogon", "fontdrvhost", "dwm", "sihost", "svchost")

if (-not ("FileLockUtil" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class FileLockUtil
{
    const int RmRebootReasonNone = 0;
    const int CCH_RM_MAX_APP_NAME = 255;
    const int CCH_RM_MAX_SVC_NAME = 63;
    const int ERROR_MORE_DATA = 234;

    [StructLayout(LayoutKind.Sequential)]
    public struct RM_UNIQUE_PROCESS
    {
        public int dwProcessId;
        public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
    }

    public enum RM_APP_TYPE
    {
        RmUnknownApp = 0,
        RmMainWindow = 1,
        RmOtherWindow = 2,
        RmService = 3,
        RmExplorer = 4,
        RmConsole = 5,
        RmCritical = 1000
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct RM_PROCESS_INFO
    {
        public RM_UNIQUE_PROCESS Process;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_APP_NAME + 1)]
        public string strAppName;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_SVC_NAME + 1)]
        public string strServiceShortName;

        public RM_APP_TYPE ApplicationType;
        public uint AppStatus;
        public uint TSSessionId;

        [MarshalAs(UnmanagedType.Bool)]
        public bool bRestartable;
    }

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, string strSessionKey);

    [DllImport("rstrtmgr.dll")]
    static extern int RmEndSession(uint pSessionHandle);

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmRegisterResources(
        uint pSessionHandle,
        uint nFiles,
        string[] rgsFilenames,
        uint nApplications,
        [In] RM_UNIQUE_PROCESS[] rgApplications,
        uint nServices,
        string[] rgsServiceNames);

    [DllImport("rstrtmgr.dll")]
    static extern int RmGetList(
        uint dwSessionHandle,
        out uint pnProcInfoNeeded,
        ref uint pnProcInfo,
        [In, Out] RM_PROCESS_INFO[] rgAffectedApps,
        ref uint lpdwRebootReasons);

    public static int[] GetLockingProcessIds(string path)
    {
        uint handle;
        string key = Guid.NewGuid().ToString();
        int result = RmStartSession(out handle, 0, key);
        if (result != 0)
        {
            throw new InvalidOperationException("RmStartSession failed with error " + result);
        }

        try
        {
            string[] resources = new string[] { path };
            result = RmRegisterResources(handle, (uint)resources.Length, resources, 0, null, 0, null);
            if (result != 0)
            {
                throw new InvalidOperationException("RmRegisterResources failed with error " + result);
            }

            uint needed = 0;
            uint count = 0;
            uint reasons = RmRebootReasonNone;
            result = RmGetList(handle, out needed, ref count, null, ref reasons);

            if (result == ERROR_MORE_DATA)
            {
                RM_PROCESS_INFO[] processInfo = new RM_PROCESS_INFO[needed];
                count = needed;
                result = RmGetList(handle, out needed, ref count, processInfo, ref reasons);
                if (result != 0)
                {
                    throw new InvalidOperationException("RmGetList failed with error " + result);
                }

                List<int> processIds = new List<int>();
                for (int i = 0; i < count; i++)
                {
                    processIds.Add(processInfo[i].Process.dwProcessId);
                }
                return processIds.ToArray();
            }

            if (result != 0)
            {
                throw new InvalidOperationException("RmGetList failed with error " + result);
            }

            return Array.Empty<int>();
        }
        finally
        {
            RmEndSession(handle);
        }
    }
}
"@
}

function Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [string]$Level = "INFO",
        [string]$Color = "White"
    )

    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "HH:mm:ss"), $Level, $Message
    Write-Host $line -ForegroundColor $Color
    Add-Content -Path $script:LogFile -Value $line
}

function Log-Debug {
    param([string]$Message)
    Log -Message $Message -Level "DEBUG" -Color "DarkGray"
}

function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "+------------------------------------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host "| ImFuckingParanoid                                                            |" -ForegroundColor Cyan
    Write-Host "| Presets, status scan, and selective application                              |" -ForegroundColor DarkGray
    Write-Host "+------------------------------------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host ("  Version {0}  |  Log: {1}" -f $script:Version, $script:LogFile) -ForegroundColor DarkGray
    Write-Host ""
}

function Show-Section {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title
    )

    Write-Host $Title -ForegroundColor White
    Write-Host ("-" * $Title.Length) -ForegroundColor DarkGray
}

function Pause-ForKey {
    param([string]$Prompt = "Press any key to continue...")
    Write-Host ""
    Write-Host $Prompt -ForegroundColor DarkGray
    [void][Console]::ReadKey($true)
}

function Show-LoadingPulse {
    $steps = @(
        "Inspecting machine configuration"
        "Loading tweak catalog"
        "Preparing console"
    )

    foreach ($step in $steps) {
        Write-Host ("  - {0}..." -f $step) -ForegroundColor DarkGray
        Start-Sleep -Milliseconds 250
    }
}

function Get-SystemSummary {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $build = [int]$os.BuildNumber
        $edition = if ($build -ge 22000) { "Windows 11" } else { "Windows 10" }
        return [pscustomobject]@{
            Edition = $edition
            Caption = $os.Caption
            Version = $os.Version
            Build   = $build
            User    = "{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME
            Device  = $env:COMPUTERNAME
        }
    } catch {
        return [pscustomobject]@{
            Edition = "Unknown"
            Caption = "Unknown"
            Version = "Unknown"
            Build   = "Unknown"
            User    = "{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME
            Device  = $env:COMPUTERNAME
        }
    }
}

function Show-SystemSummary {
    $summary = Get-SystemSummary
    Show-Section "Device Specifications"
    Write-Host ("OS      : {0} ({1})" -f $summary.Caption, $summary.Version) -ForegroundColor Gray
    Write-Host ("Edition : {0} build {1}" -f $summary.Edition, $summary.Build) -ForegroundColor Gray
    Write-Host ("User    : {0}" -f $summary.User) -ForegroundColor Gray
    Write-Host ("Device  : {0}" -f $summary.Device) -ForegroundColor Gray
    Write-Host ""
}

function New-Tweak {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][string]$Type,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Description,
        [bool]$Express = $false,
        [hashtable]$Data
    )

    $object = [ordered]@{
        Id          = $Id
        Category    = $Category
        Type        = $Type
        Name        = $Name
        Description = $Description
        Express     = $Express
    }

    foreach ($key in $Data.Keys) {
        $object[$key] = $Data[$key]
    }

    [pscustomobject]$object
}

function Get-TweakCatalog {
    @(
        New-Tweak -Id "svc_diagtrack" -Category "Telemetry Services" -Type "Service" -Name "Disable DiagTrack" -Description "Stops and disables Connected User Experiences and Telemetry." -Express $true -Data @{
            ServiceName = "DiagTrack"
        }
        New-Tweak -Id "svc_dmwappush" -Category "Telemetry Services" -Type "Service" -Name "Disable dmwappushservice" -Description "Stops and disables WAP push telemetry collection." -Express $true -Data @{
            ServiceName = "dmwappushservice"
        }
        New-Tweak -Id "svc_wersvc" -Category "Telemetry Services" -Type "Service" -Name "Disable WerSvc" -Description "Disables Windows Error Reporting service telemetry uploads." -Express $true -Data @{
            ServiceName = "WerSvc"
        }

        New-Tweak -Id "reg_allowtelemetry_policy" -Category "Registry Baseline" -Type "Registry" -Name "Set policy telemetry floor" -Description "Pins policy telemetry level to minimum when supported." -Express $true -Data @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"
            ValueName = "AllowTelemetry"
            Value = 0
            ValueType = "DWord"
        }
        New-Tweak -Id "reg_allowtelemetry_current" -Category "Registry Baseline" -Type "Registry" -Name "Set current telemetry floor" -Description "Sets current telemetry level to minimum." -Express $true -Data @{
            Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection"
            ValueName = "AllowTelemetry"
            Value = 0
            ValueType = "DWord"
        }
        New-Tweak -Id "reg_advertising_policy" -Category "Registry Baseline" -Type "Registry" -Name "Disable advertising ID by policy" -Description "Disables advertising identifier usage via policy." -Express $true -Data @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo"
            ValueName = "DisabledByGroupPolicy"
            Value = 1
            ValueType = "DWord"
        }
        New-Tweak -Id "reg_advertising_user" -Category "Registry Baseline" -Type "Registry" -Name "Disable advertising ID for current user" -Description "Turns off per-user advertising ID usage." -Express $true -Data @{
            Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo"
            ValueName = "Enabled"
            Value = 0
            ValueType = "DWord"
        }
        New-Tweak -Id "reg_feedback_notifications" -Category "Registry Baseline" -Type "Registry" -Name "Mute feedback prompts" -Description "Disables feedback notification prompts." -Express $true -Data @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"
            ValueName = "DoNotShowFeedbackNotifications"
            Value = 1
            ValueType = "DWord"
        }
        New-Tweak -Id "reg_siuf_count" -Category "Registry Baseline" -Type "Registry" -Name "Reduce SIUF prompt count" -Description "Stops repeated feedback prompt counters for the current user." -Express $true -Data @{
            Path = "HKCU:\Software\Microsoft\Siuf\Rules"
            ValueName = "NumberOfSIUFInPeriod"
            Value = 0
            ValueType = "DWord"
        }
        New-Tweak -Id "reg_siuf_period" -Category "Registry Baseline" -Type "Registry" -Name "Collapse SIUF prompt period" -Description "Shrinks the user feedback prompt interval to zero." -Express $true -Data @{
            Path = "HKCU:\Software\Microsoft\Siuf\Rules"
            ValueName = "PeriodInNanoSeconds"
            Value = 0
            ValueType = "DWord"
        }
        New-Tweak -Id "reg_tailored_experiences" -Category "Registry Baseline" -Type "Registry" -Name "Disable tailored experiences" -Description "Disables tailored experiences based on diagnostic data." -Express $true -Data @{
            Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy"
            ValueName = "TailoredExperiencesWithDiagnosticDataEnabled"
            Value = 0
            ValueType = "DWord"
        }

        New-Tweak -Id "reg_consumer_features" -Category "Registry Hardening" -Type "Registry" -Name "Disable consumer features" -Description "Turns off content and app promotion features." -Express $true -Data @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"
            ValueName = "DisableWindowsConsumerFeatures"
            Value = 1
            ValueType = "DWord"
        }
        New-Tweak -Id "reg_subscribed_content_338388" -Category "Registry Hardening" -Type "Registry" -Name "Disable suggestion feed" -Description "Turns off one of the content delivery suggestion channels." -Express $true -Data @{
            Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
            ValueName = "SubscribedContent-338388Enabled"
            Value = 0
            ValueType = "DWord"
        }
        New-Tweak -Id "reg_subscribed_content_353694" -Category "Registry Hardening" -Type "Registry" -Name "Disable settings recommendations" -Description "Turns off recommendation-driven content delivery." -Express $true -Data @{
            Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
            ValueName = "SubscribedContent-353694Enabled"
            Value = 0
            ValueType = "DWord"
        }
        New-Tweak -Id "reg_activity_feed" -Category "Registry Hardening" -Type "Registry" -Name "Disable activity feed" -Description "Disables Windows activity feed collection." -Express $true -Data @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
            ValueName = "EnableActivityFeed"
            Value = 0
            ValueType = "DWord"
        }
        New-Tweak -Id "reg_publish_activities" -Category "Registry Hardening" -Type "Registry" -Name "Disable activity publishing" -Description "Prevents publishing user activity history." -Express $true -Data @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
            ValueName = "PublishUserActivities"
            Value = 0
            ValueType = "DWord"
        }
        New-Tweak -Id "reg_upload_activities" -Category "Registry Hardening" -Type "Registry" -Name "Disable activity uploads" -Description "Prevents uploading activity history to Microsoft." -Express $true -Data @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
            ValueName = "UploadUserActivities"
            Value = 0
            ValueType = "DWord"
        }
        New-Tweak -Id "reg_cloud_search" -Category "Registry Hardening" -Type "Registry" -Name "Disable cloud search" -Description "Turns off cloud-assisted search integration." -Express $true -Data @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"
            ValueName = "AllowCloudSearch"
            Value = 0
            ValueType = "DWord"
        }
        New-Tweak -Id "reg_connected_search" -Category "Registry Hardening" -Type "Registry" -Name "Disable connected search web usage" -Description "Stops web-backed connected search queries." -Express $true -Data @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"
            ValueName = "ConnectedSearchUseWeb"
            Value = 0
            ValueType = "DWord"
        }
        New-Tweak -Id "reg_disable_web_search" -Category "Registry Hardening" -Type "Registry" -Name "Disable web search in Start" -Description "Stops web search results from appearing in local search." -Express $true -Data @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"
            ValueName = "DisableWebSearch"
            Value = 1
            ValueType = "DWord"
        }

        New-Tweak -Id "task_compat_appraiser" -Category "Scheduled Tasks" -Type "Task" -Name "Disable Compatibility Appraiser" -Description "Disables the compatibility telemetry appraiser task." -Express $true -Data @{
            TaskPath = "\Microsoft\Windows\Application Experience\"
            TaskName = "Microsoft Compatibility Appraiser"
        }
        New-Tweak -Id "task_program_data_updater" -Category "Scheduled Tasks" -Type "Task" -Name "Disable ProgramDataUpdater" -Description "Disables application experience telemetry updates." -Express $true -Data @{
            TaskPath = "\Microsoft\Windows\Application Experience\"
            TaskName = "ProgramDataUpdater"
        }
        New-Tweak -Id "task_startup_app" -Category "Scheduled Tasks" -Type "Task" -Name "Disable StartupAppTask" -Description "Disables startup app telemetry inventory." -Express $true -Data @{
            TaskPath = "\Microsoft\Windows\Application Experience\"
            TaskName = "StartupAppTask"
        }
        New-Tweak -Id "task_ceip_consolidator" -Category "Scheduled Tasks" -Type "Task" -Name "Disable CEIP Consolidator" -Description "Disables CEIP data consolidation task." -Express $true -Data @{
            TaskPath = "\Microsoft\Windows\Customer Experience Improvement Program\"
            TaskName = "Consolidator"
        }
        New-Tweak -Id "task_ceip_usb" -Category "Scheduled Tasks" -Type "Task" -Name "Disable UsbCeip" -Description "Disables customer experience USB reporting." -Express $true -Data @{
            TaskPath = "\Microsoft\Windows\Customer Experience Improvement Program\"
            TaskName = "UsbCeip"
        }
        New-Tweak -Id "task_autochk_proxy" -Category "Scheduled Tasks" -Type "Task" -Name "Disable Autochk Proxy" -Description "Disables proxy task used by disk diagnostics." -Express $true -Data @{
            TaskPath = "\Microsoft\Windows\Autochk\"
            TaskName = "Proxy"
        }
        New-Tweak -Id "task_disk_diagnostic" -Category "Scheduled Tasks" -Type "Task" -Name "Disable DiskDiagnosticDataCollector" -Description "Disables disk diagnostic data collection." -Express $true -Data @{
            TaskPath = "\Microsoft\Windows\DiskDiagnostic\"
            TaskName = "Microsoft-Windows-DiskDiagnosticDataCollector"
        }

        New-Tweak -Id "hosts_vortex" -Category "Hosts Blocking" -Type "Hosts" -Name "Block vortex.data.microsoft.com" -Description "Blocks a common telemetry endpoint in the hosts file." -Express $true -Data @{
            Domain = "vortex.data.microsoft.com"
            Address = "0.0.0.0"
        }
        New-Tweak -Id "hosts_settings_win" -Category "Hosts Blocking" -Type "Hosts" -Name "Block settings-win.data.microsoft.com" -Description "Blocks Windows settings telemetry routing." -Express $true -Data @{
            Domain = "settings-win.data.microsoft.com"
            Address = "0.0.0.0"
        }
        New-Tweak -Id "hosts_watson" -Category "Hosts Blocking" -Type "Hosts" -Name "Block watson.telemetry.microsoft.com" -Description "Blocks a Watson telemetry endpoint." -Express $true -Data @{
            Domain = "watson.telemetry.microsoft.com"
            Address = "0.0.0.0"
        }
        New-Tweak -Id "hosts_oca" -Category "Hosts Blocking" -Type "Hosts" -Name "Block oca.telemetry.microsoft.com" -Description "Blocks Microsoft error reporting telemetry name resolution." -Express $true -Data @{
            Domain = "oca.telemetry.microsoft.com"
            Address = "0.0.0.0"
        }
        New-Tweak -Id "hosts_sqm" -Category "Hosts Blocking" -Type "Hosts" -Name "Block sqm.telemetry.microsoft.com" -Description "Blocks SQM telemetry name resolution." -Express $true -Data @{
            Domain = "sqm.telemetry.microsoft.com"
            Address = "0.0.0.0"
        }
        New-Tweak -Id "hosts_telecommand" -Category "Hosts Blocking" -Type "Hosts" -Name "Block telecommand.telemetry.microsoft.com" -Description "Blocks additional telemetry command traffic by host name." -Express $true -Data @{
            Domain = "telecommand.telemetry.microsoft.com"
            Address = "0.0.0.0"
        }

        New-Tweak -Id "fw_13417030202" -Category "Firewall Blocking" -Type "Firewall" -Name "Block 134.170.30.202" -Description "Blocks a known outbound telemetry IP at the firewall." -Express $false -Data @{
            RuleName = "$script:FirewallTag-134.170.30.202"
            RemoteAddress = "134.170.30.202"
        }
        New-Tweak -Id "fw_1371168124" -Category "Firewall Blocking" -Type "Firewall" -Name "Block 137.116.81.24" -Description "Blocks a second telemetry IP at the firewall." -Express $false -Data @{
            RuleName = "$script:FirewallTag-137.116.81.24"
            RemoteAddress = "137.116.81.24"
        }
        New-Tweak -Id "fw_6454398" -Category "Firewall Blocking" -Type "Firewall" -Name "Block 64.4.54.32" -Description "Blocks a legacy telemetry endpoint IP at the firewall." -Express $false -Data @{
            RuleName = "$script:FirewallTag-64.4.54.32"
            RemoteAddress = "64.4.54.32"
        }
    )
}

function Get-ServiceState {
    param([string]$ServiceName)
    Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $ServiceName) -ErrorAction Stop
}

# Bulk-fetched caches populated once per status scan run — avoids per-tweak WMI round-trips on slow hardware
$script:ServiceCache = $null
$script:TaskCache    = $null

function Warm-StatusCaches {
    param([pscustomobject[]]$Tweaks)

    $needsServices = $Tweaks | Where-Object { $_.Type -eq "Service" }
    $needsTasks    = $Tweaks | Where-Object { $_.Type -eq "Task" }

    if ($needsServices) {
        Log-Debug "Warming service cache."
        $script:ServiceCache = @{}
        Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | ForEach-Object {
            $script:ServiceCache[$_.Name] = $_
        }
    }

    if ($needsTasks) {
        Log-Debug "Warming task cache."
        $script:TaskCache = @{}
        Get-ScheduledTask -ErrorAction SilentlyContinue | ForEach-Object {
            $key = "{0}|{1}" -f $_.TaskPath, $_.TaskName
            $script:TaskCache[$key] = $_
        }
    }
}

function Get-CachedService {
    param([string]$ServiceName)
    if ($null -ne $script:ServiceCache) {
        return $script:ServiceCache[$ServiceName]
    }
    return Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $ServiceName) -ErrorAction SilentlyContinue
}

function Get-CachedTask {
    param([string]$TaskPath, [string]$TaskName)
    if ($null -ne $script:TaskCache) {
        $key = "{0}|{1}" -f $TaskPath, $TaskName
        return $script:TaskCache[$key]
    }
    return Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
}

function Test-Tweak {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Tweak
    )

    switch ($Tweak.Type) {
        "Service" {
            try {
                $service = Get-CachedService -ServiceName $Tweak.ServiceName
                if ($null -eq $service) { throw "Service not found." }
                $disabled = $service.StartMode -eq "Disabled"
                $stopped = $service.State -ne "Running"
                $applied = $disabled -and $stopped
                $state = if ($applied) { "Applied" } elseif ($disabled) { "Stopped pending" } else { "Pending" }
                $summary = "StartMode={0}; State={1}" -f $service.StartMode, $service.State
                break
            } catch {
                return [pscustomobject]@{
                    Tweak      = $Tweak
                    Applicable = $false
                    Applied    = $true
                    State      = "Unavailable"
                    Summary    = "Service not present on this build."
                }
            }
        }
        "Registry" {
            if (-not (Test-Path -Path $Tweak.Path)) {
                $applied = $false
                $state = "Pending"
                $summary = "Registry path missing."
                break
            }

            try {
                $property = Get-ItemProperty -Path $Tweak.Path -Name $Tweak.ValueName -ErrorAction Stop
                $currentValue = $property.($Tweak.ValueName)
                $applied = ([string]$currentValue -eq [string]$Tweak.Value)
                $state = if ($applied) { "Applied" } else { "Pending" }
                $summary = "Current={0}; Desired={1}" -f $currentValue, $Tweak.Value
            } catch {
                $applied = $false
                $state = "Pending"
                $summary = "Registry value missing."
            }
        }
        "Task" {
            $task = Get-CachedTask -TaskPath $Tweak.TaskPath -TaskName $Tweak.TaskName
            if ($null -eq $task) {
                return [pscustomobject]@{
                    Tweak      = $Tweak
                    Applicable = $false
                    Applied    = $true
                    State      = "Unavailable"
                    Summary    = "Task not present on this build."
                }
            }
            $disabled = ($task.State -eq "Disabled") -or ($task.Settings.Enabled -eq $false)
            $applied = $disabled
            $state = if ($applied) { "Applied" } else { "Pending" }
            $summary = "State={0}" -f $task.State
        }
        "Hosts" {
            try {
                $escaped = [regex]::Escape($Tweak.Domain)
                $pattern = "^\s*(0\.0\.0\.0|127\.0\.0\.1)\s+{0}(\s+.*)?$" -f $escaped
                $match = Get-Content -Path $script:HostsPath -ErrorAction Stop | Select-String -Pattern $pattern
                $applied = $match.Count -gt 0
                $state = if ($applied) { "Applied" } else { "Pending" }
                $summary = if ($applied) { "Hosts entry present." } else { "Hosts entry missing." }
            } catch {
                $applied = $false
                $state = "Pending"
                $summary = "Hosts file could not be read."
            }
        }
        "Firewall" {
            try {
                $rule = Get-NetFirewallRule -DisplayName $Tweak.RuleName -ErrorAction SilentlyContinue
                $applied = $null -ne $rule
                $state = if ($applied) { "Applied" } else { "Pending" }
                $summary = if ($applied) { "Firewall rule present." } else { "Firewall rule missing." }
            } catch {
                $applied = $false
                $state = "Pending"
                $summary = "Firewall rule lookup failed."
            }
        }
        default {
            $applied = $false
            $state = "Pending"
            $summary = "Unknown tweak type."
        }
    }

    [pscustomobject]@{
        Tweak      = $Tweak
        Applicable = $true
        Applied    = $applied
        State      = $state
        Summary    = $summary
    }
}

function Get-TweakStatuses {
    param([pscustomobject[]]$Tweaks)
    Log-Debug ("Scanning {0} tweak(s) for current state." -f $Tweaks.Count)
    Warm-StatusCaches -Tweaks $Tweaks
    foreach ($tweak in $Tweaks) {
        Test-Tweak -Tweak $tweak
    }
}

function Show-SingleSelectMenu {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Instructions,
        [Parameter(Mandatory = $true)][object[]]$Options
    )

    $selected = 0

    while ($true) {
        Show-Banner
        Show-SystemSummary
        Show-Section $Title
        Write-Host $Instructions -ForegroundColor DarkGray
        Write-Host ""

        for ($i = 0; $i -lt $Options.Count; $i++) {
            $prefix = if ($i -eq $selected) { ">>" } else { "  " }
            $color = if ($i -eq $selected) { "Cyan" } else { "Gray" }
            Write-Host ("{0} {1}" -f $prefix, $Options[$i].Label) -ForegroundColor $color
        }

        Write-Host ""
        Write-Host $Options[$selected].Description -ForegroundColor Gray

        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            "UpArrow"   { if ($selected -gt 0) { $selected-- } }
            "DownArrow" { if ($selected -lt ($Options.Count - 1)) { $selected++ } }
            "Enter"     { return $Options[$selected] }
            "Escape"    { return $null }
        }
    }
}

function Show-MultiSelectMenu {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Instructions,
        [Parameter(Mandatory = $true)][object[]]$Options
    )

    $selectedIndex = 0
    $selectedValues = New-Object System.Collections.Generic.HashSet[string]

    foreach ($option in $Options | Where-Object { $_.Recommended }) {
        [void]$selectedValues.Add([string]$option.Value)
    }

    while ($true) {
        Show-Banner
        Show-SystemSummary
        if (-not [string]::IsNullOrWhiteSpace($Title)) {
            Show-Section $Title
        }
        if (-not [string]::IsNullOrWhiteSpace($Instructions)) {
            Write-Host $Instructions -ForegroundColor DarkGray
        }
        Write-Host "Space toggles, A selects all, C clears, Enter confirms." -ForegroundColor DarkGray
        Write-Host ""

        for ($i = 0; $i -lt $Options.Count; $i++) {
            $option = $Options[$i]
            $isChecked = $selectedValues.Contains([string]$option.Value)
            $marker = if ($isChecked) { "[x]" } else { "[ ]" }
            $prefix = if ($i -eq $selectedIndex) { ">>" } else { "  " }
            $color = if ($i -eq $selectedIndex) { "Cyan" } else { "Gray" }
            Write-Host ("{0} {1} {2}" -f $prefix, $marker, $option.Label) -ForegroundColor $color
        }

        Write-Host ""
        Write-Host $Options[$selectedIndex].Description -ForegroundColor Gray

        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            "UpArrow" {
                if ($selectedIndex -gt 0) { $selectedIndex-- }
            }
            "DownArrow" {
                if ($selectedIndex -lt ($Options.Count - 1)) { $selectedIndex++ }
            }
            "Spacebar" {
                $value = [string]$Options[$selectedIndex].Value
                if ($selectedValues.Contains($value)) {
                    [void]$selectedValues.Remove($value)
                } else {
                    [void]$selectedValues.Add($value)
                }
            }
            "A" {
                foreach ($option in $Options) {
                    [void]$selectedValues.Add([string]$option.Value)
                }
            }
            "C" {
                $selectedValues.Clear()
            }
            "Enter" {
                return @($selectedValues)
            }
            "Escape" {
                return $null
            }
        }
    }
}

function Show-StatusSummary {
    param(
        [Parameter(Mandatory = $true)][string]$ModeName,
        [Parameter(Mandatory = $true)][pscustomobject[]]$Statuses
    )

    $applicable = @($Statuses | Where-Object { $_.Applicable })
    $pending = @($applicable | Where-Object { -not $_.Applied })
    $alreadyApplied = @($applicable | Where-Object { $_.Applied })
    $unavailable = @($Statuses | Where-Object { -not $_.Applicable })

    Show-Banner
    Show-SystemSummary
    Show-Section ("Selection Review - {0}" -f $ModeName)
    Write-Host ("Already applied : {0}" -f $alreadyApplied.Count) -ForegroundColor Green
    Write-Host ("Still pending   : {0}" -f $pending.Count) -ForegroundColor Yellow
    Write-Host ("Not available   : {0}" -f $unavailable.Count) -ForegroundColor DarkGray
    Write-Host ""

    foreach ($group in $Statuses | Group-Object -Property { $_.Tweak.Category }) {
        $groupPending = @($group.Group | Where-Object { $_.Applicable -and -not $_.Applied }).Count
        $groupApplied = @($group.Group | Where-Object { $_.Applicable -and $_.Applied }).Count
        $groupUnavailable = @($group.Group | Where-Object { -not $_.Applicable }).Count
        Write-Host ("{0,-20} applied {1,2} | pending {2,2} | unavailable {3,2}" -f $group.Name, $groupApplied, $groupPending, $groupUnavailable) -ForegroundColor Gray
    }

    if ($pending.Count -gt 0) {
        Write-Host ""
        Write-Host "Pending tweaks:" -ForegroundColor White
        foreach ($status in $pending) {
            Write-Host ("  - {0}" -f $status.Tweak.Name) -ForegroundColor Yellow
        }
    }

    if ($pending.Count -eq 0) {
        Write-Host ""
        Write-Host "All selected tweaks are already applied. Nothing new will be changed." -ForegroundColor Green
    }

    if ($unavailable.Count -gt 0) {
        Write-Host ""
        Write-Host "Unavailable items were skipped because they do not exist on this Windows build." -ForegroundColor DarkGray
    }
}

function Read-YesNo {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [bool]$DefaultYes = $true
    )

    $suffix = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
    while ($true) {
        Write-Host ""
        Write-Host ("{0} {1}" -f $Prompt, $suffix) -ForegroundColor White
        $key = [Console]::ReadKey($true)

        switch ($key.Key) {
            "Enter" { return $DefaultYes }
            "Y"     { return $true }
            "N"     { return $false }
        }
    }
}

function Create-RestorePoint {
    if (-not (Read-YesNo -Prompt "Create a system restore point before applying tweaks?" -DefaultYes $true)) {
        Log -Message "User skipped restore point creation." -Level "INFO" -Color "DarkGray"
        return
    }

    Log -Message "Creating system restore point." -Level "INFO" -Color "Cyan"

    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description "Pre-ImFuckingParanoid" -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
        Log -Message "Restore point created successfully." -Level "INFO" -Color "Green"
    } catch {
        if ($_.Exception.Message -match "1440") {
            Log -Message "Restore point skipped because Windows already created one within the limit window." -Level "INFO" -Color "Yellow"
        } else {
            Log -Message ("Restore point failed: {0}" -f $_.Exception.Message) -Level "ERROR" -Color "Red"
        }
    }
}

function Ensure-RegistryValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$ValueType
    )

    if (-not (Test-Path -Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    $propertyExists = $true
    try {
        Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop | Out-Null
    } catch {
        $propertyExists = $false
    }

    if ($propertyExists) {
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -ErrorAction Stop
    } else {
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $ValueType -Force -ErrorAction Stop | Out-Null
    }
}

function Get-LockingProcessIds {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    try {
        $ids = [FileLockUtil]::GetLockingProcessIds($Path)
        Log-Debug ("Restart Manager reported {0} locking process(es) for {1}." -f $ids.Count, $Path)
        return @($ids)
    } catch {
        Log-Debug ("Unable to query locking processes for {0}: {1}" -f $Path, $_.Exception.Message)
        return @()
    }
}

function Stop-LockingProcessesForFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $stoppedAny = $false
    $lockingIds = @(Get-LockingProcessIds -Path $Path | Sort-Object -Unique)

    if ($lockingIds.Count -eq 0) {
        Log-Debug ("No locking process ids were returned for {0}." -f $Path)
        return $false
    }

    foreach ($processId in $lockingIds) {
        if ($processId -le 4 -or $processId -eq $PID) {
            Log-Debug ("Skipping protected or current process id {0}." -f $processId)
            continue
        }

        try {
            $process = Get-Process -Id $processId -ErrorAction Stop
            if ($script:CriticalProcessNames -contains $process.ProcessName) {
                Log-Debug ("Skipping critical process {0} ({1})." -f $process.ProcessName, $process.Id)
                continue
            }

            Log -Message ("Stopping process locking hosts file: {0} ({1})" -f $process.ProcessName, $process.Id) -Level "WARNING" -Color "Yellow"
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
            Start-Sleep -Milliseconds 300
            $stoppedAny = $true
        } catch {
            Log -Message ("Could not stop locking process {0}: {1}" -f $processId, $_.Exception.Message) -Level "ERROR" -Color "Red"
        }
    }

    return $stoppedAny
}

function Invoke-WithHostsFileAccess {
    param(
        [Parameter(Mandatory = $true)][string]$OperationName,
        [Parameter(Mandatory = $true)][scriptblock]$Operation
    )

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Log-Debug ("Hosts operation start: {0} (attempt {1}/3)" -f $OperationName, $attempt)
            & $Operation
            Log-Debug ("Hosts operation succeeded: {0}" -f $OperationName)
            return
        } catch {
            $message = $_.Exception.Message
            Log-Debug ("Hosts operation failed: {0} | {1}" -f $OperationName, $message)

            if ($message -notmatch "being used by another process" -or $attempt -eq 3) {
                throw
            }

            $stoppedAny = Stop-LockingProcessesForFile -Path $script:HostsPath
            if (-not $stoppedAny) {
                Log-Debug ("No stoppable process was found for {0}. Waiting before retry." -f $OperationName)
            }
            Start-Sleep -Milliseconds 500
        }
    }
}

function Ensure-HostsBackup {
    if ($script:HostsBackedUp) {
        Log-Debug "Hosts backup already exists for this run."
        return
    }

    Invoke-WithHostsFileAccess -OperationName "Create hosts backup" -Operation {
        Copy-Item -Path $script:HostsPath -Destination $script:BackupHosts -Force
    }
    $script:HostsBackedUp = $true
    Log -Message ("Hosts backup created: {0}" -f $script:BackupHosts) -Level "INFO" -Color "Green"
}

function Apply-Tweak {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Tweak
    )

    switch ($Tweak.Type) {
        "Service" {
            Log-Debug ("Applying service tweak: {0}" -f $Tweak.ServiceName)
            $service = Get-Service -Name $Tweak.ServiceName -ErrorAction SilentlyContinue
            if ($null -ne $service -and $service.Status -ne "Stopped") {
                Stop-Service -Name $Tweak.ServiceName -Force -ErrorAction Stop
            }
            Set-Service -Name $Tweak.ServiceName -StartupType Disabled -ErrorAction Stop
            return
        }
        "Registry" {
            Log-Debug ("Applying registry tweak: {0} -> {1}={2}" -f $Tweak.Path, $Tweak.ValueName, $Tweak.Value)
            Ensure-RegistryValue -Path $Tweak.Path -Name $Tweak.ValueName -Value $Tweak.Value -ValueType $Tweak.ValueType
            return
        }
        "Task" {
            Log-Debug ("Applying task tweak: {0}{1}" -f $Tweak.TaskPath, $Tweak.TaskName)
            Disable-ScheduledTask -TaskName $Tweak.TaskName -TaskPath $Tweak.TaskPath -ErrorAction Stop | Out-Null
            return
        }
        "Hosts" {
            Ensure-HostsBackup
            $line = "{0}`t{1}" -f $Tweak.Address, $Tweak.Domain
            Log-Debug ("Applying hosts tweak: {0}" -f $Tweak.Domain)
            Invoke-WithHostsFileAccess -OperationName ("Append hosts entry for {0}" -f $Tweak.Domain) -Operation {
                [System.IO.File]::AppendAllText($script:HostsPath, ($line + [System.Environment]::NewLine))
            }
            return
        }
        "Firewall" {
            Log-Debug ("Applying firewall tweak: {0} -> {1}" -f $Tweak.RuleName, $Tweak.RemoteAddress)
            if (-not (Get-NetFirewallRule -DisplayName $Tweak.RuleName -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -DisplayName $Tweak.RuleName -Direction Outbound -Action Block -RemoteAddress $Tweak.RemoteAddress -ErrorAction Stop | Out-Null
            }
            return
        }
        default {
            throw "Unknown tweak type: $($Tweak.Type)"
        }
    }
}

function Apply-Tweaks {
    param(
        [Parameter(Mandatory = $true)][pscustomobject[]]$PendingTweaks
    )

    $results = @()

    for ($i = 0; $i -lt $PendingTweaks.Count; $i++) {
        $tweak = $PendingTweaks[$i]
        $progress = "[{0}/{1}]" -f ($i + 1), $PendingTweaks.Count
        Log -Message ("{0} Applying {1}" -f $progress, $tweak.Name) -Level "INFO" -Color "Cyan"

        try {
            Apply-Tweak -Tweak $tweak
            $status = Test-Tweak -Tweak $tweak
            if ($status.Applied) {
                Log -Message ("Applied successfully: {0}" -f $tweak.Name) -Level "INFO" -Color "Green"
                $results += [pscustomobject]@{ Tweak = $tweak; Success = $true; Summary = $status.Summary }
            } else {
                Log -Message ("Verification still pending: {0}" -f $tweak.Name) -Level "ERROR" -Color "Red"
                $results += [pscustomobject]@{ Tweak = $tweak; Success = $false; Summary = $status.Summary }
            }
        } catch {
            Log -Message ("Failed: {0} | {1}" -f $tweak.Name, $_.Exception.Message) -Level "ERROR" -Color "Red"
            $results += [pscustomobject]@{ Tweak = $tweak; Success = $false; Summary = $_.Exception.Message }
        }
    }

    $results
}

function Show-CompletionSummary {
    param(
        [Parameter(Mandatory = $true)][string]$ModeName,
        [Parameter(Mandatory = $true)][pscustomobject[]]$BeforeStatuses,
        [Parameter(Mandatory = $true)][pscustomobject[]]$Results
    )

    $appliedBefore = @($BeforeStatuses | Where-Object { $_.Applicable -and $_.Applied }).Count
    $pendingBefore = @($BeforeStatuses | Where-Object { $_.Applicable -and -not $_.Applied }).Count
    $successes = @($Results | Where-Object { $_.Success }).Count
    $failures = @($Results | Where-Object { -not $_.Success }).Count

    Show-Banner
    Show-SystemSummary
    Show-Section ("Completed - {0}" -f $ModeName)
    Write-Host ("Already applied before run : {0}" -f $appliedBefore) -ForegroundColor Green
    Write-Host ("Pending before run         : {0}" -f $pendingBefore) -ForegroundColor Yellow
    Write-Host ("Applied this run           : {0}" -f $successes) -ForegroundColor Green
    Write-Host ("Failed this run            : {0}" -f $failures) -ForegroundColor $(if ($failures -gt 0) { "Red" } else { "DarkGray" })
    Write-Host ""

    if ($failures -gt 0) {
        Write-Host "Items that need attention:" -ForegroundColor White
        foreach ($result in $Results | Where-Object { -not $_.Success }) {
            Write-Host ("  - {0}: {1}" -f $result.Tweak.Name, $result.Summary) -ForegroundColor Red
        }
        Write-Host ""
    }

    Write-Host "A reboot is recommended so Windows fully reloads the changed policies and services." -ForegroundColor Gray
}

function Build-CustomCategoryOptions {
    param([pscustomobject[]]$Tweaks)

    $grouped = $Tweaks | Group-Object -Property Category
    $recommended = @("Telemetry Services", "Registry Baseline", "Registry Hardening", "Scheduled Tasks", "Hosts Blocking")

    foreach ($group in $grouped | Sort-Object Name) {
        [pscustomobject]@{
            Label       = "{0} ({1})" -f $group.Name, $group.Count
            Description = switch ($group.Name) {
                "Telemetry Services" { "Recommended. Shuts down the most obvious telemetry-related services." }
                "Registry Baseline"  { "Recommended. Core privacy policy and advertising settings." }
                "Registry Hardening" { "Recommended. Extra experience, activity, and search restrictions." }
                "Scheduled Tasks"    { "Recommended. Disables CEIP and appraiser style tasks." }
                "Hosts Blocking"     { "Recommended. Adds a curated hosts blocklist for well-known telemetry names." }
                "Firewall Blocking"  { "More aggressive. Adds IP-based outbound firewall rules that can be brittle over time." }
                default              { "Selectable tweak category." }
            }
            Value       = $group.Name
            Recommended = $recommended -contains $group.Name
        }
    }
}

function Resolve-Selection {
    param(
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][pscustomobject[]]$Catalog
    )

    switch ($Mode) {
        "Express Settings" {
            $selection = @($Catalog | Where-Object { $_.Express })
            Log-Debug ("Express Settings selected {0} tweak(s)." -f $selection.Count)
            return $selection
        }
        "Custom" {
            $categoryOptions = Build-CustomCategoryOptions -Tweaks $Catalog
            $selectedCategories = Show-MultiSelectMenu -Title "" -Instructions "" -Options $categoryOptions

            if ($null -eq $selectedCategories -or $selectedCategories.Count -eq 0) {
                Log-Debug "Custom mode ended with no categories selected."
                return @()
            }

            Log-Debug ("Custom categories selected: {0}" -f ($selectedCategories -join ", "))
            $selection = @($Catalog | Where-Object { $selectedCategories -contains $_.Category })
            Log-Debug ("Custom selection resolved to {0} tweak(s)." -f $selection.Count)
            return $selection
        }
        default {
            Log-Debug ("Unknown selection mode encountered: {0}" -f $Mode)
            return @()
        }
    }
}

function Maybe-Restart {
    if (Read-YesNo -Prompt "Restart the PC now?" -DefaultYes $false) {
        Log -Message "User opted to restart the PC." -Level "INFO" -Color "Yellow"
        try {
            Restart-Computer -Force -ErrorAction Stop
        } catch {
            Log -Message ("Restart failed: {0}" -f $_.Exception.Message) -Level "ERROR" -Color "Red"
        }
    } else {
        Log -Message "User declined restart." -Level "INFO" -Color "DarkGray"
    }
}

Show-Banner
Show-LoadingPulse

Log -Message ("Launching {0} {1}" -f $script:AppName, $script:Version) -Level "INFO" -Color "Cyan"

$catalog = Get-TweakCatalog
Log-Debug ("Catalog loaded with {0} tweak(s)." -f $catalog.Count)
$menuOptions = @(
    [pscustomobject]@{
        Label = "Express Settings"
        Description = "Applies the recommended settings. Includes service shutdowns, registry/privacy policies, task disables, and curated hosts blocking. It intentionally skips the more brittle IP firewall rules."
    }
    [pscustomobject]@{
        Label = "Custom"
        Description = "Pick your own categories, including the more aggressive firewall rules if you prefer."
    }
    [pscustomobject]@{
        Label = "Exit"
        Description = "Leave without changing anything."
    }
)

$modeChoice = Show-SingleSelectMenu -Title "Mode Selection" -Instructions "Use Up/Down and Enter. Escape also exits." -Options $menuOptions

if ($null -eq $modeChoice -or $modeChoice.Label -eq "Exit") {
    Log -Message "User exited from the main menu." -Level "INFO" -Color "DarkGray"
    exit
}

$selectedTweaks = Resolve-Selection -Mode $modeChoice.Label -Catalog $catalog
if ($selectedTweaks.Count -eq 0) {
    Show-Banner
    Show-SystemSummary
    Write-Host "No tweak categories were selected. Nothing was changed." -ForegroundColor Yellow
    Log -Message "No tweaks selected." -Level "INFO" -Color "Yellow"
    Pause-ForKey
    exit
}

$statuses = @(Get-TweakStatuses -Tweaks $selectedTweaks)
Log-Debug ("Status scan complete. Applied={0}; Pending={1}; Unavailable={2}" -f @($statuses | Where-Object { $_.Applicable -and $_.Applied }).Count, @($statuses | Where-Object { $_.Applicable -and -not $_.Applied }).Count, @($statuses | Where-Object { -not $_.Applicable }).Count)
Show-StatusSummary -ModeName $modeChoice.Label -Statuses $statuses

$pendingStatuses = @($statuses | Where-Object { $_.Applicable -and -not $_.Applied })
if ($pendingStatuses.Count -eq 0) {
    Log -Message "Selected tweaks were already applied. Cancelling run." -Level "INFO" -Color "Green"
    Pause-ForKey "Selected tweaks are already applied. Press any key to exit..."
    exit
}

if (-not (Read-YesNo -Prompt ("{0} tweak(s) still need to be applied. Continue?" -f $pendingStatuses.Count) -DefaultYes $true)) {
    Log -Message "User cancelled after reviewing pending tweaks." -Level "INFO" -Color "DarkGray"
    exit
}

Create-RestorePoint

$results = Apply-Tweaks -PendingTweaks @($pendingStatuses | ForEach-Object { $_.Tweak })
Show-CompletionSummary -ModeName $modeChoice.Label -BeforeStatuses $statuses -Results $results
Maybe-Restart
Pause-ForKey
