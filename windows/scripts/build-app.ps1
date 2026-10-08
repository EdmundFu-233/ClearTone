# 构建 Windows x64 发布包（在 Windows 上运行）
# 产物：windows\publish\win-x64\ 与 windows\publish\ClearTone-win-x64.zip
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WindowsDir = Split-Path -Parent $ScriptDir
$PublishDir = Join-Path $WindowsDir "publish\win-x64"
$RuntimeDir = Join-Path $WindowsDir "runtime"
$NodeExe = Join-Path $RuntimeDir "node.exe"

Write-Host "=== 1/3 准备辅助进程运行时（win-x64 node.exe） ==="
New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
if (-not (Test-Path $NodeExe)) {
    $Url = "https://nodejs.org/dist/v22.14.0/win-x64/node.exe"
    Write-Host "下载 $Url"
    Invoke-WebRequest -Uri $Url -OutFile $NodeExe
} else {
    Write-Host "node.exe 已存在，跳过下载"
}

Write-Host "=== 2/3 dotnet publish (win-x64) ==="
if (Test-Path $PublishDir) { Remove-Item -Recurse -Force $PublishDir }
dotnet publish (Join-Path $WindowsDir "src\ClearTone\ClearTone.csproj") `
    -c Release -f net8.0-windows10.0.19041.0 -r win-x64 --self-contained true `
    -p:PublishSingleFile=false `
    -o $PublishDir

Write-Host "=== 3/3 校验与打包 ==="
$Required = @(
    "ClearTone.exe",
    "helper\bin\node.exe",
    "helper\api\app.js",
    "helper\api\server.js"
)
foreach ($item in $Required) {
    $path = Join-Path $PublishDir $item
    if (-not (Test-Path $path)) {
        throw "缺少产物: $path"
    }
}

$ZipPath = Join-Path $WindowsDir "publish\ClearTone-win-x64.zip"
if (Test-Path $ZipPath) { Remove-Item -Force $ZipPath }
Compress-Archive -Path (Join-Path $PublishDir "*") -DestinationPath $ZipPath
Write-Host "完成：$ZipPath"
