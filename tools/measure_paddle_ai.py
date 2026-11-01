#!/usr/bin/env python3
"""从真机截图里量出挡板的位置（用于验证 AI 自动跟随）。

挡板在 PADDLE_Y = 662（KT2 600x800），是一条深灰横条。
两个坑：
  · 阈值太严会量不到 —— 挡板是深灰（约 140），不是纯黑，要用 <170 判定。
  · 场地边框（x=8 和 x=591 的黑线）每行都在，必须把 x<20 / x>580 排除掉。
做法：扫挡板高度附近几行，找够宽的连续暗像素段。
"""
import sys

from PIL import Image

PADDLE_Y = 662
BAND = range(PADDLE_Y, PADDLE_Y + 10)
X0, X1 = 20, 580
MIN_W = 30
THRESH = 170


def paddle_span(path):
    """返回挡板的 (x1, x2, 中心)。

    做法：扫挡板高度附近几行，把每一行里"够宽的连续暗段"全部收集起来，
    取它们的并集包围盒。
    为什么不能只看单行：挡板顶部那几行经常被球或落点标记打断成两段，
    单看一行会把宽度量成一半甚至 1px。
    """
    im = Image.open(path).convert("L")
    px = im.load()
    segs = []
    for y in BAND:
        run = None
        for x in range(X0, X1):
            dark = px[x, y] < THRESH
            if dark and run is None:
                run = x
            elif not dark and run is not None:
                if x - run >= MIN_W:
                    segs.append((run, x - 1))
                run = None
        if run is not None and X1 - run >= MIN_W:
            segs.append((run, X1 - 1))
    if not segs:
        return None
    x1 = min(s[0] for s in segs)
    x2 = max(s[1] for s in segs)
    return (x1, x2, (x1 + x2) / 2.0)


if __name__ == "__main__":
    for p in sys.argv[1:]:
        r = paddle_span(p)
        if r:
            print("%-26s 挡板 x=%d..%d (宽 %d)  中心=%.1f"
                  % (p.split('/')[-1], r[0], r[1], r[1] - r[0] + 1, r[2]))
        else:
            print("%-26s 未找到挡板" % p.split('/')[-1])
