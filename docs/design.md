# Cloudflare WARP Local Proxy 一键安装脚本方案

> 目标：把一台新的 Linux 云服务器，一键初始化成具备 Cloudflare WARP 出口能力的通用 HTTP 代理环境。应用通过 `127.0.0.1:18080` 使用该代理，包括 Git、curl、wget、包管理器、Docker、RSSHub、Node.js 服务等。

---

## 1. 背景

最初的触发场景是在阿里云 ECS 上部署 RSSHub（Docker 容器），遇到的问题不是“服务器没有代理”，而是：

1. Cloudflare WARP 的 Local proxy mode 默认暴露的是本机代理端口，例如 `127.0.0.1:40000`。
2. RSSHub / Node.js 原生 `fetch` / `undici` 对 `SOCKS5` 代理支持并不理想。
3. 直接给 RSSHub 配置 `socks5h://127.0.0.1:40000` 时，请求 Telegram、BBC 等站点失败。
4. 最终通过代理工具（原为 `pproxy`，现升级为 `gost`）把 `SOCKS5` 代理转换成 `HTTP` 代理，暴露 `127.0.0.1:18080` 后，RSSHub 才能稳定使用代理。

但 RSSHub 只是触发场景。真正沉淀出来的能力不是“解决 Docker 代理问题”，而是一个通用模式：

```text
Cloudflare WARP Local proxy mode
    ↓
127.0.0.1:40000  SOCKS5 / WARP 原始代理入口
    ↓
GOST 协议桥接
    ↓
127.0.0.1:18080  通用 HTTP 代理入口
    ↓
所有支持 HTTP_PROXY / HTTPS_PROXY 的应用
```

`18080` 的本质不是“Docker 能用”，而是一个 **HTTP 代理兼容层**：

```text
40000 是 WARP 原始能力
18080 是应用兼容能力
```

适用对象：

```text
- 命令行工具：curl、wget、git
- 包管理器：apt、yum、dnf、npm、pnpm、yarn、pip
- 容器相关：Docker daemon、docker build、docker-compose 服务
- 应用服务：RSSHub、Node.js、Python、Go、Java 等
```

---

## 2. 脚本定位

这个脚本不应该只是“已有 SOCKS5 代理后的桥接脚本”，而应该是一个完整的：

```text
Cloudflare WARP Local Proxy 一键安装器
```

它负责从零完成：

```text
安装 Cloudflare WARP Client
→ 检查环境与状态（幂等执行）
→ 注册 WARP 并开启 Local proxy mode (40000)
→ 安装 GOST v2 桥接层
→ 暴露通用 HTTP 代理端口 (默认 18080，多网络模式)
→ 写入 systemd 开机自启（带就绪等待）
→ 三层健康检查
→ 输出各类应用的代理配置方式
```

一句话定位：

```text
一键把 Linux 服务器变成一个基于 Cloudflare WARP 出口的本机通用 HTTP 代理节点。
```

而不是“一键解决 Docker 代理问题”——Docker 只是消费者之一。

---

## 3. 为什么需要 18080

Cloudflare WARP Local proxy mode 默认适合给支持代理协议的应用使用，且默认端口是 `40000`。
但大量工具更习惯、也更稳定地使用 HTTP 代理（部分应用如 Node.js 原生 `fetch` 对 SOCKS5 的支持还存在兼容性问题），因此需要将其转换为更通用的 HTTP 代理入口。

```text
40000 = Cloudflare WARP 提供的底层本地代理入口
18080 = 给所有应用使用的通用 HTTP 兼容入口
```

有了 `18080`，绝大多数程序只需标准的代理环境变量即可接入：

```bash
HTTP_PROXY=http://127.0.0.1:18080
HTTPS_PROXY=http://127.0.0.1:18080
ALL_PROXY=http://127.0.0.1:18080
```

---

## 4. Linux v0.1 推荐方案与技术栈

本方案针对现代 Linux 云服务器（如 Ubuntu 24.04, Debian 12 等）进行了工程化设计。为了避免 Python 环境由于 PEP 668 导致的 `pip install` 全局污染问题，**决定在 v0.1 中使用单二进制、零依赖的 GOST v2 替代原先的 pproxy**。

推荐技术栈：

```text
语言：Bash
WARP 客户端：cloudflare-warp / warp-cli（带兼容与降级处理）
代理桥：GOST v2（最新稳定版，单二进制部署，根据系统架构动态下载）
服务管理：systemd（包含 /dev/tcp 端口探测阻塞等待）
配置/状态管理：支持幂等安装与多模式监听安全隔离
```

---

## 5. 多监听模式设计 (Security & Network Scope)

默认坚守安全底线，只监听本机；高级网络需求通过显式 `--mode` 参数开启。三种模式的区别只是“谁能访问 18080”，主场景始终是 local。

```text
默认安全模式 (local)：
  HTTP_LISTEN_HOST=127.0.0.1
  给宿主机上的 git、curl、wget、npm、apt、Docker daemon、systemd 服务
  以及 --network host 容器使用。
  命令：./warp-proxy-setup.sh install --mode local (默认)

容器网络适配模式 (docker-bridge)：
  尝试动态获取 docker0 的 IP（例如 172.17.0.1），给 bridge 网络容器访问。
  这不是整体方案的主线，只是容器访问场景的网络适配。
  注意：只覆盖默认 bridge 网络。如果你的 docker-compose 使用了自定义 network，请通过 --host 显式指定宿主机在该网络可达的地址，或使用 lan 模式配合防火墙限制来源。
  命令：./warp-proxy-setup.sh install --mode docker-bridge

公网/局域网模式 (lan)：
  HTTP_LISTEN_HOST=0.0.0.0
  给局域网 / 指定远端机器访问。必须显式开启，脚本输出强警告，要求配置安全组或防火墙限制来源 IP。
  命令：./warp-proxy-setup.sh install --mode lan
```

---

## 6. systemd 服务设计 (含端口就绪等待)

`warp-svc` 进程拉起并不意味着端口已就绪，网络协商需要时间。为了防止桥接服务（`gost`）过早启动崩溃，通过 Bash 内置的 `/dev/tcp` 进行无外部依赖的探测阻塞。

```ini
# /etc/systemd/system/warp-proxy-bridge.service
[Unit]
Description=HTTP proxy bridge to Cloudflare WARP Local proxy
After=network-online.target warp-svc.service
Wants=network-online.target

[Service]
EnvironmentFile=/etc/warp-proxy/config.env
# 注意：必须明确使用 /bin/bash 因为 /dev/tcp 是 Bash 的特性，使用 /bin/sh 在部分系统（如 dash）下会报错
ExecStartPre=/bin/bash -c 'for i in {1..30}; do (echo > /dev/tcp/${WARP_PROXY_HOST}/${WARP_PROXY_PORT}) >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1'
ExecStart=/usr/local/bin/gost -L=http://${HTTP_LISTEN_HOST}:${HTTP_PROXY_PORT} -F=socks5://${WARP_PROXY_HOST}:${WARP_PROXY_PORT}
Restart=always
RestartSec=5
StartLimitIntervalSec=60
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
```

---

## 7. 健康检查与故障排查 (Three-Level Health Check)

Cloudflare 有可能对云服务器所在 IP 段进行风控（例如连接一直处于 `Connecting` 状态），因此脚本不仅要知道命令执行结果，还要进行状态探测。

健康检查建议分三层输出，方便故障排查：

**Level 1：WARP 服务状态**
```bash
warp-cli status
```
*如果迟迟未能处于 Connected 状态，提示：“WARP 无法连接。可能原因：1. 当前云服务器 IP 被 Cloudflare 限制 2. 服务器网络无法访问 Cloudflare WARP 节点 3. WARP 注册失败 4. 机器时间 / DNS / 防火墙异常”。*

**Level 2：WARP Local proxy 是否可用**
```bash
curl -I -x socks5h://127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace --max-time 15
```

**Level 3：HTTP bridge 是否可用**
```bash
curl -I -x http://127.0.0.1:18080 https://www.cloudflare.com/cdn-cgi/trace --max-time 15
```

如果用户排障时发现 L1 和 L2 都通，但应用代理失败，说明要么是桥接层 18080 出错（L3 报错），要么是应用的代理环境变量配置有误。

---

## 8. 通用应用接入示例

脚本安装完成后输出的使用说明，应覆盖各类常见消费者（Docker 只是其中之一）：

**Git：**
```bash
git config --global http.proxy http://127.0.0.1:18080
git config --global https.proxy http://127.0.0.1:18080
```

**curl：**
```bash
curl -x http://127.0.0.1:18080 https://www.google.com
```

**wget：**
```bash
wget -e use_proxy=yes \
  -e http_proxy=http://127.0.0.1:18080 \
  -e https_proxy=http://127.0.0.1:18080 \
  https://example.com
```

**npm / pnpm：**
```bash
npm config set proxy http://127.0.0.1:18080
npm config set https-proxy http://127.0.0.1:18080
```

**apt：**
```bash
sudo tee /etc/apt/apt.conf.d/99proxy >/dev/null <<EOF
Acquire::http::Proxy "http://127.0.0.1:18080";
Acquire::https::Proxy "http://127.0.0.1:18080";
EOF
```

**Docker daemon：**
```bash
sudo mkdir -p /etc/systemd/system/docker.service.d

sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf >/dev/null <<EOF
[Service]
Environment="HTTP_PROXY=http://127.0.0.1:18080"
Environment="HTTPS_PROXY=http://127.0.0.1:18080"
Environment="NO_PROXY=localhost,127.0.0.1"
EOF

sudo systemctl daemon-reload
sudo systemctl restart docker
```

**通用环境变量（RSSHub / Node.js / Python / Go / Java 等服务）：**
```bash
HTTP_PROXY=http://127.0.0.1:18080
HTTPS_PROXY=http://127.0.0.1:18080
ALL_PROXY=http://127.0.0.1:18080
```

---

## 9. 安装与配置（幂等与降级兼容逻辑）

Cloudflare `warp-cli` 在新老版本的命令参数发生过多次变化。安装逻辑需要做到完全幂等：

1. **架构适配：** 安装 `GOST v2` 时，识别当前系统架构（`x86_64`, `aarch64/arm64`, `armv7l`），因为云主机不仅有 x86，还有大量低成本 ARM 机器。
2. **自动接受协议：** 所有可能交互的注册和配置命令必须带有 `--accept-tos`。
3. **命令 Fallback：** 支持新旧版命令自动 fallback（如 `warp-cli --accept-tos registration new || warp-cli --accept-tos register`）。
4. **状态幂等判断：** 幂等不是“命令重复跑不报错”，而是“状态达成就不重复操作”。如果 `warp-cli status` 显示已注册，则跳过注册；如果已连接，则不重复触发连接；只需更新配置文件并重启 systemd 桥接即可。

---

## 10. 第一版脚本伪代码大纲

```bash
#!/usr/bin/env bash
set -euo pipefail

# 1. 解析 --mode 等参数并推导 $HTTP_LISTEN_HOST
# 默认使用 127.0.0.1

if [ "$MODE" == "docker-bridge" ]; then
    # 使用 awk 获取 docker0 IP，比 grep -P 兼容性更好
    DOCKER_IP=$(ip -4 addr show docker0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n 1)
    if [ -n "$DOCKER_IP" ]; then
        HTTP_LISTEN_HOST="$DOCKER_IP"
    else
        echo "未能自动检测到 docker0 网卡 IP，降级使用 127.0.0.1，或请使用 --host 显式指定"
        HTTP_LISTEN_HOST="127.0.0.1"
    fi
fi

# 2. 获取 CPU 架构，用于下载对应的 GOST v2 版本
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) GOST_ARCH="amd64" ;;
  aarch64|arm64) GOST_ARCH="arm64" ;;
  armv7l) GOST_ARCH="armv7" ;;
  *) echo "不支持的架构: $ARCH"; exit 1 ;;
esac

# 3. 安装 cloudflare-warp (若未安装则安装)

# 4. 安装 GOST v2
# 直接下载对应架构的 gost 二进制并置于 /usr/local/bin/gost

# 5. WARP 幂等配置
STATUS=$(warp-cli status 2>/dev/null || echo "Unknown")
if [[ "$STATUS" != *"Registered"* ]]; then
    warp-cli --accept-tos registration new || warp-cli --accept-tos register
fi

# 设置模式 (带有 fallback)
warp-cli --accept-tos mode proxy || warp-cli --accept-tos set-mode proxy
warp-cli --accept-tos proxy port 40000 || warp-cli --accept-tos set-proxy-port 40000

if [[ "$STATUS" != *"Connected"* ]]; then
    warp-cli --accept-tos connect
fi

# 6. 生成配置文件并启动带 /dev/tcp 检测的 systemd 桥接服务
# 7. 执行三层健康检查并输出最终信息
```

---

## 11. 最终规格总结

通过这轮评审与打磨，v0.1 的定稿规格如下：

```text
Cloudflare WARP Client
  提供 Local proxy mode，默认 127.0.0.1:40000

GOST v2
  单二进制部署（无 Python PEP 668 环境困扰），负责 HTTP → SOCKS5 桥接

systemd
  管理 gost bridge 服务，使用 /bin/bash /dev/tcp 强依赖等待 40000 就绪后再启动

多监听模式路由与安全
  local：127.0.0.1，默认安全模式，服务宿主机所有进程（主场景）
  docker-bridge：容器网络适配模式，使用 awk 自动探测 docker0 IP，并提示自定义 compose network 用户
  lan：0.0.0.0，必须显式参数开启，并警告防火墙风险

架构支持与幂等安装
  动态支持 amd64/arm64/armv7 架构部署
  根据状态检查结果决定是否执行 WARP 注册与连接，状态达成即直接更新配置并重启 bridge

三层健康检查输出
  明确分隔输出 WARP 状态、SOCKS5 本地监听、HTTP 桥接监听的连通性

通用应用接入
  安装完成后输出 Git / curl / wget / npm / apt / Docker daemon / 服务环境变量等接入方式
```

最终定位：**一键把 Linux 服务器变成一个基于 Cloudflare WARP 出口的本机通用 HTTP 代理节点**。Docker 是使用场景之一，RSSHub 是最初的触发场景，真正的产品能力是 `WARP Local proxy → 通用 HTTP proxy`。

方案现已足够成熟且具备生产级可用性，下一步可基于此规格直接编写 `install.sh` 落地。
