#!/bin/bash
# 设备现场清理：把临时启动器插件挪走（可逆）、装上 skill 的触控助手、实测截图清理脚本
#
# 为什么需要：
#   验证期间装在 /mnt/us/koreader/plugins/krlauncher.koplugin 的临时启动器，
#   会在每次 KOReader 启动时自动弹出数独，用完必须撤掉。
#   撤掉后换上 skill kindle-screen-automation 自带的 kr_tap_helper 插件，
#   以后注入走 KOReader 真实手势管线，且不会自动弹任何界面。
#
# 用法: ./tools/cleanup_device.sh [设备IP]
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IP="${1:-192.168.0.99}"
SKILL="${SKILL:-$HOME/.agents/skills/kindle-screen-automation}"

ssh_k() { ssh -p 2222 -o StrictHostKeyChecking=no -o ConnectTimeout=8 root@"$IP" "$@"; }

echo "=== 1) 移走临时启动器插件（挪到 plugins.disabled，不删，可随时挪回） ==="
ssh_k "mkdir -p /mnt/us/koreader/plugins.disabled && \
        mv /mnt/us/koreader/plugins/krlauncher.koplugin /mnt/us/koreader/plugins.disabled/ 2>/dev/null; \
        ls /mnt/us/koreader/plugins/ | grep -c krlauncher; ls /mnt/us/koreader/plugins.disabled/"

echo "=== 2) 安装 skill 的 kr_tap_helper 插件 ==="
ssh_k "mkdir -p /mnt/us/koreader/plugins/kr_tap_helper.koplugin"
scp -P 2222 -o StrictHostKeyChecking=no -q \
    "$SKILL/scripts/kr_tap_helper.koplugin/main.lua" \
    "$SKILL/scripts/kr_tap_helper.koplugin/_meta.lua" \
    root@"$IP":/mnt/us/koreader/plugins/kr_tap_helper.koplugin/
ssh_k "ls -l /mnt/us/koreader/plugins/kr_tap_helper.koplugin/"

echo "=== 3) 重启 KOReader 并确认助手心跳 ==="
ssh_k "sh /tmp/restart_kr.sh" >/dev/null 2>&1
sleep 55
echo "心跳: $(ssh_k 'cat /tmp/kr_tap_beat 2>/dev/null || echo NONE')"
echo "日志: $(ssh_k 'tail -2 /tmp/kr_tap.log 2>/dev/null')"

echo "=== 4) 实测 skill 的截图清理脚本 ==="
"$SKILL/scripts/cleanup_screenshots.sh" --ip "$IP"
echo "设备端复查: $(ssh_k 'ls /mnt/us/screenshot* 2>/dev/null || echo 无残留')"
