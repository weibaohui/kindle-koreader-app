#!/usr/bin/env python3
"""打砖块真机自动测试：用游戏自己的"落点标记"驱动挡板接球，验证完整关卡循环。

流程:
  1. 若处于待发球状态 -> 点击砖阵区发球
  2. 截屏 -> 在标记带里定位"落点十字"的黑心 -> 拖拽挡板到该 x
  3. 循环直到过关 / 生命耗尽

用法: python3 tools/breakout_autoplay.py [轮数]
"""
import subprocess
import sys
import time

from PIL import Image

SKILL = "/Users/weibh/.agents/skills/kindle-screen-automation/scripts"
SHOT = "/Users/weibh/Desktop/kindle-koreader-app/tools/kindle_screenshot.sh"
IP = "192.168.0.99"

# 屏幕几何 (与插件一致)
MARKER_Y0, MARKER_Y1 = 664, 682   # 落点十字所在带
PADDLE_Y0, PADDLE_Y1 = 688, 701   # 挡板所在带
PADDLE_TOP = 690


def click(x, y, verbose=False):
    r = subprocess.run(["/bin/bash", f"{SKILL}/click.sh", str(x), str(y)],
                       capture_output=True, text=True)
    if verbose or r.returncode != 0:
        print(f"  click({x},{y}) rc={r.returncode} out={r.stdout.strip()!r} err={r.stderr.strip()!r}")
    return r.returncode


def drag(x1, y1, x2, y2, steps=12, delay=35, verbose=False):
    r = subprocess.run(
        ["ssh", "-p", "2222", f"root@{IP}",
         f"LD_LIBRARY_PATH=/mnt/us/koreader/libs /mnt/us/koreader/luajit "
         f"/mnt/us/scripts/touch_drag.lua {x1} {y1} {x2} {y2} {steps} {delay}"],
        capture_output=True, text=True)
    if verbose or r.returncode != 0:
        print(f"  drag({x1},{y1}->{x2},{y2}) rc={r.returncode} out={r.stdout.strip()!r} err={r.stderr.strip()!r}")
    return r.returncode


def shot(path):
    subprocess.run(["/bin/bash", SHOT, path], capture_output=True)


def dark_columns(path, y0, y1, thresh=95):
    im = Image.open(path).convert("L")
    px = im.load()
    w = im.size[0]
    cols = []
    for x in range(12, w - 12):
        for y in range(y0, y1):
            if px[x, y] < thresh:
                cols.append(x)
                break
    return cols


def clusters(cols, gap=6):
    out = []
    for c in cols:
        if out and c - out[-1][1] <= gap:
            out[-1][1] = c
        else:
            out.append([c, c])
    return out


def analyze(path):
    """返回 (落点标记 x 或 None, 挡板中心 x 或 None)

    标记的十字臂是灰色 (GRAY_5=85)，而球和挡板都是纯黑 (0)，
    因此"灰度像素"是落点标记的唯一指纹。
    """
    im = Image.open(path).convert("L")
    px = im.load()
    w = im.size[0]

    marker = None
    # 标记臂 = GRAY_5 (85)；发射射线 = GRAY_7 (119)，按值域区分
    gcols = [x for x in range(12, w - 12)
             if any(70 <= px[x, y] <= 100 for y in range(MARKER_Y0, MARKER_Y1))]
    if gcols:
        marker = (min(gcols) + max(gcols)) // 2

    paddle = None
    dcols = [x for x in range(12, w - 12)
             if any(px[x, y] < 60 for y in range(PADDLE_Y0, PADDLE_Y1))]
    if dcols:
        paddle = (min(dcols) + max(dcols)) // 2
    return marker, paddle


def main():
    rounds = int(sys.argv[1]) if len(sys.argv) > 1 else 30
    path = "/tmp/autoplay.png"
    hits = 0
    launches = 0
    for i in range(rounds):
        shot(path)
        marker, paddle = analyze(path)
        if marker is not None:
            # 飞行中：把挡板挪到落点标记处
            target = max(58, min(542, marker))
            if paddle is None:
                paddle = 300
            if abs(target - paddle) > 6:
                drag(paddle, PADDLE_TOP, target, PADDLE_TOP)
                hits += 1
            time.sleep(0.4)
        else:
            # 无标记 -> 待发球 / 已结束，点砖阵区发球
            click(300, 150, verbose=True)
            launches += 1
            time.sleep(0.5)
    print(f"完成 {rounds} 轮：发球 {launches} 次，挡板移动 {hits} 次")


if __name__ == "__main__":
    main()
