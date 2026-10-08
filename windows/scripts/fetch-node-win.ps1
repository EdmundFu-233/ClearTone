<#
.SYNOPSIS
  下载 Node.js v22.14.0（win-x64 / win-arm64）到 windows\runtime\win-<arch>\node.exe。
  已存在时直接复用。
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\fetch-node-win.ps1 -Arch arm64
#>
param(
    [ValidateSet('x64', 'arm64')][string]$Arch = 'x64',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$NodeVersion = '22.14.0'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WindowsDir = Split-Path -Parent $ScriptDir
$destination = Join-Path $WindowsDir "runtime\win-$Arch"
$nodeExe = Join-Path $destination 'node.exe'

if ((Test-Path $nodeExe) -and -not $Force) {
    Write-Host "Node.js 已存在：$nodeExe"
    return $nodeExe
}

New-Item -ItemType Directory -Force -Path $destination | Out-Null
$url = "https://nodejs.org/dist/v$NodeVersion/node-v$NodeVersion-win-$Arch.zip"
$zip = Join-Path $env:TEMP "node-v$NodeVersion-win-$Arch.zip"
$extract = Join-Path $env:TEMP "node-v$NodeVersion-win-$Arch"

Write-Host "下载 Node.js v$NodeVersion ($Arch)..."
Invoke-WebRequest -Uri $url -OutFile $zip
if (Test-Path $extract) { Remove-Item -Recurse -Force $extract }
Expand-Archive -Path $zip -DestinationPath $extract
Copy-Item (Join-Path $extract "node-v$NodeVersion-win-$Arch\node.exe") $nodeExe -Force
Remove-Item -Recurse -Force $extract
Remove-Item $zip
Write-Host "完成：$nodeExe"
return $nodeExe
