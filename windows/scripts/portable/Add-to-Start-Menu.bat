@echo off
setlocal DisableDelayedExpansion
set "CT_PORTABLE_ROOT=%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference = 'Stop'; try { $root = $env:CT_PORTABLE_ROOT; $exe = Join-Path $root 'ClearTone.exe'; if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'ClearTone.exe was not found beside this script. Extract the entire ZIP first.' }; $programs = [Environment]::GetFolderPath('Programs'); if (-not $programs) { throw 'The current user Start Menu folder is unavailable.' }; [IO.Directory]::CreateDirectory($programs) | Out-Null; $shell = New-Object -ComObject WScript.Shell; $link = $shell.CreateShortcut((Join-Path $programs 'ClearTone.lnk')); $link.TargetPath = $exe; $link.WorkingDirectory = $root; $link.IconLocation = $exe + ',0'; $link.Description = 'ClearTone portable music player'; $link.Save(); Write-Host 'ClearTone was added to the current user Start Menu.'; exit 0 } catch { Write-Host $_ -ForegroundColor Red; exit 1 }"
set "CT_RESULT=%ERRORLEVEL%"
if /i not "%~1"=="--quiet" pause
exit /b %CT_RESULT%
