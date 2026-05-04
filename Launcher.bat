@echo off
setlocal EnableExtensions EnableDelayedExpansion

:: =========================
:: Resolve paths safely
:: =========================
set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%actualscript.ps1"

:: Normalize path (remove trailing backslash issues)
pushd "%SCRIPT_DIR%" >nul 2>&1
set "SCRIPT_DIR=%CD%"
popd >nul 2>&1

:: =========================
:: Check PowerShell exists
:: =========================
where powershell.exe >nul 2>&1
if errorlevel 1 (
    echo ERROR: PowerShell not found on this system.
    pause
    exit /b 1
)

:: =========================
:: Check script exists
:: =========================
if not exist "%PS_SCRIPT%" (
    echo ERROR: Could not find privacy-script.ps1
    echo Expected at:
    echo %PS_SCRIPT%
    echo.
    echo Make sure the .bat and .ps1 are in the same folder.
    pause
    exit /b 1
)

:: =========================
:: Elevation check
:: =========================
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process cmd -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)

:: =========================
:: Launch script
:: =========================
echo Running privacy script...
echo.

powershell.exe ^
  -NoProfile ^
  -ExecutionPolicy Bypass ^
  -File "%PS_SCRIPT%"

set "EXITCODE=%ERRORLEVEL%"

:: =========================
:: Result output
:: =========================
echo.
if "%EXITCODE%"=="0" (
    echo Completed successfully.
) else (
    echo Script exited with code %EXITCODE%.
    echo Check the log file for details.
)

echo.
pause
exit /b %EXITCODE%