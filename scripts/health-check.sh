#!/usr/bin/env bash
#
# warp-proxy-setup :: scripts/health-check.sh (v0.2)
#
# 三层健康检查（双 backend）：
#   L1 出口层状态（warp-cli status / 桥接服务 + wgcf profile）
#   L2 HTTP 代理入口连通性 (18080)
#   L3 出口归属校验（cdn-cgi/trace 响应 warp=on/plus）
#
# 用法：./scripts/health-check.sh
# 退出码：0 = 全部通过；非 0 = 失败层数
#
set -uo pipefail

readonly CONFIG_FILE="/etc/warp-proxy/config.env"
readonly BRIDGE_SERVICE="warp-proxy-bridge"
readonly WGCF_DIR="/etc/warp-proxy/wgcf"

# 读取安装时生成的配置；不存在时退回默认值
BACKEND="warp-cli"
WARP_PROXY_HOST="127.0.0.1"
WARP_PROXY_PORT="40000"
HTTP_LISTEN_HOST="127.0.0.1"
HTTP_PROXY_PORT="18080"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
else
    echo "[WARN] 未找到 ${CONFIG_FILE}，按默认值检查（backend=warp-cli, 18080）" >&2
fi

log()  { printf '\033[1;32m[INFO]\033[0m  %s\n' "$*"; }
err()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }

fail=0

# ---------------------------------------------------------------------------
# Level 1: 出口层状态（按 backend 分叉）
# ---------------------------------------------------------------------------
echo
if [ "$BACKEND" = "warp-cli" ]; then
    log "[L1] WARP 官方客户端状态 (warp-cli status)"
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
else
    log "[L1] wireguard backend 出口层状态"
    if systemctl is-active --quiet "$BRIDGE_SERVICE" && [ -f "${WGCF_DIR}/wgcf-profile.conf" ]; then
        log "[L1] PASS — ${BRIDGE_SERVICE} 运行中，wgcf profile 就绪"
    else
        err "[L1] FAIL — 桥接服务未运行或 wgcf profile 缺失"
        err "      检查: systemctl status ${BRIDGE_SERVICE} ; ls ${WGCF_DIR}/"
        fail=$((fail+1))
    fi
fi

# ---------------------------------------------------------------------------
# Level 2: HTTP 代理入口连通性
# ---------------------------------------------------------------------------
echo
probe_host="$HTTP_LISTEN_HOST"
[ "$probe_host" = "0.0.0.0" ] && probe_host="127.0.0.1"
log "[L2] HTTP 代理入口连通性 (http://${probe_host}:${HTTP_PROXY_PORT})"
trace=$(curl -s -x "http://${probe_host}:${HTTP_PROXY_PORT}" \
        https://www.cloudflare.com/cdn-cgi/trace --max-time 20 || true)
if [ -n "$trace" ]; then
    log "[L2] PASS — 通用 HTTP 代理入口可用"
else
    err "[L2] FAIL — ${HTTP_PROXY_PORT} 入口不可用，请检查: systemctl status ${BRIDGE_SERVICE}"
    fail=$((fail+1))
fi

# ---------------------------------------------------------------------------
# Level 3: 出口归属校验 — 流量是否真的走 WARP
# ---------------------------------------------------------------------------
echo
log "[L3] 出口归属校验 (cdn-cgi/trace 的 warp 字段)"
if echo "$trace" | grep -qE '^warp=(on|plus)$'; then
    log "[L3] PASS — 出口确认为 Cloudflare WARP ($(echo "$trace" | grep '^warp='))"
else
    err "[L3] FAIL — 代理通了但出口不是 WARP（warp=$(echo "$trace" | awk -F= '/^warp=/{print $2}')）"
    err "      检查 sing-box 出站配置 / WireGuard 握手: journalctl -u ${BRIDGE_SERVICE} -n 50"
    fail=$((fail+1))
fi

echo
if [ "$fail" -eq 0 ]; then
    log "全部通过：通用 HTTP 代理入口工作正常 (http://${probe_host}:${HTTP_PROXY_PORT}, backend=${BACKEND})"
else
    err "${fail} 个层级检查失败。排障矩阵："
    err "  L1 ✗            → WARP 出口层没起来（按上方 backend 提示排障）"
    err "  L1 ✓ L2 ✗       → sing-box 桥接故障"
    err "  L1 ✓ L2 ✓ L3 ✗  → 代理在工作但出口不是 WARP"
    err "  全部 ✓ 应用仍失败 → 应用侧代理配置问题"
fi
exit "$fail"
