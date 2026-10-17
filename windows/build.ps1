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
    [string]$QtHostPath = '',
    [string]$VlcRoot = '',
    [string]$Generator = '',
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
. (Join-Path $ScriptDir 'scripts\qt-toolchain.ps1')

if (-not $Arch) {
    $Arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
}
$Config = if ($Release) { 'Release' } else { 'Debug' }
$vsArch = if ($Arch -eq 'arm64') { 'ARM64' } else { 'x64' }
$QtRoot = Resolve-ClearToneQtRoot -Explicit $QtRoot -Arch $Arch
$isCrossArm = $Arch -eq 'arm64' -and $env:PROCESSOR_ARCHITECTURE -ne 'ARM64'
if ($isCrossArm -and -not $QtHostPath) {
    $hostKit = Get-ChildItem (Split-Path -Parent $QtRoot) -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^msvc\d+_64$' -and
            (Test-Path (Join-Path $_.FullName 'bin\windeployqt.exe')) } |
        Select-Object -First 1
    if (-not $hostKit) { throw 'ARM64 交叉编译需要同版本的 MSVC x64 主机 Qt kit（可用 -QtHostPath 指定）。' }
    $QtHostPath = $hostKit.FullName
    Write-Host "ARM64 交叉编译：使用主机 Qt $QtHostPath" -ForegroundColor Yellow
}
$isMinGW = Test-ClearToneMinGWKit -Kit $QtRoot
if ($isMinGW -and $Arch -ne 'x64') { throw 'Qt MinGW kit 仅支持 x64；ARM64 需要 Qt ARM64 + MSVC 工具链。' }
if (-not $Generator) { $Generator = if ($isMinGW) { 'Ninja' } else { 'Visual Studio 17 2022' } }
if ($isMinGW -and $Generator -ne 'Ninja') { throw 'Qt MinGW kit 请使用 Ninja 生成器（不要使用 Visual Studio 生成器）。' }
Initialize-ClearToneQtTools -Kit $QtRoot
if (-not $BuildDir) {
    $toolchain = if ($isMinGW) { 'mingw' } else { 'msvc' }
    $BuildDir = Join-Path $ScriptDir "build\$Arch-$($Config.ToLower())-$toolchain"
}

function Prepare-Helper {
    if ($SkipHelper) { return }
    Initialize-ClearToneRustTools
    Write-Host '=== [1/4] 编译 Rust 辅助进程 ===' -ForegroundColor Cyan
    $target = if ($Arch -eq 'arm64') { 'aarch64-pc-windows-msvc' } elseif ($isMinGW) { 'x86_64-pc-windows-gnu' } else { 'x86_64-pc-windows-msvc' }
    & rustup target add $target
    if ($LASTEXITCODE -ne 0) { throw "Rust target installation failed: $target" }
    & cargo build --manifest-path (Join-Path $ScriptDir 'helper\Cargo.toml') --locked --target $target
    if ($LASTEXITCODE -ne 0) { throw 'Rust helper build failed' }
    $env:CLEARTONE_HELPER_BINARY = Join-Path $ScriptDir "helper\target\$target\debug\cleartone-helper.exe"
}

function Invoke-Build {
    Write-Host "=== [2/4] CMake 配置（Qt: $QtRoot，$Arch / $Config）===" -ForegroundColor Cyan
    if ($Clean -and (Test-Path $BuildDir)) { Remove-Item -Recurse -Force $BuildDir }
    $isNinja = $Generator -like 'Ninja*'
    $cmakeArgs = @('-S', $ScriptDir, '-B', $BuildDir, '-G', $Generator)
    if (-not $isNinja) { $cmakeArgs += @('-A', $vsArch) }
    $cmakeArgs += "-DCMAKE_PREFIX_PATH=$QtRoot"
    if ($isNinja) { $cmakeArgs += "-DCMAKE_BUILD_TYPE=$Config" }
    if ($isMinGW) {
        $cmakeArgs += "-DCMAKE_C_COMPILER=$((Get-Command gcc.exe).Source)"
        $cmakeArgs += "-DCMAKE_CXX_COMPILER=$((Get-Command g++.exe).Source)"
    }
    if ($QtHostPath) { $cmakeArgs += "-DQT_HOST_PATH=$QtHostPath" }
    if ($VlcRoot) { $cmakeArgs += "-DCT_VLC_ROOT=$VlcRoot" }
    & cmake @cmakeArgs | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'CMake 配置失败' }

    Write-Host '=== [3/4] 构建 ===' -ForegroundColor Cyan
    & cmake --build $BuildDir --config $Config -j | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Qt 客户端构建失败' }
    return $(if ($isNinja) { Join-Path $BuildDir 'ClearTone.exe' } else { Join-Path $BuildDir "$Config\ClearTone.exe" })
}

# ---------------- 主流程 ----------------

if ($Package) {
    if (-not $Release) { Write-Host '提示：打包固定使用 Release 配置。' }
    & (Join-Path $ScriptDir 'scripts\build-app.ps1') -Arch $Arch -QtRoot $QtRoot -QtHostPath $QtHostPath `
        -VlcRoot $VlcRoot -Generator $Generator
    if ($LASTEXITCODE -ne 0) { throw '发布包构建失败' }
    return
}

Prepare-Helper
$exe = Invoke-Build

if ($Tests) {
    Write-Host '=== [4/4] 离线单测 ===' -ForegroundColor Cyan
    & ctest --test-dir $BuildDir -C $Config --output-on-failure
    if ($LASTEXITCODE -ne 0) { throw '离线单测失败' }
}

if ($Run) {
    Write-Host "启动 $exe"
    & $exe
}

Write-Host "完成：$exe" -ForegroundColor Green
