# Plai 自动更新发布

应用只读取固定 HTTPS 清单：`https://liuyangyang.me/downloads/plai/latest.json`。Windows、Android 在启动三秒后自动检查；用户必须确认下载与安装。

## 产物

- Windows：将 `flutter build windows --release` 的完整 `build/windows/x64/runner/Release/` 目录压缩为 ZIP；ZIP 内可有一个最外层目录。
- Android：使用同一份正式签名密钥构建 APK，且 `pubspec.yaml` 的 build number 必须递增。**当前项目 release 仍是 debug 签名，必须先配置正式 keystore，才能让已发布用户可靠覆盖更新。**
- iOS：更新清单填写 App Store 地址；iOS 由 App Store 完成安装，不可由 ECS 直接覆盖。

不要覆盖已发布版本目录；脚本总是先上传 staging，再最后替换唯一可变的 `latest.json`。

## 首次发布示例

```powershell
Compress-Archive -Path build\windows\x64\runner\Release\* -DestinationPath dist\Plai-windows-x64-2.1.3.zip -Force
flutter build apk --release

.\tool\publish_plai_update.ps1 `
  -Version 2.1.3 `
  -WindowsZip .\dist\Plai-windows-x64-2.1.3.zip `
  -AndroidApk .\build\app\outputs\flutter-apk\app-release.apk `
  -IdentityFile 'E:\LoveLife\DOCX\geeee.pem' `
  -Notes '修复内容。' `
  -Announcement '公告内容。'
```

脚本只使用传入的私钥路径进行 SSH 认证，不读取、输出或写入私钥内容。
