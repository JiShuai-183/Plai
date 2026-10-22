# 更新通道：只走新服务器 IP 直连

> 现行口径自 **2.3.1** 起生效。旧服务器与旧域名已从更新链路中移除。

## 1. 唯一受信源

| | 值 |
|---|---|
| 清单 | `https://43.142.93.106/downloads/plai/latest.json` |
| 安装包 | `https://43.142.93.106/downloads/plai/releases/<版本>/Plai-android-<版本>.apk` |
| 传输 | HTTPS + 证书校验（服务器持有 Let's Encrypt 的 **IP 证书**，SAN = `IP Address:43.142.93.106`，由 `xrun-cert-renew.timer` 自动续期，有效期 6 天） |
| DNS | **不使用**。URL 里就是 IP，域名备案状态、DNS 解析、域名拦截都不影响更新 |

- 运行时绝不接受服务端返回的任意下载地址（只认这份固定清单）。
- 2.3.1 起`AppUpdateConfig.fallbackOrigins` 默认**为空**：没有旧服务器、没有域名回退。
  若该 IP 不可达，检查更新会**如实报失败**，不会悄悄退回旧地址。

## 2. 检查更新的三态语义

已是最新 / 发现新版本 / **检查失败（带可读原因）**。失败不会显示成「已是最新版本」；
启动自动检查保持静默，手动检查如实报错。

两条硬约束（2.3.3 真机反馈「启动 3 秒后没反应」后补上）：

1. **所有网络操作必须有超时**：清单请求 15 秒、下载连接 20 秒、下载空闲 30 秒。
   没有超时的话，冷启动时网络/证书握手未就绪会让请求一直挂着 —— 既没有提示也没有报错。
2. **启动检查必须退避重试**（+6s / +15s / +30s）：冷启动后 3 秒检查一次失败是常态
   （移动网络刚唤醒），只试一次就等于「什么都不发生」。重试全部失败时只写日志、不打扰首屏。

## 3. 发布口径（只发布到新服务器）

| | 地址 | 登录 | 发布目录 |
|---|---|---|---|
| 新机 | 43.142.93.106 | `ubuntu` | `/www/wwwroot/resource/data/plai-updates` |

私钥由所有权人**线下拷贝**交付给执行发布的人，**不写入仓库、文档或提交，也不上传 GitHub**（公开仓库；`.gitignore` 对 `*.pem` 只是兜底）。发布前**需提示开发者提供本机私钥地址**（`-IdentityFile`），脚本只用路径、不读内容。

- **版本保留**：只保留最新 **5 个**完整版本目录（`-KeepReleases 5`，语义版本排序），
  发布成功后自动删除最旧目录。
- 已发布的 `releases/<版本>/` 不可覆盖（客户端缓存一年），要改只能发新版本号。
- 发布命令示例：

```powershell
.\tool\publish_plai_update.ps1 -Version <版本> `
  -AndroidApk .\build\app\outputs\flutter-apk\Plai-android-<版本>.apk `
  -IdentityFile <本机私钥绝对路径> -HostName 43.142.93.106 -SshUser ubuntu `
  -Notes '<更新内容>' -Announcement '<公告>'
```

### 新机的 Web 映射

443 默认 vhost（`/opt/x-run/shared/ingress/apache-ip-ssl.conf`，x-run 管理）里有：

```apache
Alias /downloads/plai/ /www/wwwroot/resource/data/plai-updates/
ProxyPass /downloads/plai/ !
```

> ⚠️ 该文件归 x-run 管理，**升级 x-run 可能覆盖这段**。升级后请自检：
> `curl -sS -o /dev/null -w '%{http_code}' https://43.142.93.106/downloads/plai/latest.json` 应为 200；
> 不是就补回上面两行并 `sudo systemctl reload apache2`。

## 4. 发布后核验

```powershell
# 主源（IP 直连，不要加 -k：证书必须真的能通过校验）
ssh -i <新机私钥> ubuntu@43.142.93.106 "curl -sS https://43.142.93.106/downloads/plai/latest.json; ls -1 /www/wwwroot/resource/data/plai-updates/releases/; sha256sum /www/wwwroot/resource/data/plai-updates/releases/<版本>/*.apk"
```

判定标准：清单 `version` / `size` / `sha256` 与本地构建产物一致；四项闸门
（签名指纹不变 / versionCode 递增 / applicationId 不变 / APK v2 方案）通过；
`Range` 请求返回 206（断点续传）。

## 5. 旧服务器已退役（2026-10-22）

删除了旧机 114.55.170.117 上的**全部** Plai 资产与映射：

- `/www/wwwroot/resource/data/plai-updates/`（`latest.json` + `releases/`，约 300 MB）→ 已删除
- 宝塔代理配置 `/www/server/panel/vhost/apache/proxy/blog.liuyangyang.me/00-plai-updates.conf` → 已删除（备份在 `/root/plai-updates.conf.bak-`）
- 旧域名 `https://liuyangyang.me/downloads/plai/...` 现由站点 SPA 兜底返回 HTML，客户端会判定为「检查失败」

**受影响范围**：2.2.6 及更早版本的更新入口指向旧域名，因此它们**再也无法自动更新**，
只能手动安装 2.3.1（覆盖安装，数据保留）。2.2.7 起指向新服务器（2.2.7/2.2.8 因域名不可达同样需手动安装）；
2.3.1 是第一个「只有新服务器一条通道」的版本。

## 6. GitHub Releases 同步

每次发布除了上服务器，同名 APK 也会传到 GitHub Releases（tag = `v<版本>`），作为**手动下载**的备用入口：

`https://github.com/JiShuai-183/Plai/releases`

注意：客户端**只认**本文第 1 节那份 HTTPS 清单，**不读 GitHub**。Releases 只解决「新用户/卡在旧版本的人想手动拿包」这一个需求，不能替代服务器上的 `latest.json` 与 `releases/`。
