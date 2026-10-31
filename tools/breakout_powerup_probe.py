#!/usr/bin/env python3
"""打砖块「掉落道具」真机链路探测。

思路:
  关卡 1 的最后一行是 "11*1111*11" —— 第 3 列和第 8 列是道具砖(*)。
  道具砖被击碎时, 道具在砖的 x 位置正上方生成并垂直直落(100px/s)。
  所以只要把挡板停在道具砖正下方, 道具一定会落到挡板上被接取。

本脚本:
  1. 轻触底部把挡板移到目标列(x=TARGET_X)
  2. 反复发球(点砖阵区), 让球去撞那一列的道具砖
  3. 每一帧截图存档, 并自动检测:
       - 道具徽章在场内出现 (28px 宽黑块)
       - 道具落点空心方框 (GRAY_7 宽横线)
       - 底栏效果条出现道具图标 (24x24 实心块 @ y=756)
       - 挡板宽度变化 (加长/变短)
       - 多球 (场内多个小球)

用法: python3 tools/breakout_powerup_probe.py [轮数] [目标列(1-10)]
"""
import os
import subprocess
import sys
import time

from PIL import Image

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHOT = os.path.join(REPO, "tools", "kindle_screenshot.sh")
IP = "192.168.0.99"
OUTDIR = "/tmp/bo_frames"

# ---- 插件内几何常量(与 breakoutdialog.lua 保持一致) ----
PADDLE_Y0, PADDLE_Y1 = 664, 677      # 挡板所在行带
MARK_Y0, MARK_Y1 = 636, 660          # 落点标记带
BAR_Y0 = 708                         # 底栏顶
EFFECT_Y0, EFFECT_Y1 = 756, 780      # 效果条图标行带
GRID_BOTTOM = 243                    # 砖阵底部
FIELD_BOTTOM = 660                   # 场地底部

# 道具砖所在列的 x (第 c 列):  GRID_X=26, 每列步进 55, 砖宽 52
def col_x(c):
    return 26 + (c - 1) * 55 + 26


def tap(x, y):
    subprocess.run(
        ["ssh", "-p", "2222", "-o", "StrictHostKeyChecking=no",
         f"root@{IP}",
         f"LD_LIBRARY_PATH=/mnt/us/koreader/libs /mnt/us/koreader/luajit "
         f"/mnt/us/scripts/touch_click.lua {x} {y}"],
        capture_output=True)


def shot(path):
    subprocess.run(["/bin/bash", SHOT, path], capture_output=True)


def runs_of_black(px, y0, y1, x_from=12, x_to=588):
    """返回每一行中连续纯黑段的 (起点, 宽度) 列表。"""
    out = []
    for y in range(y0, y1):
        x = x_from
        while x < x_to:
            if px[x, y] < 60:
                s = x
                while x < x_to and px[x, y] < 60:
                    x += 1
                out.append((s, x - s, y))
            else:
                x += 1
    return out


def analyze(path):
    im = Image.open(path).convert("L")
    px = im.load()

    info = {}

    # 挡板: 底栏上方那条最长黑横线
    br = [r for r in runs_of_black(px, PADDLE_Y0, PADDLE_Y1) if r[1] >= 20]
    if br:
        widest = max(br, key=lambda r: r[1])
        info["paddle_x"] = widest[0] + widest[1] // 2
        info["paddle_w"] = widest[1]

    # 待发球判定: 挡板上方有一串 GRAY_7 小点(发射射线)
    ray = 0
    for y in range(575, 634):
        for x in range(12, 588):
            if 108 <= px[x, y] <= 130:
                ray += 1
    info["ready"] = ray > 40

    # 道具徽章: 场地内出现宽度 24~32 的纯黑块(砖宽 52, 排除)
    badge = []
    for s, w, y in runs_of_black(px, GRID_BOTTOM + 8, FIELD_BOTTOM):
        if 24 <= w <= 32:
            badge.append((s + w // 2, y))
    info["badge"] = badge

    # 道具落点方框: 标记带里的 GRAY_7 长横线(球十字是 GRAY_5=85)
    sq = []
    for y in range(MARK_Y0, MARK_Y1):
        x = 12
        while x < 588:
            if 108 <= px[x, y] <= 130:
                s = x
                while x < 588 and 108 <= px[x, y] <= 130:
                    x += 1
                if x - s >= 15:
                    sq.append((s + (x - s) // 2, y))
            else:
                x += 1
    info["item_marker"] = sq

    # 球的落点十字: GRAY_5(85) 的十字臂, 取横向跨度中点
    gx = [x for x in range(12, 588)
          if any(78 <= px[x, y] <= 95 for y in range(MARK_Y0, MARK_Y1))]
    info["ball_marker"] = (min(gx) + max(gx)) // 2 if gx else None

    # 底栏效果条: x=12+k*54 处是否有 24x24 实心图标
    slots = []
    for k in range(5):
        x0 = 12 + k * 54
        dark = sum(1 for y in range(EFFECT_Y0, EFFECT_Y1)
                   for x in range(x0, x0 + 24) if px[x, y] < 60)
        if dark > 24 * 24 * 0.8:
            slots.append(k)
    info["effect_slots"] = slots

    # 多球: 场地内半径 7 的黑圆数量(粗略: 24x24 邻域内黑像素>300)
    balls = 0
    for y in range(GRID_BOTTOM, FIELD_BOTTOM - 16, 8):
        for x in range(16, 584, 8):
            dark = sum(1 for yy in range(y, y + 14) for xx in range(x, x + 14)
                       if px[xx, yy] < 60)
            if dark > 170:
                balls += 1
                break
    info["ball_blobs"] = balls

    return info


def main():
    rounds = int(sys.argv[1]) if len(sys.argv) > 1 else 24
    col = int(sys.argv[2]) if len(sys.argv) > 2 else 3
    target = col_x(col)

    os.makedirs(OUTDIR, exist_ok=True)
    for f in os.listdir(OUTDIR):
        os.remove(os.path.join(OUTDIR, f))

    print(f"目标道具砖列 = 第 {col} 列, x = {target}")

    # 把挡板移到目标列正下方(轻触底部 -> 绝对跳转)
    tap(target, 600)
    time.sleep(1.2)

    interesting = []
    for i in range(rounds):
        path = os.path.join(OUTDIR, f"f{i:03d}.png")
        shot(path)
        try:
            info = analyze(path)
        except Exception as e:  # noqa: BLE001
            print(f"[{i}] 分析失败: {e}")
            continue

        tags = []
        if info.get("badge"):
            tags.append(f"道具徽章@{info['badge'][:3]}")
        if info.get("item_marker"):
            tags.append(f"落点方框@{info['item_marker'][:3]}")
        if info.get("effect_slots"):
            tags.append(f"效果条槽{info['effect_slots']}")
        if info.get("paddle_w") and info["paddle_w"] not in (96,):
            tags.append(f"挡板宽{info['paddle_w']}")
        if info.get("ball_blobs", 0) >= 2:
            tags.append(f"多球~{info['ball_blobs']}")

        if tags:
            interesting.append((i, path, "; ".join(tags)))
            print(f"[{i}] {' | '.join(tags)}")

        # 走位策略：
        #   有道具落点方框 -> 先去接道具
        #   否则有球落点十字 -> 去接球(让球活着，才能打到更多砖)
        #   都没有(待发球) -> 回到目标列，等球从道具砖那一列弹起
        if info.get("item_marker"):
            goal = info["item_marker"][0][0]
        elif info.get("ball_marker") is not None:
            goal = info["ball_marker"]
        else:
            goal = target

        px_ = info.get("paddle_x")
        if px_ is not None and abs(goal - px_) > 8:
            tap(goal, 600)
            time.sleep(1.0)

        # 待发球 -> 发球(点在砖阵区, x 对齐目标列让出射角接近垂直)
        if info.get("ready"):
            time.sleep(0.6)
            tap(target, 150)
            time.sleep(1.0)

    print("\n=== 关键帧 ===")
    for i, p, t in interesting:
        print(f"  {p}  {t}")


if __name__ == "__main__":
    main()
