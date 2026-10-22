# 2.2.9 更新源、检查语义与版本保留基线

## 1. 客户端行为

- **受信源是固定清单**，运行时绝不接受服务端返回的任意下载地址（沿用原设计）：
  - 主源：`https://liuyangyang.online`（新服务器）
  - 回退源：`https://liuyangyang.me`（旧服务器，**两处必须发布同一份字节**）
- **主源固定解析到 IP**：`AppUpdateConfig.hostOverrides` 把 `liuyangyang.online` 的 TCP
  连接固定到 `43.142.93.106`（`HttpClient.connectionFactory`）。域名备案未完成、
  公网 DNS/入口不可用时，客户端仍能连上新机。
  **TLS 的 SNI 与证书主机名校验仍是 `liuyangyang.online`** —— 不是「IP 直连 + 跳过校验」，
  HTTPS 强制、证书校验、路径前缀校验全部保持有效。证书 SAN 只有
  `liuyangyang.online` / `www.liuyangyang.online`，**没有 IP SAN**，所以不能用
  `https://43.142.93.106` 直连（会因主机名不匹配而握手失败）。
- ⚠️ **实现要点（2.2.8 的坑）**：一旦设置 `connectionFactory`，HttpClient **不再**替客户端
  做 TLS 包装，工厂必须自己返回已完成握手的 `SecureSocket`（见 dart:io
  `_ConnectionTarget.connect`）。2.2.8 返回了裸 `Socket`，https 请求被明文发出，
  更新检查整体失败 —— 因此 2.2.8 已撤回，以 2.2.9 为基线。
- **检查更新是三态**（2.2.9 修复）：已是最新 / 发现新版本 / 检查失败（带原因）。
  失败绝不再显示成「已是最新版本」；主源失败会按回退源重试，全部失败才报错。

## 2. 发布口径

- 两个服务器都要发布同一份 APK 与同一份 `latest.json`：
  - 新机：`ssh ubuntu@43.142.93.106`，发布目录 `/www/wwwroot/resource/data/plai-updates`
  - 旧机：`ssh root@114.55.170.117`（同一发布目录）
  - 私钥路径由操作者在发布时提供，**不写入仓库、文档或提交**。
- **版本保留**：以 2.2.9 为基线，每台服务器只保留最新 **5 个**完整版本目录
  （`tool/publish_plai_update.ps1 -KeepReleases 5`，语义版本排序），发布成功后自动删除最旧目录。
- 已发布的 `releases/<版本>/` 目录不可覆盖（客户端缓存一年），要改只能发新版本号 ——
  2.2.8 撤回也是靠发 2.2.9 实现的，没有覆盖旧目录。

## 3. 发布后核验

```powershell
# 旧机（公网域名当前可用；也可用它当跳板核对新机）
ssh -i <旧机私钥> root@114.55.170.117 "cat /www/wwwroot/resource/data/plai-updates/latest.json; ls -1 /www/wwwroot/resource/data/plai-updates/releases/; sha256sum /www/wwwroot/resource/data/plai-updates/releases/2.2.9/*.apk"
# 新机（本机 SSH 到新机偶发超时，可从旧机侧 curl 域名复核）
ssh -i <新机私钥> ubuntu@43.142.93.106 "cat /www/wwwroot/resource/data/plai-updates/latest.json; ls -1 /www/wwwroot/resource/data/plai-updates/releases/"
```

判定标准：清单里的 `version` / `size` / `sha256` 与本地构建产物一致，两台服务器一致；
四项发布闸门（签名指纹不变 / versionCode 递增 / applicationId 不变 / APK v2 方案）通过。

## 4. 2.2.7 遗留说明

2.2.7 的更新源**只有** `liuyangyang.online`（无 IP 绑定、无回退），而该域名当前在 ICP 备案中
不可公网访问 —— 已安装 2.2.7 的用户在备案完成前**无法自动检查更新**，需要手动从旧域名下载安装
2.2.9（覆盖安装即可，无需卸载，本地数据保留）。2.2.9 起该问题不再出现。
