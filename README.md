# Plai

> 面向学生的私人工具 App：**课表 · 日程 · 打卡 · AI 助手**，全本地存储。

Plai 是一个纯本地的个人时间管理应用。它把学生最常用的几件事放在一起：按周看课表、管理待办与每日打卡、到点收提醒，还能用 AI 对话直接查询或帮你排课排日程 —— 所有数据只存在你自己的手机上，不需要账号、不需要服务器。

## ✨ 功能

| 模块 | 能力 |
| --- | --- |
| 🗓 课表 | 学期/课程/单双周/自定义周、停课、节次时间表；周视图横向滑动切周（跟手动画）、空课天/空行自动压缩、上课状态实时变色 |
| ✅ 日程 | 待办 / 定点日程 / 每日打卡 / 一次性跨期；优先级、按日分组、逾期置顶、完成打卡记录、日历视图 |
| 🔔 提醒 | 到点本地通知（系统调度，杀后台也能触发）、每日重复提醒、上课提前提醒、完成提示音、震动开关、开机自动重排、国内 ROM 保活引导 |
| 🤖 AI 助手 | 多供应商 OpenAI 兼容直连（Base URL 自填）；function-calling 查询课表/日程并**经你确认后**写数据；多轮对话与图片（拍照/相册/多选）识别课表；每轮注入当前真实日期避免“今天”错乱 |
| ⚙️ 数据 | 纯本地 SQLite；备份导出 / 从备份预览合并恢复；课表文件导入 |

> UI 参考“豆包”：输入胶囊、加号面板、推挤式抽屉；极简克制的排版。

## 📱 环境与兼容

- Flutter 3.47.x / Dart 3.13.2
- Android 8.0+（compileSdk / targetSdk 36）
- 纯本地：无账号、无云同步、无需联网（AI 对话除外）

## 🚀 构建

```bash
# 依赖
flutter pub get

# 运行（调试）
flutter run

# 打包 release APK
flutter build apk --release
# 产物：build/app/outputs/flutter-apk/app-release.apk

# 更换应用图标后重新生成（图标源放在 launcher_icon.jpg）
dart run flutter_launcher_icons
```

> 国内网络可用 `flutter pub get --offline` 或配置镜像后重试。

## 📦 依赖

`flutter_local_notifications`（通知/闹钟）、`sqflite`（本地库）、`flutter_riverpod`（状态）、`photo_manager`/`image_picker`（相册/拍照）、`audioplayers`（完成提示音）、`file_picker`、`http` 等。详见 `pubspec.yaml`。

## 📄 数据与隐私

- 数据全部存于设备本地 SQLite，卸载即清除；
- AI 对话需你自己填写的 Base URL / Key，仅在你主动对话时与对应服务通信；
- 本地通知由系统调度，国产 ROM 需开启自启动 / 电池白名单等（App 内有保活引导）。

## 🛠 技术说明

- 架构按 feature 分模块（课表 / 日程 / 提醒 / 设置 / AI / 数据层），页面通过 Provider 依赖仓库接口，不直接写库；
- 数据库版本迁移采用增量 `onUpgrade`（当前 db V4），老数据无损升级；
- 通知设计遵循「无服务器本地调度」：`AlarmManager` 到点触发 + 渠道管理 + 开机恢复 + 冷启动重排。

## 📌 Roadmap / 已知限制

- 文件发送、专用 OCR 服务模式：占位待后续；
- 通知提醒依赖系统与厂商策略，个别 ROM 上可能被省电策略延迟。

## 开源许可

代码以开源形式发布，未附带 License 时按仓库声明为准（如拟公开发布请补充 LICENSE）。
