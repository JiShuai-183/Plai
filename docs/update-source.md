# 更新源、检查语义与版本保留基线（当前口径）

> 版本相关历史变更见 README「版本记录」；本文只写**现行口径**，不再随版本号改名。

## 1. 客户端行为

受信源是一份**固定清单**，运行时绝不接受服务端返回的任意下载地址：

| 顺序 | 源 | 说明 |
|---|---|---|
| 1（主源） | `https://43.142.93.106` | **IP 直连，完全不经过域名解析**。服务器对该 IP 持有 Let's Encrypt 的 IP 证书（SAN = `IP Address:43.142.93.106`，由服务器 `xrun-cert-renew.timer` 自动续期），所以仍是完整 HTTPS + 证书校验，备案未完成也能更新。 |
| 2（回退） | `https://liuyangyang.online` | 新域名。备案通过后可作为替代入口（当前公网不可用）。 |
| 3（回退） | `https://liuyangyang.me` | 旧服务器域名，长期回退入口。 |

- 主源失败 → 依次尝试回退源；**下载始终回到命中清单的那个源**，不跨源混用。
- 三处发布的必须是**同一份字节**（同一 APK、同一 `latest.json`）。

### 检查更新是三态（2.2.9 起）

已是最新 / 发现新版本 / **检查失败（带可读原因）**。失败绝不显示成「已是最新版本」；启动自动检查保持静默，手动检查如实报错。

### 为什么是 IP 直连而不是域名

备案未完成时域名可能无法解析或被拦截，而 IP 直连不受影响。代价是**必须有一张含 IP SAN 的证书**：
服务器已由 x-run 申请并自动续期 Let's Encrypt IP 证书（有效期 6 天，定时任务自动换）。
⚠️ 不要改成「跳过证书校验」或明文 HTTP —— 清单与安装包都靠这条链路传递，降级等于放弃完整性保证。

## 2. 发布口径

两台服务器均发布同一份 APK 与同一份 `latest.json`：

| | 地址 | 登录 | 发布目录 |
|---|---|---|---|
| 新机（主源） | 43.142.93.106 | `ubuntu` | `/www/wwwroot/resource/data/plai-updates` |
| 旧机（回退源） | 114.55.170.117 | `root` | 同上 |

私钥路径由操作者在发布时提供，**不写入仓库、文档或提交**。

- **版本保留**：每台服务器只保留最新 **5 个**完整版本目录
  （`tool/publish_plai_update.ps1 -KeepReleases 5`，语义版本排序），发布成功后自动删除最旧目录。
- 已发布的 `releases/<版本>/` 目录不可覆盖（客户端缓存一年），要改只能发新版本号。

### 新机的 Web 映射

新机的 443 默认 vhost（`/opt/x-run/shared/ingress/apache-ip-ssl.conf`，由 x-run 管理）
已加入 Plai 的 IP 直连静态映射（与既有的 `/downloads/super/` 同一模式）：

```apache
Alias /downloads/plai/ /www/wwwroot/resource/data/plai-updates/
ProxyPass /downloads/plai/ !
```

> ⚠️ 该文件由 x-run 面板管理，**升级 x-run 可能覆盖这段配置**。升级后请检查
> `curl -sS -o /dev/null -w '%{http_code}' https://43.142.93.106/downloads/plai/latest.json`
> 是否为 200；不是就按上面的两行补回去并 `sudo systemctl reload apache2`。

## 3. 发布后核验

```powershell
# 主源（IP 直连，不要加 -k：证书必须真的能通过校验）
ssh -i <新机私钥> ubuntu@43.142.93.106 "curl -sS https://43.142.93.106/downloads/plai/latest.json; ls -1 /www/wwwroot/resource/data/plai-updates/releases/; sha256sum /www/wwwroot/resource/data/plai-updates/releases/<版本>/*.apk"
# 旧机（回退源）
ssh -i <旧机私钥> root@114.55.170.117 "cat /www/wwwroot/resource/data/plai-updates/latest.json; ls -1 /www/wwwroot/resource/data/plai-updates/releases/"
```

判定标准：清单 `version` / `size` / `sha256` 与本地构建产物一致，两台一致；
四项闸门（签名指纹不变 / versionCode 递增 / applicationId 不变 / APK v2 方案）通过。
另需确认 `Range` 请求返回 206（断点续传）：

```bash
curl -sS -r 0-99 -o /dev/null -w '%{http_code}\n' https://43.142.93.106/downloads/plai/releases/<版本>/Plai-android-<版本>.apk
```

## 4. 历史遗留：2.2.7 用户

2.2.7 的更新源**只有** `liuyangyang.online`（无 IP 直连、无回退），而该域名备案中不可公网访问 ——
已装 2.2.7 的用户在备案完成前**无法自动检查更新**，需手动从旧域名下载安装包覆盖安装
（数据保留、无需卸载）。2.2.9 起不再有这个问题（2.2.9 走域名+IP 绑定；2.3.0 起改纯 IP 直连）。
