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

**当前状态（2026-10-22 快照）**：应用版本 `2.3.2+20`；更新通道**只走新服务器 IP 直连**（`https://43.142.93.106`，不经过域名解析，服务器持有 LE IP 证书）。旧服务器 114.55.170.117 上的 Plai 资产与映射已全部删除、不再维护（见 `docs/update-source.md`）；`lib/` 102 文件约 2.6 万行，`test/` 74 文件 717 用例。分支、提交号、线上状态一律用命令实测。

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

> **本表是阅读顺序的正典。** `CLAUDE.md`、`README.md` 的「文档地图」、`docs/UPDATE_FLOW_GUIDE.md` 的附录都按**同一顺序**排列 —— 改动顺序请改本表，再同步那三处。

| 顺序 | 文件 | 作用 | 什么时候读 |
|---|---|---|---|
| 1 | `CLAUDE.md`（仓库根） | 入口，指向下列文档 | 自动加载 |
| 2 | **本文**（`docs/AGENT_ONBOARDING.md`） | 对接全貌、已踩过的坑、开发与发布闭环 | 现在 |
| 3 | `编码约定.md` | **工作规范，冲突以它为准** | 动手前必读 |
| 4 | `docs/PROJECT_HANDOFF.md` | 架构导航、关键业务入口、签名现状与未来迁移 | 需要定位代码时 |
| 5 | `数据层接口文档.md`、`提醒调度接口.md` | 接口契约 | 碰数据层 / 通知时 |
| 6 | `docs/UPDATE_FLOW_GUIDE.md` | 发布/更新流程、ECS 信息、签名密钥指南、故障对照表 | 要发布时 |
| 7 | `docs/automatic-update-release.md` | 发布步骤与版本保留策略（规范原文） | 要发版时 |
| 8 | `README.md` | 面向用户的介绍、版本记录 | 需要对外说明时 |
| 9 | `V1 验收报告.md` | 2026-08-31 的 V1 验收记录 | 仅追溯历史时 |

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

> **2026-09-22 交接：此坑又犯一次。** 曾依据用户 `Ctrl+S` 保存的门户首页推断出「服务端直出 `semester.id` / `ids`」，而那是**浏览器渲染后的 DOM**、参数由 JS 事后注入；错误结论**同时写进代码与文档**，导致真机验收卡在取参、多花数轮排查。详见 §6.12。

### ⚠️ 6.6 构建产物不能进 git

`build/` 已在 `.gitignore`，但 **`dist/` 不在其中** —— 往里放 APK 后 `git status` 会亮出 `?? dist/`，一次 `git add -A` 就会把几十 MB 的包提交进库。提交时**用显式路径 `git add <文件>`，不要 `git add -A`**（工作区可能有用户自己的未提交改动）。

### ⚠️ 6.7 Android 构建的两条噪音警告

`photo_manager` 的 Kotlin Gradle Plugin 未来兼容性警告、以及本机 SDK XML 版本提示 —— **当前不阻断构建**，不要为此改代码。升级 Flutter/Gradle 前先做独立兼容性验证。

### ⚠️ 6.8 给类「加字段」后必须**热重启**，不能只热重载（2026-09-22 交接）

真机上出现 `_TypeError: type 'Null' is not a subtype of type 'Duration'`，排查数轮才发现：**Dart 热重载（小写 `r`）不会给已存在的实例补新字段初值**，读该字段得到 `null`。

**判据**：同一次会话里，某个文件的**方法体**改动生效了、另一个文件的**新增字段**改动没生效 —— **两者的差别就是答案**。**静态分析与单测发现不了**（测试里对象是新构造的，初值正常）。

**做法**：给类加字段后，让用户按 `q` 退出再 `flutter run`，**别只说「热重载一下」**。

### ⚠️ 6.9 `testWidgets` + sqflite：**默认工厂会把用例挂死**（2026-09-22 交接）

`sqflite_common_ffi` 默认的 `databaseFactoryFfi` 把 SQLite 跑在**后台 isolate**（真实异步 I/O），而 `testWidgets` 的 body 跑在**假时钟 zone** —— 真实 I/O 的 Future 永不完成 → `await db.database` 卡死，用例无限期挂起，**`--timeout` 也不生效**（症状：用例名打印出来后卡 90s+ 不报错）。

**解法**：widget 测试里建库改用 **`databaseFactoryFfiNoIsolate`**（同进程），见 `test/features/timetable_page_test.dart` 的 `_createTestDataInProcess()`。

> 注意：`test/data/test_helpers.dart` 的 `TestData.create()` 用的是**默认工厂** —— 在 `test()`（单元测试）里没问题，**在 `testWidgets()` 里会挂**。

### ⚠️ 6.10 前台跑长命令会「卡死对话」（2026-09-22 交接）

`flutter test` 等长命令若放在**前台**跑且接了 `| tail`，输出会被缓冲到结束才吐出，期间整轮对话无响应 —— 用户会以为工具坏了。**做法**：长命令一律后台跑（`run_in_background: true`），且**不要接 `tail`/`head`**（会缓冲），直接读输出文件；真要截断也等跑完再截。

另：反复打断/杀测试进程会留下**孤儿 `flutter_tester.exe`**，它锁住 `build/native_assets/windows/sqlite3.dll`，导致下一次 `flutter test` 报「Flutter failed to delete file」。解法：`taskkill //F //IM flutter_tester.exe`。

### ⚠️ 6.11 `git log -S` **不是**「含该串」的检查（2026-09-22 交接）

`git log -S"<串>"`（pickaxe）找的是**改动过该串出现次数的提交**，命中的恰是**删掉它**的那个提交，于是会把「已删干净」误报成「还有残留」。**正确做法**是逐个提交检查树内容：

```bash
for c in $(git rev-list A..B); do git grep -q "串" "$c" -- . && echo "$c 含"; done
```

### ⚠️ 6.12 交互式 / 网络契约的验证，必须用**真实响应**（2026-09-22 交接）

教务系统的接口契约**只能靠真机实测**，不要从「保存下来的页面」或推断得出。本项目已积累一批实测结论（见 `docs/教务一键导入-实施计划.md` §2），**改网络层/解析层前先读，不要重新推断**。（与 §6.5 同源，本轮又犯 —— 详见 §6.5 的追加说明。）

### 6.13 教务（EAMS 一键导入）模块边界 —— 改它之前必读（2026-09-22 交接）

- **归属**：`lib/features/timetable/eams/**` 与 `test/features/eams/**` 归 **plai-timetable**；路由 `lib/routes/**` 归 **plai-scaffold**。跨模块改动交主会话协调。
- **明文 HTTP 是必需的**：该站 HTTPS 实测不通。`network_security_config.xml` **只对 `jwglxt.zua.edu.cn` 单域名放行明文**，全局仍禁止。**不要**改成全局 `usesCleartextTraffic`，也**不要**删掉那个域名例外（删了功能直接废）。
- **登录前有 1 秒最小停留**（`EamsClient.defaultLoginFormDwell`）：服务端有「防过快点击」闸门，不等待则登录 **100% 失败**，且返回文案长得像「密码错」。这是**有意等待、不是重试**，与「绝不自动重试登录」（防锁号）的约束不冲突。**不要删。**
- **`android/app/src/main/res/raw/keep.xml` 不能删**：删掉会让 release 包的**所有提醒崩溃**（根因见 §6.14）。
- **节次沿用 Plai 默认模板前 10 节**；开学日自动取不到（`dataQuery` 只给学期 id / 学年 / 学期序，**没有起止日期**），由导入页显示 + 手动改。

**教务专题「不要做的事」**（2026-09-22 交接）：

- **不要重新推断教务接口契约** —— 实测结论见 `docs/教务一键导入-实施计划.md` §2，重查既浪费大量时间、又容易得出与证据相反的结论（§6.12 就是这么来的）。
- **不要把 `import()` 的 `plan` / `selectedChangeKeys` 改成可选**，也**不要删掉 `_buildImportJson` 的 `skipKeys`（未勾选「将新增」的剔除逻辑）** —— 前者让「预览」形同虚设（用户可能在没看到变更的情况下改掉整个学期的课表），后者会让「取消勾选某一项」静默失效。
- **不要把凭据写入 settings、日志或备份**：只允许通过独立安全存储接口保存用户**明确选择记住**的账号密码，登录摘要仍不得持久化。
- **不要自行 `git push` 或发布**（见 §3.3）。
- **不要动已发布的 `releases/*/` 目录**（immutable 缓存一年），要改只能发新版本号。

### ⚠️ 6.14 提醒「延迟 / 不送达」（暂停中）：已确证事实与**已排除方向**（提醒议题，已暂停）

**现象**（用户原话）：10 分钟内提醒**准时**；10 小时后提醒**一直不响，直到打开 App 才响**。受控复现的分界线约在 **30 分 ~ 2 小时**之间（正好是 Android 进入 Doze 的门槛）。用户已要求**暂停**此项优化。

**已确证的事实**（都有实测证据，**不要重复验证**）：

- 闹钟**确实注册在系统里、且未被截断**，覆盖整学期（`dumpsys alarm` 实测）。
- 闹钟是**精确类型**，非降级后的非精确（`window=0`、`exactAllowReason=policy_permission`、`flags=0x9` = STANDALONE\|ALLOW_WHILE_IDLE）。
- 系统**没有**对其施加 Doze/待机惩罚 —— 但注意：采样都是在设备**活跃时**取的（`device_idle=--`）。
- 电池优化白名单已豁免、MIUI 省电策略=无限制、自启动已开、`RUN_ANY_IN_BACKGROUND: allow`、`isFrozen=false`。
- 建任务之后**无任何被系统移除的记录**（Removal history 只有我们自己 `cancelAll()` 的两批）。
- 闹钟**确实会响**；**补投可观测、可复现** —— `am start` 打开 App 后两分钟内投递计数上升、已发通知立刻出现。
- 通知本身没问题（`importance=4`、渠道正常）。

**核心判断**：闹钟一直挂在系统里，**是系统不在预定时刻投递它；App 一变活跃，积压的立刻被补投**。问题**不在「有没有排上」，而在「排上了却不按时投递」**。

**已排除的方向（别再去查这些）**：

- ❌ 不是「没排上」或「被 ROM 按数量截断」
- ❌ 不是电量优化 / 后台限制
- ❌ 不是权限或调度降级（精确闹钟授权正常）
- ❌ 不是 App 崩溃（crash buffer 干净）
- ❌ 不是我们自己的 `cancelAll()` 误删
- ❌ 不是通知被静默
- ❌ 不是「重复发请求就能解决」

**剩余方向**（唯一值得深挖的）：抓一次**设备进入空闲状态时**的 `dumpsys alarm` 快照，看 `policyWhenElapsed.device_idle` 是否被推后；并观察 `Allow while idle history` 段是否**从未**出现我们的 app（目前从没出现过，可疑）。**重做实验时务必保持 USB 连接，且每次采样后确认非空**（上次跑 18 小时 150 次采样只有 2 次非空，白跑）。

**提醒专题「不要做的事」**：

- 不要重复验证上面「已确证」的事实，也不要重查「已排除」的方向 —— 每一条都有实测数据支撑，重查会浪费大量时间，且容易得出与证据相反的结论。
- **不要盲目「每次打开 App 重发一遍通知请求」** —— 该逻辑**已经在跑**（`app_shell.dart` 冷启动即 `rescheduleAll()`，开头就是 `cancelAll()` + 全量重排）；重发**不会让系统更重视它**（影响送达的是后台/电量状态与闹钟类型，不是「说了多少遍」）。
- **不要改**：渠道划分与渠道 id、通知音策略、`res/raw/keep.xml`、发布脚本的资源闸门、`plai/app_update` 通道。
- **不要在未证实前上「前台服务常驻」**（代价是常驻通知 + 耗电，根因未明前引入它属赌博）。
- **真机排查必须记录版本号** —— **2.2.2 及更早版本的「不响」多半是另一个崩溃 bug**（release 资源压缩误删通知图标 → 插件拿到资源 id 0 → `setSmallIcon(0)` → 广播接收器内崩溃），**2.2.3 已修**；否则会把崩溃误判成调度问题（历史上已这样绕过一次弯）。
- 不要动已发布的 `releases/*/` 目录（immutable 缓存一年）。

**排查命令**（`ADB="$LOCALAPPDATA/Android/sdk/platform-tools/adb.exe"`）：

```bash
# 系统里我们的闹钟（含精确类型、Doze 惩罚等字段）
"$ADB" shell dumpsys alarm | grep -A1 "com.plai.plai}"
# 投递计数与最近投递时间（判断「响过没有」）
"$ADB" shell dumpsys alarm | grep -A2 "u0a371:com.plai.plai"
# 待机分组 / 电池白名单 / 后台限制
"$ADB" shell am get-standby-bucket com.plai.plai
"$ADB" shell dumpsys deviceidle whitelist | grep plai
"$ADB" shell cmd appops get com.plai.plai RUN_ANY_IN_BACKGROUND
```

关键文件：`lib/services/notifications/notification_scheduler.dart`（调度核心）、`notification_service.dart`（渠道创建与校正）、`提醒调度接口.md` §11（遗留验证项）。

### 6.15 上述两份原始完整报告已删除，git 历史仍可查

`docs/教务一键导入-任务交接报告.md` 与 `docs/提醒送达问题交接报告.md` 的内容已并入本节后删除。需要原文时按删除历史取回：

```bash
git log --diff-filter=D -- docs/提醒送达问题交接报告.md   # 找到删除它的提交
git show <删除提交>^:docs/提醒送达问题交接报告.md          # 取回删除前的完整内容
```

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
| **本轮交付与踩坑（2026-09-22 交接）** | 2026-09-19~22 会话新增了「郑航教务课表一键导入」并做了一次仓库隐私清理。**亲身踩到的坑已并入本文件 §6**：§6.8~6.12（任何模块都适用：给类加字段后必须热重启、`testWidgets` + sqflite 会把用例挂死、前台跑长命令会卡死对话、`git log -S` 不是包含检查、交互式验证必须用真实响应）、§6.13（教务模块边界与「不要做的事」）。⚠️ **无论你要动哪个模块，§6.8~6.12 都值得先扫一眼。** |
| **提醒延迟 / 不送达（暂停中）** | 日程提醒在「距提醒时刻较远」时**不按时送达，要等用户打开 App 才补投**（±30 分内正常，2 小时以上失效）。**已确证事实、已排除方向、不要做的事、排查命令已并入本文件 §6.14。** 用户已要求暂停此项。⚠️ **接手前务必先读 §6.14** —— 其中「已排除的方向」有实测证据，直接重查会浪费大量时间，也容易得出与证据相反的结论。 |
| **正式 keystore 迁移** | 用户已确认加入待办。一次性动作，**越晚做要重装的人越多**（每个 debug 签名版本都在增加未来的重装人数）。完整 runbook 见 `docs/PROJECT_HANDOFF.md`「签名现状与未来迁移」。密钥务必长期保管：丢失 = 永久无法升级，只能换 applicationId 重发。 |
| 历史分支 | **已无残留分支**（2026-09-22 实测 `git branch -a` 只有 `master` 与 `origin/master`）。此前记的 `feature/windows-ui-shell` / `feature/windows-desktop` 均已不存在。仅剩归档 tag `archive/windows-sqlite-ffi`（`fix/windows-sqlite-ffi` 于 2026-09-12 删除时的归档，可用 `git show archive/windows-sqlite-ffi` 查阅）。 |
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
