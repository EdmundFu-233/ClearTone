<#
.SYNOPSIS
  在 Windows 上构建并打包 ClearTone（Qt Widgets / C++）。
.PARAMETER Arch
  x64 | arm64 | all（默认 x64）。
.PARAMETER QtRoot
  Qt 安装前缀（其下含 lib\cmake\Qt6 与 bin\windeployqt.exe）。留空时按
  PATH 上的 qmake/windeployqt 自动探测。
.PARAMETER VlcRoot
  可选：libVLC SDK 根目录（含 include\ 与 lib\）。留空则使用 Qt Multimedia
  音频后端（Windows Media Foundation 解码）。
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\build-app.ps1 -Arch all -QtRoot C:\Qt\6.8.0\msvc2022_64
#>
param(
    [ValidateSet('x64', 'arm64', 'all')][string]$Arch = 'x64',
    [string]$QtRoot = '',
    # 交叉编译（x64 主机出 arm64 产物）时指向主机 Qt（x64）安装目录
    [string]$QtHostPath = '',
    [string]$VlcRoot = '',
    [string]$Generator = 'Visual Studio 17 2022',
    [ValidateSet('Debug', 'Release')][string]$BuildType = 'Release',
    [switch]$SkipNode
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WindowsDir = Split-Path -Parent $ScriptDir

function Resolve-QtRoot {
    param([string]$Explicit, [string]$TargetArch)
    if ($Explicit) { return $Explicit }
    $windeployqt = Get-Command windeployqt.exe -ErrorAction SilentlyContinue
    if ($windeployqt) { return (Split-Path -Parent $windeployqt.Source) }
    $kitPattern = if ($TargetArch -eq 'arm64') { 'arm64' } else { 'msvc\d+_64$' }
    $candidates = Get-ChildItem 'C:\Qt' -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d+\.\d+' } |
        Sort-Object Name -Descending
    foreach ($version in $candidates) {
        $kits = Get-ChildItem $version.FullName -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $kitPattern } |
            Sort-Object Name -Descending
        foreach ($kit in $kits) {
            if (Test-Path (Join-Path $kit.FullName 'bin\windeployqt.exe')) { return $kit.FullName }
        }
    }
    throw "未找到 Qt（$TargetArch）：请用 -QtRoot 指定（含 bin\windeployqt.exe）。"
}

function Fetch-Node {
    param([string]$TargetArch)
    if ($SkipNode) {
        $nodeExe = Join-Path $WindowsDir "runtime\win-$TargetArch\node.exe"
        if (-not (Test-Path $nodeExe)) { throw "缺少 $nodeExe，且指定了 -SkipNode" }
        return $nodeExe
    }
    return & (Join-Path $ScriptDir 'fetch-node-win.ps1') -Arch $TargetArch
}

function Build-One {
    param([string]$TargetArch)

    $buildDir = Join-Path $WindowsDir "build\win-$TargetArch"
    $publishDir = Join-Path $WindowsDir "publish\win-$TargetArch"
    $resolvedQt = Resolve-QtRoot -Explicit $QtRoot -TargetArch $TargetArch

    Write-Host "=== [$TargetArch] 1/5 准备辅助进程运行时 ==="
    $nodeExe = Fetch-Node -TargetArch $TargetArch

    $vsArch = if ($TargetArch -eq 'arm64') { 'ARM64' } else { 'x64' }
    $isNinja = $Generator -like 'Ninja*'

    Write-Host "=== [$TargetArch] 2/5 CMake 配置（$Generator，Qt: $resolvedQt）==="
    $configureArgs = @('-S', $WindowsDir, '-B', $buildDir, '-G', $Generator)
    if (-not $isNinja) { $configureArgs += @('-A', $vsArch) }
    $configureArgs += @(
        "-DCMAKE_PREFIX_PATH=$resolvedQt",
        '-DCT_BUILD_TESTS=OFF'
    )
    if ($isNinja) { $configureArgs += "-DCMAKE_BUILD_TYPE=$BuildType" }
    if ($QtHostPath) { $configureArgs += "-DQT_HOST_PATH=$QtHostPath" }
    if ($VlcRoot) { $configureArgs += "-DCT_VLC_ROOT=$VlcRoot" }
    & cmake @configureArgs

    Write-Host "=== [$TargetArch] 3/5 构建 ==="
    & cmake --build $buildDir --config $BuildType -j

    Write-Host "=== [$TargetArch] 4/5 windeployqt 与辅助进程 ==="
    if (Test-Path $publishDir) { Remove-Item -Recurse -Force $publishDir }
    New-Item -ItemType Directory -Force -Path $publishDir | Out-Null
    $exe = if ($isNinja) {
        Join-Path $buildDir 'ClearTone.exe'
    } else {
        Join-Path $buildDir "$BuildType\ClearTone.exe"
    }
    if (-not (Test-Path $exe)) { throw "缺少产物：$exe" }
    Copy-Item $exe $publishDir -Force

    # 交叉编译时必须用主机（x64）的 windeployqt，并用 --qtpaths 指向目标 Qt。
    $windeployqt = if ($QtHostPath) {
        Join-Path $QtHostPath 'bin\windeployqt.exe'
    } else {
        Join-Path $resolvedQt 'bin\windeployqt.exe'
    }
    if (-not (Test-Path $windeployqt)) { throw "缺少 $windeployqt" }
    $deployArgs = @('--release', '--no-translations', '--no-system-d3d-compiler', '--no-opengl-sw')
    if ($QtHostPath) { $deployArgs += @('--qtpaths', (Join-Path $resolvedQt 'bin\qtpaths.exe')) }
    $deployArgs += (Join-Path $publishDir 'ClearTone.exe')
    & $windeployqt @deployArgs

    $helperBin = Join-Path $publishDir 'helper\bin'
    $helperApi = Join-Path $publishDir 'helper\api'
    New-Item -ItemType Directory -Force -Path $helperBin | Out-Null
    Copy-Item $nodeExe (Join-Path $helperBin 'node.exe') -Force
    $apiSource = Join-Path (Split-Path -Parent $WindowsDir) 'ClearTone\Resources\HelperRuntime\api'
    if (-not (Test-Path (Join-Path $apiSource 'app.js'))) {
        throw "缺少辅助进程业务代码：$apiSource"
    }
    if (-not (Test-Path (Join-Path $apiSource 'node_modules'))) {
        throw "缺少 $apiSource\node_modules，请先在 ClearTone\Resources\HelperRuntime\api 下执行 npm ci --omit=dev --ignore-scripts"
    }
    Copy-Item $apiSource $helperApi -Recurse -Force

    if ($VlcRoot) {
        $vlcOut = Join-Path $publishDir 'libvlc'
        New-Item -ItemType Directory -Force -Path $vlcOut | Out-Null
        Get-ChildItem (Join-Path $VlcRoot 'lib') -Filter '*.dll' | Copy-Item -Destination $vlcOut
        if (Test-Path (Join-Path $VlcRoot 'plugins')) {
            Copy-Item (Join-Path $VlcRoot 'plugins') (Join-Path $vlcOut 'plugins') -Recurse -Force
        }
    }

    Write-Host "=== [$TargetArch] 5/5 打包 ==="
    $zipPath = Join-Path $WindowsDir "publish\ClearTone-win-$TargetArch.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Compress-Archive -Path (Join-Path $publishDir '*') -DestinationPath $zipPath
    Write-Host "完成：$zipPath"
}

if ($Arch -eq 'all') {
    Build-One -TargetArch 'x64'
    Build-One -TargetArch 'arm64'
} else {
    Build-One -TargetArch $Arch
}
