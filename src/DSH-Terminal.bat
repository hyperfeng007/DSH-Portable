@echo off
setlocal EnableExtensions
cd /d "%~dp0"
set "ROOT=%~dp0"
if not exist "%ROOT%node\node.exe" (
  echo [HINT] Runtime not installed yet. Double-click DeepseekHarness.exe or Install-DSH.bat first.
  pause
  exit /b 1
)
set "PATH=%ROOT%node;%ROOT%dsh;%PATH%"
set "NPM_CONFIG_PREFIX=%ROOT%dsh"
set "NPM_CONFIG_CACHE=%ROOT%npm-cache"
set "NPM_CONFIG_UPDATE_NOTIFIER=false"
set "NODE_REPL_HISTORY=%ROOT%node_repl_history.txt"
set "DSH_HOME=%ROOT%dsh-home"
set "DSH_TELEMETRY_DISABLED=1"
set "DSH_TELEMETRY_MODE=DISABLED"
set "TMP=%ROOT%temp"
set "TEMP=%ROOT%temp"
if not exist "%ROOT%dsh-home" mkdir "%ROOT%dsh-home"
if not exist "%ROOT%workspace" mkdir "%ROOT%workspace"
if not exist "%ROOT%temp" mkdir "%ROOT%temp"
rem import the current system proxy (same logic as the launcher)
for /f "usebackq delims=" %%l in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%Start-DSH.ps1" -ExportEnv`) do set "%%l"
cd /d "%ROOT%workspace"
title DSH Portable Terminal
echo ============================================================
echo   DSH Portable Terminal  (dsh / node / npm available here)
if defined HTTPS_PROXY (echo   proxy : %HTTPS_PROXY%) else (echo   proxy : none / direct)
echo   Examples:
echo     dsh --version
echo     dsh --profile headless "summarize this folder"
echo ============================================================
cmd /k
