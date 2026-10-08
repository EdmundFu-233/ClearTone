# 构建 Windows 发布包（在 Windows 上运行）
# 用法：powershell -File scripts/build-app.ps1 [-Arch x64|arm64|all]
# 产物：windows\publish\win-<arch>\ 与 windows\publish\ClearTone-win-<arch>.zip
param([string]$Arch = "x64")
$ErrorActionPreference = "Stop"
if ($Arch -notin @("x64", "arm64", "all")) { throw "用法：build-app.ps1 [-Arch x64|arm64|all]" }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WindowsDir = Split-Path -Parent $ScriptDir

function Build-Arch([string]$TargetArch) {
    $PublishDir = Join-Path $WindowsDir "publish\win-$TargetArch"
    $RuntimeDir = Join-Path $WindowsDir "runtime\win-$TargetArch"
    $NodeExe = Join-Path $RuntimeDir "node.exe"

    Write-Host "=== [$TargetArch] 1/3 准备辅助进程运行时（win-$TargetArch node.exe） ==="
    New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
    if (-not (Test-Path $NodeExe)) {
        $Url = "https://nodejs.org/dist/v22.14.0/win-$TargetArch/node.exe"
        Write-Host "下载 $Url"
        Invoke-WebRequest -Uri $Url -OutFile $NodeExe
    } else {
        Write-Host "node.exe 已存在，跳过下载"
    }

    Write-Host "=== [$TargetArch] 2/3 dotnet publish (win-$TargetArch) ==="
    if (Test-Path $PublishDir) { Remove-Item -Recurse -Force $PublishDir }
    $vlcProps = @("-p:VlcWindowsX86Enabled=false")
    if ($TargetArch -eq "x64") {
        $vlcProps += "-p:VlcWindowsArm64Enabled=false"
    } else {
        $vlcProps += "-p:VlcWindowsX64Enabled=false"
    }
    dotnet publish (Join-Path $WindowsDir "src\ClearTone\ClearTone.csproj") `
        -c Release -f net8.0-windows10.0.19041.0 -r "win-$TargetArch" --self-contained true `
        -p:PublishSingleFile=false @vlcProps `
        -o $PublishDir
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish 失败" }

    Write-Host "=== [$TargetArch] 3/3 校验与打包 ==="
    $Required = @(
        "ClearTone.exe",
        "helper\bin\node.exe",
        "helper\api\app.js",
        "helper\api\server.js",
        "libvlc\win-$TargetArch\libvlc.dll"
    )
    foreach ($item in $Required) {
        $path = Join-Path $PublishDir $item
        if (-not (Test-Path $path)) {
            throw "缺少产物: $path"
        }
    }

    $ZipPath = Join-Path $WindowsDir "publish\ClearTone-win-$TargetArch.zip"
    if (Test-Path $ZipPath) { Remove-Item -Force $ZipPath }
    Compress-Archive -Path (Join-Path $PublishDir "*") -DestinationPath $ZipPath
    Write-Host "完成：$ZipPath"
}

if ($Arch -eq "all") {
    Build-Arch "x64"
    Build-Arch "arm64"
} else {
    Build-Arch $Arch
}
