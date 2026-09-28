@echo off
setlocal
cd /d "%~dp0"
title DSH Portable - stop
echo Stopping DeepSeek Harness (window + service) ...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-DSH.ps1" -Stop
echo Done. Nothing from this folder is running any more.
timeout /t 3 >nul
