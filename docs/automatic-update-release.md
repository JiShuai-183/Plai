# Plai 自动更新发布

应用只读取固定 HTTPS 清单：`https://liuyangyang.me/downloads/plai/latest.json`。Android 在启动三秒后自动检查；用户必须确认下载与安装。

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
  -IdentityFile <用户授权的私钥文件路径> `
  -Notes '<更新内容>' `
  -Announcement '<公告>'
```

脚本只使用传入的私钥路径进行 SSH 认证，不读取、输出或写入私钥内容。私钥路径必须由用户在当前会话明确授权。

## 发布后核验

```powershell
curl.exe -s https://liuyangyang.me/downloads/plai/latest.json   # 版本号与 sha256 是否为新版
```

再下载 `releases/<版本>/<产物名>` 比对 sha256 是否等于清单声明值 —— 这是客户端安装前的校验路径，不匹配会让所有用户的更新失败。

## 签名

当前 release 用 **debug 签名**（`android/app/build.gradle.kts` 的 `buildTypes.release` 引用 `signingConfigs.getByName("debug")`），且线上已发布版本与本机构建使用同一份 debug keystore（`apksigner verify --print-certs` 比对 SHA-256 指纹逐位一致）。因此 debug→debug 覆盖升级可用，现有用户能正常收到自动更新。

> ⚠️ 不要写「debug 签名导致已发布用户无法覆盖安装」—— 这是已被实测推翻的错误判断，不要据此劝阻发布。

真正的风险是**未来迁移正式 keystore**：签名指纹一变，所有已装版本都无法覆盖升级，必须「导出 `.plai` 备份 → 卸载（本地 SQLite 随之清空）→ 装正式签名版 → 恢复备份」。完整迁移步骤见 `PROJECT_HANDOFF.md` 的「签名现状与未来迁移」。
