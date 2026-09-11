# Plai 项目交接报告

> 面向后续接手的开发智能体。最后更新：2026-09-11。先阅读本文、`编码约定.md`、`README.md`，再修改代码。

## 1. 当前状态

| 项目 | 状态 |
| --- | --- |
| 工作目录 | `C:\Users\Administrator\Desktop\Plai-master` |
| 当前分支 | `master`（另有 3 个历史分支 `feature/windows-ui-shell`、`feature/windows-desktop`、`fix/windows-sqlite-ffi`，**仅是历史分支名，不代表仍支持 Windows**） |
| 当前 HEAD | 用 `git log -1` 查 —— 本报告**刻意不锁定提交号**。旧版报告把 HEAD 与分支名写死，几次提交后就成了误导接手者的错误信息 |
| 应用版本 | `2.2.1+9`（`pubspec.yaml`，versionCode 9） |
| 线上版本 | `2.2.1`（`https://liuyangyang.me/downloads/plai/latest.json`，android-only 清单） |
| 支持平台 | Android、iOS；Android 手机与平板均支持 |
| 已移除的平台 | Windows；仓库已无 `windows/` Flutter runner |
| 最近验证 | 2026-09-11：`flutter analyze` 无问题；`flutter test` 344 项全绿；`flutter build apk --release` 成功。2.2.0 与 2.2.1 均已发布，且都完成「线上实际字节 SHA-256 == 清单声明 == 本地构建」的端到端校验 |

`dist/` 是本地构建产物的暂存目录，当前为空、未被 git 跟踪。**APK 等二进制不得提交**：`build/` 已在 `.gitignore`，但 `dist/` **不在**其中 —— 往里放文件后 `git status` 会立刻亮出 `?? dist/`，一次 `git add -A` 就会把几十 MB 的包提交进库。发布前务必递增 `pubspec.yaml` 的版本号与 build number，否则 Android 拒绝覆盖安装。

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
3. 提交目前直接落在 `master`（现状如此，非理想状态）；但**推送 GitHub 与发布 ECS 都必须先得到用户明确指示**，不要自行推送或发布。当前也**不要**因为分支名含 `windows` 而恢复桌面支持；如需新分支，默认用 `codex/` 前缀。
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
- `tool/publish_plai_update.ps1`：Android-only staging 上传、原子替换 `latest.json`，随后按保留策略清理旧版本。
- `docs/automatic-update-release.md`：发布步骤、保留策略、发布后核验。

### 服务器版本保留策略

`releases/` 下只保留**最新 5 个**版本目录，更旧的由脚本在发布成功后自动整体删除（`-KeepReleases`，默认 5）。要点：排序必须用 `sort -V`（词法排序会把 `2.1.10` 当成最旧版本误删）；清理失败只告警、不回滚已生效的发布；本次发布的版本永不被清理；只匹配数字点分目录名，`.staging-*` 不动。客户端不依赖任何具体旧版本目录（APK 地址取自清单 `path`），所以裁剪旧版本不会让在线客户端失效。

发布流程（私钥路径及服务器权限必须由用户在当前会话明确授权；文档与记忆均不保存凭据）：

```powershell
# 1) 递增 pubspec.yaml 的 version 与 build number（如 2.1.7+7 -> 2.2.0+8），单独提交
flutter analyze ; flutter test
flutter build apk --release

# 2) 按线上命名约定改名 —— 脚本以「本地文件名」生成清单里的 name，
#    现网既有命名是 Plai-android-<版本>.apk
Copy-Item .\build\app\outputs\flutter-apk\app-release.apk `
          .\build\app\outputs\flutter-apk\Plai-android-<新版本号>.apk

# 3) 发布（先传 staging，最后原子替换 latest.json；已发布的 releases/<版本>/ 会被保留）
.\tool\publish_plai_update.ps1 `
  -Version <新版本号> `
  -AndroidApk .\build\app\outputs\flutter-apk\Plai-android-<新版本号>.apk `
  -IdentityFile <用户授权的私钥文件路径> `
  -Notes '<更新内容>' `
  -Announcement '<公告>'
```

> 产物命名统一为 `Plai-android-<版本>.apk`（`编码约定.md` §12 已同步更正，README 亦已更新）。

**发布后必做核验**（做过一次就不要再凭感觉）：

```powershell
curl.exe -s https://liuyangyang.me/downloads/plai/latest.json          # 版本号与 sha256 是否为新版
# 下载 releases/<版本>/<产物名> 后比对 sha256 是否等于清单声明值 ——
# 这是客户端安装前的校验路径，不匹配会让所有用户的更新失败
```

### 签名现状与未来迁移【易被误判，务必读完】

**当前是 debug 签名，且这不会破坏覆盖升级。** `android/app/build.gradle.kts` 的 `buildTypes.release` 引用 `signingConfigs.getByName("debug")`。2026-09-11 实测：线上 2.1.7 与本机 release 构建的签名证书指纹**逐位一致**（`apksigner verify --print-certs`，`CN=Android Debug`，SHA-256 `bf7b408b…a1b9e`）——因为 debug keystore 是按机器生成、这台机一直在用它构建。所以 debug→debug 的自动更新链完好，2.2.0 即在用户明确选择下沿用 debug 签名发布。

> ⚠️ 先前本报告称「debug 签名导致已发布用户无法可靠覆盖安装」是**错误判断**，已更正。不要据此劝阻用户发布。

**真正的风险是未来迁移正式 keystore**，届时签名指纹变化，所有已装版本都无法覆盖升级，必须走：

1. 用户本地 `keytool` 生成密钥（密钥文件放**仓库外**，不入库、不提交）
2. 写 `android/key.properties`（`storeFile` 用绝对路径），与密钥文件一并加入 `.gitignore`
3. 改 `build.gradle.kts` 让 `release` 引用正式 `signingConfig`，替换 debug 兜底
4. 递增 build number 构建，`apksigner verify --print-certs` 确认指纹已变
5. **迁移已装用户**：导出 `.plai` 备份 → 卸载（本地 SQLite 随之清空）→ 装正式签名版 → 恢复备份
6. ⚠️ 密钥务必长期保管：丢失 = 永久无法升级，只能换 applicationId 重发

**每发一个 debug 签名版本，未来需要重装的人就多一个** —— 这是当前唯一的发布债。

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

## 8. 最近的里程碑（2026-09-11 快照）

本节是**按日期拍的快照，不是实时的**。要拿当前 HEAD 用 `git log -1`，不要依赖这里的列表。

```text
6ce2e88  更换应用启动图标源图并重新生成全平台图标
d3b5d45  发布脚本增加版本保留策略，服务器只留最新 5 个版本
8a63a5d  刷新交接报告至 2.2.0 实际状态
48f7a0b  发布 2.2.0，版本号升至 2.2.0+8
e774274  自动更新实现和整体优化
006338b  平台-移除桌面端保留平板适配
d6b4db6  更新-缩短 Windows 重启等待（历史提交，其运行代码已被 006338b 删除）
```

> 2026-09-11 当天还发布了 **2.2.1**（更换启动图标）并在同一次提交里修正了发布脚本保留策略的 CRLF 缺陷 —— 该提交在本快照之后，未列入上表。

接手后推荐顺序：

1. 确认用户下一条具体需求；不要自行恢复 PRD 中未确认的功能。
2. 先确认涉及的 feature/data/notify 边界与现有测试。
3. 小范围实现，优先补/改对应单测。
4. 完整执行 analyze/test；必要时构建 Android APK。
5. 提交并报告提交号，等待用户验收；**推送 GitHub / 发布 ECS 必须等用户明确要求**。
6. 发布前先读上面「签名现状与未来迁移」——那是本仓库最容易误判的一节。

## 9. 已知注意事项

- `flutter test` 中通知初始化可能打印测试宿主不支持的提示，但当前 344 项测试会通过；以最终退出结果为准。
- Android 构建可能提示 `photo_manager` 的 Kotlin Gradle Plugin 未来兼容性警告、以及本机 SDK XML 版本提示；当前不阻断构建。升级 Flutter/Gradle 前先做独立兼容性验证。
- `sqflite_common_ffi` 仍是 **dev dependency**，仅供 Windows 宿主跑内存 SQLite 单元测试，并不表示应用支持 Windows。
- 历史分支名 `feature/windows-ui-shell` 应在用户确认后择机改为中性名字；改名不是当前功能实现的一部分。
- ⚠️ **节次序号缺口是已知陷阱，用户已决定暂不修**：`period` 表的 `idx` 唯一且不重排，删除后永久空缺。此时课程表单的节次下拉会静默缺项（用户会误报为「下拉控件选不了第 N 节」），且 `course_form_page.dart` 的 `_resolvePeriod` 会把越界序号**静默改写成 `indices.first`** —— 打开编辑页看到的节次是假的，直接保存会把课程写坏。缺口来源：用户手动删节次、JSON 课表导入覆盖模式整表重建 `period`、`.plai` 备份覆盖恢复。**排查判据**：Flutter 下拉只在内容放不下时才滚动对齐选中项，所以「菜单第一项不是第 1 项」通常**不是滚动藏起来，而是列表本身缺项**。恢复办法：设置 → 课表设置 → 节次时间表 →「恢复默认模板」（会覆盖自定义时间），或课表页 → 节次时间 → 添加节次（该入口允许手填序号）。
- ⚠️ **换启动图标时，源图不能自带圆角和阴影**。启动图标源图唯一位置是 `assets/images/plai_launcher_icon.png`（`pubspec.yaml` 的 `flutter_launcher_icons.image_path`，该文件**不随包分发**，只有 `plai_calendar_logo.png` 进 assets）。要求：正方形、≥1024×1024、**无 alpha 通道**（iOS 上架要求，生成后可用 `Icon-App-1024x1024@1x.png` 的 PNG colorType 校验，需为 2）、且必须是**平铺方图**。若源图预先做了圆角/阴影，启动器再套自己的遮罩后会出现「白边 + 阴影残影」双重遮罩（iOS squircle 下尤其明显）—— 2026-09-11 修过一次这个问题。改完执行 `dart run flutter_launcher_icons`，然后用 `git status` 确认 Android `mipmap-*` 与 iOS `AppIcon.appiconset` 都有预期变更。
- 注：`dart run flutter_launcher_icons` 有时会用**相同内容**重写 `ios/Runner.xcodeproj/project.pbxproj`，让 `git status` 报 `M` 但 `git diff` 为空 —— 这是 git 的 racy-clean stat 缓存，`git add` 该文件即可刷新归零，**没有真实改动**，不要当成图标生成出错。
- ⚠️ **发往 Linux 的多行 here-string 必须先做 CRLF→LF 归一化**。`tool/publish_plai_update.ps1` 在 Windows 上存为 CRLF，PowerShell 的 here-string **原样保留换行符**，不归一化时远端 bash 每行末尾多一个 `\r`，报 `set: -: invalid option` / `cd: $'...\r': No such file or directory` / `syntax error: unexpected end of file`。2026-09-11 踩过一次（发布成功但保留策略静默失败，好在清理在发布之后且失败只告警）。原来那个单行 `$remoteCommand` 用 `;` 分隔、没有换行，所以从未暴露此问题。
- ⚠️ **验证这类脚本时，必须用真实换行跑 `bash -n`，不要先 `tr -d '\r'`** —— 那恰好会抹掉唯一的问题。2026-09-11 的第一次「验证通过」就是无效的：先剥了 CR 再检查，等于没测。教训：**验证步骤本身不能对被测对象做归一化/清理**。
