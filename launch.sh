#!/usr/bin/env bash
# launch.sh — 启动一个隔离的 openclaw RDP 容器
#
# 用法:
#   ./launch.sh <用户名> [选项]
#
# 示例:
#   ./launch.sh alice \
#     --rdp-port 13389 \
#     --gateway-port 18789 \
#     --bridge-port 18790 \
#     --maas-api-key <key> \
#     --rdp-password MyPass123
#
# 不同用户使用不同端口号实现隔离，例如:
#   alice:  --rdp-port 13389 --gateway-port 18789 --bridge-port 18790
#   bob:    --rdp-port 13390 --gateway-port 18889 --bridge-port 18890
#   carol:  --rdp-port 13391 --gateway-port 18989 --bridge-port 18990

set -euo pipefail

IMAGE="${OPENCLAW_RDP_IMAGE:-openclaw-rdp:latest}"

usage() {
    echo "用法: $0 <用户名> [--rdp-port N] [--gateway-port N] [--bridge-port N]"
    echo "                  [--maas-api-key KEY] [--maas-base-url URL]"
    echo "                  [--rdp-password PASS] [--gateway-token TOKEN]"
    echo "                  [--image IMAGE] [--restart POLICY]"
    exit 1
}

if [[ $# -lt 1 ]]; then usage; fi

USERNAME="$1"; shift

# ── 默认值 ────────────────────────────────────────────────────────────────────
RDP_PORT=13389
GATEWAY_PORT=18789
BRIDGE_PORT=18790
API_KEY=""
BASE_URL="https://maas-beta.tatucloud.com"
RDP_PASSWORD="openclaw"
GATEWAY_TOKEN=""
RESTART_POLICY="unless-stopped"

# ── 参数解析 ──────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --rdp-port)        RDP_PORT="$2";        shift 2 ;;
        --gateway-port)    GATEWAY_PORT="$2";    shift 2 ;;
        --bridge-port)     BRIDGE_PORT="$2";     shift 2 ;;
        --maas-api-key)    API_KEY="$2";         shift 2 ;;
        --maas-base-url)   BASE_URL="$2";        shift 2 ;;
        --rdp-password)    RDP_PASSWORD="$2";    shift 2 ;;
        --gateway-token)   GATEWAY_TOKEN="$2";   shift 2 ;;
        --image)           IMAGE="$2";           shift 2 ;;
        --restart)         RESTART_POLICY="$2";  shift 2 ;;
        -h|--help) usage ;;
        *) echo "未知参数: $1"; usage ;;
    esac
done

# 自动生成 gateway token（如未指定）
if [[ -z "$GATEWAY_TOKEN" ]]; then
    GATEWAY_TOKEN="$(openssl rand -hex 32)"
fi

CONTAINER_NAME="openclaw-${USERNAME}"
VOLUME_NAME="openclaw-data-${USERNAME}"
NETWORK_NAME="openclaw-net-${USERNAME}"

# ── 安全检查：RDP 密码强度 ────────────────────────────────────────────────────
if [[ "$RDP_PASSWORD" == "openclaw" ]]; then
    echo "[warn] 使用了默认 RDP 密码 'openclaw'，建议通过 --rdp-password 设置强密码。" >&2
fi

# ── 1. 创建用户独立网络（容器间互相隔离）────────────────────────────────────────
if ! docker network inspect "$NETWORK_NAME" &>/dev/null; then
    echo "[network] 创建隔离网络 ${NETWORK_NAME}..."
    docker network create --driver bridge "$NETWORK_NAME" >/dev/null
else
    echo "[network] 网络 ${NETWORK_NAME} 已存在，跳过。"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  用户:          ${USERNAME}"
echo "  容器名称:      ${CONTAINER_NAME}"
echo "  数据卷:        ${VOLUME_NAME}"
echo "  隔离网络:      ${NETWORK_NAME}"
echo "  RDP 端口:      127.0.0.1:${RDP_PORT}  →  仅本机可达（需 VSCode 端口转发）"
echo "  Gateway 端口:  127.0.0.1:${GATEWAY_PORT}  →  仅本机可达"
echo "  Bridge 端口:   127.0.0.1:${BRIDGE_PORT}   →  仅本机可达"
echo "  RDP 用户名:    node"
echo "  RDP 密码:      ${RDP_PASSWORD}"
echo "  Gateway Token: ${GATEWAY_TOKEN}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 如果已有同名容器，先停止并删除
if docker inspect "$CONTAINER_NAME" &>/dev/null; then
    echo "[launch] 停止旧容器 ${CONTAINER_NAME}..."
    docker rm -f "$CONTAINER_NAME"
fi

# ── 2. 启动容器 ───────────────────────────────────────────────────────────────
# 所有端口均绑定 127.0.0.1，只能通过 VSCode SSH 端口转发从客户端访问，不对外暴露。
docker run -d \
    --name "${CONTAINER_NAME}" \
    --network "${NETWORK_NAME}" \
    --restart "${RESTART_POLICY}" \
    --init \
    -p "127.0.0.1:${RDP_PORT}:3389" \
    -p "127.0.0.1:${GATEWAY_PORT}:18789" \
    -p "127.0.0.1:${BRIDGE_PORT}:18790" \
    -v "${VOLUME_NAME}:/home/node/.openclaw" \
    -e "OPENCLAW_GATEWAY_TOKEN=${GATEWAY_TOKEN}" \
    -e "OPENCLAW_RDP_PASSWORD=${RDP_PASSWORD}" \
    -e "MAAS_API_KEY=${API_KEY}" \
    -e "MAAS_BASE_URL=${BASE_URL}" \
    "${IMAGE}" >/dev/null

echo ""
echo "[launch] 容器 ${CONTAINER_NAME} 已启动。"
echo ""
echo "  远程桌面连接:  在 VSCode PORTS 标签转发 ${RDP_PORT} 端口后，连接 localhost:${RDP_PORT}  (用户名: node  密码: ${RDP_PASSWORD})"
echo "  进入桌面后，打开浏览器访问 http://localhost:${GATEWAY_PORT}"
echo ""
echo "  查看日志:  docker logs -f ${CONTAINER_NAME}"
echo ""
echo "  彻底删除（含网络）:"
echo "    docker rm -f ${CONTAINER_NAME}"
echo "    docker network rm ${NETWORK_NAME}"
