@echo off
setlocal EnableExtensions EnableDelayedExpansion
title ImFuckingParanoid Launcher
color 0B

set "APP_NAME=ImFuckingParanoid"
set "UPDATE_RELEASES_URL=https://github.com/veltrixtheperson013/ImFuckingParanoid/releases"
set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%actualscript.ps1"
set "LOGS_DIR="
set "LAUNCHER_LOG="

pushd "%SCRIPT_DIR%" >nul 2>&1
set "SCRIPT_DIR=%CD%"
popd >nul 2>&1

call :Banner "BOOTSTRAP"
call :Status "PATH" "%SCRIPT_DIR%"

where powershell.exe >nul 2>&1
if errorlevel 1 (
    call :Status "ERROR" "PowerShell was not found on this system."
    echo.
    pause
    exit /b 1
)
call :Status "CHECK" "PowerShell found."
call :InitLog
if errorlevel 1 (
    echo.
    pause
    exit /b 1
)
call :Log "Launcher started from %SCRIPT_DIR%"

if exist "%SCRIPT_DIR%\update.ps1" (
    call :Status "UPDATE" "Checking GitHub Releases before launch..."
    call :Log "Starting update check."
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%\update.ps1" -ScriptDir "%SCRIPT_DIR%" -LauncherPath "%~f0" -ReleasesUrl "%UPDATE_RELEASES_URL%" -LogFile "%LAUNCHER_LOG%"
    set "UPD_EXIT=!ERRORLEVEL!"
    call :Log "Update check finished with exit code !UPD_EXIT!."
    if "!UPD_EXIT!"=="1" (
        call :Status "UPDATE" "Replacement launcher started. Closing this copy."
        exit /b 0
    ) else if "!UPD_EXIT!"=="2" (
        call :Status "UPDATE" "Update check failed. Continuing with installed version."
        timeout /t 2 /nobreak >nul
    ) else (
        call :Status "UPDATE" "No update required."
    )
) else (
    call :Status "UPDATE" "update.ps1 missing. Skipping update check."
)

if not exist "%PS_SCRIPT%" (
    call :Status "ERROR" "Could not find actualscript.ps1."
    echo Expected at:
    echo %PS_SCRIPT%
    echo.
    echo Keep Launcher.bat and actualscript.ps1 in the same folder.
    pause
    exit /b 1
)

net session >nul 2>&1
if %errorlevel% neq 0 (
    call :Status "ADMIN" "Requesting administrator privileges..."
    call :Log "Requesting administrator relaunch."
    set "IFP_LAUNCHER=%~f0"
    set "IFP_WORKDIR=%SCRIPT_DIR%"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$launcher=$env:IFP_LAUNCHER; $workdir=$env:IFP_WORKDIR; Start-Process -FilePath $env:ComSpec -ArgumentList @('/d','/c',([char]34 + $launcher + [char]34)) -WorkingDirectory $workdir -Verb RunAs"
    if errorlevel 1 (
        call :Status "ERROR" "Administrator relaunch failed or was cancelled."
        call :Log "Administrator relaunch failed with exit code %ERRORLEVEL%."
        echo.
        pause
    )
    exit /b
)

call :Banner "READY"
call :Status "MODE" "Interactive PowerShell console"
call :Status "PRESET" "Express or Maximum Lockdown"
call :Status "SAFETY" "Pre-scan runs before anything is applied"
echo.

powershell.exe ^
  -NoProfile ^
  -ExecutionPolicy Bypass ^
  -File "%PS_SCRIPT%" ^
  -LogFile "%LAUNCHER_LOG%"

set "EXITCODE=%ERRORLEVEL%"
call :Log "PowerShell script exited with code %EXITCODE%."

echo.
if "%EXITCODE%"=="0" (
    call :Status "DONE" "Completed successfully."
) else (
    call :Status "EXIT" "Script exited with code %EXITCODE%. Check the log file."
)

echo.
pause
exit /b %EXITCODE%

:Banner
cls
echo.
echo ============================================================================
echo   %APP_NAME%  ::  %~1
echo ============================================================================
echo.
exit /b 0

:Status
echo   [%~1] %~2
exit /b 0

:InitLog
set "LOGS_DIR=%SCRIPT_DIR%\logs"
if defined IFP_RUN_LOG (
    set "LAUNCHER_LOG=%IFP_RUN_LOG%"
) else (
    set "IFP_LOGS_DIR=%LOGS_DIR%"
    for /f "delims=" %%L in ('powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$root=$env:IFP_LOGS_DIR; if (-not (Test-Path -LiteralPath $root)) { New-Item -Path $root -ItemType Directory -Force | Out-Null }; $next=1; Get-ChildItem -LiteralPath $root -File -Filter '*-log.txt' -ErrorAction SilentlyContinue | ForEach-Object { if ($_.Name -match '^\d{4}-\d{2}-\d{2}-\d{2}-\d{2}-\d{2}-(\d+)-log\.txt$') { $n=[int]$Matches[1]; if ($n -ge $next) { $next=$n+1 } } }; $name='{0}-{1:0000}-log.txt' -f (Get-Date -Format 'yyyy-MM-dd-HH-mm-ss'), $next; $path=Join-Path $root $name; New-Item -Path $path -ItemType File -Force | Out-Null; $path"') do set "LAUNCHER_LOG=%%L"
    set "IFP_RUN_LOG=!LAUNCHER_LOG!"
)
if not defined LAUNCHER_LOG (
    call :Status "ERROR" "Could not create run log."
    exit /b 1
)
exit /b 0

:Log
>>"%LAUNCHER_LOG%" echo [%DATE% %TIME%] %~1
exit /b 0
