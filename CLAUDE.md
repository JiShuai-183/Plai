# Plai

开始任何任务前，按顺序读（**完整顺序表见 `docs/AGENT_ONBOARDING.md` §2，那是正典**；本文与 `README.md` 文档地图、`docs/UPDATE_FLOW_GUIDE.md` 附录按同一顺序排列）：

1. **`docs/AGENT_ONBOARDING.md`** —— 对接文档：项目身份、当前状态、协作硬约定、开发与发布闭环、**已踩过的坑**、容易误判的事。**新接手者从这里开始。**
2. **仓库根 `编码约定.md`** —— 工作规范：任务分模块执行、每模块完成即单独 GIT；**模块归属表**、命名与质量门槛；AI 模块技术速查。**冲突时以它为准。**
3. **`docs/PROJECT_HANDOFF.md`** —— 架构导航、关键业务入口、签名现状与未来迁移。需要定位代码时查。
4. **`数据层接口文档.md` / `提醒调度接口.md`** —— 接口契约。碰数据层 / 通知时读。
5. **`docs/UPDATE_FLOW_GUIDE.md`** —— 发布/更新流程、ECS 信息、签名密钥指南、四条硬闸门。要发布时读。
6. **`docs/automatic-update-release.md`** —— 发布步骤与版本保留策略（规范原文）。
7. **`README.md`** —— 面向用户的介绍、版本记录。

## 本项目有 8 个项目内 subagent

定义在 **`.claude/agents/`**（`plai-scaffold` / `plai-data` / `plai-timetable` / `plai-schedule` / `plai-notify` / `plai-settings` / `plai-review` / `plai-update`），由主会话按 Agent/Task 工具派发，**agent 名即各文件 frontmatter 的 `name`**。

- 名册、文件归属矩阵、**触发词到 agent 的映射**、以及哪些模块没有归属 agent（AI / audio）见 `.claude/agents/README.md`
- 动手前先确认你要改的目录归谁 —— **文件只允许由归属 agent 修改**，跨模块改动交主会话协调
- 不要自行新增 agent 定义，需先与用户确认

### ⚠️ 用户提到「打包 / 发版 / 发布 / 出包」时必须派发 `plai-update`

用户说**「打包新版本」「发版」「出包」「发布新版本」「构建 release」「上架」「更新包」**，或反馈**「用户装不上」「更新失败」「签名不对」**时，**派发 `.claude/agents/plai-update.md`**，不要自己直接跑构建发布命令。

理由：能否被已装用户覆盖安装，只由**四条硬闸门**决定（签名指纹 / versionCode 递增 / applicationId 不变 / 签名方案 v2），而 `plai-update` 内置了这套 fail-closed 校验。绕过它直接发布，风险是发出版本用户装不上 —— 而用户必须卸载重装，**本地 SQLite 数据会随之清空**。

本文件仅作入口，内容不在此处重复。

> 文档里的提交号、版本号、线上状态**都会过期** —— 一律用 `git log -1`、`grep "^version:" pubspec.yaml`、`curl` 线上 `latest.json` 实测，不要相信任何一份文档（包括 `AGENT_ONBOARDING.md`）。
