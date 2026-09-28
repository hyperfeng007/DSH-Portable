@echo off
setlocal
cd /d "%~dp0"
title DSH Portable - one-time setup
echo ============================================================
echo   DSH Portable - one-time setup (console mode)
echo   Node runtime + DeepSeek Harness, all inside this folder.
echo   System proxy is imported automatically.
echo ============================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-DSH.ps1" -InstallOnly
echo.
if errorlevel 1 (
  echo [FAILED] See Start-DSH.log / npm-install.log in this folder.
) else (
  echo [OK] Done. From now on just double-click DeepseekHarness.exe
)
pause
