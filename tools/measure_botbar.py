#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""底栏稳定性测量：连拍 N 帧，统计底栏墨点数量与帧间差异。

背景：墨水屏上 KOReader 会把"相交或共享边界"的刷新矩形合并成一次局部刷新，
一旦运动脏区伸进底栏，底栏就会被卷进大区域刷新，e-ink 的部分刷新波形会把
实心生命圆点刷成空心、把底栏文字吃掉 —— 表现为底栏闪烁/残缺。

用法:
    python3 tools/measure_botbar.py [帧数] [输出目录]
    python3 tools/measure_botbar.py 10 /tmp/bar10

输出: 每帧的底栏墨点数、两两帧差异像素数，以及是否全部一致。
"""
import os
import shutil
import subprocess
import sys
import time

from PIL import Image

IP = os.environ.get("KINDLE_IP", "192.168.0.99")
PORT = os.environ.get("KINDLE_PORT", "2222")
REMOTE_PNG = "/tmp/kindle_shot.png"

# 底栏区域：y 从 708 到 800（与插件的 BOTBAR_H=92 对齐）
BAR_TOP = 708
BAR_BOTTOM = 800


def ssh(cmd, timeout=25):
    return subprocess.run(
        ["ssh", "-p", PORT, "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10",
         f"root@{IP}", cmd],
        capture_output=True, text=True, timeout=timeout,
    )


def capture(local_path):
    """触发真机截图并下载，失败重试 3 次；设备端零残留。"""
    for attempt in range(3):
        r = ssh(f"/mnt/us/scripts/take_screenshot.sh {REMOTE_PNG}")
        if r.returncode == 0:
            s = subprocess.run(
                ["scp", "-P", PORT, "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10",
                 f"root@{IP}:{REMOTE_PNG}", local_path],
                capture_output=True, text=True, timeout=40,
            )
            ssh(f"rm -f {REMOTE_PNG} /tmp/current_screenshot.png /mnt/us/screenshot_*.png")
            if s.returncode == 0 and os.path.exists(local_path):
                return True
        time.sleep(1.0 + attempt)
    return False


def ink(bar_img):
    """底栏墨点数量：亮度低于 128 视为黑。"""
    return sum(1 for px in bar_img.getdata() if px < 128)


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 10
    outdir = sys.argv[2] if len(sys.argv) > 2 else "/tmp/barmeasure"
    os.makedirs(outdir, exist_ok=True)

    frames = []
    print(f"连拍 {n} 帧 …")
    for i in range(n):
        p = os.path.join(outdir, f"f{i:02d}.png")
        if capture(p):
            im = Image.open(p).convert("L")
            bar = im.crop((0, BAR_TOP, im.width, BAR_BOTTOM))
            frames.append((p, ink(bar)))
            print(f"  第 {i+1:2d} 帧: 底栏墨点 = {frames[-1][1]}")
        else:
            print(f"  第 {i+1:2d} 帧: 截图失败")

    if len(frames) < 2:
        print("有效帧不足，无法比较")
        return 1

    # 帧间差异：以第一帧为基准，逐像素比较底栏
    base = Image.open(frames[0][0]).convert("L").crop((0, BAR_TOP, 600, BAR_BOTTOM))
    base_px = list(base.getdata())
    diffs = []
    for path, _ in frames[1:]:
        cur = list(Image.open(path).convert("L").crop((0, BAR_TOP, 600, BAR_BOTTOM)).getdata())
        diffs.append(sum(1 for a, b in zip(base_px, cur) if a != b))

    inks = [v for _, v in frames]
    same = len(set(inks)) == 1 and all(d == 0 for d in diffs)
    print("\n---- 结论 ----")
    print(f"  墨点数: {inks}")
    print(f"  最小/最大: {min(inks)} / {max(inks)}")
    print(f"  与首帧的差异像素数: {diffs}")
    print(f"  {'✅ 底栏完全稳定（每帧逐像素一致）' if same else '❌ 底栏存在波动'}")
    return 0 if same else 1


if __name__ == "__main__":
    sys.exit(main())
