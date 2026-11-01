#!/bin/sh
# krapi 启动脚本（设备端）
#
# 做四件事：
#   1. 放行 API 端口 —— Kindle 的 iptables INPUT 策略是 DROP，不加规则连不上
#      （这是越狱放行 SSH 2222 用的同一套手法）
#   2. 改 KOReader 的 auto_suspend_timeout_seconds = -1（禁用自动挂起）
#      默认 900 秒（15 分钟）→ 挂起时 WiFi 射频跟着断 → 设备从网络上消失
#   3. 起 keep_awake：每 10 秒给 powerd 喂一个假用户事件，
#      骗过 Kindle 自己的休眠计时器（否则它照样会进深度睡眠把 WiFi 关掉）
#   4. 后台常驻启动 HTTP 服务
#
# 用法: sh /mnt/us/krapi/start.sh [端口]
#      KEEP_AWAKE=0 sh ...   # 不要 keep_awake（屏幕会按 Kindle 原生超时熄灭）

PORT="${1:-8099}"
KRAPI_DIR=/mnt/us/krapi
PIDFILE="$KRAPI_DIR/server.pid"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ---------- 1. 防火墙 ----------
if ! iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null; then
    iptables -I INPUT 1 -p tcp --dport "$PORT" -j ACCEPT && log "iptables: 放行端口 $PORT"
else
    log "iptables: 端口 $PORT 已放行"
fi

# ---------- 2. 禁用 KOReader 自动挂起 ----------
# 必须在 KOReader 启动前改：autosuspend 插件在 init 时读这个值；
# 之后 KOReader 任何一次 flush 都会把内存里的值写回文件，所以改完是自洽的。
SETTINGS=/mnt/us/koreader/settings.reader.lua
if [ -f "$SETTINGS" ]; then
    if grep -q 'auto_suspend_timeout_seconds"\] = -1' "$SETTINGS" 2>/dev/null; then
        log "auto_suspend_timeout_seconds 已是 -1"
    else
        sed -i 's/\["auto_suspend_timeout_seconds"\] = [-0-9]*/["auto_suspend_timeout_seconds"] = -1/' "$SETTINGS" \
            && log "auto_suspend_timeout_seconds 设为 -1（禁用自动挂起）"
    fi
    grep -q 'auto_standby_timeout_seconds"\] = -1' "$SETTINGS" 2>/dev/null \
        || sed -i 's/\["auto_standby_timeout_seconds"\] = [-0-9]*/["auto_standby_timeout_seconds"] = -1/' "$SETTINGS"
fi

# ---------- 3. keep_awake ----------
# 防止 Kindle 原生电源管理把设备拖进深度睡眠（那会直接关掉 WiFi）
#
# ⚠️ 判活不能靠 `pgrep -f keep_awake`：模式串会出现在执行它的 shell 的命令行里，
#    pgrep 会把自己也算进去。这里直接扫 /proc 读 cmdline，且要求进程命令行
#    **以** "/bin/sh /etc/rc.d/keep_awake " 开头（排除扫描者自己）。
keep_awake_pids() {
    for p in /proc/[0-9]*; do
        c=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null) || continue
        case "$c" in
            "/bin/sh /etc/rc.d/keep_awake "*) echo "$(basename "$p")" ;;
        esac
    done
}

if [ "${KEEP_AWAKE:-1}" = "1" ] && [ -x /etc/rc.d/keep_awake ]; then
    EXISTING=$(keep_awake_pids)
    if [ -n "$EXISTING" ]; then
        # 有重复实例就只留一个（重复发假输入事件没意义，还白占内存）
        FIRST=$(echo "$EXISTING" | head -n 1)
        for pid in $EXISTING; do
            [ "$pid" = "$FIRST" ] || kill "$pid" 2>/dev/null
        done
        echo "$FIRST" > /tmp/krapi_keep_awake.pid
        log "keep_awake 已在运行 (pid $FIRST)"
    else
        setsid nohup /etc/rc.d/keep_awake 10 >/dev/null 2>&1 &
        sleep 1
        FIRST=$(keep_awake_pids | head -n 1)
        echo "$FIRST" > /tmp/krapi_keep_awake.pid
        log "keep_awake 已启动 (pid ${FIRST:-?})"
    fi
fi

# ---------- 4. 启动 HTTP 服务 ----------
# 停旧进程：**只用 PID 文件杀**，不要用 `pkill -f <模式>`。
#
# ⚠️ 实测踩过的大坑：busybox 的 `pkill -f` 会拿**整条命令行**去匹配，
#    而"执行 pkill 的那个 shell"的命令行里往往就含这个模式本身
#    （例如通过 `ssh host "pkill -f 'krapi/server.lua'"` 下发时，
#     远端 `sh -c` 的 cmdline 里就带着 "krapi/server.lua"）
#    → pkill 把自己和执行它的 shell 一起杀掉，
#       表现为：SSH 会话毫无征兆地断掉 / 脚本执行到一半凭空消失。
#    PID 文件没有这个问题。
if [ -f "$PIDFILE" ]; then
    OLD=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null; then
        kill "$OLD" 2>/dev/null
        log "已停止旧的 krapi 进程 (pid $OLD)"
        i=0
        while [ $i -lt 15 ] && kill -0 "$OLD" 2>/dev/null; do
            sleep 1
            i=$((i + 1))
        done
        kill -9 "$OLD" 2>/dev/null
    fi
    rm -f "$PIDFILE"
fi

# 等 LISTEN 套接字真正消失。
# 注意：busybox 的 grep 不支持 [[:space:]] 字符类，用普通空格匹配 netstat 的列分隔。
i=0
while [ $i -lt 15 ]; do
    netstat -tln 2>/dev/null | grep -q ":$PORT " || break
    sleep 1
    i=$((i + 1))
done

cd /mnt/us/koreader || exit 1
LD_LIBRARY_PATH=/mnt/us/koreader/libs \
    setsid nohup ./luajit "$KRAPI_DIR/server.lua" --port "$PORT" \
    >>"$KRAPI_DIR/stdout.log" 2>&1 &
echo $! > "$PIDFILE"

# 等端口真的进入 LISTEN 再返回。
# 服务自己还会做 bind 重试（10 次 × 3 秒），加上前面 kill 旧实例的等待，
# 整体可能要十几秒 —— 这里必须等到能连，否则调用方会误以为启动失败。
i=0
while [ $i -lt 60 ]; do
    netstat -tln 2>/dev/null | grep -q ":$PORT " && break
    sleep 1
    i=$((i + 1))
done

if netstat -tln 2>/dev/null | grep -q ":$PORT "; then
    log "krapi 已启动，监听 0.0.0.0:$PORT (pid $(cat "$PIDFILE" 2>/dev/null))"
else
    log "krapi 启动失败"
    # 打印带时间戳的 server.log（stdout.log 是累加的，里面混着历史旧行，容易误读）
    tail -n 10 "$KRAPI_DIR/server.log" 2>/dev/null
    exit 1
fi
