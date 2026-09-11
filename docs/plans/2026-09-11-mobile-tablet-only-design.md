# 移除桌面端并保留平板适配

## 目标

项目仅维护 Android 和 iOS。删除 Windows 构建工程、Windows 专属数据库与更新交接代码，以及 Windows 发布清单字段。已有手机页面在大屏设备上仍会按宽度自动切换为侧栏和分栏布局。

## 实施

1. 删除 Windows Flutter runner 和 Windows 专属窗口控件、数据库 FFI 初始化。
2. 更新自动更新服务和发布脚本，仅保留 Android APK 与 iOS App Store 路径。
3. 将布局命名从“桌面”改为“宽屏”，保留 1024px 断点、平板侧栏、今日分栏和课表 12 节自适应行高。
4. 移除电脑端 Ctrl+滚轮和缩放设置；手机/平板不再暴露该电脑专用项。

## 验收

- `flutter analyze` 无问题。
- `flutter test` 全绿。
- Android release APK 构建成功。
- 全仓库不再包含 Windows runner、Windows 更新分支或 `Platform.isWindows`。
