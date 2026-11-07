# 无需 SDK、私钥、网络或第三方 Python。真正的编解码逐字节验证由 Python/Dart 测试覆盖。
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $toolRoot 'publish_plai_update.ps1'
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
# 只加载实际函数定义，避免入口的 SDK 检查/SSH。下面仅替换外部工具边界。
foreach ($node in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    # 脱离原脚本AST后PSScriptRoot为空，固定为被测脚本的真实目录。
    $definition = $node.Extent.Text.Replace('$PSScriptRoot', ("'" + $toolRoot.Replace("'", "''") + "'"))
    . ([scriptblock]::Create($definition))
}
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('plai-delta-test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $testDirectory | Out-Null
$script:passed = 0
function Assert-True($condition, $description) { if (-not $condition) { throw $description }; $script:passed++ }
function Get-ApkIdentity([string]$ApkPath) {
    if ($script:badIdentity) { throw 'wrong APK signature' }
    if ($ApkPath -eq $script:oldPath) { return @{ version = '2.4.0'; versionCode = 25 } }
    return @{ version = '2.5.0'; versionCode = $script:newCode }
}
function FakePython {
    $script:generatorCalls++
    if ($script:generatorMode -eq 'fail') { $global:LASTEXITCODE = 1; return }
    if ($args -notcontains '--verify') { throw 'Missing --verify' }
    $index = [array]::IndexOf($args, '--output')
    $patchFile = $args[$index + 1]
    $count = if ($script:generatorMode -eq 'large') { 1800000 } else { 128 }
    [IO.File]::WriteAllBytes($patchFile, [byte[]]::new($count))
    $global:LASTEXITCODE = 0
}
function curl.exe {
    $script:curlCalls++
    if ($script:curlFailure) { $global:LASTEXITCODE = 22; return }
    if ($args[-1] -ne 'https://example.invalid/downloads/plai/latest.json') { throw 'Unexpected network endpoint' }
    $global:LASTEXITCODE = 0
    return $script:baselineJson
}
function ssh { $script:sshCommands += ($args -join ' '); $global:LASTEXITCODE = 0 }
function scp {
    $script:uploadArguments = @($args)
    $manifestArgument = $args | Where-Object { $_ -is [string] -and $_.EndsWith('latest.json') } | Select-Object -First 1
    $script:publishedManifest = Get-Content -LiteralPath $manifestArgument -Raw | ConvertFrom-Json
    $global:LASTEXITCODE = 0
}
try {
    $script:oldPath = Join-Path $testDirectory 'old.apk'
    $newPath = Join-Path $testDirectory 'new.apk'
    [IO.File]::WriteAllBytes($oldPath, [byte[]]::new(2000000))
    [IO.File]::WriteAllBytes($newPath, [byte[]]::new(2100000))
    $oldAsset = Get-Asset $oldPath
    $newAsset = Get-Asset $newPath
    $baseline = @{ schemaVersion = 1; version = '2.4.0'; assets = @{ android = $oldAsset } }
    $script:baselineJson = $baseline | ConvertTo-Json -Depth 8
    $baselinePath = Join-Path $testDirectory 'base-manifest.json'
    [IO.File]::WriteAllText($baselinePath, $baselineJson)
    $script:curlCalls = 0
    $offline = Get-PreviousReleaseManifest 'example.invalid' $baselinePath
    Assert-True ($offline.version -eq '2.4.0' -and $curlCalls -eq 0) '离线基线不应请求网络'
    $live = Get-PreviousReleaseManifest 'example.invalid' ''
    Assert-True ($live.version -eq '2.4.0' -and $curlCalls -eq 1) '在线基线应读取固定latest.json'
    $script:curlFailure = $true
    $failed = $false
    try { Get-PreviousReleaseManifest 'example.invalid' '' } catch { $failed = $true }
    Assert-True $failed '在线清单请求失败不能继续相信输出'
    $script:curlFailure = $false
    $script:generatorMode = 'ok'; $script:generatorCalls = 0; $script:newCode = 26
    $delta = New-OptionalDelta $oldPath '2.4.0' $newPath '2.5.0' $newAsset $baseline 'FakePython'
    Assert-True ($null -ne $delta) '有效且足够小的补丁应被采用'
    Assert-True ($delta.manifest.format -eq 'plai-bsdiff-gzip-v1') '格式不符'
    Assert-True ($delta.manifest.path -ceq 'releases/2.5.0/Plai-android-2.4.0-to-2.5.0.patch') '补丁路径必须属于本次版本目录'
    Assert-True ($delta.manifest.fromSha256 -ceq $oldAsset.sha256 -and $delta.manifest.fromSize -eq $oldAsset.size) '基线元数据必须来自实际APK'
    Assert-True ($delta.manifest.sha256 -ceq (Get-Asset $delta.file).sha256) '补丁哈希必须来自实际文件'
    Assert-True ($generatorCalls -eq 1) '生成器应只执行一次'
    $baseline.assets.android.sha256 = '0' * 64
    $delta = New-OptionalDelta $oldPath '2.4.0' $newPath '2.5.0' $newAsset $baseline 'FakePython'
    Assert-True ($null -eq $delta -and $generatorCalls -eq 1) '错误基线哈希必须全量且不能运行生成器'
    $baseline.assets.android = $oldAsset
    # oldAsset 被前面的引用修改过，重新读实际文件。
    $baseline.assets.android = Get-Asset $oldPath
    $script:badIdentity = $true
    $delta = New-OptionalDelta $oldPath '2.4.0' $newPath '2.5.0' $newAsset $baseline 'FakePython'
    Assert-True ($null -eq $delta) '错误签名/包名必须全量'
    $script:badIdentity = $false; $script:newCode = 25
    $delta = New-OptionalDelta $oldPath '2.4.0' $newPath '2.5.0' $newAsset $baseline 'FakePython'
    Assert-True ($null -eq $delta) '真实versionCode未递增必须全量'
    $script:newCode = 26; $script:generatorMode = 'fail'
    $delta = New-OptionalDelta $oldPath '2.4.0' $newPath '2.5.0' $newAsset $baseline 'FakePython'
    Assert-True ($null -eq $delta) '--verify失败必须全量'
    $script:generatorMode = 'large'
    $delta = New-OptionalDelta $oldPath '2.4.0' $newPath '2.5.0' $newAsset $baseline 'FakePython'
    Assert-True ($null -eq $delta) '补丁过大必须全量'
    $delta = New-OptionalDelta '' '' $newPath '2.5.0' $newAsset $null 'FakePython'
    Assert-True ($null -eq $delta) '未提供基线应保持全量'
    $unsafe = $false
    try { Assert-ArtifactName '../injected.patch' '.patch' } catch { $unsafe = $true }
    Assert-True $unsafe '外部路径不得作为补丁文件名'
    # Prepare 的离线参数不得带入真正 Publish 参数集，必须在任何工具/SSH执行前拒绝。
    $bindingFailed = $false
    try {
        & $scriptPath -Version '2.5.0' -AndroidApk $newPath -IdentityFile $oldPath -Notes 'test' -BaseManifest $baselinePath
    } catch [System.Management.Automation.ParameterBindingException] { $bindingFailed = $true }
    Assert-True $bindingFailed '正式发布不得使用外部基线清单绕过线上校验'
    # 执行真实入口、清单生成与远程命令组装，只替换SDK/SSH/Python边界。
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
    $previewPath = Join-Path $testDirectory 'preview.json'
    $script:sshCommands = @(); $script:generatorMode = 'ok'
    & $entry -Version '2.5.0' -AndroidApk $newPath -PrepareOnly -ManifestOutput $previewPath
    $preview = Get-Content -LiteralPath $previewPath -Raw | ConvertFrom-Json
    Assert-True ($preview.schemaVersion -eq 1 -and @($preview.assets.android.PSObject.Properties).Count -eq 4) '全量预览保持schemaVersion及原四字段'
    Assert-True ($sshCommands.Count -eq 0) 'PrepareOnly不得执行SSH'
    & $entry -Version '2.5.0' -AndroidApk $newPath -PrepareOnly -ManifestOutput $previewPath -BaseApk $oldPath -BaseVersion '2.4.0' -BaseManifest $baselinePath -PythonExe 'FakePython'
    $preview = Get-Content -LiteralPath $previewPath -Raw | ConvertFrom-Json
    Assert-True ($preview.assets.android.delta.format -eq 'plai-bsdiff-gzip-v1') '离线预览应包含经验证delta'
    Assert-True ($sshCommands.Count -eq 0) '增量PrepareOnly不得执行SSH'
    & $entry -Version '2.5.0' -AndroidApk $newPath -IdentityFile $oldPath -Notes 'test' -HostName 'example.invalid' -BaseApk $oldPath -BaseVersion '2.4.0' -PythonExe 'FakePython'
    Assert-True ($publishedManifest.assets.android.delta.fromVersion -eq '2.4.0') '正式发布应从在线基线生成delta'
    Assert-True (($uploadArguments | Where-Object { $_ -like '*.patch' }).Count -eq 1) 'APK和manifest之外必须上传唯一补丁'
    $commitCommand = $sshCommands | Where-Object { $_ -match 'sha256sum -c' } | Select-Object -First 1
    Assert-True ($commitCommand -match [regex]::Escape($publishedManifest.assets.android.delta.sha256)) '原子切换前必须核对补丁哈希'
    Assert-True ($commitCommand -match "stat -c%s 'Plai-android-2.4.0-to-2.5.0.patch'") '原子切换前必须核对补丁大小'
    Assert-True ($commitCommand -match "test ! -e 'releases/2.5.0'") '不得覆盖既有immutable目录'
    $pruneCommand = $sshCommands[-1]
    Assert-True ($pruneCommand -match 'sort -V' -and $pruneCommand -match 'tail -n 5' -and -not $pruneCommand.Contains("`r")) '五版本保留与CRLF归一化不可破坏'
    Write-Output "PASS: $passed delta release checks"
} finally {
    $resolved = [IO.Path]::GetFullPath($testDirectory)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected test cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
