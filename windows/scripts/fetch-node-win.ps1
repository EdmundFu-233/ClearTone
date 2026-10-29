<#
.SYNOPSIS
  下载 Node.js v22.23.4（win-x64 / win-arm64）到 windows\runtime\win-<arch>\node.exe。
  已存在时直接复用。
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\fetch-node-win.ps1 -Arch arm64
#>
param(
    [ValidateSet('x64', 'arm64')][string]$Arch = 'x64',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$NodeVersion = '22.23.4'
# 来自 https://nodejs.org/dist/v22.23.4/SHASUMS256.txt
$ZipSha256 = @{
    'x64'   = 'cbc74b5e0982c9dbb41525fd8fb5dcd32fbee237863f7829072f4639a1ce5f20'
    'arm64' = 'a8b8cd79cbbb3062435f449591d98dd63730bbbf30ce2d7cc3a6376c236cb111'
}[$Arch]
$ExeSha256 = @{
    'x64'   = 'dccc52de28d8df2ee22d2062424f8c563070d95d8ad70c54c4bf01d590dec14f'
    'arm64' = '64d9f6e69b4703870e8cd30a3477127df8b683ea04feb03660e439396549042a'
}[$Arch]

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WindowsDir = Split-Path -Parent $ScriptDir
$destination = Join-Path $WindowsDir "runtime\win-$Arch"
$nodeExe = Join-Path $destination 'node.exe'

if ((Test-Path $nodeExe) -and -not $Force) {
    $existing = (Get-FileHash -Algorithm SHA256 -Path $nodeExe).Hash.ToLowerInvariant()
    if ($existing -eq $ExeSha256) {
        Write-Host "Node.js 已存在且哈希匹配：$nodeExe"
        return $nodeExe
    }
    Write-Host "现有 node.exe 版本/哈希不匹配，重新下载"
}

New-Item -ItemType Directory -Force -Path $destination | Out-Null
$url = "https://nodejs.org/dist/v$NodeVersion/node-v$NodeVersion-win-$Arch.zip"
$zip = Join-Path $env:TEMP "node-v$NodeVersion-win-$Arch.zip"
$extract = Join-Path $env:TEMP "node-v$NodeVersion-win-$Arch"

Write-Host "下载 Node.js v$NodeVersion ($Arch)..."
Invoke-WebRequest -Uri $url -OutFile $zip
$actual = (Get-FileHash -Algorithm SHA256 -Path $zip).Hash.ToLowerInvariant()
if ($actual -ne $ZipSha256) {
    Remove-Item -Force $zip
    throw "Node.js 安装包 SHA256 不匹配：期望 $ZipSha256，实际 $actual"
}
if (Test-Path $extract) { Remove-Item -Recurse -Force $extract }
Expand-Archive -Path $zip -DestinationPath $extract
Copy-Item (Join-Path $extract "node-v$NodeVersion-win-$Arch\node.exe") $nodeExe -Force
Remove-Item -Recurse -Force $extract
Remove-Item $zip
Write-Host "完成：$nodeExe"
return $nodeExe
