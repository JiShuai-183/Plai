[CmdletBinding()]
param(
    # 版本号（不带 build number），例如 2.3.4。pubspec.yaml 必须是 <Version>+<buildNumber>。
    [Parameter(Mandatory)][ValidatePattern('^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$')][string]$Version,
    # 本机私钥绝对路径。私钥由所有权人线下拷贝，绝不入库、绝不上传 GitHub。
    # 发布前需提示开发者提供本机私钥地址；本脚本只把路径透传给发布脚本。
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$IdentityFile,
    [Parameter(Mandatory)][string]$Notes,
    [string]$Announcement = '',
    [string]$HostName = '43.142.93.106',
    [string]$SshUser = 'ubuntu',
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    # ── 0. 「打包发布」= 三同步。文档没先更新好就不许发。 ──────────────────
    $readme = Get-Content README.md -Raw
    $onboarding = Get-Content docs/AGENT_ONBOARDING.md -Raw
    if ($readme -notmatch [regex]::Escape("### $Version（")) {
        throw "README.md 缺少 `### $Version（` 版本记录 —— 先补文档再发布（三同步：文档 / 服务器 / Releases）。"
    }
    if ($onboarding -notmatch [regex]::Escape("$Version+")) {
        throw "docs/AGENT_ONBOARDING.md 快照未更新到 $Version —— 先补文档再发布。"
    }

    $pubspec = Get-Content pubspec.yaml -Raw
    # 注意 \r：Windows 下 pubspec.yaml 是 CRLF，行尾断言必须写成 \r?$。
    if ($pubspec -notmatch "(?m)^version:\s*$([regex]::Escape($Version))\+(\d+)\r?$") {
        throw "pubspec.yaml 的 version 不是 $Version+<buildNumber>。"
    }
    $buildNumber = [int]$Matches[1]

    # ── 1. 质量门槛 ──────────────────────────────────────────────────────
    Write-Host '[1/6] flutter analyze' -ForegroundColor Cyan
    flutter analyze --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'flutter analyze 失败。' }
    if (-not $SkipTests) {
        Write-Host '[2/6] flutter test' -ForegroundColor Cyan
        flutter test --no-pub
        if ($LASTEXITCODE -ne 0) { throw 'flutter test 失败。' }
    }

    # ── 2. 构建 ──────────────────────────────────────────────────────────
    Write-Host "[3/6] flutter build apk --release ($Version+$buildNumber)" -ForegroundColor Cyan
    flutter build apk --release --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'flutter build apk 失败。' }
    $apkName = "Plai-android-$Version.apk"
    $apk = Join-Path $root "build/app/outputs/flutter-apk/$apkName"
    Copy-Item 'build/app/outputs/flutter-apk/app-release.apk' $apk -Force

    # ── 3. 四道硬闸门（装不上 = 用户必须卸载重装并丢数据） ──────────────
    Write-Host '[4/6] 四道硬闸门' -ForegroundColor Cyan
    $bt = Get-ChildItem 'C:\Android\Sdk\build-tools', "$env:LOCALAPPDATA\Android\Sdk\build-tools" -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name | Select-Object -Last 1
    if (-not $bt) { throw '找不到 Android build-tools。' }
    $apksigner = Join-Path $bt.FullName 'apksigner.bat'
    $aapt2 = Join-Path $bt.FullName 'aapt2.exe'
    $certs = & $apksigner verify --print-certs $apk 2>&1 | Out-String
    if ($certs -notmatch 'bf7b408b1aad0bd5d7e76fe3558bf8edf95b9a93348bd2755f6e46ec745a1b9e') {
        throw '签名指纹变了：已装用户将无法覆盖安装（需卸载重装，本地数据清空）。停止发布。'
    }
    $verbose = & $apksigner verify --verbose $apk 2>&1 | Out-String
    if ($verbose -notmatch 'v2 scheme \(APK Signature Scheme v2\): true') { throw '未通过 v2 签名校验。' }
    $badging = & $aapt2 dump badging $apk 2>&1 | Out-String
    if ($badging -notmatch "package: name='com\.plai\.plai' versionCode='(\d+)' versionName='$([regex]::Escape($Version))'") {
        throw 'applicationId / versionName 不符合预期。'
    }
    $versionCode = [int]$Matches[1]
    if ($versionCode -ne $buildNumber) { throw "versionCode($versionCode) != build number($buildNumber)。" }
    # 线上版本必须更低，否则系统拒绝覆盖安装
    $online = (curl.exe -sS -m 20 "https://$HostName/downloads/plai/latest.json" | ConvertFrom-Json)
    $remoteListing = ssh -i $IdentityFile -o BatchMode=yes "$SshUser@$HostName" "cat /www/wwwroot/resource/data/plai-updates/latest.json"
    $remoteVersion = ($remoteListing | ConvertFrom-Json).version
    if ($online.version -eq $Version) { throw "线上 latest.json 已经是 $Version —— 发布目录不可覆盖，请升版本号。" }

    # ── 4. 三同步之一：服务器资源 ────────────────────────────────────────
    Write-Host '[5/6] 发布到服务器（上传 + 原子替换 latest.json + 保留 5 个版本）' -ForegroundColor Cyan
    & "$PSScriptRoot/publish_plai_update.ps1" -Version $Version -AndroidApk $apk `
        -IdentityFile $IdentityFile -HostName $HostName -SshUser $SshUser `
        -Notes $Notes -Announcement $Announcement
    if ($LASTEXITCODE -ne 0) { throw '服务器发布失败。' }

    # ── 5. 三同步之二：GitHub Releases ──────────────────────────────────
    Write-Host '[6/6] GitHub Releases' -ForegroundColor Cyan
    $sha = (Get-FileHash $apk -Algorithm SHA256).Hash.ToLower()
    $body = "## 安装包`n`n- ``$apkName``（versionName $Version / versionCode $buildNumber，覆盖安装，本地数据保留）`n- SHA-256：``$sha`` `n- 自动更新清单：``https://$HostName/downloads/plai/latest.json```n`n## 更新内容`n`n$Notes`n`n## 公告`n`n$Announcement"
    $bodyFile = Join-Path $env:TEMP "plai-release-$Version.md"
    Set-Content -LiteralPath $bodyFile -Value $body -Encoding utf8
    gh release view "v$Version" *> $null
    if ($LASTEXITCODE -eq 0) { throw "GitHub Release v$Version 已存在。" }
    gh release create "v$Version" $apk --title "Plai $Version (Android)" --notes-file $bodyFile --target master
    if ($LASTEXITCODE -ne 0) { throw 'GitHub Release 创建失败。' }

    Write-Host ''
    Write-Host "发布完成：$Version (versionCode $buildNumber, sha256 $sha)" -ForegroundColor Green
    Write-Host '别忘了：文档 + 本次脚本改动提交并 push 到 master（三同步中的文档同步）。' -ForegroundColor Yellow
}
finally {
    Pop-Location
}
