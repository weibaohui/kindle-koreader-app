#!/bin/bash
# 部署打砖块插件到 Kindle 并做真机回归验证
#
# 用法: ./tools/deploy_breakout.sh [KINDLE_IP]
# 依赖: ssh/scp 可免密 root@IP -p 2222

set -u

IP="${1:-192.168.0.99}"
PORT=2222
SSH="ssh -p $PORT -o StrictHostKeyChecking=no -o ConnectTimeout=6 root@$IP"
SCP="scp -P $PORT -o StrictHostKeyChecking=no -o ConnectTimeout=6"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-/tmp/breakout_deploy}"

log() { printf '\n=== %s ===\n' "$*"; }

log "1/7 探活 $IP:$PORT"
if ! nc -z -G 3 "$IP" "$PORT" 2>/dev/null; then
    echo "设备不可达，退出。"; exit 1
fi
echo "SSH 可达"

log "2/7 清理设备上的临时调试文件"
$SSH 'rm -f /mnt/us/breakout_dbg.log /mnt/us/documents/reader_probe.txt /mnt/us/screenshot*.png; echo cleaned' || \
    echo "警告: 清理失败（可忽略）"

log "3/7 上传插件与触控脚本"
# 判断是否首次安装（决定要不要重启 KOReader）
if $SSH 'test -d /mnt/us/koreader/plugins/breakout.koplugin' 2>/dev/null; then
    NEED_RESTART=0
    echo "插件已存在 -> 软部署（不重启）"
else
    NEED_RESTART=1
    echo "首次安装 -> 需要重启 KOReader 注册菜单"
fi
$SCP -r "$REPO/plugins/breakout.koplugin" root@"$IP":/mnt/us/koreader/plugins/ || exit 1
mkdir -p /tmp/breakout_scripts
cp "$REPO/tools/touch_drag.lua" "$REPO/tools/touch_hold.lua" "$REPO/tools/touch_doubleclick.lua" /tmp/breakout_scripts/
$SCP /tmp/breakout_scripts/*.lua root@"$IP":/mnt/us/scripts/ || echo "警告: 触控脚本上传失败"
echo "上传完成"

log "4/7 校验设备上的插件文件"
$SSH 'ls -l /mnt/us/koreader/plugins/breakout.koplugin/; echo "dbglog 残留数: $(grep -c dbglog /mnt/us/koreader/plugins/breakout.koplugin/breakoutdialog.lua)"'

# main.lua 里 `package.loaded["breakoutdialog"] = nil`，
# 每次从菜单启动游戏都会重新读盘加载 -> 覆盖文件即可生效，无需重启 KOReader。
# 只有"插件目录此前不存在"（首次安装）才需要重启。
if [ "$NEED_RESTART" = "1" ]; then
    log "5/7 重启 KOReader (首次安装，需要注册菜单)"
    $SSH 'killall -TERM reader.lua 2>/dev/null; sleep 4; cd /mnt/us/koreader && setsid nohup ./koreader.sh >/tmp/ko_start.log 2>&1 </dev/null & sleep 1; echo "restart issued"' || \
        echo "警告: 重启指令异常"
    echo "等待 KOReader 起来 (25s)..."
    sleep 25
    $SSH 'pidof reader.lua || echo "NO reader.lua"' || echo "设备尚未恢复 SSH"
else
    log "5/7 跳过重启 (插件已注册，菜单项会重新读盘加载新代码)"
fi

log "6/7 打开游戏并截图"
mkdir -p "$OUT"
# 若游戏对话框已开着，先点"退出"关掉，再重新打开以加载新代码
# 文件管理器顶部唤出菜单 -> 扳手(工具) -> 砖石战场
for spec in "180 60" "180 28" "137 127"; do
    set -- $spec
    $SSH "LD_LIBRARY_PATH=/mnt/us/koreader/libs /mnt/us/koreader/luajit /mnt/us/scripts/touch_click.lua $1 $2" >/dev/null 2>&1
    sleep 2
done
sleep 3
"$REPO/tools/kindle_screenshot.sh" "$OUT/after_deploy.png" || echo "截图失败"

log "7/7 完成"
echo "截图: $OUT/after_deploy.png"
echo "请人工确认画面后，再执行过关流程回归（见 README 或对话记录）"
