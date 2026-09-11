# Plai 项目交接报告

> 面向后续接手的开发智能体。最后更新：2026-09-11。先阅读本文、`编码约定.md`、`README.md`，再修改代码。

## 1. 当前状态

| 项目 | 状态 |
| --- | --- |
| 工作目录 | `C:\Users\Administrator\Desktop\Plai-master` |
| 当前分支 | `feature/windows-ui-shell`（**仅是历史分支名，不代表仍支持 Windows**） |
| 当前 HEAD | `006338b V1.1: 平台-移除桌面端保留平板适配` |
| 应用版本 | `2.1.7+7`（`pubspec.yaml`） |
| 支持平台 | Android、iOS；Android 手机与平板均支持 |
| 已移除的平台 | Windows；仓库已无 `windows/` Flutter runner |
| 最近验证 | `flutter analyze` 通过；`flutter test` 344 项全绿；`flutter build apk --release` 成功 |

工作树中 `dist/` 是未跟踪的本地 Android 构建产物，**不得提交**。发布前务必增加版本号和 build number；当前代码尚未因“移除桌面端”单独发布新版本。

## 2. 产品与边界

Plai 是纯本地学生工具：课表、日程/任务、打卡、提醒、备份与 AI 对话。除用户主动配置并使用的 AI、以及应用更新检查外，不依赖业务服务器或账号系统。

- 课表：学期、课程、节次、单双周/自定义周、停课、状态色、导入导出。
- 日程：待办、定点日程、每日打卡、跨期任务、优先级、日历与今日聚合。
- 提醒：本地通知、任务提醒、课程提醒、开机恢复与保活引导。
- AI：兼容 OpenAI 协议的用户自配服务；读取课表/日程，写操作必须经过确认。
- 数据：SQLite 本地库；支持 `.plai` 备份、预览、合并或覆盖恢复。

### 不要破坏的用户约定

1. 用户按小需求逐条确认；需求、交互或视觉不明确时先给简短方案确认，再写代码。
2. 每个小项目：实现 → `flutter analyze` → `flutter test` → Git 提交 → 等用户验收/“继续”。
3. 不向 `master` 直接提交或推送。当前也**不要**因为分支名含 `windows` 而恢复桌面支持；如需新分支，默认用 `codex/` 前缀。
4. 不读取、展示、上传或提交私钥、API Key、AI 配置等敏感信息。
5. 数据模型保持只读；feature 层通过 provider/仓库接口访问数据，禁止页面直接写 SQLite。

## 3. 平台与响应式布局

### 手机 / 平板

`lib/app_shell.dart` 是三个主 Tab 的壳：课表、今日、AI。默认进入“今日”，其余 Tab 懒构建后通过 `IndexedStack` 保持状态。

- 宽度小于 `1024`：使用底部 `NavigationBar`。
- 宽度大于等于 `1024`：使用平板宽屏侧栏 `NavigationRail`；今日页会变为任务主区 + 当天课程侧栏。
- 断点和跨页面状态由 `lib/shared/layout_breakpoints.dart` 的 `kWideLayoutBreakpoint`、`WideLayoutScope` 统一提供。页面不要自行根据自身狭窄内容区再判断宽度。
- `lib/features/timetable/week_view.dart` 在宽屏可用高度有限时会压缩**所有节次的统一行高**，确保第 9–12 节仍显示、可点击；不得按“该节有无课程”压缩空行。

### 已移除的电脑端内容

以下内容已在 `006338b` 删除：Windows runner、无边框窗口控制、Windows SQLite FFI 初始化、Windows ZIP 更新与 PowerShell 重启脚本、电脑端 Ctrl+滚轮缩放设置、Windows 发布字段与本地 Windows ZIP 包。后续只维护 Android/iOS。

ECS 上已发布的历史 Windows 文件已于 2026-09-11 按用户明确要求下架：删除 `releases/2.1.3`–`2.1.7` 下 5 个 `Plai-windows-x64-*.zip`（合计约 66.8MB），发布目录由 411MB 降至 344MB。注意这些 zip 曾是**唯一副本**（本机、git 历史均无，Windows runner 已随 `006338b` 删除故无法重建）。现网只保留 Android APK（2.1.3–2.2.0）与 android-only 的 `latest.json`，删掉的 URL 现已 404。

## 4. 架构导航

```text
lib/
  main.dart                         Flutter 启动、主题、通知延后初始化
  app_shell.dart                    主 Tab、手机/平板宽屏导航、启动预热
  routes/                           AppRoutes 常量与 route_registry
  data/
    db/                             AppDatabase、迁移、DDL、12 节内置模板
    models/                         不可变领域模型
    repositories/                   I*Repository 接口及 SQLite 实现
    backup/、import_export/         备份与课表文件处理
  features/
    timetable/                      学期、课程、周视图、节次、状态色、导入导出
    schedule/                       今日、任务 CRUD、日历、排序规则
    settings/                       设置、课表设置、备份、检查更新入口
    ai/                             会话、附件、模型设置、读写工具与确认面板
  services/
    notifications/                  本地通知、提醒计划、深链
    app_update/                     Android/iOS 更新检查、下载、安装交接提示
    ai/                             OpenAI 兼容 LLM 客户端
    audio/                          完成提示音
  shared/                           跨模块 UI 与宽屏断点
```

### 依赖规则

- UI/feature 读取 Riverpod provider，provider 再依赖 repository 接口；不要从页面直接访问 `AppDatabase`。
- 路由统一登记到 `lib/routes/route_registry.dart`，不要散落匿名导航替代命名路由。
- 设置存 `setting` 表，键使用点号命名空间（例如 `timetable.status_color_ongoing`）。
- `settings_providers.dart` 与 `timetable_providers.dart` 都有 `settingsRepositoryProvider`；跨模块导入时按现有写法用 `hide` 消除重名。
- SQLite 版本是 `dbVersion = 4`，定义在 `lib/data/db/app_database.dart`。改 schema 必须递增版本、补齐幂等 `onUpgrade` 迁移和测试。

## 5. 关键业务入口

| 需求 | 优先查看 |
| --- | --- |
| 今日页、实时课程状态 | `features/schedule/schedule_page.dart`、`schedule_providers.dart`、`features/timetable/course_status.dart` |
| 周课表与第 9–12 节布局 | `features/timetable/week_view.dart`、`class_lanes.dart`、`course_block.dart` |
| 学期/节次/状态色设置 | `features/settings/timetable_settings_page.dart`、`features/timetable/timetable_settings_keys.dart` |
| 任务排序、逾期与提醒时间 | `features/schedule/task_rules.dart` |
| 任务操作 | `features/schedule/task_actions.dart`、`task_form_page.dart`、`task_detail_page.dart` |
| 通知和点击深链 | `services/notifications/notification_scheduler.dart`、`notification_service.dart` |
| AI 工具写入确认 | `features/ai/ai_read_tools.dart`、`ai_write_tools.dart`、`ai_write_confirm_sheet.dart` |
| 备份/恢复 | `data/backup/backup_service.dart`、`features/settings/backup_page.dart` |

## 6. 自动更新与发布

### 客户端行为

发布模式下，`AppShell` 首帧后三秒调用 `runStartupUpdateFlow`：

1. 从固定 HTTPS 清单读取版本；更新源在 `AppUpdateConfig` 中固定为 `https://liuyangyang.me/downloads/plai/latest.json`。
2. 仅接受同 origin、`releases/` 相对路径、带大小与 SHA-256 的 Android APK；支持 Range 续传与完整性校验。
3. 有更新时弹窗；用户确认下载；下载后调用 Android 系统安装页。安装完成后下次启动显示更新内容与公告。
4. iOS 仅接受 `apps.apple.com` 地址，跳转 App Store，不允许 APK 式覆盖安装。

相关文件：

- `lib/services/app_update/app_update_service.dart`：固定源、清单解析、版本比较、下载/校验。
- `lib/services/app_update/app_update_flow.dart`：三秒检查、弹窗和下载交互。
- `lib/services/app_update/app_update_installer.dart`：Android `MethodChannel` 安装器与 iOS App Store 跳转。
- `android/app/src/main/kotlin/com/plai/plai/MainActivity.kt`：`plai/app_update` 原生安装通道。
- `tool/publish_plai_update.ps1`：Android-only staging 上传和原子替换 `latest.json`。
- `docs/automatic-update-release.md`：发布步骤。

发布命令（私钥路径及服务器权限必须由用户在当前会话明确提供；报告不保存凭据）：

```powershell
flutter build apk --release
.\tool\publish_plai_update.ps1 `
  -Version <新版本号> `
  -AndroidApk .\build\app\outputs\flutter-apk\app-release.apk `
  -IdentityFile <用户授权的私钥文件路径> `
  -Notes '<更新内容>' `
  -Announcement '<公告>'
```

当前 Android release 使用 debug 签名，仅适合测试/侧载；正式分发前需要配置正式 keystore，否则已发布用户无法可靠覆盖安装。

## 7. 运行、测试与构建

```powershell
# 安装依赖
flutter pub get

# 连接 Android 手机或模拟器后运行
flutter run

# 静态检查与全量测试
flutter analyze
flutter test

# Android release
flutter build apk --release
# build\app\outputs\flutter-apk\app-release.apk
```

不要运行 `flutter run -d windows` 或 `flutter build windows`：Windows 工程已删除。桌面浏览器窗口不代表 Windows 客户端；平板预览应优先用 Android 模拟器或实体平板。

## 8. 最近提交与后续建议

```text
006338b  平台-移除桌面端保留平板适配
d6b4db6  更新-缩短 Windows 重启等待（历史提交，已被 006338b 删除其运行代码）
332af21  更新-统一 2.1.4 品牌与检查页
cbde2e9  日程 V1 基础（更早提交）
```

接手后推荐顺序：

1. 确认用户下一条具体需求；不要自行恢复 PRD 中未确认的功能。
2. 先确认涉及的 feature/data/notify 边界与现有测试。
3. 小范围实现，优先补/改对应单测。
4. 完整执行 analyze/test；必要时构建 Android APK。
5. 提交到非 `master` 分支，报告提交号并等待用户验收；只有用户明确要求才推送或发布 ECS。

## 9. 已知注意事项

- `flutter test` 中通知初始化可能打印测试宿主不支持的提示，但当前 344 项测试会通过；以最终退出结果为准。
- Android 构建可能提示 `photo_manager` 的 Kotlin Gradle Plugin 未来兼容性警告、以及本机 SDK XML 版本提示；当前不阻断构建。升级 Flutter/Gradle 前先做独立兼容性验证。
- `sqflite_common_ffi` 仍是 **dev dependency**，仅供 Windows 宿主跑内存 SQLite 单元测试，并不表示应用支持 Windows。
- 历史分支名 `feature/windows-ui-shell` 应在用户确认后择机改为中性名字；改名不是当前功能实现的一部分。
