# Plai 智能体对接文档

> **这是新接手者的第一份读物。** 读完本文你就能开工，不需要先读别的。
> **本文所有路径一律相对仓库根目录**（即你 clone / 打开的项目根），不含机器相关的绝对路径。
> 远端仓库：`https://github.com/JiShuai-183/Plai.git`
> 快照时间：**2026-09-11**。状态类信息会过期 —— 凡涉及「当前版本 / 当前提交 / 线上版本」，一律以命令实测为准（本文会告诉你怎么测）。

---

## 0. 三分钟摘要

**Plai 是什么**：面向学生的纯本地工具 App —— 课表 + 日程/打卡 + 本地提醒 + AI 对话。**零服务器、零账号**，数据只在用户手机上（SQLite）。除用户自配的 AI 服务和「检查更新」外不联网。

**技术栈**：Flutter 3.47.x / Dart 3.13.2，Material 3，Riverpod 2.x，sqflite（`dbVersion = 4`）。

**支持平台**：Android（minSdk 24 / targetSdk 36）与 iOS。**Windows 已于 2026-09-11 移除并下架**，不要恢复。

**规模**：`lib/` 90 个 dart 文件约 23,300 行；`test/` 45 个文件 344 个用例。

**当前状态（2026-09-11 快照）**：应用版本 `2.2.1+9`，线上版本 `2.2.1`，分支 `master`，已推送 GitHub。

---

## 1. 开工前必做的三件事

```powershell
# 1) 校准实际状态 —— 不要相信任何文档里的提交号/版本号，包括本文
git log -1 --format="%h %ad %s"
git status -sb
grep -n "^version:" pubspec.yaml

# 2) 建立验证基线（必须全绿才算环境正常）
flutter pub get
flutter analyze     # 期望：No issues found!
flutter test        # 期望：All tests passed!（344 项）

# 3) 读工作规范（唯一有约束力的文件）
#    编码约定.md —— 冲突时以它为准
```

> `flutter test` 会打印 `NotificationService.initialize 失败: LateInitializationError` —— 这是**测试宿主不支持通知初始化的正常噪音**，以最终退出结果为准，不是失败。

---

## 2. 阅读顺序（不要跳）

| 顺序 | 文件 | 作用 | 什么时候读 |
|---|---|---|---|
| 1 | `CLAUDE.md`（仓库根） | 入口，指向规范 | 自动 |
| 2 | **本文** | 对接全貌、坑、闭环 | 现在 |
| 3 | `编码约定.md` | **工作规范，冲突以它为准** | 动手前必读 |
| 4 | `数据层接口文档.md`、`提醒调度接口.md` | 接口契约 | 碰数据层/通知时 |
| 5 | `docs/PROJECT_HANDOFF.md` | 架构导航、关键业务入口、签名与发布深度说明 | 需要定位代码时 |
| 6 | `docs/automatic-update-release.md` | 发布步骤与保留策略 | 要发版时 |
| 7 | `README.md` | 面向用户的介绍、版本记录 | 需要对外说明时 |

**分工边界（防止文档漂移）**：

- **本文** = 身份 + 状态快照 + 坑 + 闭环路径（新智能体入口）
- **PROJECT_HANDOFF.md** = 架构与业务的参考手册（按需求查）
- **编码约定.md** = 有约束力的规范（照做）
- 三者都不要互相复制正文；改一处就改对应那一份

---

## 3. 怎么和用户协作（硬约定，别违反）

1. **小需求逐条确认**。需求、交互或视觉不明确时，先给一段简短方案让用户确认，**再写代码**。
2. **每个小模块闭环**：实现 → `flutter analyze` 无告警 → 相关测试通过 → **单独一次中文语义化 commit** → 报告提交号 → **等用户验收或说「继续」**。
   - 不跨模块混做；不攒多个模块合并提交。commit 前缀用 `feat: / fix: / perf: / refactor: / docs: / test: / style: / chore: / release:`。
   - 细粒度清单见 `编码约定.md` §11。
3. **推送 GitHub 与发布 ECS，都必须先得到用户明确指示。** 提交可以按闭环约定做，推送和发布不行。
4. **不擅自恢复未确认的功能**。不要自作主张补 PRD 里没确认的东西。
5. **不因分支名含 `windows` 而恢复桌面支持。** 那三个 `feature/windows-*`、`fix/windows-*` 只是历史分支名。
6. **不读取、展示、上传或提交私钥、API Key、AI 配置等敏感信息。** 发布用的 SSH 私钥路径必须由用户在当前会话明确授权，且不写入任何文档或提交。
7. 需求模糊时**先追问**，不要猜着做。

---

## 4. 架构与依赖规则（违反会被打回）

```
lib/
  main.dart            启动、主题、通知延后初始化
  app_shell.dart        三 Tab 壳（课表 / 今日 / AI）+ 手机/平板导航
  routes/               AppRoutes 常量 + route_registry
  data/                 plai-data：db / models / repositories / backup / import_export
  features/             timetable / schedule / settings / ai
  services/             notifications / app_update / ai / audio
  shared/               跨模块 UI 与宽屏断点
```

- **数据流**：页面（`ConsumerWidget`）→ Riverpod provider → **Repository 接口**。**禁止页面直接碰 SQLite、禁止 import `sqflite`。** 数据层缺口要回报 `plai-data` 补，不能绕过。
- **路由**：全部命名路由，新页面两处登记（`app_routes.dart` 补常量 → `route_registry.dart` 登记构造器）。Tab 页由 `AppShell` 的 `IndexedStack` 承载，**不要 push 成新路由**。
- **设置项**：存 `setting` 表，键用点号命名空间（如 `timetable.status_color_ongoing`）。
- **数据库**：`dbVersion = 4`（`lib/data/db/app_database.dart`）。**改 schema 必须递增版本 + 补幂等 `onUpgrade` 迁移 + 加测试。**
- **颜色**：只能引用 `lib/theme/colors.dart` 的 `PlaiColors` 或 `Theme.of(context).colorScheme`，**禁止硬编码色值**。
- **宽屏断点**：统一用 `lib/shared/layout_breakpoints.dart` 的 `kWideLayoutBreakpoint` / `WideLayoutScope`。页面**不要**自己再按内容宽度判断。
- **通知**：统一封装在 `lib/services/notifications/`，feature 只调用方法签名，不直接碰 `flutter_local_notifications`。
- **AI**：直连统一走 `lib/services/ai/llm_client.dart`（已内置 429/503 指数退避，**不要在页面层加定时器** —— 会卡住 widget 测试的 `pumpAndSettle`）；工具 schema 一律用 `functionTool()` 生成，**不要手写裸 `{}` parameters**。详见 `编码约定.md` §12。

### 文件归属

`编码约定.md` §1 有目录归属表。**文件只允许由对应 agent 创建/修改**，跨模块改动交主会话协调。

### 仓库内的两套 agent 体系（容易搞混）

- `.claude/agents/plai-*.md` 七件套：`plai-scaffold` / `plai-data` / `plai-timetable` / `plai-schedule` / `plai-settings` / `plai-notify` / `plai-review` —— 这是**本仓库内**的分工定义。
- 外部（Jarvis 中枢）另有一套通用 Agent 注册表。**两套是并行体系**，不要假设对方知道彼此存在。

---

## 5. 开发与发布闭环

### 日常

```powershell
flutter pub get
flutter run                 # 需连接 Android 设备/模拟器
flutter analyze
flutter test
```

**不要**运行 `flutter run -d windows` 或 `flutter build windows` —— Windows 工程已删除。

### 发布（摘要；完整步骤见 `docs/automatic-update-release.md`）

```powershell
# 1) 递增 pubspec.yaml 的 version 与 build number（必须，否则 Android 拒绝覆盖安装），单独提交
flutter analyze ; flutter test
flutter build apk --release

# 2) 按线上命名改名 —— 脚本以「本地文件名」生成清单里的 name
Copy-Item .\build\app\outputs\flutter-apk\app-release.apk `
          .\build\app\outputs\flutter-apk\Plai-android-<新版本号>.apk

# 3) 发布（先传 staging → 原子替换 latest.json → 按保留策略清理旧版本）
.\tool\publish_plai_update.ps1 `
  -Version <新版本号> `
  -AndroidApk .\build\app\outputs\flutter-apk\Plai-android-<新版本号>.apk `
  -IdentityFile <用户授权的私钥路径> `
  -Notes '<更新内容>' -Announcement '<公告>'
```

**发布后必须核验**（客户端安装前就做同样的校验，不匹配会让所有用户更新失败）：

```powershell
curl.exe -s https://liuyangyang.me/downloads/plai/latest.json      # 版本 + sha256
# 再下载 releases/<版本>/<产物名> 比对 sha256 == 清单声明值 == 本地构建
```

**服务器保留策略**：只保留最新 **5** 个版本目录（`-KeepReleases`，默认 5），更旧的发布成功后自动删除。排序用 `sort -V` 语义版本（词法排序会把 `2.1.10` 当最旧版本误删）。客户端不依赖任何具体旧版本目录，所以裁剪旧版本是安全的。

---

## 6. 已踩过的坑（最省时间的部分）

### ⚠️ 6.1 节次（period）序号缺口 —— 症状会被误报成「下拉控件 bug」

`period` 表的 `idx` **唯一且不重排**，删掉后永久空缺。此时：

- 课程表单的节次下拉**静默缺项**（用户会说「选不了第 N 节」）
- `course_form_page.dart` 的 `_resolvePeriod` 会把越界序号**静默改写成 `indices.first`** —— 打开编辑页看到的节次是**假的**，直接保存会把课程写坏

缺口来源：用户手动删节次、JSON 课表导入的覆盖模式整表重建 `period`、`.plai` 备份覆盖恢复。

**排查判据**：Flutter `DropdownButtonFormField` **只在内容放不下时才滚动对齐选中项**（`material/dropdown.dart` 的 `getMenuLimits`）。所以「菜单第一项不是第 1 项」通常**不是滚动藏起来，而是列表本身缺项**。可用截图的行高 × 行数反推逻辑高度判定，不必连真机 adb。

恢复办法：设置 → 课表设置 → 节次时间表 →「恢复默认模板」（会覆盖自定义时间），或课表页 → 节次时间 → 添加节次（**该入口允许手填序号**，设置侧那个入口不行）。用户已决定暂不修代码。

### ⚠️ 6.2 换启动图标：源图必须「平铺方图」

唯一源图位置：`assets/images/plai_launcher_icon.png`（`pubspec.yaml` 的 `flutter_launcher_icons.image_path`；该文件**不随包分发**，只有 `plai_calendar_logo.png` 进 assets）。要求：

- 正方形、≥1024×1024、**无 alpha 通道**（iOS 上架要求）
- **必须是平铺方图，不能自带圆角或阴影** —— 启动器会再套一层自己的遮罩，自带圆角的图会出现「白边 + 阴影残影」的双重遮罩（iOS squircle 下最明显）。2026-09-11 修过一次。

改完执行 `dart run flutter_launcher_icons`，再用 `git status` 确认 Android `mipmap-*` 与 iOS `AppIcon.appiconset` 都有预期变更。校验生成结果：`Icon-App-1024x1024@1x.png` 的 PNG colorType 应为 **2**（RGB 无 alpha）。

### ⚠️ 6.3 `flutter_launcher_icons` 会造出「假 M」

它有时用**相同内容**重写 `ios/Runner.xcodeproj/project.pbxproj`，让 `git status` 报 `M` 但 `git diff` 为空 —— 这是 git 的 racy-clean stat 缓存。`git add` 该文件即可刷新归零，**没有真实改动**，不要当成生成出错。（判断方法：对比原始字节 SHA-256 + `git diff` 是否为空。）

### ⚠️ 6.4 PowerShell here-string 发往 Linux 必须归一化换行

从 Windows 上的 `.ps1` 用 here-string（`@'...'@`）生成多行远端 shell 脚本时，**必须**先 `.Replace("`r`n", "`n").Replace("`r", "")` 再发送。here-string 原样保留源文件换行符，而 Windows 上 `.ps1` 通常是 CRLF，直发 Linux 后每行末尾多一个 `\r`，bash 报：

```
set: -: invalid option
cd: $'...\r': No such file or directory
syntax error: unexpected end of file
```

单行命令（用 `;` 分隔、无换行）不受影响，所以问题常在把逻辑改成多行后才第一次暴露。`tool/publish_plai_update.ps1` 因此加了归一化。

### ⚠️ 6.5 验证方法论：验证步骤不能对被测对象做预处理

**这是最贵的一课。** 上面 6.4 的 bug 之所以被放过去，是因为我的第一次「验证」在 `bash -n` 之前先 `tr -d '\r'`、干跑也用去 CR 的文件 —— **恰好抹掉了唯一的问题**，于是判定通过。

**规则：验证步骤本身不得对被测对象做归一化、清理或格式转换。** 要么用真实输入测，要么明确把预处理当作被测逻辑的一部分去测。同类错误还包括：只测简化后的复现路径、只测自己构造的理想输入、把「代码看起来对」当成验证。

### ⚠️ 6.6 构建产物不能进 git

`build/` 已在 `.gitignore`，但 **`dist/` 不在其中** —— 往里放 APK 后 `git status` 会亮出 `?? dist/`，一次 `git add -A` 就会把几十 MB 的包提交进库。提交时**用显式路径 `git add <文件>`，不要 `git add -A`**（工作区可能有用户自己的未提交改动）。

### ⚠️ 6.7 Android 构建的两条噪音警告

`photo_manager` 的 Kotlin Gradle Plugin 未来兼容性警告、以及本机 SDK XML 版本提示 —— **当前不阻断构建**，不要为此改代码。升级 Flutter/Gradle 前先做独立兼容性验证。

---

## 7. 容易误判的事（旧文档留下过错误信息）

| 说法 | 真相 |
|---|---|
| 「debug 签名导致已发布用户无法可靠覆盖安装」 | **错，已被实测推翻。** 线上已发布版本与本机构建使用同一份 debug keystore（`apksigner verify --print-certs` 比对 SHA-256 指纹逐位一致），debug→debug 覆盖升级**可用**。**不要据此劝阻用户发布。** |
| 「必须先配正式 keystore 才能发布」 | 同一误判。真正的风险是**未来迁移**：指纹一变，所有已装版本都无法覆盖升级，必须「导出 `.plai` 备份 → 卸载（本地 SQLite 随之清空）→ 装正式签名版 → 恢复备份」。迁移 runbook 见 `docs/PROJECT_HANDOFF.md`。 |
| 报告里写死的 HEAD / 分支名 | 已改为「用 `git log -1` 查」。**任何文档里的提交号都会过期，务必实测。** |

---

## 8. 未决事项

| 项 | 说明 |
|---|---|
| **正式 keystore 迁移** | 用户已确认加入待办。一次性动作，**越晚做要重装的人越多**（每个 debug 签名版本都在增加未来的重装人数）。完整 runbook 见 `docs/PROJECT_HANDOFF.md`「签名现状与未来迁移」。密钥务必长期保管：丢失 = 永久无法升级，只能换 applicationId 重发。 |
| 历史分支改中性名 | `feature/windows-ui-shell`、`feature/windows-desktop`、`fix/windows-sqlite-ffi` 三个残留分支。改名需用户确认，非功能实现。 |
| 积分激励模块 | **完全未实现**。只在 `lib/theme/colors.dart` 预留 3 个颜色、`db_schema.dart` 注释说 `point_log` 留待后续。但 `编码约定.md` §6 与 pubspec description 都还写着它 —— **文档承诺 > 代码**，不要误判为已完成。 |
| iOS 支持状态 | 声明支持、`ios/` 目录完整，但**从未做过 iOS 构建/签名验证**。若声称支持 iOS，这是个对外承诺风险。 |

---

## 9. 接手的第一个小时

1. 跑 §1 的三条命令，建立基线（`git log -1` 校准状态 + analyze/test 全绿）。
2. 通读 `编码约定.md`。
3. 需要定位代码时查 `docs/PROJECT_HANDOFF.md` §5「关键业务入口」。
4. **然后停下来问用户下一步要什么。** 不要自行推进待办列表，也不要恢复 PRD 中未确认的功能。

---

## 10. 本次交接来源（2026-09-11 会话做了什么）

供你判断哪些结论是刚验证过的、哪些可能更旧：

- 移除 Windows 桌面端的历史发布文件（5 个 zip，约 66.8MB），线上发布目录 411MB → 344MB；这些 zip 曾是**唯一副本**且不可重建
- 发布 **2.2.0**（自动更新上线、平台收敛、平板宽屏适配）与 **2.2.1**（更换启动图标）
- 为发布脚本增加**版本保留策略**（只留最新 5 个），首次真实运行把 7 个目录收敛为 5 个
- 修复 6.4 的 CRLF 缺陷，并记录 6.5 的验证方法论教训
- 更正了 §7 里那条「debug 签名」的错误判断
- 交接报告的结构性修正：**不再写死 HEAD 与分支名**（这正是本次会话开始时误导接手者的原因）

*本文创建：2026-09-11*
