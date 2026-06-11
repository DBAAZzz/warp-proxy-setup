#!/usr/bin/env bash
#
# warp-proxy-setup :: uninstall.sh (v0.2)
#
# 卸载桥接层（systemd 服务 + 配置 + sing-box/wgcf 二进制，含 v0.1 遗留 gost）。
# Cloudflare WARP 官方客户端默认保留；如需一并移除，使用 --purge-warp。
#
# 用法：
#   sudo ./uninstall.sh                # 移除桥接服务、配置、sing-box/wgcf/gost
#   sudo ./uninstall.sh --purge-warp   # 同时断开并卸载 cloudflare-warp
#
set -euo pipefail

readonly BRIDGE_SERVICE="warp-proxy-bridge"
readonly BRIDGE_UNIT="/etc/systemd/system/${BRIDGE_SERVICE}.service"
readonly CONFIG_DIR="/etc/warp-proxy"
readonly SINGBOX_BIN="/usr/local/bin/sing-box"
readonly WGCF_BIN="/usr/local/bin/wgcf"
readonly GOST_BIN="/usr/local/bin/gost"

PURGE_WARP=false

log()  { printf '\033[1;32m[INFO]\033[0m  %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --purge-warp) PURGE_WARP=true; shift ;;
        -h|--help)    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            die "未知参数: $1" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "请使用 root 运行（sudo ./uninstall.sh）"

# 1. 停止并移除桥接服务
if systemctl list-unit-files | grep -q "^${BRIDGE_SERVICE}.service"; then
    log "停止并禁用 ${BRIDGE_SERVICE} ..."
    systemctl disable --now "$BRIDGE_SERVICE" 2>/dev/null || true
fi
if [ -f "$BRIDGE_UNIT" ]; then
    rm -f "$BRIDGE_UNIT"
    systemctl daemon-reload
    log "已移除 systemd unit: ${BRIDGE_UNIT}"
fi

# 2. 移除配置（含 sing-box.json 与 wgcf 账号/profile）
if [ -d "$CONFIG_DIR" ]; then
    rm -rf "$CONFIG_DIR"
    log "已移除配置目录: ${CONFIG_DIR}（含 wgcf 账号文件）"
fi

# 3. 移除二进制：sing-box、wgcf，以及 v0.1 遗留的 gost
for bin in "$SINGBOX_BIN" "$WGCF_BIN" "$GOST_BIN"; do
    if [ -e "$bin" ]; then
        rm -f "$bin"
        log "已移除: ${bin}"
    fi
done

# 4. 可选：卸载 Cloudflare WARP 官方客户端
if [ "$PURGE_WARP" = true ]; then
    if command -v warp-cli >/dev/null 2>&1; then
        log "断开 WARP 连接并删除注册..."
        warp-cli --accept-tos disconnect 2>/dev/null || true
        warp-cli --accept-tos registration delete 2>/dev/null \
            || warp-cli --accept-tos delete 2>/dev/null || true
    fi
    log "卸载 cloudflare-warp 软件包..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get remove -y cloudflare-warp || true
        rm -f /etc/apt/sources.list.d/cloudflare-client.list \
              /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    elif command -v dnf >/dev/null 2>&1; then
        dnf remove -y cloudflare-warp || true
        rm -f /etc/yum.repos.d/cloudflare-warp.repo
    elif command -v yum >/dev/null 2>&1; then
        yum remove -y cloudflare-warp || true
        rm -f /etc/yum.repos.d/cloudflare-warp.repo
    else
        warn "无法识别包管理器，请手动卸载 cloudflare-warp"
    fi
else
    if command -v warp-cli >/dev/null 2>&1; then
        log "保留 Cloudflare WARP 官方客户端（如需一并卸载: sudo ./uninstall.sh --purge-warp）"
    fi
fi

log "卸载完成。"
warn "提醒：如果你曾给 Git / npm / apt / Docker daemon 配置过 http://127.0.0.1:18080 代理，"
warn "这些应用侧配置需要自行清理，否则它们的网络请求会因代理失联而失败。"
