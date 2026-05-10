# cloudflared — 用自有域名做内网穿透

把本地服务（`http://localhost:3000` 之类）挂到自己域名上，TLS 由 Cloudflare 自动签发，无需公网 IP、无需开端口。

安装由 `install-{mac,linux,windows}` 脚本统一负责（macOS Brewfile、Linux Cloudflare 官方 apt 源、Windows Scoop extras bucket）。

## 前置条件

1. 域名已加到 Cloudflare 账户，nameserver 指向 Cloudflare（在 dash.cloudflare.com 看到 "Active"）
2. 本地有要暴露的服务，例如 `http://localhost:3000`

## 一次性配置（Named Tunnel）

```bash
# 1) 浏览器登录授权（会弹浏览器选域名）
cloudflared tunnel login
# 凭证写到 ~/.cloudflared/cert.pem

# 2) 创建命名 tunnel（名字随便起，例如 home）
cloudflared tunnel create home
# 输出含 UUID，并在 ~/.cloudflared/<UUID>.json 写入凭证

# 3) 把子域名 CNAME 到 tunnel（自动写 DNS，不用手动去 dash 加记录）
cloudflared tunnel route dns home app.example.com
```

## 配置文件

`~/.cloudflared/config.yml`（Windows: `C:\Users\<you>\.cloudflared\config.yml`）：

```yaml
tunnel: home
credentials-file: /home/you/.cloudflared/<UUID>.json   # Windows 用反斜杠绝对路径
ha-connections: 2   # 免费版服务端硬上限 2，写明可消 warning；默认 4 会提示 "I can give you at most 2"

ingress:
  - hostname: app.example.com
    service: http://localhost:3000
  - hostname: api.example.com
    service: http://localhost:8080
  # 兜底必须有，且必须是最后一条
  - service: http_status:404
```

## 启动

```bash
# 前台跑（调试用）
cloudflared tunnel run home

# 装成系统服务，开机自启
# Linux (systemd):
sudo cloudflared service install
sudo systemctl enable --now cloudflared

# Windows (管理员 PowerShell):
cloudflared service install
# 服务名: cloudflared，可在 services.msc 看到
```

浏览器访问 `https://app.example.com` 即可。

## 常用变体

- **TCP / SSH**：`service: ssh://localhost:22`，客户端用
  `cloudflared access ssh --hostname ssh.example.com`
- **后端是自签 https**：该 hostname 下加
  ```yaml
  originRequest:
    noTLSVerify: true
  ```
- **临时一次性，不要域名**（最快验证 cloudflared 是否能用）：
  ```bash
  cloudflared tunnel --url http://localhost:3000
  ```
  会给一个 `xxx.trycloudflare.com` URL，重启即变。

## 排查

```bash
cloudflared tunnel list                 # 列出所有 tunnel
cloudflared tunnel info home            # 看 connector / 边缘节点 / origin IP
cloudflared tunnel info <UUID>          # 名字解析失败时用 UUID（CLI 偶尔识别不对名字）
journalctl -u cloudflared -f            # Linux 日志
# Windows: Event Viewer -> Applications and Services Logs -> cloudflared
```

绕过本机 DNS 劫持（Clash / sing-box fake-ip 会让 `nslookup` / `Resolve-DnsName` 拿到 198.18.x.x 假 IP）—— 直接 DoH：

```powershell
# Windows
Invoke-RestMethod -Uri 'https://1.1.1.1/dns-query?name=app.example.com&type=A' `
  -Headers @{'accept'='application/dns-json'} | ConvertTo-Json -Depth 5
```

```bash
# mac/linux
curl -sH 'accept: application/dns-json' \
  'https://1.1.1.1/dns-query?name=app.example.com&type=A' | jq
```

常见报错：

| 报错 / 现象 | 原因 / 处置 |
|---|---|
| `An A, AAAA, or CNAME record with that host already exists` | dash 里已有同名 DNS 记录，删掉后重跑 `route dns`（或加 `--overwrite-dns`，但有时不生效见下） |
| `route dns` 输出 `is already configured to route to your tunnel` 但 zone 里没记录 | tunnel 内部 hostname 路由表脏了。dashboard 先删该 zone 下所有同名 DNS 记录，再重跑 `route dns`；`--overwrite-dns` 在某些版本不生效，靠不住 |
| `failed to sufficiently increase receive buffer size` | Linux UDP buffer 偏小，无害；想消除：`sudo sysctl -w net.core.rmem_max=7500000 net.core.wmem_max=7500000` |
| `error="Unauthorized"` | `cert.pem` 过期或换号了，重新 `cloudflared tunnel login` |
| `failed to dial to edge with quic: timeout` + `ip=198.18.x.x` | cloudflared 解析到了 fake-ip（被代理软件 DNS 劫持）。给 Clash / sing-box 加直连规则：`DOMAIN-SUFFIX,argotunnel.com,DIRECT`、`DOMAIN-SUFFIX,cftunnel.com,DIRECT`、`DOMAIN-SUFFIX,cloudflareclient.com,DIRECT` |
| `You requested 4 HA connections but I can give you at most 2` | 免费版服务端硬上限 2。在 `config.yml` 加 `ha-connections: 2` |
| `"cloudflared tunnel run" accepts only one argument` | `--ha-connections 2` 之类的 flag 必须放在 `run` 之后、tunnel 名之前：`cloudflared tunnel run --ha-connections 2 home` |
| 1016 Origin DNS error | CF 边缘没找到 hostname → tunnel 的有效路由。99% 是 DNS 这条 CNAME 缺失 / 灰云 / 指向已删 tunnel UUID。dashboard 看 zone 里 CNAME 的 target 和云朵颜色 |
| 502 Bad Gateway | Tunnel 路由 OK，但 cloudflared 连不到本地服务。`curl http://localhost:<port>` 确认源站在跑 |
| 域名打不开但 `tunnel info` 显示 connected | DNS 还没生效，或浏览器缓存；DoH 验证 CNAME 指向 `<UUID>.cfargotunnel.com` |

## 纯 CLI 管理原则（强烈推荐）

**不要混用 Cloudflare Zero Trust UI 和 CLI**。两条路在底层是同一个 tunnel 资源，但状态管理不同：

- **CLI / config.yml 派**：`cloudflared tunnel create`，凭证文件 `~/.cloudflared/<UUID>.json`，ingress 在 `config.yml`，命令 `cloudflared tunnel run home` 启动。
- **Zero Trust UI 派**：dashboard 创建 tunnel，给一段 `cloudflared service install <token>` 命令，token 模式跑成系统服务，ingress 全在 dashboard 里配。

混用典型症状：
- `tunnel list` 看到一堆陌生 tunnel
- 某个 hostname 的 DNS CNAME 指向其它 UUID（不是你 config.yml 里那条）
- 卸载不掉的 Windows Service 一直把幽灵 tunnel 拉起来
- 删 tunnel 时报 "tunnel has active connections"

排查 Windows Service 的 token 属于哪条 tunnel：

```powershell
Get-WmiObject Win32_Service -Filter "Name='Cloudflared'" |
  Select-Object PathName | Format-List
# PathName 里的 --token 是个 base64 JWT，第二段解码后 "t" 字段就是 tunnel UUID
```

## 停止 / 卸载 / 重建

**停止前台进程**：终端里 Ctrl+C。

**卸 Windows 服务**（管理员 PowerShell）：

```powershell
cloudflared service uninstall
# 或手动：
Stop-Service Cloudflared
sc.exe delete Cloudflared
```

**卸 Linux systemd 服务**：

```bash
sudo systemctl disable --now cloudflared
sudo cloudflared service uninstall
```

**踢掉远程 / 残留 connector**（连接还挂在 CF 边缘上但本地进程已没）：

```bash
cloudflared tunnel cleanup <name|UUID>
```

**强制删 tunnel**（即使有 active connections）：

```bash
cloudflared tunnel delete -f <name|UUID>
```

**完整重建一个 hostname 的路由**（DNS 脏掉时的标准修法）：

```bash
# 1. dashboard 进对应 zone -> DNS Records，删掉所有同名旧记录
# 2. CLI 重建（zone 真的空了之后才会真正写入）
cloudflared tunnel route dns home app.example.com
```

**子域作为独立 zone 时的额外坑**：如果在 CF 加了 `foo.example.com` 当独立 zone（不是把 `foo` 作为 `example.com` 的记录），父 zone（在哪个 DNS provider 都行）必须把 `foo` 子域 NS 委托给 CF，否则 CF 这边的 zone 配置全是哑火（DoH 查会 NXDOMAIN，权威 SOA 仍是父 zone 的）。CF dashboard 的 zone overview 底部会列出该 zone 应该用哪两个 nameserver。

**多个独立 zone 共享后缀时的 `route dns` bug**：账户里同时有 `foo.example.com`、`bar.example.com`、`baz.example.com` 三个**独立 zone**（都被加成顶级 zone，而不是 `example.com` 下的子记录），`cloudflared tunnel route dns home foo.example.com` 可能把记录错误地写到 `bar.example.com` 或 `baz.example.com` zone 里去（按 suffix `*.example.com` 匹配到的第一个 zone，而非最精确匹配 hostname 同名的 zone）。

症状：DoH 查 `foo.example.com` 返回 NODATA（zone 是空的），但 dashboard 看 `bar.example.com` zone 里却有一条名字写着 `foo.example.com` 的 Tunnel 记录。

修复：dashboard 进错放的 zone 删掉非本 zone 名的记录，然后到正确 zone 手动 `Add record` 创建 CNAME 指向 `<UUID>.cfargotunnel.com`（橙云）。CLI 在这种拓扑下不靠谱，全手动加最稳。

避坑：尽量用「一个父 zone + 多个子记录」的拓扑（`example.com` 一个 zone，`foo`/`bar`/`baz` 是其下的 CNAME 记录），而不是「每个子域一个独立 zone」。
