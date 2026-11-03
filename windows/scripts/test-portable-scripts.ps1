param([Parameter(Mandatory = $true)][string]$AppPath)
$ErrorActionPreference = 'Stop'
$taskRoot = Join-Path ([IO.Path]::GetTempPath()) ("cleartone-shortcut-test-" + [guid]::NewGuid())
$taskApp = Join-Path $taskRoot "portable 测试 & ' [x] ! %"
$taskPrograms = Join-Path $taskRoot 'Programs 测试'
$previousPrograms = $env:CLEARTONE_TEST_START_MENU_DIR
try {
    [IO.Directory]::CreateDirectory($taskApp) | Out-Null
    [IO.Directory]::CreateDirectory($taskPrograms) | Out-Null
    Copy-Item -LiteralPath $AppPath -Destination (Join-Path $taskApp 'ClearTone.exe')
    foreach ($name in @('Add-to-Start-Menu.bat', 'Remove-from-Start-Menu.bat')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "portable\$name") -Destination $taskApp
    }
    [IO.File]::WriteAllText((Join-Path $taskApp 'data-sentinel'), 'keep')
    $env:CLEARTONE_TEST_START_MENU_DIR = $taskPrograms
    function Invoke-PortableScript {
        param([string]$Name, [int]$ExpectedExit = 0)
        $bat = Join-Path $taskApp $Name
        $arguments = '/d /s /c ""' + $bat + '" --quiet"'
        $process = Start-Process -FilePath $env:ComSpec -ArgumentList $arguments -WorkingDirectory $taskRoot -WindowStyle Hidden -PassThru -Wait
        if ($process.ExitCode -ne $ExpectedExit) { throw "$Name returned $($process.ExitCode), expected $ExpectedExit" }
    }
    Invoke-PortableScript 'Add-to-Start-Menu.bat'
    Invoke-PortableScript 'Add-to-Start-Menu.bat'
    $path = Join-Path $taskPrograms 'ClearTone.lnk'
    if (-not (Test-Path -LiteralPath $path)) { throw 'Shortcut was not created in the isolated Programs directory' }
    Invoke-PortableScript 'Remove-from-Start-Menu.bat'
    Invoke-PortableScript 'Remove-from-Start-Menu.bat'
    if (Test-Path -LiteralPath $path) { throw 'Shortcut was not removed' }
    if (-not (Test-Path -LiteralPath (Join-Path $taskApp 'data-sentinel'))) { throw 'Data was removed' }
    Remove-Item -LiteralPath (Join-Path $taskApp 'ClearTone.exe')
    Invoke-PortableScript 'Add-to-Start-Menu.bat' -ExpectedExit 1
    Write-Host 'Portable BAT scripts passed (Unicode paths and isolated Programs directory).'
} finally {
    $env:CLEARTONE_TEST_START_MENU_DIR = $previousPrograms
    $resolvedRoot = [IO.Path]::GetFullPath($taskRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($resolvedRoot) -eq $tempRoot -and
        [IO.Path]::GetFileName($resolvedRoot) -like 'cleartone-shortcut-test-*') {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
exit 0
