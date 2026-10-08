<#
.SYNOPSIS
  ClearTone（Windows / Qt）一键编译脚本：准备辅助进程 → CMake 配置 → 构建 →（可选）测试/运行/打包。
.EXAMPLE
  # 开发构建（Debug，自动探测 Qt）
  powershell -ExecutionPolicy Bypass -File build.ps1

.EXAMPLE
  # 构建并运行全部离线单测
  powershell -ExecutionPolicy Bypass -File build.ps1 -Tests

.EXAMPLE
  # 构建、打包 win-arm64 发布包（Release，含 Qt 运行库与 helper）
  powershell -ExecutionPolicy Bypass -File build.ps1 -Arch arm64 -Release -Package -QtRoot C:\Qt\6.8.0\msvc2022_arm64

.EXAMPLE
  # Release 构建并直接运行
  powershell -ExecutionPolicy Bypass -File build.ps1 -Release -Run
#>
param(
    [ValidateSet('x64', 'arm64')][string]$Arch = '',
    [string]$QtRoot = '',
    [string]$VlcRoot = '',
    [switch]$Release,
    [switch]$Tests,
    [switch]$Run,
    [switch]$Package,
    [switch]$Clean,
    [switch]$SkipHelper,
    [string]$BuildDir = ''
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir

if (-not $Arch) {
    $Arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
}
$Config = if ($Release) { 'Release' } else { 'Debug' }
$vsArch = if ($Arch -eq 'arm64') { 'ARM64' } else { 'x64' }
if (-not $BuildDir) { $BuildDir = Join-Path $ScriptDir "build\$Arch-$($Config.ToLower())" }

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
    throw "未找到 Qt（$TargetArch）：请用 -QtRoot 指定（含 bin\windeployqt.exe）；ARM64 需要 Qt 的 win64_msvc2022_arm64 包。"
}

function Prepare-Helper {
    if ($SkipHelper) { return }
    Write-Host '=== [1/4] 准备辅助进程运行时 ===' -ForegroundColor Cyan
    & (Join-Path $ScriptDir 'scripts\fetch-node-win.ps1') -Arch $Arch | Out-Null

    $apiDir = Join-Path $RepoRoot 'ClearTone\Resources\HelperRuntime\api'
    if (-not (Test-Path (Join-Path $apiDir 'app.js'))) {
        throw "缺少辅助进程业务代码：$apiDir"
    }
    if (-not (Test-Path (Join-Path $apiDir 'node_modules'))) {
        if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
            throw "缺少 $apiDir\node_modules，且未找到 npm；请安装 Node.js 后执行 npm ci --omit=dev --ignore-scripts"
        }
        Write-Host "安装 api 依赖（npm ci）..."
        Push-Location $apiDir
        try { & npm ci --omit=dev --ignore-scripts | Out-Host } finally { Pop-Location }
    }
}

function Invoke-Build {
    $QtRoot = Resolve-QtRoot -Explicit $QtRoot -TargetArch $Arch
    Write-Host "=== [2/4] CMake 配置（Qt: $QtRoot，$Arch / $Config）===" -ForegroundColor Cyan
    if ($Clean -and (Test-Path $BuildDir)) { Remove-Item -Recurse -Force $BuildDir }
    $cmakeArgs = @(
        '-S', $ScriptDir, '-B', $BuildDir,
        '-G', 'Visual Studio 17 2022', '-A', $vsArch,
        "-DCMAKE_PREFIX_PATH=$QtRoot"
    )
    if ($VlcRoot) { $cmakeArgs += "-DCT_VLC_ROOT=$VlcRoot" }
    & cmake @cmakeArgs | Out-Host

    Write-Host '=== [3/4] 构建 ===' -ForegroundColor Cyan
    & cmake --build $BuildDir --config $Config -j | Out-Host
    return (Join-Path $BuildDir "$Config\ClearTone.exe")
}

# ---------------- 主流程 ----------------

if ($Package) {
    if (-not $Release) { Write-Host '提示：打包固定使用 Release 配置。' }
    & (Join-Path $ScriptDir 'scripts\build-app.ps1') -Arch $Arch -QtRoot $QtRoot -VlcRoot $VlcRoot -SkipNode
    return
}

Prepare-Helper
$exe = Invoke-Build

if ($Tests) {
    Write-Host '=== [4/4] 离线单测 ===' -ForegroundColor Cyan
    & ctest --test-dir $BuildDir -C $Config --output-on-failure
}

if ($Run) {
    Write-Host "启动 $exe"
    & $exe
}

Write-Host "完成：$exe" -ForegroundColor Green
