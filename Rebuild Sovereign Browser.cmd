@echo off
title Rebuild Sovereign Browser
rem Double-click THIS instead of build-exe.ps1.
rem On this machine .ps1 has no file association, so double-clicking a .ps1
rem just pops up "How do you want to open this file?" forever.
rem Close Sovereign Browser first - Windows will not let the build overwrite a
rem running .exe.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-exe.ps1"

echo.
if errorlevel 1 (
    echo Rebuild FAILED. If it said "access is denied", close the
    echo Sovereign Browser window first, then run this again.
) else (
    echo "Sovereign Browser.exe" was rebuilt.
)
echo.
pause
