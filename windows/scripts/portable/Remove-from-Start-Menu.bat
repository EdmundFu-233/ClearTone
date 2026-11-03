@echo off
setlocal DisableDelayedExpansion
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference = 'Stop'; try { $programs = [Environment]::GetFolderPath('Programs'); if (-not $programs) { throw 'The current user Start Menu folder is unavailable.' }; $path = Join-Path $programs 'ClearTone.lnk'; if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }; Write-Host 'ClearTone was removed from the current user Start Menu. Application files and data are unchanged.'; exit 0 } catch { Write-Host $_ -ForegroundColor Red; exit 1 }"
set "CT_RESULT=%ERRORLEVEL%"
if /i not "%~1"=="--quiet" pause
exit /b %CT_RESULT%
