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
$buildRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $toolRoot) 'build')) + [IO.Path]::DirectorySeparatorChar
$testDirectory = Join-Path $buildRoot ('plai-delta-test-' + [guid]::NewGuid())
$externalDirectory = Join-Path ([IO.Path]::GetTempPath()) ('plai-external-test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $testDirectory | Out-Null
New-Item -ItemType Directory -Path $externalDirectory | Out-Null
$script:passed = 0
function Assert-True($condition, $description) { if (-not $condition) { throw $description }; $script:passed++ }
function ExpectThrow([scriptblock]$Action, [string]$Description) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Assert-True $failed $Description
}
function Get-ApkIdentity([string]$ApkPath) {
    if ($script:badIdentity) { throw [System.Security.SecurityException]::new('wrong APK signature') }
    if ($ApkPath -eq $script:oldPath -or [IO.Path]::GetFileName($ApkPath) -eq 'base.apk') { return @{ version = '2.4.0'; versionCode = 25 } }
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
    if ($args -contains '--output') {
        if ($script:failArtifactDownload) { $global:LASTEXITCODE = 22; return }
        if ($args[-1] -ne 'https://example.invalid/downloads/plai/releases/2.4.0/old.apk') { throw 'Unexpected artifact endpoint' }
        $destination = $args[[array]::IndexOf($args, '--output') + 1]
        if ($script:corruptArtifactDownload) { [IO.File]::WriteAllBytes($destination, [byte[]]@(1)) }
        else { Copy-Item -LiteralPath $script:oldPath -Destination $destination }
        $global:LASTEXITCODE = 0
        return
    }
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
    $oldAsset.path = 'releases/2.4.0/old.apk'
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
    $baseline.assets.android.path = 'releases/2.4.0/old.apk'
    $script:badIdentity = $true
    ExpectThrow { New-OptionalDelta $oldPath '2.4.0' $newPath '2.5.0' $newAsset $baseline 'FakePython' } '错误签名/包名必须停止，不能静默全量'
    $script:badIdentity = $false; $script:newCode = 25
    ExpectThrow { New-OptionalDelta $oldPath '2.4.0' $newPath '2.5.0' $newAsset $baseline 'FakePython' } '真实versionCode未递增必须停止'
    $script:newCode = 26; $script:generatorMode = 'fail'
    $delta = New-OptionalDelta $oldPath '2.4.0' $newPath '2.5.0' $newAsset $baseline 'FakePython'
    Assert-True ($null -eq $delta) '--verify失败必须全量'
    $script:generatorMode = 'large'
    $delta = New-OptionalDelta $oldPath '2.4.0' $newPath '2.5.0' $newAsset $baseline 'FakePython'
    Assert-True ($null -eq $delta) '补丁过大必须全量'
    $delta = New-OptionalDelta '' '' $newPath '2.5.0' $newAsset $null 'FakePython'
    Assert-True ($null -eq $delta) '未提供基线应保持全量'
    $externalApk = Join-Path $externalDirectory 'new.apk'
    Copy-Item -LiteralPath $newPath -Destination $externalApk
    $externalPatch = Join-Path $externalDirectory 'Plai-android-2.4.0-to-2.5.0.patch'
    [IO.File]::WriteAllText($externalPatch, 'external patch sentinel')
    [IO.File]::WriteAllText(($externalPatch + '.json'), 'external sidecar sentinel')
    $delta = New-OptionalDelta $oldPath '2.4.0' $externalApk '2.5.0' $newAsset $baseline 'FakePython'
    Assert-True ($null -eq $delta) 'build外补丁只能回退全量'
    Assert-True ((Get-Content -LiteralPath $externalPatch -Raw) -ceq 'external patch sentinel') 'build外patch不得被catch清理'
    Assert-True ((Get-Content -LiteralPath ($externalPatch + '.json') -Raw) -ceq 'external sidecar sentinel') 'build外sidecar不得被清理'
    Assert-True ((Get-VerifiedBaselineCode $baseline $oldPath 'example.invalid') -eq 25) '清单没有versionCode时精确基线应提供真实版本号'
    $beforeDownload = $curlCalls
    Assert-True ((Get-VerifiedBaselineCode $baseline '' 'example.invalid') -eq 25 -and $curlCalls -eq $beforeDownload + 1) '缺少精确基线时应下载核验实际旧APK'
    $script:corruptArtifactDownload = $true
    ExpectThrow { Get-VerifiedBaselineCode $baseline '' 'example.invalid' } '旧APK下载哈希不符必须停止'
    $script:corruptArtifactDownload = $false
    $baseline.versionCode = 24
    ExpectThrow { Get-VerifiedBaselineCode $baseline $oldPath 'example.invalid' } '线上versionCode与精确旧APK冲突必须停止'
    $baseline.versionCode = 25
    $beforeDownload = $curlCalls
    Assert-True ((Get-VerifiedBaselineCode $baseline '' 'example.invalid') -eq 25 -and $curlCalls -eq $beforeDownload) '正式清单已记载versionCode时无需下载旧APK'
    $baseline.Remove('versionCode')
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
            "function Get-ApkIdentity { param(`$ApkPath) if (`$ApkPath -eq '$($oldPath.Replace("'", "''"))' -or [IO.Path]::GetFileName(`$ApkPath) -eq 'base.apk') { return @{version='2.4.0';versionCode=25} }; return @{version='2.5.0';versionCode=26} }"
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
    $script:baselineJson = $baseline | ConvertTo-Json -Depth 8
    $script:failArtifactDownload = $true; $script:sshCommands = @()
    ExpectThrow { & $entry -Version '2.5.0' -AndroidApk $newPath -IdentityFile $oldPath -Notes 'test' -HostName 'example.invalid' } '全量发布无baseline code且无法核实旧包时必须停止'
    Assert-True ($sshCommands.Count -eq 0) '版本闸门未通过前不得SSH或上传'
    $script:failArtifactDownload = $false
    & $entry -Version '2.5.0' -AndroidApk $newPath -IdentityFile $oldPath -Notes 'test' -HostName 'example.invalid'
    Assert-True ($publishedManifest.versionCode -eq 26 -and $null -eq $publishedManifest.assets.android.delta) '全量发布核实旧APK后记录真实code并保持无delta'
    $baseline.versionCode = 26
    $script:baselineJson = $baseline | ConvertTo-Json -Depth 8
    $script:sshCommands = @()
    ExpectThrow { & $entry -Version '2.5.0' -AndroidApk $newPath -IdentityFile $oldPath -Notes 'test' -HostName 'example.invalid' } '即使未请求delta，全量发布也必须拒绝未递增code'
    Assert-True ($sshCommands.Count -eq 0) '全量code闸门失败不得有远端副作用'
    Write-Output "PASS: $passed delta release checks"
} finally {
    $resolved = [IO.Path]::GetFullPath($testDirectory)
    if (-not $resolved.StartsWith($buildRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected test cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
    $externalResolved = [IO.Path]::GetFullPath($externalDirectory)
    if (-not $externalResolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected external test cleanup path' }
    Remove-Item -LiteralPath $externalResolved -Recurse -Force
}
