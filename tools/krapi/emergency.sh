#!/bin/sh
# =============================================================================
#  /mnt/us/emergency.sh —— 开机 root 钩子
#
#  这个文件是越狱（KMC / KindleModding Core）官方注册的开机启动项：
#    /var/local/appreg.db 里有一条 org.kindlemodding.emergency_launcher，
#    command = "/bin/sh /mnt/us/emergency.sh"。
#  每次 Kindle 开机、framework 起来之后，Amazon 的应用框架就会以 root 跑它。
#  文件不存在 = 什么都不做（越狱默认状态）。
#
#  我们用它来：
#    1. 启动 krapi HTTP 服务（含 iptables 放行 + 禁用 KOReader 自动挂起 + keep_awake）
#    2. 兜底：如果 KOReader 没起来，把它拉起来（触控接口需要它）
#
#  删掉这个文件即可完全撤销，不影响越狱本身。
# =============================================================================

exec >/dev/null 2>&1

# 开机后框架还没跑完，先等等，别和 Amazon 的启动流程抢资源
sleep 20

# ---- 1. 启动 krapi（内部会做 iptables / 挂起超时 / keep_awake） ----
sh /mnt/us/krapi/start.sh 8099

# ---- 2. 兜底拉起 KOReader（触控接口靠它执行手势） ----
# 注意：不要重复启动，先看有没有 reader.lua 在跑
if ! pgrep -f reader.lua >/dev/null 2>&1; then
    cd /mnt/us/koreader 2>/dev/null && {
        # 前台模式：带 --kual 只会在后台跑，屏幕上根本不显示 KOReader
        setsid nohup ./koreader.sh >/tmp/koreader_stdout.log 2>&1 &
    }
fi

exit 0
