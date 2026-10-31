#!/bin/bash
# 在 Kindle 上注入一次触控点击，坐标由参数给出
#
# ⚠️ 重要：这条"往 /dev/input/event1 写 input_event"的路子在 **zforce2 触摸驱动的机型
#    （如 Kindle Basic 第 7 代 / KT2）上无效** —— write() 会返回成功，但事件进不了输入
#    子系统（另开读端抓不到任何事件），真机上点不动。
#    可行替代：把合成事件喂给 KOReader 的 Input:handleTouchEv（走真实手势管线），
#    见 skill kindle-screen-automation 的 scripts/kr_tap_helper.koplugin + scripts/tap.sh。
#
# 用法: ./tools/kindle_tap.sh <x> <y> [ip]
IP="${3:-192.168.0.99}"
ssh -p 2222 -o StrictHostKeyChecking=no -o ConnectTimeout=8 "root@$IP" \
  "LD_LIBRARY_PATH=/mnt/us/koreader/libs /mnt/us/koreader/luajit /mnt/us/scripts/touch_click.lua $1 $2"
