#!/bin/sh
# krapi 停止脚本（设备端）：关服务、撤防火墙规则、停 keep_awake
#
# ⚠️ 不用 `pkill -f <模式>`：busybox 的 pkill -f 匹配整条命令行，
#    连"执行它的那个 shell"也会一起杀掉（模式串就在它的 cmdline 里），
#    表现为 SSH 会话凭空断掉。这里一律用 PID 文件杀。
PORT="${1:-8099}"
PIDFILE=/mnt/us/krapi/server.pid

if [ -f "$PIDFILE" ]; then
    PID=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        kill "$PID" 2>/dev/null
        i=0
        while [ $i -lt 10 ] && kill -0 "$PID" 2>/dev/null; do
            sleep 1
            i=$((i + 1))
        done
        kill -9 "$PID" 2>/dev/null
        echo "krapi 已停止 (pid $PID)"
    fi
    rm -f "$PIDFILE"
fi

# keep_awake：模式串 "keep_awake" 不会出现在本脚本的 cmdline 里（只有路径部分会），
# 但保险起见也用 PID 文件的方式处理。
if [ -f /tmp/krapi_keep_awake.pid ]; then
    KPID=$(cat /tmp/krapi_keep_awake.pid 2>/dev/null)
    [ -n "$KPID" ] && kill "$KPID" 2>/dev/null && echo "keep_awake 已停止"
    rm -f /tmp/krapi_keep_awake.pid
fi

# 撤防火墙规则（幂等：不存在时 -D 会报错，忽略即可）
iptables -D INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null && echo "iptables: 已撤销端口 $PORT"

# 恢复 KOReader 的自动挂起（默认 900 秒 = 15 分钟）
SETTINGS=/mnt/us/koreader/settings.reader.lua
if [ -f "$SETTINGS" ]; then
    sed -i 's/\["auto_suspend_timeout_seconds"\] = -1/["auto_suspend_timeout_seconds"] = 900/' "$SETTINGS"
    echo "auto_suspend_timeout_seconds 恢复为 900"
fi

rm -f /tmp/krapi_beat
exit 0
