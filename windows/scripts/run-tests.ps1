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
& (Join-Path $WindowsDir 'build.ps1') -Tests -BuildDir $BuildDir -QtRoot $QtRoot
if ($LASTEXITCODE -ne 0) { throw 'Windows 离线单测失败' }
