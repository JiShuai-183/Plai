# Plai 自动更新发布

应用只读取固定 HTTPS 清单：`https://43.142.93.106/downloads/plai/latest.json`。Android 在启动三秒后自动检查（网络操作全部有超时，失败按 +6s/+15s/+30s 退避重试）；用户必须确认下载与安装。

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
