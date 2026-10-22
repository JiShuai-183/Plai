# Plai

开始任何任务前，按顺序读（**完整顺序表见 `docs/AGENT_ONBOARDING.md` §2，那是正典**；本文与 `README.md` 文档地图、`docs/UPDATE_FLOW_GUIDE.md` 附录按同一顺序排列）：

1. **`docs/AGENT_ONBOARDING.md`** —— 对接文档：项目身份、当前状态、协作硬约定、开发与发布闭环、**已踩过的坑**、容易误判的事。**新接手者从这里开始。**
2. **仓库根 `编码约定.md`** —— 工作规范：任务分模块执行、每模块完成即单独 GIT；**模块归属表**、命名与质量门槛；AI 模块技术速查。**冲突时以它为准。**
3. **`docs/PROJECT_HANDOFF.md`** —— 架构导航、关键业务入口、签名现状与未来迁移。需要定位代码时查。
4. **`数据层接口文档.md` / `提醒调度接口.md`** —— 接口契约。碰数据层 / 通知时读。
5. **`docs/UPDATE_FLOW_GUIDE.md`** —— 发布/更新流程、ECS 信息、签名密钥指南、四条硬闸门。要发布时读。
6. **`docs/automatic-update-release.md`** —— 发布步骤与版本保留策略（规范原文）。
7. **`README.md`** —— 面向用户的介绍、版本记录。

## ⚠️ 历史交接经验已并入对接文档 —— 接手前先看你要碰的那一块

两份历史交接报告（「教务一键导入」2026-09-19~22 会话；提醒「延迟 / 不送达」**已暂停**）已删除，
其仍然有效的内容已并入 **`docs/AGENT_ONBOARDING.md` §6「已踩过的坑」**：

- **§6.8 ~ §6.12** —— 任何模块都适用的坑（给类加字段后必须热重启 / `testWidgets` + sqflite 会把
  用例挂死 / 前台跑长命令会卡死对话 / `git log -S` 不是「含该串」的检查 / 交互式验证必须用真实响应）。
  **无论你要动哪个模块，都值得先扫一眼。**
- **§6.13** —— 教务（EAMS）模块边界与「不要做的事」。
- **§6.14** —— 提醒「延迟 / 不送达」（暂停中）：已确证事实、**已排除的方向**、排查命令。
  直接重查已排除的方向会浪费大量时间。

原始完整报告已删除，**git 历史仍可查**（取回方式见 `AGENT_ONBOARDING.md` §6.15）。

## 本项目有 8 个项目内 subagent

定义在 **`.claude/agents/`**（`plai-scaffold` / `plai-data` / `plai-timetable` / `plai-schedule` / `plai-notify` / `plai-settings` / `plai-review` / `plai-update`），由主会话按 Agent/Task 工具派发，**agent 名即各文件 frontmatter 的 `name`**。

- 名册、文件归属矩阵、**触发词到 agent 的映射**、以及哪些模块没有归属 agent（AI / audio）见 `.claude/agents/README.md`
- 动手前先确认你要改的目录归谁 —— **文件只允许由归属 agent 修改**，跨模块改动交主会话协调
- 不要自行新增 agent 定义，需先与用户确认

### ⚠️ 用户提到「打包 / 发版 / 发布 / 出包」时必须派发 `plai-update`

用户说**「打包新版本」「发版」「出包」「发布新版本」「构建 release」「上架」「更新包」**，或反馈**「用户装不上」「更新失败」「签名不对」**时，**派发 `.claude/agents/plai-update.md`**，不要自己直接跑构建发布命令。

理由：能否被已装用户覆盖安装，只由**四条硬闸门**决定（签名指纹 / versionCode 递增 / applicationId 不变 / 签名方案 v2），而 `plai-update` 内置了这套 fail-closed 校验。绕过它直接发布，风险是发出版本用户装不上 —— 而用户必须卸载重装，**本地 SQLite 数据会随之清空**。

### 「打包发布」= 三同步（缺一即未完成）

用户说**「打包发布」**时，必须一次做完三件事：

| # | 同步项 | 落地方式 |
|---|---|---|
| 1 | **服务器资源** | `tool/publish_plai_update.ps1`：上传 APK → 原子替换 `latest.json` → 保留最新 5 个版本 |
| 2 | **GitHub Releases** | `gh release create v<版本> <APK>`：同一份包与说明，tag 打在 master |
| 3 | **GitHub 文档** | README 版本记录 + `AGENT_ONBOARDING` 快照 + `PROJECT_HANDOFF` 线上版本 + `docs/automatic-update-release.md`，随同一次 push 到 master |

一键脚本：**`tool/release_plai.ps1 -Version <版本> -IdentityFile <本机私钥绝对路径> -Notes '<说明>' -Announcement '<公告>'`**
（先校验文档已写本版本 → analyze/test → 构建 → 四道硬闸门 → 服务器发布 → GitHub Release）。

私钥由所有权人**线下拷贝**交付，**绝不入库、绝不上传 GitHub**；发布前**需提示开发者提供本机私钥地址**，脚本只用路径、不读内容。

本文件仅作入口，内容不在此处重复。

> 文档里的提交号、版本号、线上状态**都会过期** —— 一律用 `git log -1`、`grep "^version:" pubspec.yaml`、`curl` 线上 `latest.json` 实测，不要相信任何一份文档（包括 `AGENT_ONBOARDING.md`）。
