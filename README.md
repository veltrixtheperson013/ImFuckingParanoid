# ImFuckingParanoid

> [!CAUTION]
> This project is no longer maintained. 

ImFuckingParanoid is a production-ready Windows telemetry reduction tool for users who want tighter control over outbound diagnostics, telemetry services, scheduled tasks, and known telemetry endpoints.

**Version:** 1.0.0

---

## Overview

ImFuckingParanoid uses a launcher-first workflow. Run `Launcher.bat`; it handles update checks, run logging, administrator relaunch, and then starts the PowerShell tool.

The script applies selected Windows privacy and telemetry reduction changes, then verifies the current state before and after changes. It is designed to be readable, logged, and reversible where Windows supports it, but it is not a privacy guarantee.

---

## Features

### Launcher-first startup

- `Launcher.bat` is the supported entrypoint
- Checks GitHub Releases before starting the main script
- Requests administrator privileges when needed
- Creates one run log per launch under `logs`

### Run logs

- Each run creates a `.txt` log in the local `logs` folder
- Log names use this format: `yyyy-MM-dd-HH-mm-ss-0001-log.txt`
- Launcher, update check, updater apply steps, and main script output share the same run log
- Logs include debug details for update checks, version comparison, package selection, staging paths, and applied tweak verification

### Auto-update

- Reads the installed version from `actualscript.ps1`
- Checks the configured GitHub Releases URL before launch
- Only updates when the release version is comparable and greater than the installed version
- Skips non-version release names such as branch or UI labels unless a real version is present
- Prompts before downloading or applying an update
- Prefers release `.zip` assets and can fall back to the GitHub source zip
- Applies updates in place and restarts the launcher after a successful update

### Service and task optimization

- Caches service state during scans instead of querying each service one by one
- Caches scheduled task state during scans instead of querying each task one by one
- Refreshes only the service or task that was changed during apply verification

---

## What It Changes

### System Services

- Stops and disables selected telemetry-related services, such as `DiagTrack` and `dmwappushservice`
- Includes optional aggressive service changes in `Maximum Lockdown`

### Registry Policies

- Sets telemetry level to the minimum supported value
- Disables advertising ID behavior
- Reduces feedback prompts and diagnostic reporting
- Disables Windows Error Reporting, SQM/CEIP, app compatibility inventory, input personalization, contact harvesting, and handwriting reporting policies where supported

### Scheduled Tasks

- Disables selected scheduled tasks related to compatibility tracking, CEIP, Windows Error Reporting, feedback prompts, Bluetooth SQM, kernel CEIP, and power diagnostics

### Telemetry Domain Blocking

- Adds an expanded hosts-file blocklist for known Windows, Edge, Office, Teams, Watson, SQM, and diagnostic telemetry endpoints
- Batches hosts-file updates for faster execution
- Flushes DNS client cache after hosts changes are applied

### Firewall Rules

- Creates optional outbound firewall block rules for known telemetry IP addresses
- Firewall IP blocking is included in `Maximum Lockdown` because cloud IP routing can change over time

---

## Modes

### Express Settings

Recommended baseline. Applies the standard service, registry, scheduled task, and telemetry domain changes.

### Maximum Lockdown

Applies the full catalog, including aggressive services and IP firewall blocks. Use this mode only if you accept a higher chance of compatibility side effects.

---

## Usage

1. Run `Launcher.bat`
2. Let the update check complete
3. If an update is available, choose whether to install it
4. Choose `Express Settings` or `Maximum Lockdown`
5. Review the pre-scan results
6. Confirm before applying pending tweaks
7. Review the completion summary and reboot if needed

Do not run `actualscript.ps1` directly. The launcher is responsible for logging, update checks, and the supported startup flow.

---

## Production Package

The `ImFuckingParanoid_production` folder is the runtime package. It should contain only:

- `Launcher.bat`
- `actualscript.ps1`
- `update.ps1`
- `README.md`
- `LICENSE`

Generated folders such as `logs` may appear after running the tool. Installer build files are not required in the production package.

---

## Source Build Files

The source repo may include installer build files:

- `installer.iss`
- `BuildInstaller.bat`
- `dist`

These are for building a setup EXE with Inno Setup. They are not needed to run the production package.

---

## GitHub Releases

The launcher uses this default release source:

`https://github.com/veltrixtheperson013/ImFuckingParanoid/releases`

Release tags should use comparable versions, such as:

- `v1.0.1`
- `1.1.0`
- `v2.0.0`

Non-version tags are ignored for update purposes unless the release name contains a comparable version.

---

## What It Does Not Do

- It does not fully eliminate telemetry
- It cannot guarantee every current or future telemetry endpoint is blocked
- It does not anonymize your system
- It does not replace DNS filtering, firewall management, VPNs, or other network privacy tools
- It does not prevent Windows updates from changing or reverting settings later

---

## Risks

These changes operate at a low level and can affect system behavior.

Possible side effects include:

- Windows Update issues or partial failures
- Microsoft Store connectivity problems
- Reduced diagnostic reporting
- Compatibility prompt changes
- Features relying on telemetry or diagnostics behaving differently
- Major Windows updates reverting some settings

Review the script before running it on a system you rely on. You are responsible for any changes made to your machine.

---

## Requirements

- Windows 10 or Windows 11
- Administrator privileges
- PowerShell

---

## Supported Entrypoint

Run:

```bat
Launcher.bat
```

Do not start the `.ps1` directly.
