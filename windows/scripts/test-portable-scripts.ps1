$ErrorActionPreference = 'Stop'
$taskRoot = Join-Path ([IO.Path]::GetTempPath()) ("cleartone-shortcut-test-" + [guid]::NewGuid())
$taskApp = Join-Path $taskRoot "portable 测试 & ' [x] ! %"
$taskPrograms = Join-Path $taskRoot 'Programs'
$previousRoot = $env:CT_PORTABLE_ROOT
$previousPrograms = $env:CT_TEST_PROGRAMS
try {
    New-Item -ItemType Directory -Path $taskApp, $taskPrograms | Out-Null
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\cmd.exe') -Destination (Join-Path $taskApp 'ClearTone.exe')
    [IO.File]::WriteAllText((Join-Path $taskApp 'data-sentinel'), 'keep')
    $env:CT_PORTABLE_ROOT = $taskApp
    $env:CT_TEST_PROGRAMS = $taskPrograms
    $probeShell = New-Object -ComObject WScript.Shell
    foreach ($probeName in @('plain', 'with space', '测试', 'with &', "with '", 'with [x]', 'with !', 'with %')) {
        $probeDirectory = Join-Path $taskRoot $probeName
        [IO.Directory]::CreateDirectory($probeDirectory) | Out-Null
        $probeExe = Join-Path $probeDirectory 'ClearTone.exe'
        Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\cmd.exe') -Destination $probeExe
        $probeLink = $probeShell.CreateShortcut((Join-Path $taskPrograms 'probe.lnk'))
        try { $probeLink.TargetPath = $probeExe; Write-Host "TargetPath probe [$probeName]: passed" }
        catch { Write-Host "TargetPath probe [$probeName]: $($_.Exception.Message)" }
    }

    function Invoke-PortableScript {
        param([string]$Name, [int]$ExpectedExit = 0)
        $lines = Get-Content -LiteralPath (Join-Path $PSScriptRoot "portable\$Name")
        $command = $lines | Where-Object { $_ -match '^powershell.exe .* -Command "(.*)"$' }
        if (-not $command -or $command -notmatch ' -Command "(.*)"$') { throw "Missing PowerShell command in $Name" }
        $body = $Matches[1]
        $tokens = $null
        $errors = $null
        [Management.Automation.Language.Parser]::ParseInput($body, [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors) { throw "$Name contains a PowerShell syntax error: $errors" }
        $lookup = "[Environment]::GetFolderPath('Programs')"
        if (-not $body.Contains($lookup)) { throw "$Name no longer uses the expected current-user folder lookup" }
        $body = $body.Replace($lookup, '$env:CT_TEST_PROGRAMS')
        $body = $body.Replace('Write-Host $_ -ForegroundColor Red', 'Write-Host $_.Exception.ToString(); Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor Red')
        $body = '$ProgressPreference = ''SilentlyContinue''; ' + $body.Replace(';', ";`n")
        $body = $body.Replace('$link.TargetPath = $exe', 'Write-Host (''Setting target: '' + $exe); $link.TargetPath = $exe')
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
        & powershell.exe -NoLogo -NoProfile -NonInteractive -OutputFormat Text -ExecutionPolicy Bypass -EncodedCommand $encoded
        if ($LASTEXITCODE -ne $ExpectedExit) { throw "$Name returned $LASTEXITCODE, expected $ExpectedExit" }
    }

    Invoke-PortableScript 'Add-to-Start-Menu.bat'
    Invoke-PortableScript 'Add-to-Start-Menu.bat'
    $path = Join-Path $taskPrograms 'ClearTone.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($path)
    if ($link.TargetPath -ne (Join-Path $taskApp 'ClearTone.exe') -or
        $link.WorkingDirectory.TrimEnd('\') -ne $taskApp -or
        $link.IconLocation -ne ((Join-Path $taskApp 'ClearTone.exe') + ',0')) {
        throw 'Shortcut target, working directory or icon is incorrect'
    }
    Invoke-PortableScript 'Remove-from-Start-Menu.bat'
    Invoke-PortableScript 'Remove-from-Start-Menu.bat'
    if (Test-Path -LiteralPath $path) { throw 'Shortcut was not removed' }
    if (-not (Test-Path -LiteralPath (Join-Path $taskApp 'data-sentinel'))) { throw 'Data was removed' }
    $env:CT_PORTABLE_ROOT = $taskRoot
    Invoke-PortableScript 'Add-to-Start-Menu.bat' -ExpectedExit 1
    Write-Host 'Portable shortcut scripts passed (isolated Programs directory).'
} finally {
    $env:CT_PORTABLE_ROOT = $previousRoot
    $env:CT_TEST_PROGRAMS = $previousPrograms
    $resolvedRoot = [IO.Path]::GetFullPath($taskRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($resolvedRoot) -eq $tempRoot -and
        [IO.Path]::GetFileName($resolvedRoot) -like 'cleartone-shortcut-test-*') {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
exit 0
