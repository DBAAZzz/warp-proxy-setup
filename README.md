# warp-proxy-setup

一键把 Linux 服务器变成一个基于 Cloudflare WARP 出口的本机**通用 HTTP 代理节点**。

```text
Cloudflare WARP Local proxy mode
    ↓
127.0.0.1:40000  SOCKS5 / WARP 原始代理入口
    ↓
GOST v2 协议桥接
    ↓
127.0.0.1:18080  通用 HTTP 代理入口
    ↓
所有支持 HTTP_PROXY / HTTPS_PROXY 的应用
```

`40000` 是 WARP 原始能力，`18080` 是应用兼容能力——它不是“Docker 专用代理入口”，而是一个 HTTP 代理兼容层，服务于：

- 命令行工具：curl、wget、git
- 包管理器：apt、yum、dnf、npm、pnpm、yarn、pip
- 容器相关：Docker daemon、docker build、docker-compose 服务
- 应用服务：RSSHub、Node.js、Python、Go、Java 等

## 快速开始

```bash
git clone <repo-url> && cd warp-proxy-setup
chmod +x install.sh uninstall.sh scripts/health-check.sh
sudo ./install.sh
```

脚本会自动完成：

1. 安装 Cloudflare WARP Client（apt / dnf / yum 自适应）
2. 安装 GOST v2（单二进制，按 amd64 / arm64 / armv7 架构下载）
3. 幂等注册 WARP 并开启 Local proxy mode（端口 40000，新旧 `warp-cli` 命令自动 fallback）
4. 写入 systemd 桥接服务（带 `/dev/tcp` 端口就绪等待，开机自启）
5. 执行三层健康检查并输出各类应用的接入方式

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
| L1 | `warp-cli status` 是否 Connected | WARP 本身连不上：IP 被 Cloudflare 风控 / 网络不通 / 注册失败 / 时间·DNS·防火墙异常 |
| L2 | `socks5h://127.0.0.1:40000` 能否出网 | WARP 进程在但本地代理口不可用 |
| L3 | `http://127.0.0.1:18080` 能否出网 | gost 桥接层故障，查 `systemctl status warp-proxy-bridge` |

L1、L2 都通但应用代理失败 → 要么 L3 桥接出错，要么应用侧的代理环境变量配置有误。

常用管理命令：

```bash
systemctl status warp-proxy-bridge   # 桥接服务状态
journalctl -u warp-proxy-bridge -f   # 桥接服务日志
warp-cli status                      # WARP 连接状态
```

## 卸载

```bash
sudo ./uninstall.sh                # 移除桥接服务、配置与 gost，保留 WARP 客户端
sudo ./uninstall.sh --purge-warp   # 同时断开并卸载 cloudflare-warp
```

卸载后请记得清理应用侧的代理配置（Git / npm / apt / Docker daemon 等），否则它们会因代理失联而请求失败。

## 设计文档

完整方案设计（技术选型、systemd 就绪等待、幂等逻辑、多模式安全设计）见 [docs/design.md](docs/design.md)。

## License

[MIT](LICENSE)
