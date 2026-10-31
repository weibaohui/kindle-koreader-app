#!/usr/bin/env python3
"""测量真机上挡板的水平位置（用于验证拖拽跟手是否准确）。

用法: python3 tools/measure_paddle.py <截图文件> ...
"""
import sys
from PIL import Image

PADDLE_Y = 697          # 挡板下半部（避开白色条纹）
SCAN_X0, SCAN_X1 = 12, 589


def paddle_runs(path):
    im = Image.open(path).convert("L")
    runs, cur = [], None
    for x in range(SCAN_X0, SCAN_X1):
        dark = im.getpixel((x, PADDLE_Y)) < 100
        if dark and cur is None:
            cur = x
        elif not dark and cur is not None:
            runs.append((cur, x - 1))
            cur = None
    if cur is not None:
        runs.append((cur, SCAN_X1 - 1))
    return [r for r in runs if r[1] - r[0] >= 30]


for f in sys.argv[1:]:
    r = paddle_runs(f)
    centers = [(a + b) // 2 for a, b in r]
    print(f"{f}: 挡板 {r} 中心 {centers}")
