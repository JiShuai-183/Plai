[CmdletBinding(DefaultParameterSetName = 'Publish')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Publish')]
    [ValidatePattern('^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$')]
    [string]$Version,
    [Parameter(Mandatory, ParameterSetName = 'Publish')]
    [Parameter(Mandatory, ParameterSetName = 'CheckResources')]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$AndroidApk,
    [Parameter(Mandatory, ParameterSetName = 'Publish')]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$IdentityFile,
    [Parameter(Mandatory, ParameterSetName = 'Publish')]
    [string]$Notes,
    [Parameter(ParameterSetName = 'Publish')]
    [string]$Announcement = '',
    [Parameter(ParameterSetName = 'Publish')]
    [ValidatePattern('^https://apps\.apple\.com/.+')][string]$IosStoreUrl,
    [Parameter(ParameterSetName = 'Publish')]
    [string]$HostName = 'liuyangyang.me',
    [Parameter(ParameterSetName = 'Publish')]
    [string]$SshUser = 'root',
    [Parameter(ParameterSetName = 'Publish')]
    [ValidateRange(1, 65535)][int]$SshPort = 22,
    [Parameter(ParameterSetName = 'Publish')]
    [string]$RemoteDirectory = '/www/wwwroot/resource/data/plai-updates',
    # 服务器上保留的最新版本目录数量；超出的旧版本在发布成功后清理。
    [Parameter(ParameterSetName = 'Publish')]
    [ValidateRange(1, 100)][int]$KeepReleases = 5,
    # 只跑「必需资源」这道闸门后立即退出：不生成清单、不连服务器、无任何副作用。
    # 用法：-AndroidApk <apk> -CheckResourcesOnly
    [Parameter(Mandatory, ParameterSetName = 'CheckResources')]
    [switch]$CheckResourcesOnly
)

$ErrorActionPreference = 'Stop'

# 只在 Dart 侧以【字符串】引用、因此易被 release 资源压缩误删的 Android 资源。
#
# 为什么这类资源要单独校验：Flutter 的 Gradle 插件对 release 应用构建默认开启资源压缩
# （FlutterPlugin.kt: releaseBuildType.isShrinkResources = FlutterUtils.isBuiltAsApp(...)）。
# 压缩器按「Android 资源图里是否存在引用」判定去留，而这类资源是在 Dart 侧以字符串引用的：
#     AndroidInitializationSettings('ic_notification')
# 这个引用对压缩器完全不可见，于是 drawable/ic_notification 被当作无用资源删除。
# debug 包不做压缩，所以本地调试与全部单元测试都发现不了 —— 2026-09-12 的 2.2.2 就是这样
# 漏出去的：每次提醒投递都让 App 闪退且通知不弹。
#
# 新增同类资源（如自定义通知音 raw 资源）时，必须【同时】登记到
# android/app/src/main/res/raw/keep.xml 的 tools:keep 与本数组。
$RequiredResources = @('drawable/ic_notification')

# 定位 aapt2：依次尝试 ANDROID_HOME、ANDROID_SDK_ROOT、%LOCALAPPDATA%\Android\sdk，
# 在各自的 build-tools\* 下取版本号最新的一个（用 [version] 排序，避免 "36.0.0" 被
# 词法排序判成比 "9.0.0" 更小）。
function Get-Aapt2Path {
    $sdkRoots = [System.Collections.Generic.List[string]]::new()
    if ($env:ANDROID_HOME) { $sdkRoots.Add($env:ANDROID_HOME) }
    if ($env:ANDROID_SDK_ROOT) { $sdkRoots.Add($env:ANDROID_SDK_ROOT) }
    if ($env:LOCALAPPDATA) { $sdkRoots.Add((Join-Path $env:LOCALAPPDATA 'Android\sdk')) }

    foreach ($root in $sdkRoots) {
        $buildTools = Join-Path $root 'build-tools'
        if (-not (Test-Path -LiteralPath $buildTools -PathType Container)) { continue }
        $candidates = Get-ChildItem -LiteralPath $buildTools -Directory -ErrorAction SilentlyContinue |
            Sort-Object -Property @{ Expression = { try { [version]$_.Name } catch { [version]'0.0.0' } } } -Descending
        foreach ($dir in $candidates) {
            foreach ($name in @('aapt2.exe', 'aapt2')) {
                $exe = Join-Path $dir.FullName $name
                if (Test-Path -LiteralPath $exe -PathType Leaf) { return $exe }
            }
        }
    }
    return $null
}

# 资源闸门：确认待发布 APK 的资源表里每一项必需资源都存在，缺任意一项即抛错终止发布。
function Assert-RequiredResourcesPresent([string]$ApkPath, [string[]]$RequiredResources) {
    $apk = Get-Item -LiteralPath $ApkPath

    $aapt2 = Get-Aapt2Path
    if (-not $aapt2) {
        throw @'
未找到 aapt2，无法校验 release 包里的资源完整性 —— 按 fail-closed 原则拒绝发布。
请安装 Android SDK build-tools（内含 aapt2），或设置 ANDROID_HOME / ANDROID_SDK_ROOT
指向 Android SDK 根目录（aapt2 位于 <sdk>/build-tools/<版本>/aapt2.exe）。
理由：能构建出待发布 APK 的机器必然装着 build-tools，找不到通常意味着环境异常；
与其放行一个资源可能已被压缩删掉的包，不如先停在这里。
'@
    }

    $dump = (& $aapt2 dump resources $apk.FullName) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        throw "aapt2 dump resources 失败（退出码 $LASTEXITCODE）：$($apk.FullName)"
    }

    $missing = @()
    foreach ($resource in $RequiredResources) {
        $pattern = '(?m)^\s*resource\s+0x[0-9A-Fa-f]+\s+' + [regex]::Escape($resource) + '\s*$'
        if ($dump -notmatch $pattern) { $missing += $resource }
    }
    if ($missing.Count -gt 0) {
        throw @"
发布前的资源闸门未通过：待发布 APK 里缺少以下只在 Dart 侧以字符串引用的资源。
  $($missing -join "`n  ")
APK：$($apk.FullName)

这些资源在 release 包中缺失会导致：
  插件按资源名取 id 时拿到 0 → 通知构建时 setSmallIcon(0) 抛
  IllegalArgumentException: Invalid notification (no valid small icon)
  → 异常在通知接收器内无人接住 → 提醒触发时 App 进程直接崩溃、且通知不弹。
（debug 包不做资源压缩，本地调试与单元测试都发现不了这类问题。）

修复：把这些资源登记到 android/app/src/main/res/raw/keep.xml 的 tools:keep，
      再 flutter build apk --release 重新出包后发布。
"@
    }
    Write-Host "资源闸门通过：$($apk.Name) 包含全部 $($RequiredResources.Count) 项必需资源（$($RequiredResources -join ', ')）。"
}

# 只做校验的模式：跑完资源闸门即退出，不产生任何线上副作用（供发布前单独验证用）。
if ($PSCmdlet.ParameterSetName -eq 'CheckResources') {
    Assert-RequiredResourcesPresent -ApkPath $AndroidApk -RequiredResources $RequiredResources
    return
}

function Assert-ArtifactName([string]$Name, [string]$Extension) {
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$' -or -not $Name.EndsWith($Extension, [StringComparison]::OrdinalIgnoreCase)) {
        throw "产物文件名不安全或不是 $Extension：$Name"
    }
}

function Get-Asset([string]$InputPath) {
    $item = Get-Item -LiteralPath $InputPath
    $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    return @{ name = $item.Name; size = [int64]$item.Length; sha256 = $hash }
}

if ($Notes.Length -gt 12000 -or $Announcement.Length -gt 12000) { throw '更新说明或公告超过 12000 字符。' }
if (-not (Test-Path -LiteralPath $IdentityFile -PathType Leaf)) { throw 'SSH 私钥文件不存在。' }

$android = Get-Asset $AndroidApk
Assert-ArtifactName $android.name '.apk'

# 资源闸门（fail-closed）：进到这一步说明已即将发布，先确认 release 资源压缩
# 没有把「只在 Dart 侧以字符串引用」的资源删掉，缺一个就终止，不做任何上传。
Assert-RequiredResourcesPresent -ApkPath $AndroidApk -RequiredResources $RequiredResources

$releasePath = "releases/$Version"
$assets = [ordered]@{
    'android' = [ordered]@{ name = $android.name; path = "$releasePath/$($android.name)"; size = $android.size; sha256 = $android.sha256 }
}
if ($IosStoreUrl) { $assets['ios'] = [ordered]@{ storeUrl = $IosStoreUrl } }
$manifest = [ordered]@{ schemaVersion = 1; version = $Version; notes = $Notes; announcement = $Announcement; assets = $assets }

# 保留策略：只保留按语义版本排序后的最新 N 个版本目录，更旧的整体删除。
# 用占位符注入本地变量，避免 PowerShell 提前展开脚本里的 shell 变量。
# 只匹配「数字点分（可带 -预发布 / +构建）」的目录名，因此 .staging-* 等不会被误删。
$pruneTemplate = @'
set -e
cd 'REMOTE_DIR/releases'
versions=$(find . -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | grep -E '^[0-9]+(\.[0-9]+)*([-+][0-9A-Za-z.-]+)?$' | sort -V)
if [ -z "$versions" ]; then echo 'prune: no release dirs'; exit 0; fi
total=$(printf '%s\n' "$versions" | wc -l)
kept=$(printf '%s\n' "$versions" | tail -n KEEP_N | tr '\n' ' ')
if [ "$total" -le KEEP_N ]; then echo "prune: kept $kept"; exit 0; fi
printf '%s\n' "$versions" | head -n -KEEP_N | while read -r v; do
  if [ "$v" = "CURRENT_VERSION" ]; then continue; fi
  rm -rf -- "./$v"
  echo "prune: removed $v"
done
echo "prune: kept $kept"
'@
$pruneCommand = $pruneTemplate.
    Replace('REMOTE_DIR', $RemoteDirectory).
    Replace('KEEP_N', "$KeepReleases").
    Replace('CURRENT_VERSION', $Version).
    # here-string 原样保留源文件的换行符。本文件在 Windows 上存为 CRLF，
    # 直接发给 Linux shell 会让每行末尾多出一个 \r，报
    # "set: -: invalid option" / "cd: $'...\r': No such file or directory"。
    # 发送前统一归一化为 LF。
    Replace("`r`n", "`n").
    Replace("`r", "")

$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ("plai-update-$Version-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
try {
    $manifestPath = Join-Path $temporaryDirectory 'latest.json'
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    $stage = ".staging-$Version-" + [guid]::NewGuid().ToString('N')
    $target = "$SshUser@$HostName"
    $sshBase = @('-i', $IdentityFile, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-p', $SshPort, $target)

    & ssh @sshBase "mkdir -p '$RemoteDirectory/$stage' '$RemoteDirectory/releases/$Version'"
    if ($LASTEXITCODE -ne 0) { throw '无法创建 ECS staging 目录。' }
    & scp -i $IdentityFile -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -P $SshPort -- $AndroidApk $manifestPath "${target}:$RemoteDirectory/$stage/"
    if ($LASTEXITCODE -ne 0) { throw '上传 ECS staging 目录失败。' }

    $remoteCommand = "set -e; cd '$RemoteDirectory'; test -f '$stage/latest.json'; mv '$stage/$($android.name)' 'releases/$Version/$($android.name)'; mv '$stage/latest.json' 'latest.json'; rmdir '$stage'"
    & ssh @sshBase $remoteCommand
    if ($LASTEXITCODE -ne 0) { throw 'ECS 原子发布失败；latest.json 未被替换。' }
    Write-Host "发布成功：https://$HostName/downloads/plai/latest.json"

    # 清理旧版本放在发布成功之后：即使清理失败，本次发布也已经生效，不回滚、不报错中断。
    & ssh @sshBase $pruneCommand
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "旧版本清理失败（本次发布已成功生效）。请手动检查 $RemoteDirectory/releases。"
    }
} finally {
    Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
