# v0.2 设计：双 Backend 架构（warp-cli / wireguard）

> 目标不变：一键把 Linux 服务器变成一个基于 Cloudflare WARP 出口的本机通用 HTTP 代理节点（`127.0.0.1:18080`）。
> v0.2 的变化：不再绑定死在官方客户端的 Local proxy mode 上，把「WARP 出口怎么来」抽象成可切换的 backend。

v0.1 设计见 [design.md](design.md)，其问题域分析（为什么需要 18080、多监听模式、幂等原则）在 v0.2 全部继承，不再重复。

---

## 1. 为什么需要 v0.2

v0.1 在 CentOS 7 上的真实失败案例暴露了两个事实：

1. Cloudflare WARP 官方客户端只支持 Ubuntu 22.04+/Debian 12+/RHEL·CentOS 8+/Fedora 34+，**不提供 el7 包**，CentOS 7 无解。
2. 工具的真正价值是「18080 这个通用 HTTP 代理入口」，官方客户端只是获得 WARP 出口的一种方式。

因此 v0.2 把架构拆成三层：

```text
入口层（两个 backend 完全一致）：
  sing-box HTTP inbound → http://127.0.0.1:18080

出口层（按系统选择）：
  backend=warp-cli   官方客户端 Local proxy mode (127.0.0.1:40000)
  backend=wireguard  wgcf 生成 WARP WireGuard 配置

桥接层（统一为 sing-box，v0.1 的 GOST 退役）：
  warp-cli:   sing-box socks outbound     → 127.0.0.1:40000
  wireguard:  sing-box wireguard endpoint → Cloudflare WARP
```

---

## 2. Backend 选择策略

```bash
sudo ./install.sh                        # --backend auto（默认）
sudo ./install.sh --backend warp-cli     # 强制官方客户端
sudo ./install.sh --backend wireguard    # 强制 wgcf + sing-box 用户态 WireGuard
```

`auto` 的判定逻辑：

```text
读取 /etc/os-release
  在官方支持列表内（Ubuntu 22+/Debian 12+/RHEL·CentOS 8+/Fedora 34+）
    → backend=warp-cli
  不在列表内（CentOS 7 等）
    → backend=wireguard，并输出非官方方案警告
```

**关键原则：官方支持的系统上默认必须是 warp-cli。** 原因：

- wgcf 是非官方工具（[ViRb3/wgcf](https://github.com/ViRb3/wgcf)），调用 Cloudflare 未公开的注册 API，处于 ToS 灰色地带，接口随时可能变更失效。
- wireguard backend 只作为官方客户端覆盖不到的系统的兜底，不上位成默认。
- 强制 `--backend warp-cli` 但系统不支持时，直接报错退出（不静默降级）。

| 系统 | auto 选择 | 方式 |
| ---- | --------- | ---- |
| Ubuntu 22.04 / 24.04 | `warp-cli` | 官方客户端 + Local proxy 40000 |
| Debian 12 / 13 | `warp-cli` | 官方客户端 + Local proxy 40000 |
| RHEL / CentOS 8+ | `warp-cli` | 官方客户端 + Local proxy 40000 |
| Fedora 34+ | `warp-cli` | 官方客户端 + Local proxy 40000 |
| CentOS 7 | `wireguard` | wgcf + sing-box WireGuard endpoint |
| 其他未识别系统 | `wireguard` | 同上，输出警告 |

---

## 3. 为什么 wireguard backend 用 sing-box 而不是内核 WireGuard

CentOS 7 内核是 3.10，**没有内核态 WireGuard**（内核 5.6+ 才内置），传统方案要装 ELRepo kmod 或 wireguard-go，在 EOL 系统上是依赖地狱。而且全局 WireGuard 路由有经典死锁风险：隧道自身握手流量被路由进隧道，需要 fwmark 策略路由才能解开，配错一次 SSH 就断——对一键脚本不可接受，**全局路由方案直接否决，不做**。

sing-box 的 WireGuard 是**纯用户态实现**：

- 单个静态 Go 二进制，不碰内核模块、不碰路由表、不需要 TUN 设备
- 不改系统默认路由，SSH / Docker / 已有服务的出站完全不受影响
- 只有连到 18080 的流量走 WARP，天然就是「代理入口」模型

---

## 4. 桥接层统一为 sing-box（GOST 退役）

v0.1 用 GOST 做 `HTTP → SOCKS5` 桥接。v0.2 如果保留它，桥接层就会分裂成两套工具、两套 systemd 模板、两套排障路径。因此统一：

```text
warp-cli backend 的 sing-box 配置：
  inbound:  http 127.0.0.1:18080
  outbound: socks 127.0.0.1:40000
  route.final → socks outbound

wireguard backend 的 sing-box 配置：
  inbound:  http 127.0.0.1:18080
  endpoint: wireguard（wgcf 生成的密钥与地址）
  route.final → wireguard endpoint
```

切换 backend 只是换配置文件里的出站段；systemd 服务（`warp-proxy-bridge`）、健康检查、卸载逻辑全部只有一份。

**版本锁定（必须）：** sing-box 1.11 把 WireGuard 从 outbound 迁移到了 endpoint 格式，上游配置 schema 有破坏性变更史。脚本锁定 `SING_BOX_VERSION=1.12.4`、`WGCF_VERSION=2.2.26`（均可用环境变量覆盖），绝不追 latest。

**下载源策略（大陆服务器适配）：** sing-box 与 wgcf 均发布在 GitHub Releases，大陆服务器对 `github.com` / `objects.githubusercontent.com` 经常完全不可达。下载逻辑为多源 fallback + 强制校验：

```text
GitHub 直连
  → 失败则依次尝试加速镜像（前缀 + 完整 GitHub URL）：
      $GITHUB_MIRROR（用户自有镜像，最高优先，可选）
      https://ghfast.top
      https://gh-proxy.com
      https://ghproxy.net
  → 每个源下载成功后强制 SHA256 校验
      校验和在脚本内嵌（从官方 GitHub Release 下载后计算）
      不匹配 = 可能被镜像篡改或截断 → 丢弃，换下一个源
  → 全部失败则报错退出，提示 GITHUB_MIRROR 自救或手动放置二进制
```

这正是版本锁定的另一个红利：版本固定 → 官方校验和可以内嵌进脚本 → 第三方镜像（运营方不可控、域名常更换）即使返回被篡改的二进制也会被拦下。**没有校验和的文件一律拒绝安装**（升级锁定版本时必须同步更新脚本内的 `pinned_sha256` 表）。jsDelivr 不支持 Release 二进制，不在备选之列。

从 v0.1 升级：unit 名不变（`warp-proxy-bridge.service`），重跑 install.sh 直接覆盖为 sing-box 版；遗留的 `/usr/local/bin/gost` 由 uninstall.sh 负责清理。

---

## 5. wireguard backend 安装流程

```text
1. 下载 wgcf 单二进制（按 amd64/arm64/armv7 架构）→ /usr/local/bin/wgcf
2. 注册（幂等：账号文件存在则跳过）
     cd /etc/warp-proxy/wgcf && wgcf register --accept-tos
3. 生成配置（幂等：profile 存在则跳过）
     wgcf generate → wgcf-profile.conf
4. 解析 profile 中的 PrivateKey / Address / PublicKey / Endpoint
5. 获取 client_id → 解码为 3 字节 reserved 值（见下）
     用 wgcf-account.toml 的 device_id + access_token 调用
     api.cloudflareclient.com/v0a2158/reg/<device_id>
     结果缓存到 /etc/warp-proxy/wgcf/client_id（600 权限），幂等重跑不重复请求
6. Endpoint 域名（engage.cloudflareclient.com）解析为 IP
     解析失败时回退到已知锚点 IP 162.159.192.1:2408
7. 渲染 sing-box 配置（wireguard endpoint 格式，MTU 1280）
8. 写入 systemd unit 并启动
```

sing-box wireguard endpoint 配置模板（1.11+ 格式）：

```json
{
  "log": { "level": "warn" },
  "inbounds": [
    { "type": "http", "tag": "http-in", "listen": "127.0.0.1", "listen_port": 18080 }
  ],
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "warp-wg",
      "mtu": 1280,
      "address": ["172.16.0.2/32", "<wgcf 分配的 IPv6>/128"],
      "private_key": "<wgcf PrivateKey>",
      "peers": [
        {
          "address": "162.159.192.1",
          "port": 2408,
          "public_key": "<wgcf PublicKey>",
          "reserved": [<client_id 解码的 3 字节>],
          "allowed_ips": ["0.0.0.0/0", "::/0"],
          "persistent_keepalive_interval": 25
        }
      ]
    }
  ],
  "route": { "final": "warp-wg" }
}
```

**reserved 字段（必须，真机验证过的坑）：** WARP 要求 WireGuard 包头携带 3 字节 client_id（即 `reserved`），wgcf 生成的 profile 里**不含**这个字段。缺少它的症状极具迷惑性：UDP 端点可达、sing-box 日志无任何报错、服务状态 active，但所有经隧道的数据包被 Cloudflare **静默丢弃**，表现为代理请求整体挂起（CentOS 7 真机复现）。

注意 **wgcf-account.toml 里也没有 client_id**（文件只含 device_id / access_token / private_key / license_key，真机验证），必须调用 Cloudflare 设备 API 查询：

```bash
curl -H "Authorization: Bearer <access_token>" \
  https://api.cloudflareclient.com/v0a2158/reg/<device_id>
# 响应 JSON 含 "client_id":"kc\/y" → 还原 \/ 转义 → base64 -d → od -tu1 → [145, 207, 242]
```

结果缓存到 `/etc/warp-proxy/wgcf/client_id`（600 权限）。获取失败（接口变更 / token 失效）时降级为不渲染 reserved 并输出警告，不中断安装——但代理大概率会挂起，警告信息中已注明因果。该 API 与 wgcf 注册接口同属未公开接口，是 wireguard backend 的固有风险面。

**端点自动扫描（真机验证过的第二个坑）：** 默认端点 `engage.cloudflareclient.com:2408` 在部分线路（尤其大陆）受针对性干扰——`nc -u` 探测"通"（UDP 包能发出），但 WireGuard 握手回包被丢，症状与 reserved 缺失完全相同（服务正常、日志干净、代理挂起）。因此 UDP 可达性探测不可信，**唯一可信的检验是经 18080 实测 `warp=on`**。安装流程在桥接服务启动后：

```text
1. 等待隧道就绪，经 18080 实测 trace（重试 3 次）
2. warp=on → 锁定当前端点，写入缓存 /etc/warp-proxy/wgcf/endpoint
3. 不通 → 作废缓存，遍历候选端点列表：
     162.159.192.1 / 162.159.193.10 / 188.114.96.1 / 188.114.97.1
     × 端口 2408 / 500 / 854 / 1701 / 4500 / 8854（精选 10 组合）
   对每个候选：重写 sing-box 配置 → 重启桥接 → 等待 6s → 实测 warp=on
4. 找到可用端点即锁定并缓存；全部失败则警告（整个 UDP 端口段被封锁）
     可用 WARP_ENDPOINT_CANDIDATES="ip:port ..." 环境变量自定义候选重试
```

下次重跑 install.sh 时优先使用缓存端点（已验证可用），避免重复扫描。

---

## 6. systemd 兼容性（CentOS 7 / systemd 219）

CentOS 7 的 systemd 是 219，v0.1 unit 里的写法有两处不兼容：

| v0.1 写法 | 问题 | v0.2 写法 |
| --------- | ---- | --------- |
| `[Service]` 里 `StartLimitIntervalSec=` | 219 不识别（新版才支持） | 改用 legacy 名 `StartLimitInterval=`（新旧 systemd 都接受） |
| `ExecStartPre` 等待 40000 | wireguard backend 没有 40000 | 仅 warp-cli backend 渲染这一行 |

unit 按 backend 动态渲染：

```ini
[Unit]
Description=WARP HTTP proxy bridge (sing-box, backend=<backend>)
After=network-online.target          # warp-cli backend 追加 warp-svc.service
Wants=network-online.target

[Service]
ExecStartPre=...                     # 仅 warp-cli：/bin/bash /dev/tcp 等待 40000
ExecStart=/usr/local/bin/sing-box run -c /etc/warp-proxy/sing-box.json
Restart=always
RestartSec=5
StartLimitInterval=60
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
```

---

## 7. 健康检查升级（warp=on 校验）

v0.1 的 L2（SOCKS5 40000 探测）在 wireguard backend 下不存在。v0.2 重新分层，并引入更强的最终校验——`https://www.cloudflare.com/cdn-cgi/trace` 响应中的 `warp=on/plus` 字段，它验证的是「流量真的走了 WARP 出口」，而不只是「代理通了」：

```text
L1  出口层状态（按 backend 分叉）
    warp-cli:   warp-cli status 是否 Connected
                （失败提示 IP 风控 / 网络 / 注册 / 时间·DNS·防火墙四类原因）
    wireguard:  warp-proxy-bridge 服务是否 active
                + wgcf profile 是否存在

L2  入口层连通性（两个 backend 一致）
    curl -x http://127.0.0.1:18080 https://www.cloudflare.com/cdn-cgi/trace

L3  出口归属校验（两个 backend 一致）
    L2 响应体中 warp=on 或 warp=plus
    失败含义：代理通了但流量没走 WARP（配置错误 / 隧道未握手成功）
```

排障矩阵：

| L1 | L2 | L3 | 结论 |
| -- | -- | -- | ---- |
| ✗ | - | - | WARP 出口层没起来（按 backend 提示排障） |
| ✓ | ✗ | - | sing-box 桥接故障，查 `systemctl status warp-proxy-bridge` |
| ✓ | ✓ | ✗ | 代理在工作但出口不是 WARP：检查 sing-box 出站配置 / WireGuard 握手 |
| ✓ | ✓ | ✓ | 全链路正常；应用仍失败则是应用侧代理配置问题 |

---

## 8. 配置文件变更

`/etc/warp-proxy/config.env` 新增 `BACKEND` 字段：

```bash
BACKEND=wireguard          # 或 warp-cli
MODE=local
WARP_PROXY_HOST=127.0.0.1  # 仅 warp-cli backend 有意义
WARP_PROXY_PORT=40000      # 仅 warp-cli backend 有意义
HTTP_LISTEN_HOST=127.0.0.1
HTTP_PROXY_PORT=18080
```

新增文件：

```text
/etc/warp-proxy/sing-box.json     # 桥接层配置（按 backend 渲染）
/etc/warp-proxy/wgcf/             # 仅 wireguard backend
  wgcf-account.toml               # WARP 账号（含私钥，权限 600）
  wgcf-profile.conf               # WireGuard profile
/usr/local/bin/sing-box
/usr/local/bin/wgcf               # 仅 wireguard backend
```

多监听模式（local / docker-bridge / lan）与 v0.1 完全一致，对两个 backend 都生效。

---

## 9. 卸载

uninstall.sh 在 v0.1 基础上扩展：

```text
1. 停止并移除 warp-proxy-bridge.service
2. 移除 /etc/warp-proxy/（含 sing-box.json 与 wgcf 账号文件）
3. 移除 /usr/local/bin/sing-box、/usr/local/bin/wgcf
4. 移除 /usr/local/bin/gost（v0.1 遗留兼容清理）
5. --purge-warp 时额外断开并卸载官方 cloudflare-warp（仅 warp-cli backend 装过才有）
```

---

## 10. v0.2 规格总结

```text
统一入口
  sing-box HTTP inbound，默认 127.0.0.1:18080，多监听模式同 v0.1

双 backend
  warp-cli（官方支持系统的默认）：官方客户端 Local proxy 40000 → sing-box socks outbound
  wireguard（CentOS 7 等的兜底）：wgcf 注册 → sing-box 用户态 wireguard endpoint
  --backend auto 按 /etc/os-release 自动判定；强制指定不匹配时报错而非降级

工程约束
  sing-box / wgcf 版本锁定，环境变量可覆盖，不追 latest
  systemd unit 使用 legacy StartLimitInterval 写法，兼容 systemd 219
  wgcf 注册与 profile 生成幂等（文件存在即跳过）
  全局路由方案明确否决，永不接管系统默认路由

健康检查
  L1 出口层状态（按 backend）→ L2 18080 连通性 → L3 trace warp=on 出口归属校验
```

落地路径：v0.1 用户重跑 `install.sh` 即原地升级（GOST → sing-box）；CentOS 7 用户全新安装自动走 wireguard backend。
