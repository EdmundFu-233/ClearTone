@echo off
setlocal DisableDelayedExpansion
if not exist "%~dp0ClearTone.exe" (
  echo ClearTone.exe was not found. Extract the entire ZIP first.
  if /i not "%~1"=="--quiet" pause
  exit /b 1
)
"%~dp0ClearTone.exe" --add-to-start-menu
set "CT_RESULT=%ERRORLEVEL%"
if "%CT_RESULT%"=="0" (echo ClearTone was added to the current user Start Menu.) else (echo Failed to add the Start Menu shortcut.)
if /i not "%~1"=="--quiet" pause
exit /b %CT_RESULT%
