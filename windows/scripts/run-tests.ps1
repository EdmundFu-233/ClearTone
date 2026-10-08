<#
.SYNOPSIS
  在 Windows 上构建并运行全部离线单测（Qt Test）。
#>
param(
    [string]$BuildDir = '',
    [string]$QtRoot = ''
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WindowsDir = Split-Path -Parent $ScriptDir
if (-not $BuildDir) { $BuildDir = Join-Path $WindowsDir 'build-dev' }

if (-not $QtRoot) {
    $windeployqt = Get-Command windeployqt.exe -ErrorAction SilentlyContinue
    if ($windeployqt) { $QtRoot = Split-Path -Parent $windeployqt.Source }
}

$configureArgs = @('-S', $WindowsDir, '-B', $BuildDir)
if ($QtRoot) { $configureArgs += "-DCMAKE_PREFIX_PATH=$QtRoot" }
& cmake @configureArgs
& cmake --build $BuildDir --config Debug -j
& ctest --test-dir $BuildDir -C Debug --output-on-failure
