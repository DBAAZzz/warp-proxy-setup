# warp-proxy-setup

一键把 Linux 服务器变成一个基于 Cloudflare WARP 出口的本机**通用 HTTP 代理节点**。

```text
入口层（统一）
  sing-box HTTP inbound → 127.0.0.1:18080

出口层（backend 按系统自动选择）
  backend=warp-cli   官方客户端 Local proxy (127.0.0.1:40000)
  backend=wireguard  wgcf + sing-box 用户态 WireGuard（CentOS 7 等系统兜底）

  ↓
所有支持 HTTP_PROXY / HTTPS_PROXY 的应用
```

`18080` 不是“Docker 专用代理入口”，而是一个 HTTP 代理兼容层，服务于：

- 命令行工具：curl、wget、git
- 包管理器：apt、yum、dnf、npm、pnpm、yarn、pip
- 容器相关：Docker daemon、docker build、docker-compose 服务
- 应用服务：RSSHub、Node.js、Python、Go、Java 等

## 系统支持与 backend 选择

`--backend auto`（默认）按系统自动选择出口方案：

| 系统 | auto 选择 | 方式 |
| ---- | --------- | ---- |
| Ubuntu 22.04 / 24.04 LTS | `warp-cli` | 官方客户端 + Local proxy 40000 |
| Debian 12+ | `warp-cli` | 官方客户端 + Local proxy 40000 |
| RHEL / CentOS 8+ | `warp-cli` | 官方客户端 + Local proxy 40000 |
| Fedora 34+ | `warp-cli` | 官方客户端 + Local proxy 40000 |
| CentOS 7 等其他系统 | `wireguard` | wgcf + sing-box 用户态 WireGuard |

说明：

- 官方支持的系统上默认始终用 `warp-cli`；[wgcf](https://github.com/ViRb3/wgcf) 是非官方工具（调用 Cloudflare 未公开 API），只作为官方客户端覆盖不到的系统的兜底。
- wireguard backend 是**纯用户态**实现：不装内核模块、不碰路由表、不改默认路由，SSH 与已有服务出站不受影响（CentOS 7 的 3.10 内核没有内核态 WireGuard，这正是 sing-box 方案成立的原因）。
- 另需 systemd 与 root 权限。

强制指定 backend：

```bash
sudo ./install.sh --backend warp-cli     # 系统不支持时直接报错，不静默降级
sudo ./install.sh --backend wireguard
```

### 大陆服务器下载加速

sing-box / wgcf 发布在 GitHub Releases，大陆服务器经常直连不通。脚本会自动按「GitHub 直连 → ghfast.top → gh-proxy.com → ghproxy.net」顺序尝试，**每个源下载后都强制校验内嵌的官方 SHA256**，校验失败（镜像篡改/截断）自动换源。也可指定自有镜像（最高优先）：

```bash
GITHUB_MIRROR=https://your-mirror.example.com sudo -E ./install.sh
```

全部源失败时，可在能访问 GitHub 的机器上手动下载二进制放到 `/usr/local/bin/` 后重跑脚本（已存在的二进制会跳过下载）。

## 快速开始

```bash
git clone <repo-url> && cd warp-proxy-setup
chmod +x install.sh uninstall.sh scripts/health-check.sh
sudo ./install.sh
```

脚本会自动完成：

1. 按系统选定 backend，安装 sing-box（统一桥接层，版本锁定，按 amd64 / arm64 / armv7 架构下载）
2. `warp-cli` backend：安装官方客户端（apt / dnf / yum 自适应），幂等注册并开启 Local proxy mode（新旧 `warp-cli` 命令自动 fallback）
3. `wireguard` backend：安装 wgcf，幂等注册 WARP 账号并生成 WireGuard profile
4. 渲染 sing-box 配置（HTTP inbound 18080 → socks/wireguard 出站）并 `sing-box check` 校验
5. 写入 systemd 桥接服务（兼容 CentOS 7 的 systemd 219；warp-cli backend 带 `/dev/tcp` 端口就绪等待）
6. 执行三层健康检查并输出各类应用的接入方式

从 v0.1 升级：直接重跑 `sudo ./install.sh`，桥接层会自动从 GOST 切换为 sing-box 并清理遗留二进制。

## 监听模式

默认只监听本机，更大的暴露面必须显式开启：

| 模式 | 监听地址 | 适用场景 |
| ---- | -------- | -------- |
| `local`（默认） | `127.0.0.1` | 宿主机上的 git、curl、npm、apt、Docker daemon、systemd 服务，以及 `--network host` 容器 |
| `docker-bridge` | docker0 网关 IP（如 `172.17.0.1`） | 默认 bridge 网络中的容器 |
| `lan` | `0.0.0.0` | 局域网 / 指定远端机器（**必须配置防火墙限制来源**） |

```bash
sudo ./install.sh                          # local（默认）
sudo ./install.sh --mode docker-bridge     # bridge 容器访问
sudo ./install.sh --mode lan               # 监听 0.0.0.0，输出强警告
sudo ./install.sh --host 172.18.0.1        # 自定义 compose 网络时显式指定监听地址
sudo ./install.sh --port 28080             # 自定义 HTTP 代理端口
```

注意：`docker-bridge` 只覆盖默认 bridge 网络。docker-compose 自定义 network 请用 `--host` 显式指定宿主机在该网络可达的地址，或使用 `lan` 模式配合防火墙限制来源。

## 应用接入

以 `local` 模式为例（`PROXY=http://127.0.0.1:18080`）：

```bash
# 通用环境变量（RSSHub / Node.js / Python / Go / Java 等服务）
export HTTP_PROXY=http://127.0.0.1:18080
export HTTPS_PROXY=http://127.0.0.1:18080
export ALL_PROXY=http://127.0.0.1:18080

# Git
git config --global http.proxy http://127.0.0.1:18080
git config --global https.proxy http://127.0.0.1:18080

# curl
curl -x http://127.0.0.1:18080 https://www.google.com

# npm / pnpm
npm config set proxy http://127.0.0.1:18080
npm config set https-proxy http://127.0.0.1:18080

# apt
echo 'Acquire::http::Proxy "http://127.0.0.1:18080";
Acquire::https::Proxy "http://127.0.0.1:18080";' | sudo tee /etc/apt/apt.conf.d/99proxy

# Docker daemon
sudo mkdir -p /etc/systemd/system/docker.service.d
printf '[Service]\nEnvironment="HTTP_PROXY=http://127.0.0.1:18080"\nEnvironment="HTTPS_PROXY=http://127.0.0.1:18080"\nEnvironment="NO_PROXY=localhost,127.0.0.1"\n' \
    | sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf
sudo systemctl daemon-reload && sudo systemctl restart docker
```

## 健康检查与排障

```bash
./scripts/health-check.sh
```

输出分三层，方便定位故障在哪一段：

| 层级 | 检查内容 | 失败时的含义 |
| ---- | -------- | ------------ |
| L1 | 出口层状态（warp-cli: `warp-cli status`；wireguard: 桥接服务 + wgcf profile） | WARP 出口层没起来：IP 被 Cloudflare 风控 / 网络不通 / 注册失败 / 时间·DNS·防火墙异常 |
| L2 | `http://127.0.0.1:18080` 能否出网 | sing-box 桥接层故障，查 `systemctl status warp-proxy-bridge` |
| L3 | trace 响应里 `warp=on/plus` | 代理通了但流量没走 WARP：检查 sing-box 出站配置 / WireGuard 握手 |

L3 比单纯的连通性检查更强——它验证的是「流量真的从 Cloudflare WARP 出口出去了」。三层全过但应用仍失败 → 应用侧的代理环境变量配置有误。

常用管理命令：

```bash
systemctl status warp-proxy-bridge   # 桥接服务状态
journalctl -u warp-proxy-bridge -f   # 桥接服务日志
warp-cli status                      # WARP 连接状态
```

## 卸载

```bash
sudo ./uninstall.sh                # 移除桥接服务、配置、sing-box/wgcf（含 v0.1 遗留 gost）
sudo ./uninstall.sh --purge-warp   # 同时断开并卸载 cloudflare-warp 官方客户端
```

卸载后请记得清理应用侧的代理配置（Git / npm / apt / Docker daemon 等），否则它们会因代理失联而请求失败。

## 设计文档

- [docs/design.md](docs/design.md) — v0.1：问题域分析、为什么需要 18080、多监听模式、幂等原则
- [docs/design-v0.2.md](docs/design-v0.2.md) — v0.2：双 backend 架构、sing-box 统一桥接、wgcf 方案与风险、CentOS 7 适配、warp=on 健康检查

## License

[MIT](LICENSE)
