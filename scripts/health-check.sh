#!/usr/bin/env bash
#
# warp-proxy-setup :: scripts/health-check.sh
#
# 独立三层健康检查：
#   L1 WARP 服务状态
#   L2 WARP Local proxy (SOCKS5) 连通性
#   L3 HTTP bridge 连通性
#
# 用法：./scripts/health-check.sh
# 退出码：0 = 全部通过；非 0 = 有失败层级
#
set -uo pipefail

readonly CONFIG_FILE="/etc/warp-proxy/config.env"
readonly BRIDGE_SERVICE="warp-proxy-bridge"

# 读取安装时生成的配置；不存在时退回默认值
WARP_PROXY_HOST="127.0.0.1"
WARP_PROXY_PORT="40000"
HTTP_LISTEN_HOST="127.0.0.1"
HTTP_PROXY_PORT="18080"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
else
    echo "[WARN] 未找到 ${CONFIG_FILE}，使用默认端口检查（40000 / 18080）" >&2
fi

log()  { printf '\033[1;32m[INFO]\033[0m  %s\n' "$*"; }
err()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }

fail=0

# ---------------------------------------------------------------------------
# Level 1: WARP 服务状态
# ---------------------------------------------------------------------------
echo
log "[L1] WARP 服务状态 (warp-cli status)"
status=$(warp-cli --accept-tos status 2>/dev/null || echo "Unknown")
echo "      ${status}" | head -n 3
if [[ "$status" == *"Connected"* ]]; then
    log "[L1] PASS — WARP 已连接"
else
    err "[L1] FAIL — WARP 未处于 Connected 状态。可能原因："
    err "      1. 当前云服务器 IP 被 Cloudflare 限制"
    err "      2. 服务器网络无法访问 Cloudflare WARP 节点"
    err "      3. WARP 注册失败"
    err "      4. 机器时间 / DNS / 防火墙异常"
    fail=$((fail+1))
fi

# ---------------------------------------------------------------------------
# Level 2: WARP Local proxy (SOCKS5) 连通性
# ---------------------------------------------------------------------------
echo
log "[L2] WARP Local proxy 连通性 (socks5h://${WARP_PROXY_HOST}:${WARP_PROXY_PORT})"
if curl -sI -x "socks5h://${WARP_PROXY_HOST}:${WARP_PROXY_PORT}" \
        https://www.cloudflare.com/cdn-cgi/trace --max-time 15 >/dev/null; then
    log "[L2] PASS — SOCKS5 本地代理可用"
else
    err "[L2] FAIL — 无法通过 WARP SOCKS5 代理访问外网"
    fail=$((fail+1))
fi

# ---------------------------------------------------------------------------
# Level 3: HTTP bridge 连通性
# ---------------------------------------------------------------------------
echo
probe_host="$HTTP_LISTEN_HOST"
[ "$probe_host" = "0.0.0.0" ] && probe_host="127.0.0.1"
log "[L3] HTTP 桥接连通性 (http://${probe_host}:${HTTP_PROXY_PORT})"
if curl -sI -x "http://${probe_host}:${HTTP_PROXY_PORT}" \
        https://www.cloudflare.com/cdn-cgi/trace --max-time 15 >/dev/null; then
    log "[L3] PASS — 通用 HTTP 代理入口可用"
else
    err "[L3] FAIL — HTTP 桥接不可用，请检查: systemctl status ${BRIDGE_SERVICE}"
    fail=$((fail+1))
fi

echo
if [ "$fail" -eq 0 ]; then
    log "全部通过：通用 HTTP 代理入口工作正常 (http://${probe_host}:${HTTP_PROXY_PORT})"
else
    err "${fail} 个层级检查失败。排障提示：L1/L2 都通但应用代理失败时，"
    err "要么是桥接层出错（L3 报错），要么是应用的代理环境变量配置有误。"
fi
exit "$fail"
