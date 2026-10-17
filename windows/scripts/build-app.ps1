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
   powershell -ExecutionPolicy Bypass -File scripts\build-app.ps1 -Arch x64 -QtRoot C:\Qt\6.12.0\mingw_64
#>
param(
    [ValidateSet('x64', 'arm64', 'all')][string]$Arch = 'x64',
    [string]$QtRoot = '',
    # 交叉编译（x64 主机出 arm64 产物）时指向主机 Qt（x64）安装目录
    [string]$QtHostPath = '',
    [string]$VlcRoot = '',
    [string]$Generator = '',
    [ValidateSet('Debug', 'Release')][string]$BuildType = 'Release'
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WindowsDir = Split-Path -Parent $ScriptDir
. (Join-Path $ScriptDir 'qt-toolchain.ps1')

# 交叉编译（x64 主机 → arm64 目标）时的运行库部署。
# 清单与 x64 上 windeployqt 的输出保持一致（见 CI 的“列出产物内容”）。
function Get-PeMachine {
    param([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 0x40) { throw "无效 PE 文件：$Path" }
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
    if ($peOffset -le 0 -or ($peOffset + 6) -gt $bytes.Length -or
        $bytes[$peOffset] -ne 0x50 -or $bytes[$peOffset + 1] -ne 0x45) {
        throw "无效 PE 文件：$Path"
    }
    return [BitConverter]::ToUInt16($bytes, $peOffset + 4)
}

function Deploy-CrossRuntime {
    param([string]$TargetQt, [string]$Destination)

    $targetBin = Join-Path $TargetQt 'bin'
    # Ship all target Qt libraries: Multimedia and its transitive Qt dependencies
    # change between Qt versions, and host windeployqt cannot inspect ARM64 qtpaths.
    $runtimeDlls = Get-ChildItem $targetBin -Filter 'Qt6*.dll' -File |
        Where-Object { $_.Name -notmatch 'd\.dll$' } | Select-Object -ExpandProperty Name
    foreach ($name in @('Qt6Core.dll', 'Qt6Gui.dll', 'Qt6Widgets.dll', 'Qt6Network.dll', 'Qt6Svg.dll')) {
        if ($runtimeDlls -notcontains $name) { throw "缺少目标 Qt 运行库：$name" }
    }
    foreach ($name in $runtimeDlls) {
        $source = Join-Path $targetBin $name
        if (-not (Test-Path $source)) { throw "缺少目标 Qt 运行库：$source" }
        Copy-Item $source $Destination -Force
    }
    foreach ($pattern in @('dxcompiler.dll', 'dxil.dll', 'av*.dll', 'sw*.dll')) {
        Get-ChildItem $targetBin -Filter $pattern -File -ErrorAction SilentlyContinue |
            Copy-Item -Destination $Destination -Force
    }
    foreach ($category in @('platforms', 'styles', 'imageformats', 'iconengines',
                            'networkinformation', 'tls', 'generic', 'multimedia')) {
        $source = Join-Path $TargetQt "plugins\$category"
        if (Test-Path $source) {
            $target = Join-Path $Destination $category
            Copy-Item $source $target -Recurse -Force
            # 目标包同时带 debug 插件（qxxxd.dll），发布包只留 release
            foreach ($file in Get-ChildItem $target -Filter '*.dll' -File -ErrorAction SilentlyContinue) {
                if ($file.Name -match 'd\.dll$') {
                    Remove-Item $file.FullName -Force
                }
            }
        }
    }
    if (-not (Test-Path (Join-Path $Destination 'platforms\qwindows.dll'))) {
        throw '交叉部署缺少 platforms\qwindows.dll'
    }

    # MSVC ARM64 运行库（避免要求目标机预装 VC++ Redistributable）
    $vsWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vsWhere) {
        $vsRoot = & $vsWhere -latest -property installationPath | Select-Object -First 1
        if ($vsRoot) {
            $redistRoot = Join-Path $vsRoot 'VC\Redist\MSVC'
            $crt = Get-ChildItem $redistRoot -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending |
                ForEach-Object {
                    Get-ChildItem (Join-Path $_.FullName 'arm64') -Directory -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -like 'Microsoft.VC*.CRT' }
                } | Select-Object -First 1
            if ($crt) {
                # Some VS redist directories also contain x64 helper DLLs (notably
                # vcruntime140_1.dll). Never let them overwrite ARM64 Qt dependencies.
                foreach ($file in Get-ChildItem $crt.FullName -Filter '*.dll' -File) {
                    if ((Get-PeMachine -Path $file.FullName) -eq 0xAA64) {
                        Copy-Item $file.FullName $Destination -Force
                    }
                }
                foreach ($name in @('vcruntime140.dll', 'msvcp140.dll')) {
                    if (-not (Test-Path (Join-Path $Destination $name))) {
                        throw "缺少 ARM64 MSVC 运行库：$name"
                    }
                }
            } else {
                $redistExe = Get-ChildItem $redistRoot -Recurse -Filter 'vc_redist.arm64.exe' -ErrorAction SilentlyContinue |
                    Select-Object -First 1
                if ($redistExe) {
                    Copy-Item $redistExe.FullName $Destination -Force
                } else {
                    Write-Warning '未找到 ARM64 MSVC 运行库，目标机需要安装 VC++ Redistributable (ARM64)。'
                }
            }
        }
    }

}

function Assert-PackageArchitecture {
    param([string]$Destination, [string]$TargetArch)

    $expected = if ($TargetArch -eq 'arm64') { 0xAA64 } else { 0x8664 }
    foreach ($file in Get-ChildItem $Destination -Recurse -File |
        Where-Object { $_.Extension -in @('.dll', '.exe') }) {
        $machine = Get-PeMachine -Path $file.FullName
        if ($machine -ne $expected) {
            throw ("发布包架构不匹配：{0} (machine=0x{1:X4}, expected=0x{2:X4})" -f $file.FullName, $machine, $expected)
        }
    }
}

function Build-One {
    param([string]$TargetArch)

    $resolvedQt = Resolve-ClearToneQtRoot -Explicit $QtRoot -Arch $TargetArch
    if ($TargetArch -eq 'arm64' -and $env:PROCESSOR_ARCHITECTURE -ne 'ARM64') {
        if (-not $QtHostPath) { throw '从 x64 交叉构建 ARM64 需要 -QtHostPath（同版本 MSVC x64 Qt kit）。' }
        $resolvedHost = Resolve-ClearToneQtRoot -Explicit $QtHostPath -Arch 'x64'
        if ((Split-Path -Parent $resolvedHost) -ne (Split-Path -Parent $resolvedQt)) {
            throw 'ARM64 目标 Qt 与 x64 主机 Qt 必须使用相同版本。'
        }
    }
    $isMinGW = Test-ClearToneMinGWKit -Kit $resolvedQt
    if ($isMinGW -and $TargetArch -ne 'x64') { throw 'Qt MinGW kit 仅支持 x64。' }
    $selectedGenerator = if ($Generator) { $Generator } elseif ($isMinGW) { 'Ninja' } else { 'Visual Studio 17 2022' }
    if ($isMinGW -and $selectedGenerator -ne 'Ninja') { throw 'Qt MinGW kit 请使用 Ninja 生成器。' }
    Initialize-ClearToneQtTools -Kit $(if ($TargetArch -eq 'arm64' -and $QtHostPath) { $QtHostPath } else { $resolvedQt })

    $flavor = if ($isMinGW) { 'mingw' } else { 'msvc' }
    $buildDir = Join-Path $WindowsDir "build\win-$TargetArch-$flavor-$($BuildType.ToLower())"
    $publishDir = Join-Path $WindowsDir "publish\win-$TargetArch"

    Write-Host "=== [$TargetArch] 1/5 编译 Rust 辅助进程 ==="
    Initialize-ClearToneRustTools
    $rustTarget = if ($TargetArch -eq 'arm64') { 'aarch64-pc-windows-msvc' } elseif ($isMinGW) { 'x86_64-pc-windows-gnu' } else { 'x86_64-pc-windows-msvc' }
    & rustup target add $rustTarget
    if ($LASTEXITCODE -ne 0) { throw "rustup target add $rustTarget failed" }
    & cargo build --manifest-path (Join-Path $WindowsDir 'helper\Cargo.toml') --release --locked --target $rustTarget
    if ($LASTEXITCODE -ne 0) { throw "Rust helper build failed for $rustTarget" }
    $helperExe = Join-Path $WindowsDir "helper\target\$rustTarget\release\cleartone-helper.exe"
    if (-not (Test-Path $helperExe)) { throw "缺少产物：$helperExe" }

    $vsArch = if ($TargetArch -eq 'arm64') { 'ARM64' } else { 'x64' }
    $isNinja = $selectedGenerator -like 'Ninja*'

    Write-Host "=== [$TargetArch] 2/5 CMake 配置（$selectedGenerator，Qt: $resolvedQt）==="
    $configureArgs = @('-S', $WindowsDir, '-B', $buildDir, '-G', $selectedGenerator)
    if (-not $isNinja) { $configureArgs += @('-A', $vsArch) }
    $configureArgs += @(
        "-DCMAKE_PREFIX_PATH=$resolvedQt",
        '-DCT_BUILD_TESTS=OFF'
    )
    if ($isNinja) { $configureArgs += "-DCMAKE_BUILD_TYPE=$BuildType" }
    if ($isMinGW) {
        $configureArgs += "-DCMAKE_C_COMPILER=$((Get-Command gcc.exe).Source)"
        $configureArgs += "-DCMAKE_CXX_COMPILER=$((Get-Command g++.exe).Source)"
    }
    if ($QtHostPath) { $configureArgs += "-DQT_HOST_PATH=$QtHostPath" }
    if ($VlcRoot) { $configureArgs += "-DCT_VLC_ROOT=$VlcRoot" }
    & cmake @configureArgs
    if ($LASTEXITCODE -ne 0) { throw "CMake 配置失败：$TargetArch" }

    Write-Host "=== [$TargetArch] 3/5 构建 ==="
    & cmake --build $buildDir --config $BuildType -j
    if ($LASTEXITCODE -ne 0) { throw "Qt 客户端构建失败：$TargetArch" }

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

    if ($QtHostPath) {
        # 交叉包没有可在 x64 主机运行的 qtpaths，主机 windeployqt 无法解析目标 Qt；
        # 按 x64 windeployqt 的部署清单手动部署目标运行库与插件。
        Deploy-CrossRuntime -TargetQt $resolvedQt -Destination $publishDir
    } else {
        $windeployqt = Join-Path $resolvedQt 'bin\windeployqt.exe'
        if (-not (Test-Path $windeployqt)) { throw "缺少 $windeployqt" }
        $deployArgs = @('--release', '--no-translations', '--no-system-d3d-compiler', '--no-opengl-sw')
        if ($isMinGW) { $deployArgs += '--compiler-runtime' }
        & $windeployqt @deployArgs (Join-Path $publishDir 'ClearTone.exe')
        if ($LASTEXITCODE -ne 0) { throw "windeployqt 失败：$TargetArch" }
        if ($isMinGW) {
            $compilerBin = Split-Path -Parent (Get-Command g++.exe).Source
            foreach ($dll in @('libgcc_s_seh-1.dll', 'libstdc++-6.dll', 'libwinpthread-1.dll')) {
                $source = Join-Path $compilerBin $dll
                if (-not (Test-Path $source)) { throw "缺少 MinGW 运行库：$source" }
                Copy-Item $source $publishDir -Force
            }
        }
    }

    $helperDir = Join-Path $publishDir 'helper'
    New-Item -ItemType Directory -Force -Path $helperDir | Out-Null
    Copy-Item $helperExe (Join-Path $helperDir 'cleartone-helper.exe') -Force

    if ($VlcRoot) {
        $vlcOut = Join-Path $publishDir 'libvlc'
        New-Item -ItemType Directory -Force -Path $vlcOut | Out-Null
        Get-ChildItem (Join-Path $VlcRoot 'lib') -Filter '*.dll' | Copy-Item -Destination $vlcOut
        if (Test-Path (Join-Path $VlcRoot 'plugins')) {
            Copy-Item (Join-Path $VlcRoot 'plugins') (Join-Path $vlcOut 'plugins') -Recurse -Force
        }
    }

    Assert-PackageArchitecture -Destination $publishDir -TargetArch $TargetArch

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
