# Plai 更新流程指南

> **规范版位置**：本文件（仓库 `docs/UPDATE_FLOW_GUIDE.md`）。**交接包**里的 `Plai更新流程指南.md`（位置见文末「所有者本机环境备注」）是同一内容的交付副本 —— **改内容请改这里，再同步副本**，不要反过来。仓库内不再保留第二份副本。
> **读这份文档的人**：接手 Plai 的开发者，以及你背后的 AI 助手。
> **要解决的问题**：在**一台新机器**上打包，如何让**已经装了 Plai 的用户能正常更新**。
> **一句话答案**：发布这一步谁都能做，但能不能被用户装上，只取决于一件事 —— **签名密钥是不是同一份**。
> 远端仓库：`https://github.com/JiShuai-183/Plai.git`（**公开仓库**）。**本文所有路径一律相对仓库根目录**，不含任何机器相关的绝对路径（少数外部资源位置统一放在文末「所有者本机环境备注」）。
> 快照时间：**2026-09-11**。凡涉及版本号、线上状态的内容都会过期，以实测为准。

---

## 0. 先记住这条判断标准

新机器上打出来的包，能不能被老用户装上？**只看签名指纹**：

| 项 | 值 |
|---|---|
| 目标 SHA-256 | `BF:7B:40:8B:1A:AD:0B:D5:D7:E7:6F:E3:55:8B:F8:ED:F9:5B:9A:93:34:8B:D2:75:5F:6E:46:EC:74:5A:1B:9E` |
| 目标 SHA-1 | `A7:F1:F5:76:71:59:AE:39:AC:EE:44:E9:11:F8:1D:E9:8D:70:9A:02` |
| 证书 DN | `CN=Android Debug, O=Android, C=US` |
| 证书有效期 | 2026-09-11 → **2056-09-03**（30 年，非近期风险） |
| 签名方案 | **v2（APK Signature Scheme v2），且仅 v2** —— 见下方「签名方案」 |

另外三条同样会让用户装不上的硬条件，见第 0 节末尾的检查表。

构建后立刻验：

```bash
apksigner verify --print-certs build/app/outputs/flutter-apk/Plai-android-<版本>.apk
```

**指纹不一致 → 用户 100% 装不上**（`INSTALL_FAILED_UPDATE_INCOMPATIBLE`），用户必须先卸载，而卸载会**清空全部本地数据**（课表、日程都在 SQLite 里）。所以这一步不是可选检查，是发布前的硬闸门。

### 发布前的四条硬闸门（缺一条用户就装不上）

| # | 检查项 | 必须满足 | 违反后果 |
|---|---|---|---|
| 1 | 签名证书指纹 | `BF:7B:40:8B:…:1B:9E` | 装不上（`INSTALL_FAILED_UPDATE_INCOMPATIBLE`），用户须卸载 → **本地数据清空** |
| 2 | `versionCode` | **大于**上一版（当前 9） | 系统拒绝覆盖安装 |
| 3 | `applicationId` | `com.plai.plai` 不变 | 装成另一个 App，用户数据不继承 |
| 4 | **签名方案** | 保持 **v2**（AGP 默认，勿手工改） | 若产出 **v3-only**，Android 7/8 无法验证签名 → 装不上 |

第 4 条容易忽略：线上 APK 实测为 **v2-only**（v1/v3 均未启用），而 `minSdk = 24`（Android 7），v2 恰好满足 —— **正好卡在边界上**。所以不要动 `enableV1Signing` / `enableV2Signing` / `enableV3Signing` 之类的签名方案配置，AGP 默认产出的就是对的。

---

## 第一部分：更新是怎么运作的（给 AI 读的机制说明）

### 客户端行为

发布模式下，`AppShell` 首帧后 **3 秒**调用 `runStartupUpdateFlow`（`lib/services/app_update/app_update_flow.dart`）：

1. 读取**固定** HTTPS 清单（`AppUpdateConfig` 中写死，不可配置）：
   `https://liuyangyang.me/downloads/plai/latest.json`
2. 解析清单 → 按当前平台取 `assets[平台键]`，平台键为 `android` / `ios`
   （代码依据：`lib/services/app_update/app_update_service.dart` 的 `AppUpdatePlatform` —— 只有 `android` / `ios` / `unsupported`；`windows-x64` 已随 2.2.0 移除桌面端一并废弃）
3. 与本地版本比较；有更新则弹窗
4. 用户确认 → 下载 → 校验 → 交给系统安装

### 客户端接受的校验规则（发布时别踩）

- `path` 必须是**同 origin** 的**安全相对路径**，且**必须以 `releases/` 开头**
- 必须提供 `size` 与 `sha256`，下载后逐字节校验 → **清单里的 sha256 与产物不一致 = 所有用户更新失败**
- 支持 HTTP **Range 断点续传**
- Android 通过原生通道安装：`MethodChannel plai/app_update`（`android/app/src/main/kotlin/com/plai/plai/MainActivity.kt`）
- iOS **只**接受 `apps.apple.com` 地址并跳转 App Store，**不做** APK 式覆盖安装
- **取不到对应平台的 asset 会抛异常**（被 flow 的 `catch` 吞掉 → 表现为「静默收不到更新」，不报错、不崩溃）

> ⚠️ 这最后一条解释了历史现象：线上清单 2026-09-11 起改为 **android-only**，所以老的 Windows 客户端从此收不到更新 —— 那是预期行为（Windows 平台已下架），不是 bug。

### 清单格式（`latest.json`，schemaVersion 1）

```json
{
  "schemaVersion": 1,
  "version": "2.2.1",
  "notes": "更新说明，安装前弹窗展示",
  "announcement": "公告，安装完成后下次启动展示",
  "assets": {
    "android": {
      "name": "Plai-android-2.2.1.apk",
      "path": "releases/2.2.1/Plai-android-2.2.1.apk",
      "size": 60103503,
      "sha256": "22e47032d865fda5e25aedc7b9dee3a8b591d897c3af56ec981f9405af293b7a"
    }
  }
}
```

`assets.ios` 为可选项：`{"storeUrl": "https://apps.apple.com/..."}`。

### 让用户能装的三个硬条件

| # | 条件 | 说明 |
|---|---|---|
| 1 | **签名指纹不变** | 见本文第 0 节与第三部分。**最容易在新机器上踩的一个** |
| 2 | **versionCode 递增** | 来自 `pubspec.yaml` 的 `version: <版本>+<build号>`。不递增 → 系统拒绝覆盖安装 |
| 3 | **applicationId 不变** | 固定 `com.plai.plai`（`android/app/build.gradle.kts`）。改了 = 装成另一个 App |

---

## 第二部分：ECS 信息指南

### 服务器

| 项 | 值 |
|---|---|
| 主机 | `liuyangyang.me` |
| SSH 用户 / 端口 | `root` / `22` |
| 系统 | Ubuntu 20.04.6 LTS (Focal Fossa) |
| Web 服务 | Apache **2.4.62** 实际提供下载；前面有 nginx 1.18.0 |
| 发布根目录 | `/www/wwwroot/resource/data/plai-updates/` |
| 公网路径 | `https://liuyangyang.me/downloads/plai/` |
| 清单固定地址 | `https://liuyangyang.me/downloads/plai/latest.json` |
| 当前占用 | 约 287 MB |

### 目录结构

```
/www/wwwroot/resource/data/plai-updates/
├── latest.json                 ← 唯一可变的文件，客户端只读它
└── releases/
    ├── 2.1.5/Plai-android-2.1.5.apk
    ├── 2.1.6/...
    ├── 2.1.7/...
    ├── 2.2.0/...
    └── 2.2.1/Plai-android-2.2.1.apk
```

### Web 映射与缓存策略

映射配置已纳入仓库：`ops/apache/plai-updates.conf`（放到宝塔 Apache 的 proxy include 目录，用 `00-` 前缀保证优先级）。

```apache
ProxyPass /downloads/plai/ !                     # 在全站 ProxyPass 之前排除本路径
Alias /downloads/plai/ "/www/wwwroot/resource/data/plai-updates/"

<Location "/downloads/plai/latest.json">
    Cache-Control: no-cache, no-store, must-revalidate    # 清单强制不缓存
    X-Content-Type-Options: nosniff
    ForceType application/json
</Location>

<LocationMatch "^/downloads/plai/releases/">
    Cache-Control: public, max-age=31536000, immutable    # 产物缓存一年
    X-Content-Type-Options: nosniff
</LocationMatch>
```

**这里有一条必须遵守的推论**：`releases/` 下的文件被声明为 `immutable` 且缓存一年 —— 所以**绝不要覆盖已发布版本目录里的内容**。要改就发新版本号，走新目录。

> `ops/nginx/` 是个空目录：nginx 侧配置**未纳入仓库**（只在服务器上）。要改 nginx 行为必须上服务器看，别以为仓库里有。

### 版本保留策略

发布脚本会**只保留最新 5 个版本目录**，更旧的在发布成功后自动整体删除（`-KeepReleases`，默认 5）。要点：

- 排序用 `sort -V`（语义版本）。**用词法排序会把 `2.1.10` 当最旧版本误删**
- 清理在**发布成功之后**执行，失败只告警、不回滚已生效的发布
- **本次发布的版本永不被清理**（防「回滚式发布旧版本」时把自己删掉）
- 只匹配「数字点分（可带 `-`/`+`）」的目录名，`.staging-*` 等一律不动
- 客户端不依赖任何具体旧版本目录（APK 地址一律取自清单 `path`），所以裁剪旧版本不会让在线客户端失效

### 磁盘

`/` 共 40G，已用 31G，**剩约 7.5G（81% 已用）**。每个版本约 60MB，5 个约 300MB，稳态压力不大 —— 但别在这台服务器上堆大文件。

### ECS 私钥（必须向项目所有者索取）

- 私钥**不在仓库里，也不要放进仓库**。向项目所有者单独索取。
- 私钥路径属于机器相关信息，本文不写死；所有者本机的具体位置见文末「所有者本机环境备注」。
- ⚠️ **脚本使用 `StrictHostKeyChecking=yes` + `BatchMode=yes`** —— 即不弹任何交互提示。**新机器首次使用前必须先接受主机指纹**，否则会以一句难懂的报错直接失败：

  ```bash
  ssh-keyscan -p 22 liuyangyang.me >> ~/.ssh/known_hosts
  # 或先手动连一次并确认：ssh -p 22 root@liuyangyang.me
  ```

---

## 第三部分：debug key 指南（新机器必读）

### 现状：release 用的是「debug 签名」

`android/app/build.gradle.kts`：

```kotlin
buildTypes {
    release {
        signingConfig = signingConfigs.getByName("debug")   // ← AGP 内置 debug 配置
    }
}
```

`signingConfigs.getByName("debug")` 是 Android Gradle Plugin 内置的配置，指向：

```
~/.android/debug.keystore          # Windows: C:\Users\<用户名>\.android\debug.keystore
```

### 关键事实：这份 keystore 是**机器本地随机生成**的

- 本机这份生成于 **2026-09-11 20:38**，2618 字节
- 它**不是**任何标准值，**每台机器都不同**，而且是随机的 —— **无法重新生成出相同的一份**
- 线上**所有已发布版本（2.1.3 起）都由它签名**

所以：**新机器上直接构建 → 生成的 debug keystore 不同 → 签名不同 → 老用户装不上。**

### 备份位置与内容

```
<keystore 备份目录>\
├── debug.keystore          2618 bytes（原样副本，已验证逐字节一致）
└── 说明-必读.md             来历、指纹、口令、用法、安全注意
```

> `<keystore 备份目录>` 是本机路径，不写死在文档里；所有者本机的实际位置见文末「所有者本机环境备注」。

### 口令（Android debug 公开约定的默认值，不是秘密）

```
storepass: android
keypass:   android
alias:     androiddebugkey
```

### 新机器操作（**必须在第一次构建之前做**）

1. 从项目所有者处取得 `debug.keystore`。**交付方式为线下**（微信 / 加密网盘 / U 盘等私有渠道）——
   ⚠️ **绝不要把它提交进本仓库或任何公开仓库**。本仓库是公开仓库，且该文件的口令是 Android 公开默认值，
   文件本身就是全部秘密：一旦入库，等于把 App 的签名身份永久公开（git 历史不可回收、GitHub 无法清理 fork），
   此后任何人签出的 APK 在签名上都无法与正版区分。`.gitignore` 已用 `*.keystore` 拦截，
   正常 `git add` 会被拒 —— 若有人要用 `git add -f` 绕过，那就是这个动作本身该被叫停的信号。
2. 覆盖到新机器的默认位置：
   - Windows：`C:\Users\<用户名>\.android\debug.keystore`
   - macOS / Linux：`~/.android/debug.keystore`
   - 该文件通常已由构建工具自动生成过一份，**直接替换**即可
3. 然后才执行构建
4. 构建后**必须**校验指纹（第 0 节的 `apksigner verify`），与 `BF:7B:40:8B:…:1B:9E` 一致才能发布

> 若在构建之后才发现签名不对，不用慌：替换 keystore 后重新构建即可，`flutter clean` 更保险。

### 丢失的后果（务必让所有者知道）

这份密钥**一旦丢失，就再也无法给已装用户发更新**。唯一补救是换 `applicationId` 换包名重发 —— 等于让所有用户重装一个「新 App」，本地数据随卸载清空。

所以：**不要在服务器上、也不要在仓库里存密钥；备份必须放在机器之外**（私人网盘 / U 盘 / 密码管理器附件）。目前 `<keystore 备份目录>` 这份备份**仍在同一台机器上**，防不了硬盘故障与系统重装。

### ⚠️ 安全注意

- 口令是公开默认值 → **任何拿到这份 keystore 的人都能签出与正版同签名的 APK**
- **本 GitHub 仓库是公开的**，`debug.keystore`、`key.properties`、任何 `.pem`/`.jks` **绝对不得提交**（`.gitignore` 已加规则挡住这些，但不要依赖它兜底）
- 真正拦住攻击者的只有更新清单服务端（HTTPS + 清单里的 SHA-256 由服务器控制）—— 所以 **ECS 私钥与服务器权限要和这份密钥同等严格看管**。同时拿到 keystore 和服务器权限的人，可以给全部用户推任意安装包。

### 长期正解：正式 keystore 迁移

上面这套「用口令公开的 debug keystore 当生产密钥」只是权宜。长期应做一次正式 keystore 迁移：自定口令、明确备份、可放心交接。代价是现有用户需一次性「导出 `.plai` 备份 → 卸载 → 装新版 → 恢复备份」。完整 runbook 见仓库 `docs/PROJECT_HANDOFF.md` 的「签名现状与未来迁移」。

---

## 第四部分：完整的发布操作

### 0）环境准备（新机器）

- Flutter **3.47.x**（本机 3.47.2）/ Dart 3.13.2
- JDK **17**（构建用；`apksigner` 由 Android SDK 提供）
- Android SDK：platform 36、build-tools 36（`apksigner` / `aapt` 在这里）
- ⚠️ **先放好 debug.keystore**（第三部分）
- ⚠️ **先接受 ECS 主机指纹**（第二部分）

### 1）建立基线（必须全绿）

```bash
flutter pub get
flutter analyze      # 期望：No issues found!
flutter test         # 期望：All tests passed!（344 项）
```

> `flutter test` 打印 `NotificationService.initialize 失败: LateInitializationError` 是**测试宿主不支持通知初始化的正常噪音**，以最终退出结果为准。

### 2）递增版本号（必须）

编辑 `pubspec.yaml`：

```yaml
version: 2.2.1+9      # → 例如 2.2.2+10：语义版本 + build number，两者都要动
```

**build number 不递增 = 用户装不上（系统拒绝覆盖）。**

### 3）构建并按线上命名改名

```bash
flutter build apk --release

# 脚本以「本地文件名」生成清单里的 name，所以必须改成线上约定
cp build/app/outputs/flutter-apk/app-release.apk \
   build/app/outputs/flutter-apk/Plai-android-<新版本号>.apk
```

### 4）校验（硬闸门）

```bash
apksigner verify --print-certs build/app/outputs/flutter-apk/Plai-android-<新版本号>.apk
# → 指纹必须为 BF:7B:40:8B:…:1B:9E

aapt dump badging build/app/outputs/flutter-apk/Plai-android-<新版本号>.apk | head -1
# → versionCode 必须是递增后的值，versionName 必须为新版本号
```

### 5）发布

**方式 A：用仓库脚本（Windows / 任一装了 PowerShell 7 的平台）**

```powershell
.\tool\publish_plai_update.ps1 `
  -Version <新版本号> `
  -AndroidApk .\build\app\outputs\flutter-apk\Plai-android-<新版本号>.apk `
  -IdentityFile <ECS 私钥路径> `
  -Notes '<更新说明>' `
  -Announcement '<公告>'
```

脚本行为：先传到 `.staging-*` → 校验 staging 里的清单存在 → 原子替换 `latest.json` → 按保留策略清理旧版本。任何一步失败都不会留下半成品。

**方式 B：手写命令（macOS / Linux，或不装 PowerShell）**

原理与脚本完全一致，照抄即可：

```bash
VERSION=2.2.2
KEY=~/keys/plai-ecs.pem
HOST=root@liuyangyang.me
REMOTE=/www/wwwroot/resource/data/plai-updates
APK=build/app/outputs/flutter-apk/Plai-android-$VERSION.apk

SIZE=$(stat -c%s "$APK")                    # macOS 用: stat -f%z "$APK"
SHA=$(sha256sum "$APK" | cut -d' ' -f1)     # macOS 用: shasum -a 256 "$APK" | cut -d' ' -f1

cat > /tmp/latest.json <<EOF
{"schemaVersion":1,"version":"$VERSION","notes":"更新说明","announcement":"公告","assets":{"android":{"name":"Plai-android-$VERSION.apk","path":"releases/$VERSION/Plai-android-$VERSION.apk","size":$SIZE,"sha256":"$SHA"}}}
EOF

STAGE=".staging-$VERSION-$$"
ssh -i "$KEY" -o StrictHostKeyChecking=yes "$HOST" "mkdir -p '$REMOTE/$STAGE' '$REMOTE/releases/$VERSION'"
scp -i "$KEY" -o StrictHostKeyChecking=yes "$APK" /tmp/latest.json "$HOST:$REMOTE/$STAGE/"
ssh -i "$KEY" -o StrictHostKeyChecking=yes "$HOST" \
  "set -e; cd '$REMOTE'; test -f '$STAGE/latest.json'; mv '$STAGE/$(basename $APK)' 'releases/$VERSION/'; mv '$STAGE/latest.json' 'latest.json'; rmdir '$STAGE'"
```

> 手写方式**不含**版本保留清理。要么单独清理，要么用脚本。

### 6）发布后核验（必做，别凭感觉）

```bash
curl -s https://liuyangyang.me/downloads/plai/latest.json
# → version 与 sha256 必须是新版本

# 下载线上产物，比对实际字节的 sha256 == 清单声明值（这就是客户端安装前的校验路径）
curl -s -o /tmp/check.apk https://liuyangyang.me/downloads/plai/releases/<版本>/Plai-android-<版本>.apk
sha256sum /tmp/check.apk
```

**三者必须一致：线上实际字节 == 清单声明 == 本地构建产物。** 不一致 = 所有用户更新失败。

---

## 第五部分：故障对照表

| 症状 | 原因 | 处理 |
|---|---|---|
| 用户点安装，直接失败 | **签名指纹不同**（最常见） | 核对第 0 节指纹；确认新机器用的是同一份 debug.keystore |
| Android 7/8 用户装不上，新机型正常 | APK 变成了 v3-only 签名 | 恢复默认签名方案（保持 v2）；`apksigner verify --verbose` 确认 v2 = true |
| 用户装上了但版本没变 | versionCode 未递增 | 递增 `pubspec.yaml` 的 build number 后重发 |
| 客户端一直提示「已是最新」 | 清单 `version` 未更新 / `latest.json` 没替换成功 | 实测 `curl` 清单 |
| 下载完成但安装报校验错误 | 清单 `sha256`/`size` 与产物不符 | 重新发布；核对发布后 sha256 |
| 老 Windows 客户端收不到更新 | 清单已改为 android-only | **预期行为**，Windows 已下架 |
| `Host key verification failed` | 新机器未接受主机指纹（脚本 BatchMode + StrictHostKeyChecking=yes） | `ssh-keyscan -p 22 liuyangyang.me >> ~/.ssh/known_hosts` |
| 远端报 `set: -: invalid option` / `cd: $'...\r'` | 从 Windows CRLF 的 `.ps1` 把裸 CR 发给了 Linux shell | 生成远端命令时归一化换行（脚本已修；改脚本时别破坏它） |
| `flutter_launcher_icons` 后 `git status` 报 `ios/Runner.xcodeproj/project.pbxproj` 是 `M` 但 `git diff` 为空 | git 的 racy-clean stat 缓存（生成器用相同内容重写了文件） | `git add` 该文件刷新即可，**不是生成出错** |
| 换了图标但 App 里没变 | 只改了图没重新生成 | `dart run flutter_launcher_icons`；源图要求：正方形、≥1024×1024、**无 alpha**、**平铺方图（不可自带圆角/阴影）** |

---

## 第六部分：禁止事项

1. **不要把 `debug.keystore`、`key.properties`、`.jks`、`.pem`、`.env` 提交进仓库** —— 本仓库是公开的。
2. **不要覆盖 `releases/<已有版本>/` 里的任何文件** —— 该路径被声明为 `immutable` 且缓存一年。
3. **不要修改 `applicationId`**（`com.plai.plai`）—— 改了就是另一个 App。
4. **不要跳过发布后的 sha256 核验** —— 客户端会做同样的校验，不匹配等于白发布。
5. **不要把 ECS 私钥放进仓库或本文档所在目录** —— 单独保管。
6. **不要用词法排序实现版本清理** —— 必须 `sort -V`。
7. **不要在没有新机器签名校验的情况下发布** —— 用户装不上的代价是丢数据。

---

## 附：与仓库内文档的关系

> 顺序与 `docs/AGENT_ONBOARDING.md` §2「阅读顺序」（正典）一致。

| 文件 | 管什么 |
|---|---|
| `CLAUDE.md`（仓库根） | 入口，指向下列文档（工具自动加载） |
| `docs/AGENT_ONBOARDING.md` | 项目整体对接：身份、状态、协作约定、开发闭环、已踩过的坑 |
| `编码约定.md` | 有约束力的工作规范（冲突时以它为准） |
| `docs/PROJECT_HANDOFF.md` | 架构导航、关键业务入口、签名迁移深度说明 |
| `数据层接口文档.md` / `提醒调度接口.md` | 数据层与提醒调度的接口契约 |
| **本文**（`docs/UPDATE_FLOW_GUIDE.md`） | 更新与发布全流程、ECS 信息、签名指南、故障排查 |
| `docs/automatic-update-release.md` | 发布与保留策略的规范原文 |
| `README.md` | 面向用户的介绍、版本记录 |

*本文创建：2026-09-11*

---

## 附：所有者本机环境备注（不属于流程，换机器时忽略）

本文正文刻意不含机器相关绝对路径。以下为**当前这台机器**的实际位置，仅供所有者本人参考，**不要连同文档一起分发给他人**。

> ⚠️ 本表是**逐机器**的：换机器后必须重新核对，**不要照抄**。表里每一条都应在该机器上实测存在再采信。

| 资源 | 本机位置（2026-09-12 实测） |
|---|---|
| keystore | `D:\图片\Plai开发交接指南\Plai开发交接指南\App签名密钥\debug.keystore` —— 2618 B，指纹实测 `BF:7B:40:8B:…:1B:9E` ✓（**已确认是生产签名身份**） |
| ECS 私钥 | `D:\图片\Plai开发交接指南\Plai开发交接指南\ECS服务器配置及其密钥\geeee.pem` |
| 服务器连接信息 | `D:\图片\Plai开发交接指南\Plai开发交接指南\ECS服务器配置及其密钥\配置信息.txt` |
| 交接包（交付介质） | `D:\图片\Plai开发交接指南\Plai开发交接指南\` —— 上面两项都在包内 |
| 仓库 | `D:\Study\Project\Plai` |
| JDK | `C:\Program Files\Java\jdk-17` |

**注意 keystore 的当前形态**：它只存在于**交接包内**，并未安装到 `~/.android/debug.keystore`。本机那份默认 keystore 是 AGP 自动生成的**另一份**（指纹 `AA:E3:92:42:…:07:17:3D`），**用它构建出来的包老用户装不上**。要在本机发布，先按第三部分第 2 步把包内这份覆盖过去，再验指纹。
