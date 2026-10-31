#!/bin/bash
# 数独插件真机交互验证脚本
#
# 做什么：
#   1) 部署最新 sudoku 插件到设备并重启 KOReader
#   2) 依次注入 6 组手势（tap），每步后截图，验证：选中态 / 键盘变灰 / 填数 /
#      笔记模式 / 撤销 / 提示
#   3) 输出截图目录供人工核对
#
# ⚠️ 触控注入方式：
#   这台机（KT2 / zforce2）的 evdev 节点不接受外部注入，写 /dev/input/event1
#   的事件进不了输入子系统。脚本通过设备上的辅助插件
#   /mnt/us/koreader/plugins/krlauncher.koplugin 把合成事件直接喂给 KOReader 的
#   Input:handleTouchEv，走真实手势管线（详见 skill kindle-screen-automation
#   的 scripts/kr_tap_helper.koplugin，同一套原理）。
#
# 用法: ./tools/verify_sudoku_device.sh [设备IP]
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IP="${1:-192.168.0.99}"
SHOTS="${SHOTS:-/tmp/sud_verify}"
LOG="${LOG:-/tmp/verify_sudoku.log}"

# 坐标（KT2 600x800，与 sudokudialog.lua 的布局常量对应）
#   棋盘 GRID_X0=66 GRID_Y0=54 CELL=52 → 第1行第4格中心 (248, 80)
#   键盘 PAD_X0=16 PAD_BW=57 PAD_GAP=6 PAD_Y0=566 → 数字4 (233,606)、数字7 (422,606)
#   操作行 ACT_Y0=654 高68 → 笔记(227,688) 撤销(373,688) 提示(519,688)
GRID_XY="248 80"
KEY_4_XY="233 606"
KEY_7_XY="422 606"
BTN_NOTES_XY="227 688"
BTN_UNDO_XY="373 688"
BTN_HINT_XY="519 688"

mkdir -p "$SHOTS"
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
ssh_k() { ssh -p 2222 -o StrictHostKeyChecking=no -o ConnectTimeout=8 root@"$IP" "$@"; }
tap()  { ssh_k "echo 'tap $1 $2' > /tmp/kr_trigger" >/dev/null 2>&1; sleep 2.5; }
shot() { "$REPO/tools/kindle_screenshot.sh" "$SHOTS/$1.png" >/dev/null 2>&1; log "截图: $SHOTS/$1.png"; }

log "=== 部署插件并重启 KOReader ==="
scp -P 2222 -o StrictHostKeyChecking=no -q "$REPO/plugins/sudoku.koplugin/"*.lua \
    root@"$IP":/mnt/us/koreader/plugins/sudoku.koplugin/ || log "scp 失败（设备不可达？）"
ssh_k "sh /tmp/restart_kr.sh" >/dev/null 2>&1
sleep 50
ssh_k "tail -3 /tmp/kr_launcher.log"

log "=== 确保数独已打开 ==="
ssh_k "echo 'open' > /tmp/kr_trigger" >/dev/null 2>&1
sleep 4
shot 00_baseline

log "=== 步骤1: 选中第1行第4格（应出现粗框 + 键盘变灰） ==="
tap $GRID_XY
shot 01_select

log "=== 步骤2: 填入数字 4（应出现数字 + 下方短横线） ==="
tap $KEY_4_XY
shot 02_place4

log "=== 步骤3: 点『笔记』（按钮应变按下态） ==="
tap $BTN_NOTES_XY
shot 03_notes_on

log "=== 步骤4: 写候选数 7（应出现小号浅灰数字） ==="
tap $KEY_7_XY
shot 04_note7

log "=== 步骤5: 点『撤销』（候选数应消失） ==="
tap $BTN_UNDO_XY
shot 05_undo

log "=== 步骤6: 点『提示』（应自动填一个正确的数） ==="
tap $BTN_HINT_XY
shot 06_hint

log "=== 全部完成，截图在 $SHOTS ==="
ls -l "$SHOTS"
