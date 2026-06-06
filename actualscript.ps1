param([string]$LogFile = "")

# ImFuckingParanoid console
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)) {

    Write-Host "Requesting administrator privileges..."
    $adminArgs = @(
        "-NoProfile"
        "-ExecutionPolicy", "Bypass"
        "-File", "`"$PSCommandPath`""
    )
    if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
        $adminArgs += @("-LogFile", "`"$LogFile`"")
    }
    Start-Process powershell -Verb RunAs -ArgumentList $adminArgs
    exit
}

$script:AppName = "ImFuckingParanoid"
$script:Version = "1.0.0"
$script:ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $PSCommandPath }
$script:LogRoot = Join-Path -Path $script:ScriptRoot -ChildPath "logs"
$script:RunStartedAt = Get-Date
$script:RunTimestamp = $script:RunStartedAt.ToString("yyyy-MM-dd-HH-mm-ss")
$script:ServiceStateCache = $null
$script:ScheduledTaskCache = $null
$script:LogFile = $LogFile
$script:BackupHosts = "$env:SystemDrive\hosts_backup_$(Get-Date -Format 'yyyyMMdd_HHmmss').bak"
$script:FirewallTag = "ImFuckingParanoid"
$script:HostsPath = "$env:windir\System32\drivers\etc\hosts"
$script:HostsBackedUp = $false
$script:CriticalProcessNames = @("Idle", "System", "Registry", "smss", "csrss", "wininit", "services", "lsass", "winlogon", "fontdrvhost", "dwm", "sihost", "svchost", "MsMpEng", "NisSrv", "SecurityHealthService", "Sense", "MpDefenderCoreService")

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

function Initialize-RunLog {
    if (-not (Test-Path -LiteralPath $script:LogRoot)) {
        New-Item -Path $script:LogRoot -ItemType Directory -Force | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($script:LogFile)) {
        $script:LogFile = [System.IO.Path]::GetFullPath($script:LogFile)
        $logDirectory = Split-Path -Parent $script:LogFile
        if (-not (Test-Path -LiteralPath $logDirectory)) {
            New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
        }
        if (-not (Test-Path -LiteralPath $script:LogFile)) {
            New-Item -Path $script:LogFile -ItemType File -Force | Out-Null
        }
        Add-Content -Path $script:LogFile -Value ("[{0}] [INFO] Main script attached to existing run log for {1} v{2}" -f (Get-Date -Format "HH:mm:ss"), $script:AppName, $script:Version)
        return
    }

    $nextRunNumber = 1
    $existingLogs = @(Get-ChildItem -LiteralPath $script:LogRoot -File -Filter "*-log.txt" -ErrorAction SilentlyContinue)
    foreach ($log in $existingLogs) {
        if ($log.Name -match '^\d{4}-\d{2}-\d{2}-\d{2}-\d{2}-\d{2}-(\d+)-log\.txt$') {
            $runNumber = [int]$Matches[1]
            if ($runNumber -ge $nextRunNumber) {
                $nextRunNumber = $runNumber + 1
            }
        }
    }

    $logName = "{0}-{1:0000}-log.txt" -f $script:RunTimestamp, $nextRunNumber
    $script:LogFile = Join-Path -Path $script:LogRoot -ChildPath $logName

    New-Item -Path $script:LogFile -ItemType File -Force | Out-Null
    Add-Content -Path $script:LogFile -Value ("[{0}] [INFO] Run log created for {1} v{2}" -f $script:RunStartedAt.ToString("HH:mm:ss"), $script:AppName, $script:Version)
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

function Get-UiWidth {
    try {
        $width = [Console]::WindowWidth - 2
        if ($width -lt 72) { return 72 }
        if ($width -gt 96) { return 96 }
        return $width
    } catch {
        return 78
    }
}

function Write-UiRule {
    param(
        [string]$Color = "DarkCyan",
        [string]$Char = "="
    )

    Write-Host ($Char * (Get-UiWidth)) -ForegroundColor $Color
}

function Write-UiPair {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Value,
        [string]$Color = "Gray"
    )

    Write-Host ("  {0,-12} {1}" -f ($Label + ":"), $Value) -ForegroundColor $Color
}

function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-UiRule -Color DarkCyan
    Write-Host ("  {0}  v{1}" -f $script:AppName.ToUpperInvariant(), $script:Version) -ForegroundColor Cyan
    Write-UiRule -Color DarkCyan
    Write-Host ""
}

function Show-Section {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title
    )

    Write-Host $Title -ForegroundColor White
    Write-Host ("-" * [Math]::Min((Get-UiWidth), [Math]::Max(24, $Title.Length))) -ForegroundColor DarkGray
}

function Pause-ForKey {
    param([string]$Prompt = "Press any key to continue...")
    Write-Host ""
    Write-Host $Prompt -ForegroundColor DarkGray
    [void][Console]::ReadKey($true)
}

function Show-LoadingPulse {
    $steps = @(
        "Inspecting machine configuration",
        "Loading lockdown catalog",
        "Preparing interactive console"
    )

    foreach ($step in $steps) {
        Write-Host ("  [..] {0}..." -f $step) -ForegroundColor DarkGray
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
    Show-Section "Device"
    Write-UiPair -Label "OS" -Value ("{0} ({1})" -f $summary.Caption, $summary.Version)
    Write-UiPair -Label "Build" -Value ("{0} build {1}" -f $summary.Edition, $summary.Build)
    Write-UiPair -Label "User" -Value $summary.User
    Write-UiPair -Label "Device" -Value $summary.Device
    Write-UiPair -Label "Log" -Value $script:LogFile -Color DarkGray
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

function Convert-ToTweakIdFragment {
    param([Parameter(Mandatory = $true)][string]$Value)

    $fragment = ($Value.ToLowerInvariant() -replace "[^a-z0-9]+", "_").Trim("_")
    if ($fragment.Length -gt 64) {
        $fragment = $fragment.Substring(0, 64).Trim("_")
    }
    return $fragment
}

function New-HostsTweak {
    param(
        [Parameter(Mandatory = $true)][string]$Domain,
        [bool]$Express = $true
    )

    New-Tweak -Id ("hosts_{0}" -f (Convert-ToTweakIdFragment -Value $Domain)) -Category "Telemetry Domains" -Type "Hosts" -Name ("Block {0}" -f $Domain) -Description "Blocks this telemetry endpoint in the hosts file." -Express $Express -Data @{
        Domain = $Domain
        Address = "0.0.0.0"
    }
}

function New-FirewallTweak {
    param([Parameter(Mandatory = $true)][string]$RemoteAddress)

    New-Tweak -Id ("fw_{0}" -f (Convert-ToTweakIdFragment -Value $RemoteAddress)) -Category "Firewall Blocking" -Type "Firewall" -Name ("Block {0}" -f $RemoteAddress) -Description "Blocks a known telemetry IP at the firewall." -Express $false -Data @{
        RuleName = "$script:FirewallTag-$RemoteAddress"
        RemoteAddress = $RemoteAddress
    }
}

function Get-TelemetryDomainBlockList {
    @(
        "browser.events.data.msn.com",
        "df.telemetry.microsoft.com",
        "diagnostics.microsoft.com",
        "diagnostics.office.com",
        "diagnostics.support.microsoft.com",
        "eu-v10c.events.data.microsoft.com",
        "eu-watsonc.events.data.microsoft.com",
        "feedback.microsoft-hohm.com",
        "feedback.search.microsoft.com",
        "feedback.windows.com",
        "functional.events.data.microsoft.com",
        "mobile.events.data.microsoft.com",
        "oca.telemetry.microsoft.com",
        "oca.telemetry.microsoft.com.nsatc.net",
        "officeclient.microsoft.com",
        "reports.wes.df.telemetry.microsoft.com",
        "self.events.data.microsoft.com",
        "services.wes.df.telemetry.microsoft.com",
        "settings-sandbox.data.microsoft.com",
        "settings-win.data.microsoft.com",
        "settings.data.microsoft.com",
        "sqm.df.telemetry.microsoft.com",
        "sqm.microsoft.com",
        "sqm.telemetry.microsoft.com",
        "sqm.telemetry.microsoft.com.nsatc.net",
        "statsfe1.update.microsoft.com",
        "statsfe1.ws.microsoft.com",
        "statsfe2.update.microsoft.com",
        "statsfe2.update.microsoft.com.akadns.net",
        "statsfe2.ws.microsoft.com",
        "survey.watson.microsoft.com",
        "telecommand.telemetry.microsoft.com",
        "telecommand.telemetry.microsoft.com.nsatc.net",
        "telecommandstorageprod.blob.core.windows.net",
        "telemetry.appex.bing.net",
        "telemetry.microsoft.com",
        "telemetry.remoteapp.windowsazure.com",
        "telemetry.urs.microsoft.com",
        "teams.events.data.microsoft.com",
        "v10.events.data.microsoft.com",
        "v10.vortex-win.data.microsoft.com",
        "v10c.events.data.microsoft.com",
        "v20.events.data.microsoft.com",
        "vortex-bn2.metron.live.com.nsatc.net",
        "vortex-cy2.metron.live.com.nsatc.net",
        "vortex-sandbox.data.microsoft.com",
        "vortex-win.data.microsoft.com",
        "vortex.data.microsoft.com",
        "watson.events.data.microsoft.com",
        "watson.live.com",
        "watson.microsoft.com",
        "watson.ppe.telemetry.microsoft.com",
        "watson.telemetry.microsoft.com",
        "watson.telemetry.microsoft.com.nsatc.net",
        "watsonc.events.data.microsoft.com",
        "wes.df.telemetry.microsoft.com",
        "www.telecommandsvc.microsoft.com"
    ) | Sort-Object -Unique
}

function Get-TelemetryFirewallAddressList {
    @(
        "64.4.54.32",
        "65.52.100.7",
        "65.55.108.23",
        "65.55.138.114",
        "65.55.252.43",
        "65.55.252.63",
        "65.55.252.71",
        "65.55.252.92",
        "65.55.252.93",
        "66.119.144.157",
        "93.184.215.200",
        "111.221.29.177",
        "131.253.40.37",
        "134.170.30.202",
        "134.170.52.151",
        "137.116.81.24",
        "157.56.91.77",
        "168.63.108.233",
        "191.232.139.254",
        "207.46.101.29"
    ) | Sort-Object -Unique
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
        New-Tweak -Id "svc_diagnosticshub" -Category "Telemetry Services" -Type "Service" -Name "Disable Diagnostics Hub collector" -Description "Disables the Diagnostics Hub collector service when it exists." -Express $true -Data @{
            ServiceName = "diagnosticshub.standardcollector.service"
        }
        New-Tweak -Id "svc_pcasvc" -Category "Aggressive Services" -Type "Service" -Name "Disable Program Compatibility Assistant" -Description "Aggressive. Disables PCA compatibility tracking and prompts." -Express $false -Data @{
            ServiceName = "PcaSvc"
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
        New-Tweak -Id "reg_wer_policy_disabled" -Category "Registry Hardening" -Type "Registry" -Name "Disable Windows Error Reporting by policy" -Description "Turns off Windows Error Reporting uploads through policy." -Express $true -Data @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"
            ValueName = "Disabled"
            Value = 1
            ValueType = "DWord"
        }
        New-Tweak -Id "reg_wer_local_disabled" -Category "Registry Hardening" -Type "Registry" -Name "Disable local Windows Error Reporting" -Description "Turns off local Windows Error Reporting configuration." -Express $true -Data @{
            Path = "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting"
            ValueName = "Disabled"
            Value = 1
            ValueType = "DWord"
        }
        New-Tweak -Id "reg_sqm_policy" -Category "Registry Hardening" -Type "Registry" -Name "Disable SQM CEIP by policy" -Description "Disables the Software Quality Metrics customer experience program." -Express $true -Data @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows"
            ValueName = "CEIPEnable"
            Value = 0
            ValueType = "DWord"
        }
        New-Tweak -Id "reg_sqm_local" -Category "Registry Hardening" -Type "Registry" -Name "Disable local SQM CEIP" -Description "Pins local SQM participation off." -Express $true -Data @{
            Path = "HKLM:\SOFTWARE\Microsoft\SQMClient\Windows"
            ValueName = "CEIPEnable"
            Value = 0
            ValueType = "DWord"
        }
        New-Tweak -Id "reg_appcompat_inventory" -Category "Registry Hardening" -Type "Registry" -Name "Disable app compatibility inventory" -Description "Stops application compatibility inventory collection by policy." -Express $true -Data @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat"
            ValueName = "DisableInventory"
            Value = 1
            ValueType = "DWord"
        }
        New-Tweak -Id "reg_appcompat_ait" -Category "Registry Hardening" -Type "Registry" -Name "Disable Application Impact Telemetry" -Description "Disables AIT app compatibility telemetry when honored by this build." -Express $true -Data @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat"
            ValueName = "AITEnable"
            Value = 0
            ValueType = "DWord"
        }
        New-Tweak -Id "reg_input_personalization_policy" -Category "Registry Hardening" -Type "Registry" -Name "Disable input personalization policy" -Description "Disables input personalization data collection by policy." -Express $true -Data @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization"
            ValueName = "AllowInputPersonalization"
            Value = 0
            ValueType = "DWord"
        }
        New-Tweak -Id "reg_ink_text_collection" -Category "Registry Hardening" -Type "Registry" -Name "Restrict ink and text collection" -Description "Restricts implicit ink and text collection for the current user." -Express $true -Data @{
            Path = "HKCU:\Software\Microsoft\InputPersonalization"
            ValueName = "RestrictImplicitTextCollection"
            Value = 1
            ValueType = "DWord"
        }
        New-Tweak -Id "reg_ink_collection" -Category "Registry Hardening" -Type "Registry" -Name "Restrict implicit ink collection" -Description "Restricts implicit ink collection for the current user." -Express $true -Data @{
            Path = "HKCU:\Software\Microsoft\InputPersonalization"
            ValueName = "RestrictImplicitInkCollection"
            Value = 1
            ValueType = "DWord"
        }
        New-Tweak -Id "reg_contact_harvesting" -Category "Registry Hardening" -Type "Registry" -Name "Disable contact harvesting" -Description "Stops contact harvesting used for personalization." -Express $true -Data @{
            Path = "HKCU:\Software\Microsoft\InputPersonalization\TrainedDataStore"
            ValueName = "HarvestContacts"
            Value = 0
            ValueType = "DWord"
        }
        New-Tweak -Id "reg_handwriting_data_sharing" -Category "Registry Hardening" -Type "Registry" -Name "Disable handwriting data sharing" -Description "Blocks handwriting data sharing policy." -Express $true -Data @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\TabletPC"
            ValueName = "PreventHandwritingDataSharing"
            Value = 1
            ValueType = "DWord"
        }
        New-Tweak -Id "reg_handwriting_error_reports" -Category "Registry Hardening" -Type "Registry" -Name "Disable handwriting error reports" -Description "Blocks handwriting recognition error reports." -Express $true -Data @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\HandwritingErrorReports"
            ValueName = "PreventHandwritingErrorReports"
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
        New-Tweak -Id "task_ait_agent" -Category "Scheduled Tasks" -Type "Task" -Name "Disable AitAgent" -Description "Disables legacy Application Impact Telemetry task when present." -Express $true -Data @{
            TaskPath = "\Microsoft\Windows\Application Experience\"
            TaskName = "AitAgent"
        }
        New-Tweak -Id "task_mare_backup" -Category "Scheduled Tasks" -Type "Task" -Name "Disable MareBackup" -Description "Disables app compatibility database maintenance when present." -Express $true -Data @{
            TaskPath = "\Microsoft\Windows\Application Experience\"
            TaskName = "MareBackup"
        }
        New-Tweak -Id "task_pca_patch_db" -Category "Scheduled Tasks" -Type "Task" -Name "Disable PcaPatchDbTask" -Description "Disables Program Compatibility Assistant patch database task." -Express $true -Data @{
            TaskPath = "\Microsoft\Windows\Application Experience\"
            TaskName = "PcaPatchDbTask"
        }
        New-Tweak -Id "task_kernel_ceip" -Category "Scheduled Tasks" -Type "Task" -Name "Disable KernelCeipTask" -Description "Disables kernel customer experience reporting when present." -Express $true -Data @{
            TaskPath = "\Microsoft\Windows\Customer Experience Improvement Program\"
            TaskName = "KernelCeipTask"
        }
        New-Tweak -Id "task_bth_sqm" -Category "Scheduled Tasks" -Type "Task" -Name "Disable BthSQM" -Description "Disables Bluetooth SQM reporting when present." -Express $true -Data @{
            TaskPath = "\Microsoft\Windows\Customer Experience Improvement Program\"
            TaskName = "BthSQM"
        }
        New-Tweak -Id "task_queue_reporting" -Category "Scheduled Tasks" -Type "Task" -Name "Disable WER QueueReporting" -Description "Disables queued Windows Error Reporting uploads." -Express $true -Data @{
            TaskPath = "\Microsoft\Windows\Windows Error Reporting\"
            TaskName = "QueueReporting"
        }
        New-Tweak -Id "task_feedback_dmclient" -Category "Scheduled Tasks" -Type "Task" -Name "Disable Feedback DmClient" -Description "Disables feedback prompt download task when present." -Express $true -Data @{
            TaskPath = "\Microsoft\Windows\Feedback\Siuf\"
            TaskName = "DmClient"
        }
        New-Tweak -Id "task_feedback_dmclient_scenario" -Category "Scheduled Tasks" -Type "Task" -Name "Disable Feedback scenario download" -Description "Disables feedback scenario download task when present." -Express $true -Data @{
            TaskPath = "\Microsoft\Windows\Feedback\Siuf\"
            TaskName = "DmClientOnScenarioDownload"
        }
        New-Tweak -Id "task_power_efficiency_diagnostics" -Category "Scheduled Tasks" -Type "Task" -Name "Disable power efficiency diagnostics" -Description "Disables scheduled power efficiency diagnostic collection." -Express $true -Data @{
            TaskPath = "\Microsoft\Windows\Power Efficiency Diagnostics\"
            TaskName = "AnalyzeSystem"
        }

        foreach ($domain in Get-TelemetryDomainBlockList) {
            New-HostsTweak -Domain $domain -Express $true
        }

        foreach ($address in Get-TelemetryFirewallAddressList) {
            New-FirewallTweak -RemoteAddress $address
        }
    )
}

function Get-ServiceState {
    param([string]$ServiceName)
    if ($null -eq $script:ServiceStateCache) {
        Log-Debug "Building service state cache."
        $script:ServiceStateCache = @{}
        foreach ($service in Get-CimInstance Win32_Service -ErrorAction Stop) {
            $script:ServiceStateCache[$service.Name.ToLowerInvariant()] = $service
        }
    }

    $key = $ServiceName.ToLowerInvariant()
    if (-not $script:ServiceStateCache.ContainsKey($key)) {
        throw "Service not present: $ServiceName"
    }

    $script:ServiceStateCache[$key]
}

function Update-ServiceStateCache {
    param([string]$ServiceName)

    if ($null -eq $script:ServiceStateCache) {
        return
    }

    $key = $ServiceName.ToLowerInvariant()
    $service = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $ServiceName.Replace("'", "''")) -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        [void]$script:ServiceStateCache.Remove($key)
        return
    }

    $script:ServiceStateCache[$key] = $service
}

function Get-ScheduledTaskCacheKey {
    param(
        [string]$TaskPath,
        [string]$TaskName
    )

    $normalizedPath = if ($TaskPath.EndsWith("\")) { $TaskPath } else { "$TaskPath\" }
    ("{0}{1}" -f $normalizedPath, $TaskName).ToLowerInvariant()
}

function Get-ScheduledTaskState {
    param(
        [string]$TaskPath,
        [string]$TaskName
    )

    if ($null -eq $script:ScheduledTaskCache) {
        Log-Debug "Building scheduled task cache."
        $script:ScheduledTaskCache = @{}
        foreach ($task in Get-ScheduledTask -ErrorAction Stop) {
            $key = Get-ScheduledTaskCacheKey -TaskPath $task.TaskPath -TaskName $task.TaskName
            $script:ScheduledTaskCache[$key] = $task
        }
    }

    $lookupKey = Get-ScheduledTaskCacheKey -TaskPath $TaskPath -TaskName $TaskName
    if (-not $script:ScheduledTaskCache.ContainsKey($lookupKey)) {
        throw "Scheduled task not present: $TaskPath$TaskName"
    }

    $script:ScheduledTaskCache[$lookupKey]
}

function Update-ScheduledTaskCache {
    param(
        [string]$TaskPath,
        [string]$TaskName
    )

    if ($null -eq $script:ScheduledTaskCache) {
        return
    }

    $lookupKey = Get-ScheduledTaskCacheKey -TaskPath $TaskPath -TaskName $TaskName
    $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        [void]$script:ScheduledTaskCache.Remove($lookupKey)
        return
    }

    $script:ScheduledTaskCache[$lookupKey] = $task
}

function Test-Tweak {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Tweak
    )

    switch ($Tweak.Type) {
        "Service" {
            try {
                $service = Get-ServiceState -ServiceName $Tweak.ServiceName
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
            try {
                $task = Get-ScheduledTaskState -TaskName $Tweak.TaskName -TaskPath $Tweak.TaskPath
                $disabled = ($task.State -eq "Disabled") -or ($task.Settings.Enabled -eq $false)
                $applied = $disabled
                $state = if ($applied) { "Applied" } else { "Pending" }
                $summary = "State={0}" -f $task.State
            } catch {
                return [pscustomobject]@{
                    Tweak      = $Tweak
                    Applicable = $false
                    Applied    = $true
                    State      = "Unavailable"
                    Summary    = "Task not present on this build."
                }
            }
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
        Write-Host "Hotkeys: number selects, Up/Down moves, Enter confirms, Esc exits." -ForegroundColor DarkGray
        Write-Host ""

        for ($i = 0; $i -lt $Options.Count; $i++) {
            $prefix = if ($i -eq $selected) { "=>" } else { "  " }
            $color = if ($i -eq $selected) { "Cyan" } else { "Gray" }
            Write-Host ("{0} [{1}] {2}" -f $prefix, ($i + 1), $Options[$i].Label) -ForegroundColor $color
        }

        Write-Host ""
        Write-Host ("Selected: {0}" -f $Options[$selected].Description) -ForegroundColor Gray

        $key = [Console]::ReadKey($true)
        $keyName = $key.Key.ToString()
        if ($keyName -match "^D([1-9])$" -or $keyName -match "^NumPad([1-9])$") {
            $index = [int]$Matches[1] - 1
            if ($index -ge 0 -and $index -lt $Options.Count) {
                return $Options[$index]
            }
        }

        switch ($key.Key) {
            "UpArrow"   { if ($selected -gt 0) { $selected-- } }
            "DownArrow" { if ($selected -lt ($Options.Count - 1)) { $selected++ } }
            "Enter"     { return $Options[$selected] }
            "Escape"    { return $null }
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
    Write-Host ("  Applied {0}  |  Pending {1}  |  Unavailable {2}" -f $alreadyApplied.Count, $pending.Count, $unavailable.Count) -ForegroundColor Cyan
    Write-Host ""

    foreach ($group in $Statuses | Group-Object -Property { $_.Tweak.Category }) {
        $groupPending = @($group.Group | Where-Object { $_.Applicable -and -not $_.Applied }).Count
        $groupApplied = @($group.Group | Where-Object { $_.Applicable -and $_.Applied }).Count
        $groupUnavailable = @($group.Group | Where-Object { -not $_.Applicable }).Count
        $color = if ($groupPending -gt 0) { "Yellow" } elseif ($groupApplied -gt 0) { "Green" } else { "DarkGray" }
        Write-Host ("  {0,-22} applied {1,3} | pending {2,3} | unavailable {3,3}" -f $group.Name, $groupApplied, $groupPending, $groupUnavailable) -ForegroundColor $color
    }

    if ($pending.Count -gt 0) {
        Write-Host ""
        Write-Host "Pending preview:" -ForegroundColor White
        foreach ($group in $pending | Group-Object -Property { $_.Tweak.Category }) {
            Write-Host ("  {0}" -f $group.Name) -ForegroundColor Yellow
            foreach ($status in $group.Group | Select-Object -First 4) {
                Write-Host ("    - {0}" -f $status.Tweak.Name) -ForegroundColor DarkYellow
            }
            if ($group.Count -gt 4) {
                Write-Host ("    ... {0} more in this category" -f ($group.Count - 4)) -ForegroundColor DarkGray
            }
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

    $maxAttempts = 8
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            Log-Debug ("Hosts operation start: {0} (attempt {1}/{2})" -f $OperationName, $attempt, $maxAttempts)
            $result = & $Operation
            Log-Debug ("Hosts operation succeeded: {0}" -f $OperationName)
            return $result
        } catch {
            $message = $_.Exception.Message
            Log-Debug ("Hosts operation failed: {0} | {1}" -f $OperationName, $message)

            $isTransientLock = $message -match "being used by another process"
            if (-not $isTransientLock -or $attempt -eq $maxAttempts) {
                throw
            }

            $stoppedAny = Stop-LockingProcessesForFile -Path $script:HostsPath
            if (-not $stoppedAny) {
                Log-Debug ("No stoppable process was found for {0}. Waiting before retry." -f $OperationName)
            }
            Start-Sleep -Milliseconds ([Math]::Min(2500, 300 * $attempt))
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

function Apply-HostsTweaks {
    param(
        [Parameter(Mandatory = $true)][pscustomobject[]]$Tweaks
    )

    Ensure-HostsBackup

    $addedCount = Invoke-WithHostsFileAccess -OperationName ("Append {0} hosts entries" -f $Tweaks.Count) -Operation {
        $content = [System.IO.File]::ReadAllText($script:HostsPath)
        $missingLines = @()

        foreach ($tweak in $Tweaks) {
            $escaped = [regex]::Escape($tweak.Domain)
            $pattern = "(?im)^\s*(0\.0\.0\.0|127\.0\.0\.1)\s+{0}(\s+.*)?$" -f $escaped
            if ($content -notmatch $pattern) {
                $missingLines += ("{0}`t{1}" -f $tweak.Address, $tweak.Domain)
            }
        }

        if ($missingLines.Count -eq 0) {
            return 0
        }

        $prefix = ""
        if ($content.Length -gt 0 -and -not $content.EndsWith([System.Environment]::NewLine)) {
            $prefix = [System.Environment]::NewLine
        }

        $appendText = $prefix + ($missingLines -join [System.Environment]::NewLine) + [System.Environment]::NewLine
        [System.IO.File]::AppendAllText($script:HostsPath, $appendText)
        return $missingLines.Count
    }

    Log -Message ("Hosts file updated with {0} new entr{1}." -f $addedCount, $(if ($addedCount -eq 1) { "y" } else { "ies" })) -Level "INFO" -Color "Green"
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
            Update-ServiceStateCache -ServiceName $Tweak.ServiceName
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
            Update-ScheduledTaskCache -TaskName $Tweak.TaskName -TaskPath $Tweak.TaskPath
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
    $hostsTweaks = @($PendingTweaks | Where-Object { $_.Type -eq "Hosts" })
    $otherTweaks = @($PendingTweaks | Where-Object { $_.Type -ne "Hosts" })

    if ($hostsTweaks.Count -gt 0) {
        Log -Message ("[hosts] Applying {0} telemetry domain block(s) in one hosts-file update" -f $hostsTweaks.Count) -Level "INFO" -Color "Cyan"

        try {
            Apply-HostsTweaks -Tweaks $hostsTweaks
            foreach ($tweak in $hostsTweaks) {
                $status = Test-Tweak -Tweak $tweak
                if ($status.Applied) {
                    Log-Debug ("Verified hosts entry: {0}" -f $tweak.Domain)
                    $results += [pscustomobject]@{ Tweak = $tweak; Success = $true; Summary = $status.Summary }
                } else {
                    Log -Message ("Verification still pending: {0}" -f $tweak.Name) -Level "ERROR" -Color "Red"
                    $results += [pscustomobject]@{ Tweak = $tweak; Success = $false; Summary = $status.Summary }
                }
            }
        } catch {
            Log -Message ("Failed hosts batch update: {0}" -f $_.Exception.Message) -Level "ERROR" -Color "Red"
            foreach ($tweak in $hostsTweaks) {
                $results += [pscustomobject]@{ Tweak = $tweak; Success = $false; Summary = $_.Exception.Message }
            }
        }
    }

    for ($i = 0; $i -lt $otherTweaks.Count; $i++) {
        $tweak = $otherTweaks[$i]
        $progress = "[{0}/{1}]" -f ($i + 1), $otherTweaks.Count
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

    $hostsChanged = @($results | Where-Object { $_.Success -and $_.Tweak.Type -eq "Hosts" }).Count
    if ($hostsChanged -gt 0) {
        try {
            Clear-DnsClientCache -ErrorAction Stop
            Log -Message "DNS client cache flushed after hosts updates." -Level "INFO" -Color "Green"
        } catch {
            Log -Message ("DNS cache flush skipped: {0}" -f $_.Exception.Message) -Level "WARNING" -Color "Yellow"
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
    Write-Host ("  Before: applied {0}, pending {1}" -f $appliedBefore, $pendingBefore) -ForegroundColor Gray
    Write-Host ("  Run   : applied {0}, failed {1}" -f $successes, $failures) -ForegroundColor $(if ($failures -gt 0) { "Red" } else { "Green" })
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
        "Maximum Lockdown" {
            $selection = @($Catalog)
            Log-Debug ("Maximum Lockdown selected {0} tweak(s)." -f $selection.Count)
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

Initialize-RunLog
Show-Banner
Show-LoadingPulse

Log -Message ("Launching {0} {1}" -f $script:AppName, $script:Version) -Level "INFO" -Color "Cyan"

$catalog = Get-TweakCatalog
Log-Debug ("Catalog loaded with {0} tweak(s)." -f $catalog.Count)
$menuOptions = @(
    [pscustomobject]@{
        Label = "Express Settings"
        Description = "Recommended baseline: services, policies, tasks, and expanded telemetry domain blocking."
    }
    [pscustomobject]@{
        Label = "Maximum Lockdown"
        Description = "Applies every catalog item, including aggressive services and IP firewall blocks."
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
