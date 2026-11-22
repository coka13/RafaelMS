@echo off
REM RafaelMS server setup wizard: Java, MySQL database + account, config.yaml,
REM build, launch.bat and Windows Firewall. Asks for administrator rights.
REM Unattended: setup-server.bat -Silent -AdminPassword "rootpw" -ServerIp 1.2.3.4
if "%~1"=="" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup\ServerSetupWizard.ps1" -HideConsole
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup\ServerSetupWizard.ps1" %*
)
