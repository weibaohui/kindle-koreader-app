#!/bin/sh
FBINK=/mnt/us/libkh/bin/fbink
[ -x "$FBINK" ] || FBINK=/var/local/kmc/bin/fbink

$FBINK -c
$FBINK -y 4 -m -S 4 "===== 配置 GLM API Key ====="
$FBINK -y 7 -m -S 2 "请通过 USB 或 SSH 把 API Key 写入："
$FBINK -y 9 -m -S 3 "/mnt/us/extensions/glm_usage/api_key.txt"
$FBINK -y 12 -m -S 2 "或者在 Mac 终端运行:"
$FBINK -y 14 -m -S 2 "ssh -p 2222 root@192.168.0.99 'echo 你的KEY > /mnt/us/extensions/glm_usage/api_key.txt'"
