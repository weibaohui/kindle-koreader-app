#!/bin/bash
# Kindle 自动无残留截图工具
# 截取 Kindle 当前屏幕，并自动彻底清理 Kindle 根目录 (/mnt/us/) 及临时目录中的截图文件

set -e

LOCAL_OUT="${1:-/tmp/kindle_test_shot.png}"
KINDLE_IP="${KINDLE_IP:-192.168.0.99}"
KINDLE_PORT="${KINDLE_PORT:-2222}"

# 1. 触发真机截图，自动转存至 /tmp，同时立即清理 /mnt/us/ 根目录
ssh -p "$KINDLE_PORT" "root@$KINDLE_IP" "/mnt/us/scripts/take_screenshot.sh /tmp/kindle_shot.png" >/dev/null 2>&1

# 2. 从临时目录下载到本地
scp -P "$KINDLE_PORT" "root@$KINDLE_IP:/tmp/kindle_shot.png" "$LOCAL_OUT" >/dev/null 2>&1

# 3. 彻底清除 Kindle 端临时文件及任何残留
ssh -p "$KINDLE_PORT" "root@$KINDLE_IP" "rm -f /tmp/kindle_shot.png /tmp/current_screenshot.png /mnt/us/screenshot_*.png" >/dev/null 2>&1

echo "截图已成功保存至: $LOCAL_OUT (Kindle 端零残留，已全部自动清理)"
