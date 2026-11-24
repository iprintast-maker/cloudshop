@echo off
if exist "%LOCALAPPDATA%\IprintDesk\App\IprintDesk.exe" (
 start "" "%LOCALAPPDATA%\IprintDesk\App\IprintDesk.exe"
) else (
 call "%~dp0INSTALL.cmd"
)
