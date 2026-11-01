#!/bin/bash
# krapi 命令行客户端（Mac 端）
#
#   ./tools/krapi/krapi.sh status
#   ./tools/krapi/krapi.sh shot [输出路径]
#   ./tools/krapi/krapi.sh tap X Y
#   ./tools/krapi/krapi.sh hold X Y [毫秒]
#   ./tools/krapi/krapi.sh swipe X1 Y1 X2 Y2 [毫秒]
#
# 环境变量覆盖: KRAPI_IP / KRAPI_PORT / KRAPI_TOKEN
set -u

IP="${KRAPI_IP:-192.168.0.99}"
PORT="${KRAPI_PORT:-8099}"
TOKEN="${KRAPI_TOKEN:-}"
[ -z "$TOKEN" ] && TOKEN=$(cat /mnt/us/krapi/token 2>/dev/null || true)
# 令牌默认从设备上读（需要 ssh）
if [ -z "$TOKEN" ]; then
    TOKEN=$(ssh -p 2222 -o StrictHostKeyChecking=no -o ConnectTimeout=6 \
            root@"$IP" "cat /mnt/us/krapi/token 2>/dev/null" 2>/dev/null | tr -d '\r\n')
fi

api() {
    local path="$1"; shift
    curl -s -m 20 -H "X-Api-Token: $TOKEN" "http://$IP:$PORT$path" "$@"
}

cmd="${1:-status}"
shift || true

case "$cmd" in
    status)  api /status ;;
    ping)    api /ping ;;
    shot)
        out="${1:-/tmp/krapi_shot.png}"
        curl -s -m 20 -H "X-Api-Token: $TOKEN" -o "$out" \
             -w "已保存 $out（HTTP %{http_code}, %{size_download} 字节）\n" \
             "http://$IP:$PORT/screenshot.png"
        ;;
    tap)     api "/tap?x=$1&y=$2" ;;
    hold)    api "/hold?x=$1&y=$2&ms=${3:-1200}" ;;
    swipe)   api "/swipe?x1=$1&y1=$2&x2=$3&y2=$4&ms=${5:-400}" ;;
    logs)    api "/logs?n=${1:-30}" ;;
    *) echo "用法: $0 {status|ping|shot [路径]|tap X Y|hold X Y [ms]|swipe X1 Y1 X2 Y2 [ms]|logs [n]}"; exit 1 ;;
esac
