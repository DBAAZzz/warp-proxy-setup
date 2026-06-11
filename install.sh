#!/usr/bin/env bash
#
# warp-proxy-setup :: install.sh
#
# 一键把 Linux 服务器变成一个基于 Cloudflare WARP 出口的本机通用 HTTP 代理节点。
#
#   Cloudflare WARP Local proxy mode
#     ↓ 127.0.0.1:40000  SOCKS5 / WARP 原始代理入口
#   GOST v2 协议桥接
#     ↓ 127.0.0.1:18080  通用 HTTP 代理入口
#   git / curl / wget / npm / apt / Docker / RSSHub / Node.js ...
#
# 用法：
#   sudo ./install.sh                          # 默认 local 模式（仅监听 127.0.0.1）
#   sudo ./install.sh --mode docker-bridge     # 监听 docker0 网关 IP，供 bridge 容器使用
#   sudo ./install.sh --mode lan               # 监听 0.0.0.0（必须自行配置防火墙）
#   sudo ./install.sh --host 172.18.0.1        # 显式指定监听地址（覆盖 mode 推导）
#   sudo ./install.sh --port 18080             # 自定义 HTTP 代理端口
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 常量与默认配置
# ---------------------------------------------------------------------------
readonly SCRIPT_VERSION="0.1.0"
readonly CONFIG_DIR="/etc/warp-proxy"
readonly CONFIG_FILE="${CONFIG_DIR}/config.env"
readonly BRIDGE_SERVICE="warp-proxy-bridge"
readonly BRIDGE_UNIT="/etc/systemd/system/${BRIDGE_SERVICE}.service"
readonly GOST_BIN="/usr/local/bin/gost"
readonly GOST_VERSION="${GOST_VERSION:-2.12.0}"

MODE="local"
HTTP_LISTEN_HOST=""
HTTP_PROXY_PORT="18080"
WARP_PROXY_HOST="127.0.0.1"
WARP_PROXY_PORT="40000"

# ---------------------------------------------------------------------------
# 输出工具
# ---------------------------------------------------------------------------
log()  { printf '\033[1;32m[INFO]\033[0m  %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --mode)
                MODE="${2:?--mode 需要参数: local | docker-bridge | lan}"
                shift 2 ;;
            --host)
                HTTP_LISTEN_HOST="${2:?--host 需要监听地址参数}"
                shift 2 ;;
            --port)
                HTTP_PROXY_PORT="${2:?--port 需要端口参数}"
                shift 2 ;;
            -h|--help)
                usage ;;
            install)
                # 兼容 ./install.sh install 写法
                shift ;;
            *)
                die "未知参数: $1（使用 --help 查看用法）" ;;
        esac
    done

    case "$MODE" in
        local|docker-bridge|lan) ;;
        *) die "非法 --mode: ${MODE}（支持 local | docker-bridge | lan）" ;;
    esac
}

# 根据 mode 推导监听地址（--host 显式指定时优先）
resolve_listen_host() {
    if [ -n "$HTTP_LISTEN_HOST" ]; then
        log "使用显式指定的监听地址: ${HTTP_LISTEN_HOST}"
        return
    fi

    case "$MODE" in
        local)
            HTTP_LISTEN_HOST="127.0.0.1"
            ;;
        docker-bridge)
            # 使用 awk 获取 docker0 IP，比 grep -P 兼容性更好
            local docker_ip
            docker_ip=$(ip -4 addr show docker0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n 1)
            if [ -n "$docker_ip" ]; then
                HTTP_LISTEN_HOST="$docker_ip"
                log "检测到 docker0 网关 IP: ${docker_ip}"
                warn "docker-bridge 模式只覆盖默认 bridge 网络。"
                warn "若 docker-compose 使用了自定义 network，请用 --host 显式指定宿主机在该网络可达的地址。"
            else
                warn "未能自动检测到 docker0 网卡 IP，降级使用 127.0.0.1（或请使用 --host 显式指定）"
                HTTP_LISTEN_HOST="127.0.0.1"
            fi
            ;;
        lan)
            HTTP_LISTEN_HOST="0.0.0.0"
            warn "=============================================================="
            warn " lan 模式将在 0.0.0.0:${HTTP_PROXY_PORT} 暴露 HTTP 代理！"
            warn " 任何能访问本机该端口的主机都可以使用此代理。"
            warn " 请务必在云厂商安全组 / 防火墙中限制来源 IP，"
            warn " 否则你的服务器会变成公网开放代理。"
            warn "=============================================================="
            ;;
    esac
}

# ---------------------------------------------------------------------------
# 环境检查
# ---------------------------------------------------------------------------
require_root() {
    [ "$(id -u)" -eq 0 ] || die "请使用 root 运行（sudo ./install.sh）"
}

require_systemd() {
    command -v systemctl >/dev/null 2>&1 || die "本脚本依赖 systemd，未检测到 systemctl"
}

detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v yum >/dev/null 2>&1; then
        echo "yum"
    else
        echo "unknown"
    fi
}

detect_gost_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)        echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l)        echo "armv7" ;;
        *)             die "不支持的架构: ${arch}" ;;
    esac
}

# ---------------------------------------------------------------------------
# 安装 Cloudflare WARP Client
# ---------------------------------------------------------------------------
install_warp() {
    if command -v warp-cli >/dev/null 2>&1; then
        log "warp-cli 已安装，跳过安装步骤"
        return
    fi

    local pkg_mgr
    pkg_mgr=$(detect_pkg_manager)
    log "安装 Cloudflare WARP Client（包管理器: ${pkg_mgr}）..."

    case "$pkg_mgr" in
        apt)
            apt-get update -y
            apt-get install -y curl gpg lsb-release
            curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
                | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
            local codename
            codename=$(lsb_release -cs)
            echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${codename} main" \
                > /etc/apt/sources.list.d/cloudflare-client.list
            apt-get update -y
            apt-get install -y cloudflare-warp
            ;;
        dnf|yum)
            curl -fsSL https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo \
                > /etc/yum.repos.d/cloudflare-warp.repo
            "$pkg_mgr" install -y cloudflare-warp
            ;;
        *)
            die "无法识别包管理器，请手动安装 cloudflare-warp 后重试: https://pkg.cloudflareclient.com/"
            ;;
    esac

    command -v warp-cli >/dev/null 2>&1 || die "cloudflare-warp 安装失败"
    log "cloudflare-warp 安装完成"
}

# ---------------------------------------------------------------------------
# 安装 GOST v2（单二进制，按架构下载）
# ---------------------------------------------------------------------------
install_gost() {
    if [ -x "$GOST_BIN" ]; then
        log "gost 已存在于 ${GOST_BIN}，跳过安装（当前版本: $("$GOST_BIN" -V 2>&1 | head -n1 || true)）"
        return
    fi

    local gost_arch tarball url tmpdir
    gost_arch=$(detect_gost_arch)
    tarball="gost_${GOST_VERSION}_linux_${gost_arch}.tar.gz"
    url="https://github.com/ginuerzh/gost/releases/download/v${GOST_VERSION}/${tarball}"
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    log "下载 GOST v${GOST_VERSION} (${gost_arch}) ..."
    if ! curl -fSL --retry 3 -o "${tmpdir}/${tarball}" "$url"; then
        die "下载 gost 失败: ${url}
如服务器无法直连 GitHub，可手动下载后放置为 ${GOST_BIN} 再重新运行本脚本。"
    fi

    tar -xzf "${tmpdir}/${tarball}" -C "$tmpdir"
    # 压缩包内二进制名为 gost
    install -m 0755 "${tmpdir}/gost" "$GOST_BIN"
    log "gost 安装完成: $("$GOST_BIN" -V 2>&1 | head -n1 || echo "$GOST_BIN")"
}

# ---------------------------------------------------------------------------
# WARP 幂等配置：状态达成就不重复操作
# ---------------------------------------------------------------------------
warp_status() {
    warp-cli --accept-tos status 2>/dev/null || echo "Unknown"
}

warp_is_registered() {
    # 新版：registration show；旧版：status 不报 Registration Missing
    if warp-cli --accept-tos registration show >/dev/null 2>&1; then
        return 0
    fi
    local st
    st=$(warp_status)
    [[ "$st" != *"Registration Missing"* && "$st" != "Unknown" ]]
}

configure_warp() {
    log "确保 warp-svc 服务运行..."
    systemctl enable --now warp-svc

    # 等待 warp-svc IPC 就绪
    local i
    for i in $(seq 1 15); do
        if warp-cli --accept-tos status >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    if warp_is_registered; then
        log "WARP 已注册，跳过注册"
    else
        log "注册 WARP（新旧命令自动 fallback）..."
        warp-cli --accept-tos registration new \
            || warp-cli --accept-tos register \
            || die "WARP 注册失败，请检查网络后重试"
    fi

    log "设置 Local proxy mode 与端口 ${WARP_PROXY_PORT}（带 fallback）..."
    warp-cli --accept-tos mode proxy \
        || warp-cli --accept-tos set-mode proxy \
        || die "设置 proxy mode 失败"
    warp-cli --accept-tos proxy port "$WARP_PROXY_PORT" \
        || warp-cli --accept-tos set-proxy-port "$WARP_PROXY_PORT" \
        || die "设置 proxy 端口失败"

    local st
    st=$(warp_status)
    if [[ "$st" == *"Connected"* ]]; then
        log "WARP 已处于 Connected 状态，跳过连接"
    else
        log "连接 WARP..."
        warp-cli --accept-tos connect || true
    fi
}

# ---------------------------------------------------------------------------
# 配置文件 + systemd 桥接服务
# ---------------------------------------------------------------------------
write_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
# Generated by warp-proxy-setup v${SCRIPT_VERSION} -- $(date '+%Y-%m-%d %H:%M:%S')
MODE=${MODE}
WARP_PROXY_HOST=${WARP_PROXY_HOST}
WARP_PROXY_PORT=${WARP_PROXY_PORT}
HTTP_LISTEN_HOST=${HTTP_LISTEN_HOST}
HTTP_PROXY_PORT=${HTTP_PROXY_PORT}
EOF
    log "配置已写入 ${CONFIG_FILE}"
}

write_bridge_service() {
    cat > "$BRIDGE_UNIT" <<'EOF'
[Unit]
Description=HTTP proxy bridge to Cloudflare WARP Local proxy
After=network-online.target warp-svc.service
Wants=network-online.target

[Service]
EnvironmentFile=/etc/warp-proxy/config.env
# 必须使用 /bin/bash：/dev/tcp 是 Bash 特性，/bin/sh (dash) 不支持
ExecStartPre=/bin/bash -c 'for i in {1..30}; do (echo > /dev/tcp/${WARP_PROXY_HOST}/${WARP_PROXY_PORT}) >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1'
ExecStart=/usr/local/bin/gost -L=http://${HTTP_LISTEN_HOST}:${HTTP_PROXY_PORT} -F=socks5://${WARP_PROXY_HOST}:${WARP_PROXY_PORT}
Restart=always
RestartSec=5
StartLimitIntervalSec=60
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$BRIDGE_SERVICE"
    systemctl restart "$BRIDGE_SERVICE"
    log "systemd 桥接服务已启动: ${BRIDGE_SERVICE}"
}

# ---------------------------------------------------------------------------
# 三层健康检查
# ---------------------------------------------------------------------------
health_check() {
    local ok=0 fail=0
    echo
    log "================= 三层健康检查 ================="

    # Level 1: WARP 服务状态
    echo
    log "[L1] WARP 服务状态 (warp-cli status)"
    local st
    st=$(warp_status)
    echo "      ${st}" | head -n 3
    if [[ "$st" == *"Connected"* ]]; then
        log "[L1] PASS — WARP 已连接"
        ok=$((ok+1))
    else
        err "[L1] FAIL — WARP 未处于 Connected 状态。可能原因："
        err "      1. 当前云服务器 IP 被 Cloudflare 限制"
        err "      2. 服务器网络无法访问 Cloudflare WARP 节点"
        err "      3. WARP 注册失败"
        err "      4. 机器时间 / DNS / 防火墙异常"
        fail=$((fail+1))
    fi

    # Level 2: WARP Local proxy (SOCKS5) 是否可用
    echo
    log "[L2] WARP Local proxy 连通性 (socks5h://${WARP_PROXY_HOST}:${WARP_PROXY_PORT})"
    if curl -sI -x "socks5h://${WARP_PROXY_HOST}:${WARP_PROXY_PORT}" \
            https://www.cloudflare.com/cdn-cgi/trace --max-time 15 >/dev/null; then
        log "[L2] PASS — SOCKS5 本地代理可用"
        ok=$((ok+1))
    else
        err "[L2] FAIL — 无法通过 WARP SOCKS5 代理访问外网"
        fail=$((fail+1))
    fi

    # Level 3: HTTP bridge 是否可用
    echo
    local probe_host="$HTTP_LISTEN_HOST"
    [ "$probe_host" = "0.0.0.0" ] && probe_host="127.0.0.1"
    log "[L3] HTTP 桥接连通性 (http://${probe_host}:${HTTP_PROXY_PORT})"
    if curl -sI -x "http://${probe_host}:${HTTP_PROXY_PORT}" \
            https://www.cloudflare.com/cdn-cgi/trace --max-time 15 >/dev/null; then
        log "[L3] PASS — 通用 HTTP 代理入口可用"
        ok=$((ok+1))
    else
        err "[L3] FAIL — HTTP 桥接不可用，请检查: systemctl status ${BRIDGE_SERVICE}"
        fail=$((fail+1))
    fi

    echo
    log "健康检查完成: ${ok} 通过 / ${fail} 失败"
    [ "$fail" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 输出通用应用接入方式
# ---------------------------------------------------------------------------
print_usage_guide() {
    local host="$HTTP_LISTEN_HOST"
    [ "$host" = "0.0.0.0" ] && host="<服务器IP>"
    local proxy="http://${host}:${HTTP_PROXY_PORT}"

    cat <<EOF

==================================================================
 安装完成！通用 HTTP 代理入口: ${proxy}
==================================================================

通用环境变量（RSSHub / Node.js / Python / Go / Java 等服务）:
    HTTP_PROXY=${proxy}
    HTTPS_PROXY=${proxy}
    ALL_PROXY=${proxy}

Git:
    git config --global http.proxy ${proxy}
    git config --global https.proxy ${proxy}

curl:
    curl -x ${proxy} https://www.google.com

wget:
    wget -e use_proxy=yes -e http_proxy=${proxy} -e https_proxy=${proxy} https://example.com

npm / pnpm:
    npm config set proxy ${proxy}
    npm config set https-proxy ${proxy}

apt:
    echo 'Acquire::http::Proxy "${proxy}";
Acquire::https::Proxy "${proxy}";' | sudo tee /etc/apt/apt.conf.d/99proxy

Docker daemon:
    sudo mkdir -p /etc/systemd/system/docker.service.d
    printf '[Service]\nEnvironment="HTTP_PROXY=${proxy}"\nEnvironment="HTTPS_PROXY=${proxy}"\nEnvironment="NO_PROXY=localhost,127.0.0.1"\n' \\
        | sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf
    sudo systemctl daemon-reload && sudo systemctl restart docker

管理命令:
    systemctl status ${BRIDGE_SERVICE}     # 查看桥接服务
    warp-cli status                        # 查看 WARP 状态
    ./scripts/health-check.sh              # 重新执行三层健康检查
    ./uninstall.sh                         # 卸载

EOF
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    require_root
    require_systemd

    log "warp-proxy-setup v${SCRIPT_VERSION} | mode=${MODE}"
    resolve_listen_host
    log "监听配置: http://${HTTP_LISTEN_HOST}:${HTTP_PROXY_PORT} -> socks5://${WARP_PROXY_HOST}:${WARP_PROXY_PORT}"

    install_warp
    install_gost
    configure_warp
    write_config
    write_bridge_service

    if health_check; then
        print_usage_guide
    else
        warn "部分健康检查未通过，请根据上方提示排障后运行 scripts/health-check.sh 复检。"
        print_usage_guide
        exit 1
    fi
}

main "$@"
