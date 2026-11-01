#!/bin/bash
# krapi 安装脚本（Mac 端）
#
# 把 HTTP 控制服务装到 Kindle 上，并挂上开机自启。
#
#   ./tools/krapi/install.sh [设备IP] [端口]
#
# 装完：
#   • 设备上多了一个常驻 HTTP 服务（默认 8099）
#   • /mnt/us/emergency.sh 被创建 → 每次开机自动拉起（含防火墙规则与禁用自动挂起）
#   • 令牌写在 /mnt/us/krapi/token，调用方要带 X-Api-Token 头
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$REPO/tools/krapi"
IP="${1:-192.168.0.99}"
PORT="${2:-8099}"
REMOTE_DIR=/mnt/us/krapi

ssh_k() { ssh -p 2222 -o StrictHostKeyChecking=no -o ConnectTimeout=8 root@"$IP" "$@"; }
scp_k() { scp -P 2222 -o StrictHostKeyChecking=no -q "$@"; }

echo "=== 1) 上传服务文件到 $REMOTE_DIR ==="
ssh_k "mkdir -p $REMOTE_DIR"
scp_k "$HERE/server.lua" "$HERE/start.sh" "$HERE/stop.sh" root@"$IP":"$REMOTE_DIR"/
scp_k "$HERE/emergency.sh" root@"$IP":/mnt/us/emergency.sh
ssh_k "chmod +x $REMOTE_DIR/*.sh /mnt/us/emergency.sh"
echo "  上传完成"

echo "=== 2) 生成访问令牌（已有则沿用） ==="
TOKEN=$(ssh_k "cat $REMOTE_DIR/token 2>/dev/null" | tr -d '\r\n')
if [ -z "$TOKEN" ]; then
    TOKEN=$(openssl rand -hex 16)
    ssh_k "printf '%s' '$TOKEN' > $REMOTE_DIR/token"
    echo "  新令牌: $TOKEN"
else
    echo "  沿用已有令牌: $TOKEN"
fi

echo "=== 3) 启动服务 ==="
ssh_k "sh $REMOTE_DIR/start.sh $PORT"

echo "=== 4) 验证接口 ==="
sleep 1
echo "--- /ping ---"
curl -s -m 8 -H "X-Api-Token: $TOKEN" "http://$IP:$PORT/ping"; echo
echo "--- /status ---"
curl -s -m 8 -H "X-Api-Token: $TOKEN" "http://$IP:$PORT/status"; echo
echo "--- /screenshot.png ---"
curl -s -m 15 -H "X-Api-Token: $TOKEN" -o /tmp/krapi_shot.png -w "  HTTP %{http_code}, %{size_download} 字节\n" \
    "http://$IP:$PORT/screenshot.png"

echo
echo "=== 完成 ==="
cat <<EOF
调用示例：
  curl -H "X-Api-Token: $TOKEN" http://$IP:$PORT/status
  curl -H "X-Api-Token: $TOKEN" -X POST -d '{"x":248,"y":80}' http://$IP:$PORT/tap
  curl -H "X-Api-Token: $TOKEN" http://$IP:$PORT/screenshot.png -o /tmp/s.png

卸载：ssh -p 2222 root@$IP 'sh $REMOTE_DIR/stop.sh $PORT; rm -f /mnt/us/emergency.sh'
EOF
