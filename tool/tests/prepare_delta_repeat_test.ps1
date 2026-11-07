# 真实调用 Python 生成器两次；仅模拟 Android SDK 身份/资源边界，不联网/发布。
param([string]$PythonExe = '')
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $toolRoot
if (-not $PythonExe) { $PythonExe = Join-Path $repoRoot 'build/delta-venv/Scripts/python.exe' }
if (-not (Test-Path -LiteralPath $PythonExe -PathType Leaf)) { throw '请先安装 requirements-delta.txt，并传入 PythonExe。' }
$script:realPythonPath = $PythonExe
$buildRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'build')) + [IO.Path]::DirectorySeparatorChar
$fixtureDirectory = Join-Path $buildRoot ('delta-repeat-test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $fixtureDirectory | Out-Null
$script:realGeneratorCalls = 0
$script:generatorExitCodes = @()
function RealPython {
    $script:realGeneratorCalls++
    & $script:realPythonPath @args
    $script:generatorExitCodes += $LASTEXITCODE
}
try {
    $oldPath = Join-Path $fixtureDirectory 'old.apk'
    $newPath = Join-Path $fixtureDirectory 'new.apk'
    $oldBytes = [byte[]]::new(2000000)
    [Random]::new(42).NextBytes($oldBytes)
    $newBytes = [byte[]]::new(2100000)
    [Array]::Copy($oldBytes, $newBytes, $oldBytes.Length)
    [IO.File]::WriteAllBytes($oldPath, $oldBytes)
    [IO.File]::WriteAllBytes($newPath, $newBytes)
    $baseManifest = Join-Path $fixtureDirectory 'base.json'
    $baseline = @{ schemaVersion = 1; version = '2.4.0'; assets = @{ android = @{
        size = 2000000; sha256 = (Get-FileHash -LiteralPath $oldPath -Algorithm SHA256).Hash.ToLowerInvariant()
    } } }
    [IO.File]::WriteAllText($baseManifest, ($baseline | ConvertTo-Json -Depth 6))
    $scriptPath = Join-Path $toolRoot 'publish_plai_update.ps1'
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
    $source = [IO.File]::ReadAllText($scriptPath)
    foreach ($functionName in @('Get-ApkIdentity', 'Assert-RequiredResourcesPresent')) {
        $original = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $functionName }, $false)
        $replacement = if ($functionName -eq 'Get-ApkIdentity') {
            "function Get-ApkIdentity { param(`$ApkPath) if (`$ApkPath -eq '$($oldPath.Replace("'", "''"))') { return @{version='2.4.0';versionCode=25} }; return @{version='2.5.0';versionCode=26} }"
        } else { 'function Assert-RequiredResourcesPresent { param($ApkPath,$RequiredResources) }' }
        $source = $source.Replace($original.Extent.Text, $replacement)
    }
    $source = $source.Replace('$PSScriptRoot', ("'" + $toolRoot.Replace("'", "''") + "'"))
    $entry = [scriptblock]::Create($source)
    $previewPath = Join-Path $fixtureDirectory 'preview.json'
    $patchPath = Join-Path $fixtureDirectory 'Plai-android-2.4.0-to-2.5.0.patch'
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        if ($attempt -eq 2 -and -not (Test-Path -LiteralPath ($patchPath + '.json'))) { throw '第一次必须实际生成sidecar才能验证重复准备。' }
        & $entry -Version '2.5.0' -AndroidApk $newPath -PrepareOnly -ManifestOutput $previewPath `
            -BaseApk $oldPath -BaseVersion '2.4.0' -BaseManifest $baseManifest -PythonExe 'RealPython'
        $preview = Get-Content -LiteralPath $previewPath -Raw | ConvertFrom-Json
        if ($preview.assets.android.delta.format -ne 'plai-bsdiff-gzip-v1') { throw "第${attempt}次真实生成应保留增量，不能静默全量。" }
        $metadata = Get-Content -LiteralPath ($patchPath + '.json') -Raw | ConvertFrom-Json
        if ($metadata.targetSha256 -ne (Get-FileHash -LiteralPath $newPath -Algorithm SHA256).Hash.ToLowerInvariant()) { throw 'sidecar必须由本次真实生成器重新产生。' }
        if ($attempt -eq 1) { [IO.File]::WriteAllText(($patchPath + '.json'), '{"stale":true}') }
    }
    if ($realGeneratorCalls -ne 2 -or $generatorExitCodes.Count -ne 2 -or @($generatorExitCodes | Where-Object { $_ -ne 0 }).Count) {
        throw '必须两次都实际执行Python生成器并成功完成--verify。'
    }
    Write-Output 'PASS: two real PrepareOnly generations with existing patch sidecar'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixtureDirectory)
    if (-not $resolved.StartsWith($buildRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected fixture cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
