# ImFuckingParanoid

An aggressive Windows telemetry reduction script for users who want tighter control over outbound data and system diagnostics.

**Version:** 0.3.0

---

## Overview

This project provides a PowerShell-based toolset that applies multiple system-level changes to reduce Windows telemetry and background data collection.

It is not a guarantee of privacy or anonymity. It reduces some default data flows and disables selected components commonly associated with telemetry.

---

## What It Does

The script can apply the following categories of changes:

### System Services
- Disables telemetry-related services (e.g. `DiagTrack`, `dmwappushservice`)

### Registry Policies
- Sets telemetry level to minimum (where supported)
- Disables advertising ID
- Reduces feedback prompts and diagnostic reporting

### Scheduled Tasks
- Disables selected tasks related to compatibility tracking and CEIP (Customer Experience Improvement Program)

### Hosts File Blocking
- Adds entries to block known telemetry endpoints at the DNS level

### Firewall Rules
- Creates outbound block rules for known telemetry IPs

### Menu System
- Interactive arrow-key menu with richer console output
- `Express Settings` preset for a recommended baseline
- `Custom` mode for category-by-category selection
- Automatically scans selected tweaks before applying them
- Cancels the run if the selected tweaks are already applied
- Prompts before continuing when only some tweaks still need work

---

## What It Does NOT Do

- It does not fully eliminate telemetry
- It does not anonymize your system
- It does not replace network-level privacy tools (firewalls, DNS filtering, VPNs)
- It does not prevent future Windows updates from reverting changes

---

## Risks and Side Effects

These changes operate at a low level and can impact system functionality.

Possible side effects include:

- Windows Update issues or partial failures
- Microsoft Store connectivity problems
- Reduced diagnostic reporting (harder troubleshooting)
- Some features relying on telemetry may stop working
- Changes may be reverted by major updates

Firewall and hosts blocking can also interfere with legitimate Microsoft services.

---

## Use With Caution

- This is a **beta release**
- No guarantees of stability or compatibility
- Test on a non-critical system first if possible
- Review the script before running if you care about exact behavior

You are responsible for any changes made to your system.

---

## Requirements

- Windows 10 or Windows 11
- Administrator privileges
- PowerShell (standard on Windows)

---

## Usage

1. Run Launcher.bat (it's that simple)
2. Choose `Express Settings` for the recommended baseline or `Custom` to pick categories yourself
3. Review the scan result
4. If tweaks are already applied, the script exits without changing anything
5. If some tweaks are still pending, confirm to continue

## Build A Setup EXE

This repo now includes an Inno Setup installer script:

- `installer.iss` builds a Windows installer
- `BuildInstaller.bat` compiles it if Inno Setup 6 is installed

Steps:

1. Install Inno Setup 6
2. Double-click `BuildInstaller.bat`
3. Grab the generated installer from the `dist` folder

The installer copies `Launcher.bat`, `actualscript.ps1`, `README.md`, and `LICENSE` into Program Files and creates shortcuts to launch the tool.

## GitHub Publishing

Recommended files to commit:

- `actualscript.ps1`
- `Launcher.bat`
- `installer.iss`
- `BuildInstaller.bat`
- `README.md`
- `LICENSE`
- `.gitignore`

The generated `dist` folder is ignored so you can publish source cleanly and attach built installers to GitHub Releases instead.

## DO NOT RUN THE .ps1 RUN THE .bat
