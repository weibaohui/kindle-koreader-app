#!/bin/sh
FBINK=/mnt/us/libkh/bin/fbink
[ -x "$FBINK" ] || FBINK=/var/local/kmc/bin/fbink
PYTHON=/usr/bin/python3
[ -x "$PYTHON" ] || PYTHON=/usr/bin/python

HERE=$(dirname "$0")

# 清屏并提示正在查询
$FBINK -c -pm -S 3 "正在联网查询 GLM 额度..."

RES=$($PYTHON "$HERE/glm_query.py" 2>&1)

if echo "$RES" | grep -q "^OK|"; then
    LEVEL=$(echo "$RES" | cut -d'|' -f2)
    W5_PCT=$(echo "$RES" | cut -d'|' -f3)
    W5_REM=$(echo "$RES" | cut -d'|' -f4)
    W5_RST=$(echo "$RES" | cut -d'|' -f5)
    WK_PCT=$(echo "$RES" | cut -d'|' -f6)
    WK_REM=$(echo "$RES" | cut -d'|' -f7)
    WK_RST=$(echo "$RES" | cut -d'|' -f8)
    R_5H=$(echo "$RES" | cut -d'|' -f9)
    R_WK=$(echo "$RES" | cut -d'|' -f10)

    # 优美的多行卡片式排版输出到墨水屏
    $FBINK -c
    $FBINK -y 2 -m -S 4 "===== 智谱 GLM 用量看板 ====="
    $FBINK -y 5 -m -S 3 "套餐级别: [ $LEVEL ]"
    $FBINK -y 8 -m -S 3 "【5小时窗口】已用: ${W5_PCT}% (剩余: ${W5_REM})"
    $FBINK -y 10 -m -S 2 "重置时间: ${W5_RST}  | 剩余重置券: ${R_5H}次"
    $FBINK -y 13 -m -S 3 "【本周窗口】  已用: ${WK_PCT}% (剩余: ${WK_REM})"
    $FBINK -y 15 -m -S 2 "重置时间: ${WK_RST}  | 剩余重置券: ${R_WK}次"
    $FBINK -y 19 -m -S 2 "更新于: $(date '+%Y-%m-%d %H:%M:%S')"
else
    $FBINK -c
    $FBINK -y 5 -m -S 4 "GLM 查询失败"
    $FBINK -y 8 -m -S 2 "$RES"
    $FBINK -y 12 -m -S 2 "请检查网络或 /mnt/us/extensions/glm_usage/api_key.txt"
fi
