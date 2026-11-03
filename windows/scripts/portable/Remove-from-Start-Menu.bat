@echo off
setlocal DisableDelayedExpansion
if not exist "%~dp0ClearTone.exe" (
  echo ClearTone.exe was not found. Extract the entire ZIP first.
  if /i not "%~1"=="--quiet" pause
  exit /b 1
)
"%~dp0ClearTone.exe" --remove-from-start-menu
set "CT_RESULT=%ERRORLEVEL%"
if "%CT_RESULT%"=="0" (echo ClearTone was removed from the current user Start Menu.) else (echo Failed to remove the Start Menu shortcut.)
if /i not "%~1"=="--quiet" pause
exit /b %CT_RESULT%
