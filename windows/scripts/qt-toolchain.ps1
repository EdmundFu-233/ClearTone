# Shared Qt kit discovery for the development and release builds.
function Resolve-ClearToneQtRoot {
    param([string]$Explicit, [string]$Arch)

    if ($Explicit) {
        $kit = (Resolve-Path $Explicit -ErrorAction Stop).Path
        if (-not (Test-Path (Join-Path $kit 'bin\windeployqt.exe'))) {
            throw "Qt kit 无效：$kit（缺少 bin\windeployqt.exe）"
        }
        return $kit
    }

    $versions = @('C:\Qt', 'D:\Qt') | ForEach-Object {
        Get-ChildItem $_ -Directory -ErrorAction SilentlyContinue
    } |
        Where-Object { $_.Name -match '^\d+\.\d+(\.\d+)?$' } |
        Sort-Object { [version]$_.Name } -Descending
    foreach ($version in $versions) {
        $kits = Get-ChildItem $version.FullName -Directory -ErrorAction SilentlyContinue
        if ($Arch -eq 'arm64') {
            $kits = $kits | Where-Object { $_.Name -match 'arm64|aarch64' }
        } else {
            # Prefer the MinGW kit when both MinGW and MSVC are installed.
            $kits = $kits | Where-Object { $_.Name -match '^mingw.*64$|^msvc\d+_64$' } |
                Sort-Object { if ($_.Name -match '^mingw') { 0 } else { 1 } }
        }
        foreach ($kit in $kits) {
            if (Test-Path (Join-Path $kit.FullName 'bin\windeployqt.exe')) { return $kit.FullName }
        }
    }
    $command = Get-Command windeployqt.exe -ErrorAction SilentlyContinue
    if ($command) {
        $kit = Split-Path -Parent (Split-Path -Parent $command.Source)
        if ($Arch -eq 'arm64' -and $kit -match 'arm64|aarch64') { return $kit }
        if ($Arch -eq 'x64' -and $kit -notmatch 'arm64|aarch64') { return $kit }
    }
    throw "未找到 Qt（$Arch）。x64 请安装 Qt 6.12.0 的 MinGW 13.1.0 64-bit kit，或用 -QtRoot 指定安装目录。"
}

function Initialize-ClearToneQtTools {
    param([string]$Kit)

    $env:PATH = "$(Join-Path $Kit 'bin');$env:PATH"
    if (-not $env:QT_PLUGIN_PATH) { $env:QT_PLUGIN_PATH = Join-Path $Kit 'plugins' }
    if ($Kit -match '[\\/]mingw[^\\/]*$') {
        $root = Split-Path -Parent (Split-Path -Parent $Kit)
        $tools = Join-Path $root 'Tools'
        $compilers = Get-ChildItem $tools -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^mingw.*_64$' -and (Test-Path (Join-Path $_.FullName 'bin\g++.exe')) } |
            Sort-Object Name -Descending
        if (-not $compilers) {
            throw '缺少 MinGW 编译器。请在 Qt Online Installer 的 Build Tools 下勾选 MinGW 13.1.0 64-bit。'
        }
        # Qt 6.12 MinGW 13.1 kit uses mingw1310_64; prefer that over other installed toolchains.
        $compiler = $compilers | Where-Object { $_.Name -eq 'mingw1310_64' } | Select-Object -First 1
        if (-not $compiler) { $compiler = $compilers | Select-Object -First 1 }
        $env:PATH = "$(Join-Path $compiler.FullName 'bin');$env:PATH"

        foreach ($path in @((Join-Path $tools 'CMake_64\bin'), (Join-Path $tools 'Ninja'))) {
            if (Test-Path $path) { $env:PATH = "$path;$env:PATH" }
        }
        if (-not (Get-Command ninja.exe -ErrorAction SilentlyContinue)) {
            throw '缺少 Ninja。请在 Qt Online Installer 的 Build Tools 下勾选 Ninja。'
        }
    }
    if (-not (Get-Command cmake.exe -ErrorAction SilentlyContinue)) {
        throw '缺少 CMake。请在 Qt Online Installer 的 Build Tools 下勾选 CMake。'
    }
}

function Test-ClearToneMinGWKit {
    param([string]$Kit)
    return ($Kit -match '[\\/]mingw[^\\/]*$')
}

function Initialize-ClearToneRustTools {
    if (-not (Get-Command cargo.exe -ErrorAction SilentlyContinue) -or
        -not (Get-Command rustup.exe -ErrorAction SilentlyContinue)) {
        $cargoBin = Join-Path $HOME '.cargo\bin'
        if (Test-Path (Join-Path $cargoBin 'rustup.exe')) {
            $env:PATH = "$cargoBin;$env:PATH"
        }
    }
    if (-not (Get-Command cargo.exe -ErrorAction SilentlyContinue) -or
        -not (Get-Command rustup.exe -ErrorAction SilentlyContinue)) {
        throw '缺少 Rust（cargo / rustup）。请安装 rustup，或将 ~/.cargo/bin 加入 PATH。'
    }
}
