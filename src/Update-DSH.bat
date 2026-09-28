@echo off
setlocal
cd /d "%~dp0"
title DSH Portable - update
echo ============================================================
echo   Upgrading DeepSeek Harness to the latest version
echo   (everything stays inside this folder)
echo ============================================================
echo.
if exist "%~dp0run.lock" (
  echo [HINT] DeepSeek Harness seems to be running. Close its window first.
  echo.
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-DSH.ps1" -Update
echo.
if errorlevel 1 (
  echo [FAILED] See Start-DSH.log / npm-install.log in this folder.
) else (
  echo [OK] Upgrade done.
)
pause
