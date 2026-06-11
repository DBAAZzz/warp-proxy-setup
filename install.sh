#!/usr/bin/env bash
#
# warp-proxy-setup :: install.sh (v0.2)
#
# 一键把 Linux 服务器变成一个基于 Cloudflare WARP 出口的本机通用 HTTP 代理节点。
#
#   入口层（统一）：sing-box HTTP inbound → http://127.0.0.1:18080
#   出口层（backend 可选）：
#     warp-cli   官方客户端 Local proxy (127.0.0.1:40000)，官方支持系统的默认
#     wireguard  wgcf + sing-box 用户态 WireGuard endpoint，CentOS 7 等系统的兜底
#
# 用法：
#   sudo ./install.sh                          # --backend auto（按系统自动选择）
#   sudo ./install.sh --backend warp-cli       # 强制官方客户端
#   sudo ./install.sh --backend wireguard      # 强制 wgcf + 用户态 WireGuard
#   sudo ./install.sh --mode docker-bridge     # 监听 docker0 网关 IP
#   sudo ./install.sh --mode lan               # 监听 0.0.0.0（必须自行配置防火墙）
#   sudo ./install.sh --host 172.18.0.1        # 显式指定监听地址
#   sudo ./install.sh --port 18080             # 自定义 HTTP 代理端口
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 常量与默认配置
# ---------------------------------------------------------------------------
readonly SCRIPT_VERSION="0.2.0"
readonly CONFIG_DIR="/etc/warp-proxy"
readonly CONFIG_FILE="${CONFIG_DIR}/config.env"
readonly SINGBOX_CONFIG="${CONFIG_DIR}/sing-box.json"
readonly WGCF_DIR="${CONFIG_DIR}/wgcf"
readonly BRIDGE_SERVICE="warp-proxy-bridge"
readonly BRIDGE_UNIT="/etc/systemd/system/${BRIDGE_SERVICE}.service"
readonly SINGBOX_BIN="/usr/local/bin/sing-box"
readonly WGCF_BIN="/usr/local/bin/wgcf"
# 版本锁定：sing-box 1.11+ 的 wireguard endpoint 格式有过破坏性变更，不追 latest
readonly SING_BOX_VERSION="${SING_BOX_VERSION:-1.12.4}"
readonly WGCF_VERSION="${WGCF_VERSION:-2.2.26}"
# WARP WireGuard 端点域名解析失败时的回退锚点
readonly WARP_ENDPOINT_FALLBACK_IP="162.159.192.1"

# GitHub Releases 在大陆服务器经常不可达，依次尝试：直连 → 加速镜像。
# 镜像用法均为 "前缀 + 完整 GitHub URL"。可用 GITHUB_MIRROR 指定自有镜像（最高优先）。
# 镜像是第三方服务，存在篡改风险——因此下载后强制 SHA256 校验（见下方内嵌校验和表）。
readonly GH_MIRRORS="${GITHUB_MIRROR:+${GITHUB_MIRROR} }https://ghfast.top https://gh-proxy.com https://ghproxy.net"

# 锁定版本二进制的官方 SHA256（从 github.com 官方 Release 下载后计算）。
# 升级 SING_BOX_VERSION / WGCF_VERSION 时必须同步更新本表，否则校验失败拒绝安装。
pinned_sha256() {
    case "$1" in
        sing-box-1.12.4-linux-amd64.tar.gz) echo "8c770d34d27fa81c4d6533bfc75489d706c613831fc8234ca0a7be51e6af2a32" ;;
        sing-box-1.12.4-linux-arm64.tar.gz) echo "4037fca86cc7c2d78ab09127567584544fc7dc3bba7ff06ba3dba41632827de7" ;;
        sing-box-1.12.4-linux-armv7.tar.gz) echo "bc3f323493bdc76aa2eebe2f34761a07efa5d7ddcc66cf82044e10f34849e52a" ;;
        wgcf_2.2.26_linux_amd64)            echo "b49e7c52307df1f0a9ccd13ad12f87bf7ee7092df4e189f064d81860ec6f4bf5" ;;
        wgcf_2.2.26_linux_arm64)            echo "cbda1a8e4e1144c49ed9a8a2d99f3d5a70e6115ebca62ae3d354d8b074a4ae73" ;;
        wgcf_2.2.26_linux_armv7)            echo "d523c71a7d294823c4e37af51ef891924069fb23b82a854f01ca2517a479be08" ;;
        *)                                  echo "" ;;
    esac
}

BACKEND="auto"
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
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --backend)
                BACKEND="${2:?--backend 需要参数: auto | warp-cli | wireguard}"
                shift 2 ;;
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
                shift ;;
            *)
                die "未知参数: $1（使用 --help 查看用法）" ;;
        esac
    done

    case "$BACKEND" in
        auto|warp-cli|wireguard) ;;
        *) die "非法 --backend: ${BACKEND}（支持 auto | warp-cli | wireguard）" ;;
    esac
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
# 环境检查与 backend 判定
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

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)        echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l)        echo "armv7" ;;
        *)             die "不支持的架构: ${arch}" ;;
    esac
}

# 计算文件 SHA256（sha256sum / shasum 自适应，老系统兜底用 openssl）
file_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$1" | awk '{print $NF}'
    else
        echo ""
    fi
}

# 从 GitHub Release 下载文件：先直连，失败后依次走加速镜像；
# 每个下载源成功后都做 SHA256 校验，不匹配则丢弃换下一个源。
#   $1 = GitHub 完整 URL（github.com/...）
#   $2 = 本地保存路径
#   $3 = 文件名（用于查内嵌校验和表）
download_release() {
    local gh_url="$1" dest="$2" fname="$3"
    local expected actual src
    expected=$(pinned_sha256 "$fname")
    [ -n "$expected" ] || die "内部错误：${fname} 没有内嵌校验和（升级版本时需同步更新 pinned_sha256 表）"

    for src in "" $GH_MIRRORS; do
        local url label
        if [ -z "$src" ]; then
            url="$gh_url"; label="GitHub 直连"
        else
            url="${src}/${gh_url}"; label="镜像 ${src}"
        fi
        log "下载 ${fname}（${label}）..."
        if ! curl -fSL --retry 2 --connect-timeout 10 --max-time 300 -o "$dest" "$url" 2>/dev/null; then
            warn "${label} 下载失败，尝试下一个源"
            rm -f "$dest"
            continue
        fi
        actual=$(file_sha256 "$dest")
        if [ -z "$actual" ]; then
            warn "系统缺少 sha256sum/shasum/openssl，无法校验完整性，拒绝使用该文件"
            rm -f "$dest"
            die "请先安装 coreutils（提供 sha256sum）后重试"
        fi
        if [ "$actual" = "$expected" ]; then
            log "${fname} 下载完成，SHA256 校验通过"
            return 0
        fi
        warn "${label} 下载的 ${fname} SHA256 校验失败（可能被篡改或截断），丢弃并尝试下一个源"
        warn "  期望: ${expected}"
        warn "  实际: ${actual}"
        rm -f "$dest"
    done

    die "所有下载源（GitHub 直连 + 加速镜像）均失败: ${fname}
可选自救方式：
  1. 设置自有镜像: GITHUB_MIRROR=https://your-mirror.example.com sudo -E ./install.sh ...
  2. 在能访问 GitHub 的机器上手动下载并放置到目标路径后重跑脚本:
     ${gh_url}"
}

# Cloudflare WARP 官方客户端是否支持当前系统
# 支持列表: Ubuntu 22.04+/Debian 12+/RHEL·CentOS 8+/Fedora 34+
os_officially_supported() {
    [ -f /etc/os-release ] || return 1
    local id version_id major
    id=$(. /etc/os-release && echo "${ID:-}")
    version_id=$(. /etc/os-release && echo "${VERSION_ID:-}")
    major=${version_id%%.*}
    case "$id" in
        ubuntu) [ "${major:-0}" -ge 22 ] ;;
        debian) [ "${major:-0}" -ge 12 ] ;;
        centos) [ "${major:-0}" -ge 8 ] ;;
        rhel)   [ "${major:-0}" -ge 8 ] ;;
        fedora) [ "${major:-0}" -ge 34 ] ;;
        *)      return 1 ;;
    esac
}

os_pretty_name() {
    [ -f /etc/os-release ] && (. /etc/os-release && echo "${PRETTY_NAME:-unknown}") || echo "unknown"
}

resolve_backend() {
    case "$BACKEND" in
        auto)
            if os_officially_supported; then
                BACKEND="warp-cli"
                log "系统 $(os_pretty_name) 在 Cloudflare 官方支持列表内 → backend=warp-cli"
            else
                BACKEND="wireguard"
                warn "系统 $(os_pretty_name) 不在 Cloudflare WARP 官方客户端支持列表内"
                warn "（官方支持: Ubuntu 22.04+/Debian 12+/RHEL·CentOS 8+/Fedora 34+）"
                warn "自动切换 backend=wireguard（wgcf + sing-box 用户态 WireGuard）。"
                warn "注意：wgcf 为非官方工具，调用 Cloudflare 未公开 API，存在接口变更失效的可能。"
            fi
            ;;
        warp-cli)
            if ! os_officially_supported; then
                die "当前系统 $(os_pretty_name) 不被 Cloudflare WARP 官方客户端支持，无法使用 --backend warp-cli。
请改用 --backend wireguard（或 --backend auto 自动选择）。"
            fi
            ;;
        wireguard)
            warn "已强制 backend=wireguard。注意 wgcf 为非官方工具，官方支持的系统上推荐 warp-cli。"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# 安装 Cloudflare WARP Client（仅 warp-cli backend）
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
# 安装 sing-box（统一桥接层，单二进制，版本锁定）
# ---------------------------------------------------------------------------
install_sing_box() {
    if [ -x "$SINGBOX_BIN" ]; then
        local cur
        cur=$("$SINGBOX_BIN" version 2>/dev/null | head -n1 || true)
        if echo "$cur" | grep -q "$SING_BOX_VERSION"; then
            log "sing-box ${SING_BOX_VERSION} 已安装，跳过"
            return
        fi
        warn "检测到已有 sing-box（${cur:-未知版本}），将替换为锁定版本 ${SING_BOX_VERSION}"
    fi

    local arch dirname tarball url tmpdir
    arch=$(detect_arch)
    dirname="sing-box-${SING_BOX_VERSION}-linux-${arch}"
    tarball="${dirname}.tar.gz"
    url="https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/${tarball}"
    tmpdir=$(mktemp -d)

    download_release "$url" "${tmpdir}/${tarball}" "$tarball" || { rm -rf "$tmpdir"; exit 1; }

    tar -xzf "${tmpdir}/${tarball}" -C "$tmpdir"
    install -m 0755 "${tmpdir}/${dirname}/sing-box" "$SINGBOX_BIN"
    rm -rf "$tmpdir"
    log "sing-box 安装完成: $("$SINGBOX_BIN" version 2>/dev/null | head -n1 || echo "$SINGBOX_BIN")"
}

# ---------------------------------------------------------------------------
# wgcf：安装、注册、生成并解析 WireGuard profile（仅 wireguard backend）
# ---------------------------------------------------------------------------
install_wgcf() {
    if [ -x "$WGCF_BIN" ]; then
        log "wgcf 已安装，跳过"
        return
    fi
    local arch fname url
    arch=$(detect_arch)
    fname="wgcf_${WGCF_VERSION}_linux_${arch}"
    url="https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/${fname}"
    download_release "$url" "$WGCF_BIN" "$fname"
    chmod 0755 "$WGCF_BIN"
    log "wgcf 安装完成"
}

# 幂等：账号/与 profile 文件存在即跳过对应步骤
wgcf_register_and_generate() {
    mkdir -p "$WGCF_DIR"
    chmod 700 "$WGCF_DIR"

    if [ -f "${WGCF_DIR}/wgcf-account.toml" ]; then
        log "WARP 账号已存在（${WGCF_DIR}/wgcf-account.toml），跳过注册"
    else
        log "通过 wgcf 注册 WARP 账号..."
        (cd "$WGCF_DIR" && "$WGCF_BIN" register --accept-tos) \
            || die "wgcf 注册失败。可能原因：Cloudflare 注册接口变更 / 网络无法访问 api.cloudflareclient.com"
        chmod 600 "${WGCF_DIR}/wgcf-account.toml"
    fi

    if [ -f "${WGCF_DIR}/wgcf-profile.conf" ]; then
        log "WireGuard profile 已存在，跳过生成"
    else
        log "生成 WireGuard profile..."
        (cd "$WGCF_DIR" && "$WGCF_BIN" generate) || die "wgcf generate 失败"
        chmod 600 "${WGCF_DIR}/wgcf-profile.conf"
    fi
}

# 从 wgcf-profile.conf 提取一个 ini 键的值（取第一个匹配）。
# 注意：只剥掉第一个 "key =" 前缀，不能按 "=" 整体分列——
# WireGuard 密钥是 base64，末尾的 "=" 会被 awk -F'=' 截掉导致握手失败。
profile_get() {
    sed -n "s/^${1}[[:space:]]*=[[:space:]]*//p" "${WGCF_DIR}/wgcf-profile.conf" | head -n 1 | tr -d ' \r'
}

# 解析 profile 并渲染 sing-box wireguard endpoint 所需变量：
# WG_PRIVATE_KEY / WG_ADDRESS_JSON / WG_PEER_PUBLIC_KEY / WG_PEER_IP / WG_PEER_PORT / WG_RESERVED_JSON
parse_wgcf_profile() {
    WG_PRIVATE_KEY=$(profile_get "PrivateKey")
    WG_PEER_PUBLIC_KEY=$(profile_get "PublicKey")
    local endpoint addresses
    endpoint=$(profile_get "Endpoint")
    # Address 可能是单行逗号分隔，也可能多行；统一收集后拼 JSON 数组
    addresses=$(sed -n 's/^Address[[:space:]]*=[[:space:]]*//p' "${WGCF_DIR}/wgcf-profile.conf" \
        | tr ',' '\n' | tr -d ' \r' | grep -v '^$')

    [ -n "$WG_PRIVATE_KEY" ]    || die "未能从 wgcf-profile.conf 解析 PrivateKey"
    [ -n "$WG_PEER_PUBLIC_KEY" ] || die "未能从 wgcf-profile.conf 解析 PublicKey"
    [ -n "$addresses" ]          || die "未能从 wgcf-profile.conf 解析 Address"

    WG_ADDRESS_JSON=$(echo "$addresses" | awk '{printf "%s\"%s\"", (NR>1?", ":""), $0}')

    # Endpoint 形如 engage.cloudflareclient.com:2408，解析域名为 IP（失败回退锚点 IP）
    local host port ip
    host=${endpoint%:*}
    port=${endpoint##*:}
    [ -n "$port" ] || port="2408"
    ip=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}')
    if [ -z "$ip" ]; then
        warn "无法解析 WARP 端点域名 ${host}，回退使用锚点 IP ${WARP_ENDPOINT_FALLBACK_IP}"
        ip="$WARP_ENDPOINT_FALLBACK_IP"
    fi
    WG_PEER_IP="$ip"
    WG_PEER_PORT="$port"
    log "WARP WireGuard 端点: ${WG_PEER_IP}:${WG_PEER_PORT}"

    parse_wgcf_reserved
}

# 从 wgcf-account.toml 提取一个 TOML 键的值（兼容单/双引号）
account_get() {
    sed -n "s/^${1}[[:space:]]*=[[:space:]]*['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}$/\1/p" \
        "${WGCF_DIR}/wgcf-account.toml" | head -n 1 | tr -d ' \r'
}

# WARP 要求 WireGuard 包头携带 3 字节 client_id（reserved 字段）。
# 缺少 reserved 的典型症状：握手"成功"、无报错，但所有数据包被 Cloudflare 静默丢弃。
# 注意：wgcf 不会把 client_id 写进 wgcf-account.toml（文件里只有 device_id /
# access_token / private_key / license_key），必须用 device_id + access_token
# 调用 Cloudflare 设备 API 查询。结果缓存到 ${WGCF_DIR}/client_id 避免重复请求。
parse_wgcf_reserved() {
    WG_RESERVED_JSON=""
    local client_id=""
    local cache_file="${WGCF_DIR}/client_id"

    if [ -f "$cache_file" ]; then
        client_id=$(tr -d ' \r\n' < "$cache_file")
        log "使用缓存的 client_id（${cache_file}）"
    fi

    if [ -z "$client_id" ]; then
        local device_id access_token resp
        device_id=$(account_get "device_id")
        access_token=$(account_get "access_token")
        if [ -z "$device_id" ] || [ -z "$access_token" ]; then
            warn "wgcf-account.toml 中缺少 device_id / access_token，无法获取 client_id"
            warn "跳过 reserved 字段（若代理请求挂起，这就是原因）"
            return
        fi
        log "调用 Cloudflare API 获取 client_id（设备: ${device_id}）..."
        resp=$(curl -fsSL --max-time 20 \
            -H "Authorization: Bearer ${access_token}" \
            -H "Accept: application/json" \
            -H "User-Agent: okhttp/3.12.1" \
            "https://api.cloudflareclient.com/v0a2158/reg/${device_id}" 2>/dev/null || true)
        # 提取 "client_id":"..."，并还原 JSON 对 "/" 的 \/ 转义（base64 可能含 / + =）
        client_id=$(printf '%s' "$resp" \
            | sed -n 's/.*"client_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
            | head -n 1 | sed 's_\\/_/_g')
        if [ -z "$client_id" ]; then
            warn "Cloudflare API 未返回 client_id（接口变更或 access_token 失效）"
            warn "跳过 reserved 字段（若代理请求挂起，这就是原因）"
            return
        fi
        printf '%s\n' "$client_id" > "$cache_file"
        chmod 600 "$cache_file"
    fi

    local bytes
    bytes=$(printf '%s' "$client_id" | base64 -d 2>/dev/null | od -An -tu1 \
        | tr -s ' \n' ' ' | sed 's/^ //; s/ $//; s/ /, /g')

    local count
    count=$(echo "$bytes" | awk -F', ' '{print NF}')
    if [ -z "$bytes" ] || [ "$count" -ne 3 ]; then
        warn "client_id 解码异常（得到 ${count:-0} 字节，期望 3），跳过 reserved 字段"
        return
    fi

    WG_RESERVED_JSON="$bytes"
    log "已从 wgcf 账号解析 reserved 字段: [${WG_RESERVED_JSON}]"
}

# ---------------------------------------------------------------------------
# WARP 官方客户端幂等配置（仅 warp-cli backend）
# ---------------------------------------------------------------------------
warp_status() {
    warp-cli --accept-tos status 2>/dev/null || echo "Unknown"
}

warp_is_registered() {
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
# 配置文件 + sing-box 配置 + systemd 桥接服务
# ---------------------------------------------------------------------------
write_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
# Generated by warp-proxy-setup v${SCRIPT_VERSION} -- $(date '+%Y-%m-%d %H:%M:%S')
BACKEND=${BACKEND}
MODE=${MODE}
WARP_PROXY_HOST=${WARP_PROXY_HOST}
WARP_PROXY_PORT=${WARP_PROXY_PORT}
HTTP_LISTEN_HOST=${HTTP_LISTEN_HOST}
HTTP_PROXY_PORT=${HTTP_PROXY_PORT}
EOF
    log "配置已写入 ${CONFIG_FILE}"
}

write_singbox_config() {
    if [ "$BACKEND" = "warp-cli" ]; then
        cat > "$SINGBOX_CONFIG" <<EOF
{
  "log": { "level": "warn" },
  "inbounds": [
    {
      "type": "http",
      "tag": "http-in",
      "listen": "${HTTP_LISTEN_HOST}",
      "listen_port": ${HTTP_PROXY_PORT}
    }
  ],
  "outbounds": [
    {
      "type": "socks",
      "tag": "warp-socks",
      "server": "${WARP_PROXY_HOST}",
      "server_port": ${WARP_PROXY_PORT}
    }
  ],
  "route": { "final": "warp-socks" }
}
EOF
    else
        local reserved_line=""
        if [ -n "${WG_RESERVED_JSON:-}" ]; then
            reserved_line="
          \"reserved\": [${WG_RESERVED_JSON}],"
        fi
        cat > "$SINGBOX_CONFIG" <<EOF
{
  "log": { "level": "warn" },
  "inbounds": [
    {
      "type": "http",
      "tag": "http-in",
      "listen": "${HTTP_LISTEN_HOST}",
      "listen_port": ${HTTP_PROXY_PORT}
    }
  ],
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "warp-wg",
      "mtu": 1280,
      "address": [${WG_ADDRESS_JSON}],
      "private_key": "${WG_PRIVATE_KEY}",
      "peers": [
        {
          "address": "${WG_PEER_IP}",
          "port": ${WG_PEER_PORT},
          "public_key": "${WG_PEER_PUBLIC_KEY}",${reserved_line}
          "allowed_ips": ["0.0.0.0/0", "::/0"],
          "persistent_keepalive_interval": 25
        }
      ]
    }
  ],
  "route": { "final": "warp-wg" }
}
EOF
    fi
    chmod 600 "$SINGBOX_CONFIG"

    "$SINGBOX_BIN" check -c "$SINGBOX_CONFIG" \
        || die "sing-box 配置校验失败: ${SINGBOX_CONFIG}"
    log "sing-box 配置已生成并通过校验: ${SINGBOX_CONFIG}"
}

write_bridge_service() {
    # systemd 兼容性：CentOS 7 是 systemd 219，
    # 必须用 legacy 的 [Service] StartLimitInterval= 写法（新版 systemd 同样接受）
    local after="network-online.target"
    local pre=""
    if [ "$BACKEND" = "warp-cli" ]; then
        after="network-online.target warp-svc.service"
        # /dev/tcp 是 Bash 特性，必须 /bin/bash；等待 WARP Local proxy 40000 就绪
        pre="ExecStartPre=/bin/bash -c 'for i in {1..30}; do (echo > /dev/tcp/${WARP_PROXY_HOST}/${WARP_PROXY_PORT}) >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1'"
    fi

    cat > "$BRIDGE_UNIT" <<EOF
[Unit]
Description=WARP HTTP proxy bridge (sing-box, backend=${BACKEND})
After=${after}
Wants=network-online.target

[Service]
${pre}
ExecStart=${SINGBOX_BIN} run -c ${SINGBOX_CONFIG}
Restart=always
RestartSec=5
StartLimitInterval=60
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$BRIDGE_SERVICE"
    systemctl restart "$BRIDGE_SERVICE"
    log "systemd 桥接服务已启动: ${BRIDGE_SERVICE} (backend=${BACKEND})"
}

# v0.1 遗留清理：GOST 已被 sing-box 取代
cleanup_v01_gost() {
    if [ -x /usr/local/bin/gost ]; then
        warn "检测到 v0.1 遗留的 /usr/local/bin/gost，桥接层已统一为 sing-box，移除 gost"
        rm -f /usr/local/bin/gost
    fi
}

# ---------------------------------------------------------------------------
# 三层健康检查（v0.2：L1 出口层 / L2 入口连通 / L3 出口归属 warp=on）
# ---------------------------------------------------------------------------
health_check() {
    local ok=0 fail=0
    echo
    log "================= 三层健康检查 ================="

    # Level 1: 出口层状态（按 backend 分叉）
    echo
    if [ "$BACKEND" = "warp-cli" ]; then
        log "[L1] WARP 官方客户端状态 (warp-cli status)"
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
    else
        log "[L1] wireguard backend 出口层状态"
        if systemctl is-active --quiet "$BRIDGE_SERVICE" && [ -f "${WGCF_DIR}/wgcf-profile.conf" ]; then
            log "[L1] PASS — ${BRIDGE_SERVICE} 运行中，wgcf profile 就绪"
            ok=$((ok+1))
        else
            err "[L1] FAIL — 桥接服务未运行或 wgcf profile 缺失"
            err "      检查: systemctl status ${BRIDGE_SERVICE} ; ls ${WGCF_DIR}/"
            fail=$((fail+1))
        fi
    fi

    # Level 2: 入口层连通性（两个 backend 一致）
    echo
    local probe_host="$HTTP_LISTEN_HOST"
    [ "$probe_host" = "0.0.0.0" ] && probe_host="127.0.0.1"
    local trace=""
    log "[L2] HTTP 代理入口连通性 (http://${probe_host}:${HTTP_PROXY_PORT})"
    trace=$(curl -s -x "http://${probe_host}:${HTTP_PROXY_PORT}" \
            https://www.cloudflare.com/cdn-cgi/trace --max-time 20 || true)
    if [ -n "$trace" ]; then
        log "[L2] PASS — 通用 HTTP 代理入口可用"
        ok=$((ok+1))
    else
        err "[L2] FAIL — 18080 入口不可用，请检查: systemctl status ${BRIDGE_SERVICE}"
        fail=$((fail+1))
    fi

    # Level 3: 出口归属校验 — 流量是否真的走 WARP
    echo
    log "[L3] 出口归属校验 (cdn-cgi/trace 的 warp 字段)"
    if echo "$trace" | grep -qE '^warp=(on|plus)$'; then
        log "[L3] PASS — 出口确认为 Cloudflare WARP ($(echo "$trace" | grep '^warp='))"
        ok=$((ok+1))
    else
        err "[L3] FAIL — 代理通了但出口不是 WARP（warp=$(echo "$trace" | awk -F= '/^warp=/{print $2}')）"
        err "      检查 sing-box 出站配置 / WireGuard 握手: journalctl -u ${BRIDGE_SERVICE} -n 50"
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
 安装完成！backend=${BACKEND}
 通用 HTTP 代理入口: ${proxy}
==================================================================

通用环境变量（RSSHub / Node.js / Python / Go / Java 等服务）:
    HTTP_PROXY=${proxy}
    HTTPS_PROXY=${proxy}
    ALL_PROXY=${proxy}

Git:
    git config --global http.proxy ${proxy}
    git config --global https.proxy ${proxy}

curl:
    curl -x ${proxy} https://www.cloudflare.com/cdn-cgi/trace

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
    journalctl -u ${BRIDGE_SERVICE} -f     # 桥接服务日志
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
    resolve_backend

    log "warp-proxy-setup v${SCRIPT_VERSION} | backend=${BACKEND} | mode=${MODE}"
    resolve_listen_host
    log "监听配置: http://${HTTP_LISTEN_HOST}:${HTTP_PROXY_PORT}"

    install_sing_box

    if [ "$BACKEND" = "warp-cli" ]; then
        install_warp
        configure_warp
    else
        install_wgcf
        wgcf_register_and_generate
        parse_wgcf_profile
    fi

    write_config
    write_singbox_config
    write_bridge_service
    cleanup_v01_gost

    if health_check; then
        print_usage_guide
    else
        warn "部分健康检查未通过，请根据上方提示排障后运行 scripts/health-check.sh 复检。"
        print_usage_guide
        exit 1
    fi
}

main "$@"
