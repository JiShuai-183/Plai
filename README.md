# Plai

> 面向学生的私人工具 App：**课表 · 日程 · 打卡 · 提醒 · AI 助手**，全本地存储。

Plai 是一个纯本地的个人时间管理应用。它把学生最常用的几件事放在一起：按周看课表、管理待办与每日打卡、到点收提醒，还能用 AI 对话直接查询或帮你排课排日程 —— 所有数据只存在你自己的手机上，不需要账号、不需要服务器。

## ✨ 功能

| 模块 | 能力 |
| --- | --- |
| 🗓 课表 | 学期/课程/单双周/自定义周、停课、节次时间表；周视图横向滑动切周（跟手动画）、空课天/空行自动压缩、上课状态实时变色；课表文件导入导出（JSON/CSV） |
| ✅ 日程 | 待办 / 定点日程 / 每日打卡 / 一次性跨期；优先级、按日分组、逾期置顶、完成打卡记录、日历视图 |
| 🔔 提醒 | 到点本地通知（系统调度，杀后台也能触发）、通知音跟随系统、通知渠道按「课表 / 日程」分类（可在系统设置里分别调声音与震动）、每日重复提醒、上课提前提醒、完成提示音、开机自动重排、**提醒保护**（检测系统设置并一键直达对应设置页） |
| 🤖 AI 助手 | 多供应商 OpenAI 兼容直连（Base URL 自填）；function-calling 查询课表/日程并**经你确认后**写数据；多轮对话与图片（拍照/相册/多选）识别课表；OCR 支持「对话模型视觉」与「专用服务」两种模式；每轮注入当前真实日期避免“今天”错乱 |
| 🔄 自动更新 | 启动 3 秒后自动检查新版本；用户确认后下载并由系统安装；SHA-256 完整性校验 + Range 断点续传 |
| ⚙️ 数据 | 纯本地 SQLite；`.plai` 备份导出 / 预览合并或覆盖恢复 |

> UI 参考“豆包”：输入胶囊、加号面板、推挤式抽屉；极简克制的排版。

## 📥 下载与更新

客户端**固定**读取这个 HTTPS 清单（不可配置）：

```
https://liuyangyang.me/downloads/plai/latest.json
```

- 清单里给出当前版本的产物路径、字节数与 **SHA-256**；客户端下载后逐字节校验，不匹配即判定更新失败
- 服务器只保留**最新 5 个**版本目录，更旧的自动清理
- 当前版本号请以清单或 `pubspec.yaml` 为准 —— 本 README 不写死版本号，避免过期

## 📱 环境与兼容

- Flutter 3.47.x / Dart 3.13.2
- **Android 8.0+**（minSdk 24 / compileSdk、targetSdk 36）
- **iOS**：支持，但更新经 App Store 下发，不做 APK 式覆盖安装
- 纯本地：无账号、无云同步、无需联网（AI 对话与更新检查除外）
- 仓库里的 `web/` 是 `flutter create` 留下的脚手架（可 `flutter run -d chrome` 快速预览），**不是受支持的发布平台**；Windows 桌面端已于 2.2.0 移除

## 🚀 构建

```bash
# 依赖
flutter pub get

# 运行（调试）
flutter run

# 静态检查与测试（提交前必须全绿）
flutter analyze      # 期望：No issues found!
flutter test         # 期望：All tests passed!

# 打包 release APK
flutter build apk --release
# 产物：build/app/outputs/flutter-apk/app-release.apk
# 发布前按线上命名约定改名（脚本以本地文件名生成清单里的 name）：
cp build/app/outputs/flutter-apk/app-release.apk \
   build/app/outputs/flutter-apk/Plai-android-<版本号>.apk

# 更换应用图标后重新生成
# 图标源：assets/images/plai_launcher_icon.png（= pubspec 的 flutter_launcher_icons.image_path）
# 源图要求：正方形、≥1024×1024、无 alpha 通道、且必须是【平铺方图】（不可自带圆角/阴影）
dart run flutter_launcher_icons
```

> 国内网络可用 `flutter pub get --offline` 或配置镜像后重试。

### ⚠️ 构建可被用户覆盖安装的版本

release 目前使用 **debug 签名**（`android/app/build.gradle.kts` 的 `buildTypes.release`），而 debug keystore **是按机器生成的**。所以在**新机器**上构建前，必须先把既有项目的 `debug.keystore` 放到 `~/.android/debug.keystore`，否则签出的包**已装用户装不上**（`INSTALL_FAILED_UPDATE_INCOMPATIBLE`）。

判断标准只有签名指纹，四条硬闸门（指纹 / versionCode 递增 / applicationId 不变 / 签名方案 v2）与完整发布流程见 **`docs/UPDATE_FLOW_GUIDE.md`**。

## 🧪 开发规范

**工作规范以仓库根 `编码约定.md` 为准**（冲突时以它为准），要点：

- 按模块开发，**每模块完成即单独提交**（中文 + 语义化前缀）
- 模块完成判据：实现完毕 + 相关测试通过 + `flutter analyze` 无问题
- 目录归属明确，**文件只允许由归属方修改**；跨模块改动先协调
- 数据层纪律：页面通过 Provider 依赖 Repository 接口，**禁止直接操作 SQLite**
- AI 模块有专门速查（`编码约定.md` §12），改 AI 前先读

## 📦 依赖

`flutter_riverpod`（状态）、`sqflite`（本地库）、`flutter_local_notifications`（通知/闹钟）、`flutter_localizations`（中文界面本地化）、`intl`（日期与周次）、`timezone`、`shared_preferences`、`package_info_plus`、`url_launcher`、`http`、`crypto`（更新包校验）、`file_picker`、`image_picker` / `photo_manager`（拍照与相册）、`audioplayers`（完成提示音）。详见 `pubspec.yaml`。

## 📄 数据与隐私

- 数据全部存于设备本地 SQLite，卸载即清除
- AI 对话需你自己填写的 Base URL / Key，仅在你主动对话时与对应服务通信
- 更新检查会向固定清单地址发起请求（仅此一处联网，可理解为版本探测）
- 本地通知由系统调度，国产 ROM 需开启自启动 / 电池白名单等（设置页「提醒保护」会逐项检测并一键跳转到对应系统设置）

## 🛠 技术说明

- 架构按 feature 分模块（`lib/features/` 课表/日程/设置/AI、`lib/services/` 通知/更新/AI/音频、`lib/data/` 数据层），页面通过 Provider 依赖仓库接口，不直接写库
- 数据库：9 张表，迁移版本 `dbVersion = 4`，采用增量 `onUpgrade`（幂等容错），老数据无损升级
- 路由：12 条命名路由，全部登记在 `lib/routes/route_registry.dart`
- 宽屏（≥1024px）自适应：侧栏导航 + 今日页分栏 + 课表 9–12 节自适应行高，断点统一在 `lib/shared/layout_breakpoints.dart`
- 通知遵循「无服务器本地调度」：`AlarmManager` 到点触发 + 渠道管理 + 开机恢复 + 冷启动重排

## 📚 文档地图

> 顺序与 `docs/AGENT_ONBOARDING.md` §2「阅读顺序」（正典）一致，便于按序通读。

| 文档 | 管什么 |
| --- | --- |
| `CLAUDE.md` | 仓库入口，指向下列文档（工具自动加载） |
| `docs/AGENT_ONBOARDING.md` | 项目对接总览：身份、状态、协作约定、开发闭环、已踩过的坑 |
| `编码约定.md` | **有约束力的工作规范**（模块归属、命名、质量门槛、AI 速查） |
| `docs/PROJECT_HANDOFF.md` | 架构导航、关键业务入口、签名现状与未来迁移 |
| `数据层接口文档.md` / `提醒调度接口.md` | 数据层与提醒调度的接口契约 |
| `docs/UPDATE_FLOW_GUIDE.md` | 发布/更新流程、ECS 信息、签名密钥指南、故障对照表 |
| `docs/automatic-update-release.md` | 发布步骤与版本保留策略 |
| `V1 验收报告.md` | 2026-08-31 的 V1 验收记录（历史） |

## 📌 已知限制与待办

- **积分激励模块未实现**：目前只有 `lib/theme/colors.dart` 预留的 3 个状态色与 `db_schema.dart` 里的 `point_log` 预留注释，无表、无功能
- **iOS 未做过构建/签名验证**：`ios/` 目录完整，但从未实际出包
- **release 仍是 debug 签名**：正式分发前应迁移到正式 keystore，迁移步骤见 `docs/PROJECT_HANDOFF.md`（该迁移需已装用户卸载重装一次）
- 通知提醒依赖系统与厂商策略，个别 ROM 上可能被省电策略延迟

## 🏷 版本记录

### 2.2.4（2026-09）
- **修复**：部分机型（OPPO / ColorOS 等）上，从「提醒保护」或「日程提醒」点「点击设置」只提示「请手动进入系统设置」而无法跳转。根因是跳转前的可跳转性判断用了 `Intent.resolveActivity()`，而**包可见性过滤只作用于查询类 API、不作用于启动行为**（Android 11+），于是本可打开的设置页被误判为不可用、三级退化链每一级都被自己跳过。已改为直接尝试启动、失败再逐级回退；`<queries>` 同时补齐（属冗余保险）。
- 打包产物：`Plai-android-2.2.4.apk`（versionName 2.2.4 / versionCode 12，可覆盖安装 2.2.3）。

### 2.2.3（2026-09）
- **紧急修复：正式安装包中「提醒到点会让 App 闪退，且收不到提醒」**。根因是 release 构建的资源压缩误删了通知小图标——`drawable/ic_notification` 只在 Dart 侧以字符串引用，压缩器看不见该引用（Flutter 对 release 应用构建默认开启资源压缩，debug 包不受影响因此本地调试发现不了）。系统投递通知时抛 `Invalid notification (no valid small icon)` 并终止进程，**影响全部上课与日程提醒**。已用 `res/raw/keep.xml` 的 `tools:keep` 显式保住该资源。
- 移除「提醒保护」页中面向调试的「发一条测试提醒」按钮。
- 打包产物：`Plai-android-2.2.3.apk`（versionName 2.2.3 / versionCode 11，可覆盖安装 2.2.2）。

### 2.2.2（2026-09）
- **提醒保护**：新增设置页「提醒保护」——自动识别手机品牌，逐项检测通知权限 / 精确闹钟 / 电池优化 / 自启动，未开启的可一键直达对应系统设置，并能发一条测试提醒自证「划掉 App 后仍会响」。原「提醒诊断」并入本页。
- **通知体系重做**：通知音改为跟随系统默认；通知渠道由「按震动拆两条」改为**按内容拆「课表提醒 / 日程提醒」**，可在系统设置里分别调声音与震动；设置页新增两个直达渠道设置的入口，同时移除 App 内两个震动开关。
- **AI 可删除数据**：新增删除日程 / 课程的写工具，经逐条确认后执行（不可恢复）。
- **AI 密钥更安全**：密钥框改为只写不读（已存密钥不再回显），支持一键粘贴与一键拉取模型列表；`.plai` 备份与恢复均不含 AI 密钥。
- **修复**：选完时间 / 日期后软键盘重复弹出（日程表单与课表）；自启动检测误报「未开启」；提醒调度失败导致任务保存失败并留下幽灵任务；保存课程后先返回课表页再弹提示。
- **体验**：完成任务时横线从左到右划出（动画播完再归入「已完成」）；日期选择器显示中文（全局中文本地化）；全应用提示统一为圆角气泡，错误另设醒目样式。
- 打包产物：`Plai-android-2.2.2.apk`（versionName 2.2.2 / versionCode 10，可覆盖安装 2.2.1）。

### 2.2.1（2026-09）
- **更换应用启动图标**：新源图改为平铺方图，修掉旧图自带圆角与阴影、被启动器二次遮罩后出现的白边与阴影残影，并与 App 内 logo 视觉统一。无功能变更。

### 2.2.0（2026-09）
- **自动更新上线**：启动三秒后自动检查新版本，用户确认后直接下载并由系统安装；固定 HTTPS 清单源、安装包 SHA-256 完整性校验、Range 断点续传。
- **平台收敛**：移除 Windows 桌面端（runner、无边框窗口控制、Windows 库与更新/重启脚本、电脑端缩放设置），此后只维护 Android 与 iOS。
- **平板宽屏适配**：宽屏（≥1024px）改用侧栏导航；今日页为任务主区 + 当天课程侧栏；课表第 9–12 节自适应行高。
- 应用图标、启动页与品牌视觉统一。

### 2.1.2（2026-09）
- **AI 抗限流**：瞬时繁忙（HTTP 429 / 503）自动指数退避重试——默认最多 3 次尝试、优先遵循服务端 `Retry-After`，退避 1→2→4s + 抖动；流式仅在首个 token 输出前重试，不会造成已显示文字重复；连通性测试（设置页“测试连接”）不自动重试、立即反馈。
- **AI 结果化回复**：AI 回复只汇报做了什么与结果，不再出现“我将调用 xx 函数 / 分几步查询”等机制叙述；工具轮前置叙述不入库、不入历史。
- 打包产物：`Plai.2.1.2.apk`（versionName 2.1.2 / versionCode 2，可覆盖安装 2.1.0）。

### 2.1.0（2026-08）
- AI 流式输出逐 token 渲染（ValueNotifier 只重建尾部气泡）、贴近底部自动跟随；AI 图片缩略图按显示尺寸×DPR 限流解码；
- 今日/课表分钟级定时刷新跳过 no-op 整页重建；周视图套 RepaintBoundary 隔离重绘；列表拖动收起键盘；
- 开源风格化 README 与工程整理。

## 开源许可

本仓库**公开可见，但未附带 `LICENSE` 文件** —— 按默认著作权规则，这意味着**未授予**任何复制、修改、分发或商用的许可。如需授权请另行联系仓库所有者。
