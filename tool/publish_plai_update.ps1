[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$')]
    [string]$Version,
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$AndroidApk,
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$IdentityFile,
    [Parameter(Mandatory)][string]$Notes,
    [string]$Announcement = '',
    [ValidatePattern('^https://apps\.apple\.com/.+')][string]$IosStoreUrl,
    [string]$HostName = 'liuyangyang.me',
    [string]$SshUser = 'root',
    [ValidateRange(1, 65535)][int]$SshPort = 22,
    [string]$RemoteDirectory = '/www/wwwroot/resource/data/plai-updates',
    # 服务器上保留的最新版本目录数量；超出的旧版本在发布成功后清理。
    [ValidateRange(1, 100)][int]$KeepReleases = 5
)

$ErrorActionPreference = 'Stop'

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
    Replace('CURRENT_VERSION', $Version)

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
