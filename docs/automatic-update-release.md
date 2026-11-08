# Plai 自动更新发布

应用只读取固定 HTTPS 清单：`https://43.142.93.106/downloads/plai/latest.json`。Android 在启动三秒后自动检查（网络操作全部有超时，失败按 +6s/+15s/+30s 退避重试）；用户必须确认下载与安装。

开发代码已新增可选增量下载，具体流程见 [增量更新发布](增量更新发布.md)。完整 APK 字段和 `schemaVersion: 1` 保持兼容，旧客户端继续全量；新客户端按基线版本、大小和 SHA-256 精确匹配，合成后再次验证完整 APK，任何补丁失败只回退一次全量。该能力已随 2.5.0 分发，旧 2.4.0 客户端本次仍全量升级；下面的 2.4.0 发布记录保留历史事实。

> 2026-11-08 已发布 **2.5.0+26**：更新服务器、GitHub Releases 与 README 已同步。本轮包含日程照片、AI 附图与分类、无截止／长期任务、Android 打卡提醒修复及增量更新接入。手机已覆盖安装正式包，首启更新公告正常；启动自动检查仅在 release 模式运行。

## 2.5.0 发布验证（2026-11-08）

- 质量门槛：全库静态检查无问题，完整回归 **1074 项**通过。
- 产物：`Plai-android-2.5.0.apk`，**64,710,983 字节**；SHA-256：`fadbd704507f00b9cc7be03263f77dea2b679b7bb233d88db916d0f45a7de8ed`。
- 四道闸门：既有证书一致、versionCode **26 > 25**、`com.plai.plai` 不变、v2 验证通过；通知小图标资源存在，正式包无 DEBUGGABLE 标志。
- 单基线补丁：真实已发布的 2.4.0 APK → 2.5.0，**6,039,766 字节**（约整包 9.33%）；SHA-256：`6296b7d3acee80a0efe196847dbe9d90ddc6506b27b53b1bd7b1de738e6887a2`。公网回读补丁结合真实旧基线还原后与完整包逐字节一致。
- 公网实际完整 APK、清单、本地构建与 GitHub asset digest 一致；Range 返回 **206**，`Content-Range: bytes 0-1023/64710983`；清单更新内容及公告与发布说明一致。
- [GitHub Release v2.5.0](https://github.com/JiShuai-183/Plai/releases/tag/v2.5.0) 已公开；发布源为 `21e14fa97a770a849a42cdc3d42bfd83d4a9ecc8`，后续只补发布状态文档，不移动 tag。
- 服务器保留 **2.3.4、2.3.5、2.3.6、2.4.0、2.5.0**，按策略移除 2.3.3。
- 真机覆盖安装至 **2.5.0 / 26**，版本及首启“已更新至 2.5.0”弹窗已通过界面核验。2.4.0 旧客户端本次仍全量升级；后续已接入的新客户端按匹配基线使用增量，不要求手动安装过渡包。

## 2.4.0 发布验证（2026-11-07）


- 质量门槛：`flutter analyze` 无问题，`flutter test` **880** 项通过。
- 产物：`Plai-android-2.4.0.apk`，**63,826,087 字节**；SHA-256：`65064a4056eb0617d70ad98ff381ed9ab3195424f6057412ae3f8821163e486d`。
- 四道闸门：签名证书与既有目标一致；旧线上 APK 实测 versionCode 24，新包 25；applicationId 为 `com.plai.plai`；v2 签名验证通过。通知资源 `drawable/ic_notification` 保留。
- 发布结果：公网整包、本地构建与清单哈希一致；Range 返回 206；服务器保留 2.3.3、2.3.4、2.3.5、2.3.6、2.4.0，移除旧 2.3.2。
- [GitHub Release v2.4.0](https://github.com/JiShuai-183/Plai/releases/tag/v2.4.0) 已公开，附件大小与 digest 一致；tag 指向 `e5f5294c1c5694230ca48df27e2b63ca6c1533e3`。其后的发布状态文档提交不修改包内代码，也不移动 tag。
- 真机：覆盖安装到 2.4.0（versionCode 25），安装包无 DEBUGGABLE 标志，用户确认首启“已更新至 2.4.0”公告正常。

## 0. 「打包发布」的固定含义：三同步

用户说「**打包发布**」时，指下面三件事**必须一次全做完**，缺一即视为没发完：

| # | 同步项 | 怎么做 |
|---|---|---|
| 1 | **服务器资源** | `tool/publish_plai_update.ps1`：上传 APK → 原子替换 `latest.json` → 只保留最新 5 个版本 |
| 2 | **GitHub Releases** | `gh release create v<版本> <APK>`（同一个包、同一份说明），tag 打在 master 上 |
| 3 | **GitHub 文档** | README 版本记录、`AGENT_ONBOARDING` 快照、`PROJECT_HANDOFF` 线上版本、本文件 —— 随同一次 push 提交到 master |

**一键跑完 1+2**（并校验文档已先更新）：

```powershell
.\tool\release_plai.ps1 -Version <版本> -IdentityFile <本机私钥绝对路径> `
  -Notes '<更新内容>' -Announcement '<公告>'
```

脚本会先查 `README.md` / `AGENT_ONBOARDING.md` 是否已写本版本 —— **文档没写就先失败**，避免“发了包但文档没跟上”。发布成功后仍需把文档与本次改动 `git push` 到 master（第 3 项同步）。

## 产物

- Android：产物名用 `Plai-android-<版本>.apk`，且 `pubspec.yaml` 的 build number 必须递增，否则系统拒绝覆盖安装。
- iOS：更新清单填写 App Store 地址；iOS 由 App Store 完成安装，不可由 ECS 直接覆盖。

签名现状见下方「签名」一节 —— **当前 debug 签名可以正常覆盖升级，不要据此阻断发布**。

不要覆盖已发布版本目录；脚本总是先上传 staging，再最后替换唯一可变的 `latest.json`。

## 更新公告（装完首次打开）

覆盖安装后的首次启动会弹**一次**「已更新至 X」，内容取自清单的 `notes` + `announcement`。两条来源：

1. **应用内下载安装**：打开安装页前 `AppUpdateCompletionStore.markPending` 把 version/notes/announcement 写进本地偏好；装完首启 `consumeForVersion` 命中即弹，弹完删除。
2. **手动 / 外部渠道安装**（应用商店、传输工具、直接装 APK）：**没有**交接记录。启动时用「本机上次记录版本」+「Android `firstInstallTime` / `lastUpdateTime` 时间差」判断确实是覆盖安装，再向更新服务器读清单，取**当前版本**的 notes/announcement 补弹一次。

- 全新安装**不弹**（两个时间戳几乎相同）。
- 同一版本只弹一次（`app.update.last_seen_version.v1`）；读清单失败就静默跳过，下次升级再补。
- ⚠️ 所以清单里的 `notes` / `announcement` 不只是「给人看的说明」—— 它决定装完首启弹什么，**发版时不要留空**。

## 版本保留策略

服务器只保留**最新 5 个**版本目录，更旧的在发布成功后自动整体删除。数量由 `-KeepReleases`（默认 5）控制。

- 排序用 `sort -V`（语义版本），**不是**词法排序 —— 否则 `2.1.10` 会被排到 `2.1.9` 之前当成最旧版本误删。
- 清理在**发布成功之后**执行；清理失败只打印告警，不回滚、不影响已生效的发布。
- 本次发布的版本永不被清理（防「回滚式发布旧版本」时把自己删掉）。
- 只匹配「数字点分（可带 `-` 预发布 / `+` 构建）」的目录名，`.staging-*` 等其它内容一律不动。
- 客户端不依赖任何具体旧版本目录：APK 地址一律取自清单的 `path`，且只接受 `releases/` 开头的相对路径。所以裁剪旧版本不会让任何在线客户端失效。

## 前置条件：本机私钥（线下拷贝，不进仓库）

发布走 SSH，需要**新服务器 43.142.93.106 的私钥**（`.pem`）。这条凭据**只线下拷贝**：

- 私钥**不在仓库里，也永远不要提交/上传 GitHub** —— 本仓库是**公开仓库**。`.gitignore` 已拦 `*.pem` / `*.jks` / `*.keystore` / `*.p12` / `配置信息.txt`，但那只是兜底，**不要依赖它**。
- 所有权人采用**线下拷贝**方式把私钥交给执行发布的人（U 盘 / 面对面）；执行人保存到本机任意目录即可。
- **发布前必须提示开发者提供本机私钥地址**，例如：`请把你本机私钥的绝对路径发我（如 D:\keys\plai.pem），这个路径不会写进仓库`。
- 脚本只把该路径交给 `ssh -i`，**不读取、不输出、不写入私钥内容**；也不要把路径写进文档或提交。
- 首次在新机器发布前先接受主机指纹（脚本 `BatchMode=yes` + `StrictHostKeyChecking=yes`，不弹交互）：

  ```powershell
  ssh-keyscan -p 22 43.142.93.106 >> ~/.ssh/known_hosts
  ```

## 发布步骤

```powershell
# 1) 递增 pubspec.yaml 的 version 与 build number（如 2.1.7+7 -> 2.2.0+8），单独提交
flutter analyze ; flutter test
flutter build apk --release

# 2) 按线上命名改名 —— 脚本以「本地文件名」生成清单里的 name
Copy-Item .\build\app\outputs\flutter-apk\app-release.apk `
          .\build\app\outputs\flutter-apk\Plai-android-<新版本号>.apk

# 3) 发布：先传 staging，原子替换 latest.json，随后按保留策略清理旧版本
.\tool\publish_plai_update.ps1 `
  -Version <新版本号> `
  -AndroidApk .\build\app\outputs\flutter-apk\Plai-android-<新版本号>.apk `
  -IdentityFile <本机私钥绝对路径> `      # 线下拷贝获得；发布前需提示开发者提供
  -HostName 43.142.93.106 -SshUser ubuntu `
  -Notes '<更新内容>' `
  -Announcement '<公告>'
```

脚本只使用传入的私钥路径进行 SSH 认证，**不读取、不输出、不写入私钥内容**。私钥由所有权人线下拷贝交付，**不入库、不上传 GitHub**；发布前**需提示开发者提供本机私钥地址**，路径只在本机命令里出现。

## 发布后核验

```powershell
curl.exe -s https://43.142.93.106/downloads/plai/latest.json   # 版本号与 sha256 是否为新版
```

再下载 `releases/<版本>/<产物名>` 比对 sha256 是否等于清单声明值 —— 这是客户端安装前的校验路径，不匹配会让所有用户的更新失败。

## 签名

当前 release 用 **debug 签名**（`android/app/build.gradle.kts` 的 `buildTypes.release` 引用 `signingConfigs.getByName("debug")`），且线上已发布版本与本机构建使用同一份 debug keystore（`apksigner verify --print-certs` 比对 SHA-256 指纹逐位一致）。因此 debug→debug 覆盖升级可用，现有用户能正常收到自动更新。

> ⚠️ 不要写「debug 签名导致已发布用户无法覆盖安装」—— 这是已被实测推翻的错误判断，不要据此劝阻发布。

真正的风险是**未来迁移正式 keystore**：签名指纹一变，所有已装版本都无法覆盖升级，必须「导出 `.plai` 备份 → 卸载（本地 SQLite 随之清空）→ 装正式签名版 → 恢复备份」。完整迁移步骤见 `PROJECT_HANDOFF.md` 的「签名现状与未来迁移」。
