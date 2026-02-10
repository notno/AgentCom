@echo off
REM AgentCom sidecar startup wrapper for Windows
REM Auto-updates from git before launching

REM Navigate to repo root
cd /d "%~dp0\.."

REM Pull latest changes (fast-forward only, ignore errors)
git pull --ff-only origin main 2>nul
if errorlevel 1 echo [sidecar] git pull failed, continuing with current version

REM Install any new dependencies
cd sidecar
call npm install --production 2>nul
if errorlevel 1 echo [sidecar] npm install failed, continuing with current packages

REM Create results and logs directories
if not exist results mkdir results
if not exist logs mkdir logs

REM Launch sidecar
node index.js
