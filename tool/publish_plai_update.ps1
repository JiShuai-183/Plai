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
    [string]$RemoteDirectory = '/www/wwwroot/resource/data/plai-updates'
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
} finally {
    Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
