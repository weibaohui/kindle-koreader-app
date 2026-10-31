#!/usr/bin/env python3
"""砖块配色候选预览：用与插件完全一致的几何，在本地渲染几套灰阶方案。

只渲染砖阵区(10 列 x 6 行)，用于肉眼比较"不同灰度是否更好看/更好认"。
"""
from PIL import Image, ImageDraw

COLS, ROWS = 10, 6
BRICK_W, BRICK_H, GAP = 52, 24, 3
GRID_X, GRID_Y = 26, 84

BLACK, WHITE = 0, 255
G33, G44, G66, G88, G99, GBB = 0x33, 0x44, 0x66, 0x88, 0x99, 0xBB


def draw_brick(d, x, y, fill, pip=None, steel=False, power=False):
    """pip: None / 1 / 2 / 'diamond'"""
    r = 3
    d.rounded_rectangle([x, y, x + BRICK_W - 1, y + BRICK_H - 1], radius=r, fill=fill)
    cx, cy = x + BRICK_W // 2, y + BRICK_H // 2
    if steel:
        # 黑描边 + 黑菱形点阵
        d.rectangle([x, y, x + BRICK_W - 1, y + 1], fill=BLACK)
        d.rectangle([x, y + BRICK_H - 2, x + BRICK_W - 1, y + BRICK_H - 1], fill=BLACK)
        d.rectangle([x, y, x + 1, y + BRICK_H - 1], fill=BLACK)
        d.rectangle([x + BRICK_W - 2, y, x + BRICK_W - 1, y + BRICK_H - 1], fill=BLACK)
        for ox, oy in ((0, 0), (-9, -5), (9, -5), (-9, 5), (9, 5)):
            d.rectangle([cx + ox - 2, cy + oy - 2, cx + ox + 1, cy + oy + 1], fill=BLACK)
    elif power:
        for i in range(7):
            rw = 8 - 2 * abs(i - 3)
            d.rectangle([cx - rw // 2, cy - 7 + i * 2, cx - rw // 2 + rw - 1, cy - 7 + i * 2 + 1], fill=WHITE)
    elif pip == 1:
        d.rectangle([cx - 4, cy - 4, cx + 3, cy + 3], fill=WHITE)
    elif pip == 2:
        d.rectangle([cx - 12, cy - 4, cx - 5, cy + 3], fill=WHITE)
        d.rectangle([cx + 4, cy - 4, cx + 11, cy + 3], fill=WHITE)


def render(layout, path):
    """layout: list of rows, each row a list of (fill, pip, kind)"""
    W, H = 600, 300
    im = Image.new("L", (W, H), WHITE)
    d = ImageDraw.Draw(im)
    for r, row in enumerate(layout):
        for c, (fill, pip, kind) in enumerate(row):
            x = GRID_X + c * (BRICK_W + GAP)
            y = GRID_Y + r * (BRICK_H + GAP)
            draw_brick(d, x, y, fill, pip, steel=(kind == "steel"), power=(kind == "power"))
    im.save(path)
    return path


def base_rows():
    """典型的一关：普通/2血/3血/钢/道具 混排"""
    n = ("normal",)
    return [
        [("hp3",)] * 4 + [("hp2",)] * 3 + [("hp3",)] * 3,
        [("hp2",)] * 4 + [("normal",)] * 6,
        [("normal",)] * 10,
        [("normal",)] * 4 + [("steel",)] * 2 + [("normal",)] * 4,
        [("normal",)] * 2 + [("power",)] + [("normal",)] * 7,
        [("normal",)] * 3 + [("power",)] + [("normal",)] * 6,
    ]


SCHEMES = {
    "A_现状全黑": lambda k: (
        (BLACK, None, "normal") if k == "normal" else
        (BLACK, 1, "normal") if k == "hp2" else
        (BLACK, 2, "normal") if k == "hp3" else
        (GBB, None, "steel") if k == "steel" else
        (BLACK, None, "power")),
    "B_普通砖退深灰": lambda k: (
        (G33, None, "normal") if k == "normal" else
        (BLACK, 1, "normal") if k == "hp2" else
        (BLACK, 2, "normal") if k == "hp3" else
        (GBB, None, "steel") if k == "steel" else
        (BLACK, None, "power")),
    "C_血量分灰阶": lambda k: (
        (BLACK, None, "normal") if k == "normal" else
        (G44, 1, "normal") if k == "hp2" else
        (G88, 2, "normal") if k == "hp3" else
        (GBB, None, "steel") if k == "steel" else
        (BLACK, None, "power")),
    "D_价值分亮度": lambda k: (
        (G33, None, "normal") if k == "normal" else
        (G66, 1, "normal") if k == "hp2" else
        (G99, 2, "normal") if k == "hp3" else
        (GBB, None, "steel") if k == "steel" else
        (BLACK, None, "power")),
}


def main():
    rows = base_rows()
    imgs = []
    for name, fn in SCHEMES.items():
        layout = [[fn(k[0]) for k in row] for row in rows]
        imgs.append((name, render(layout, f"/tmp/brick_{name}.png")))
    # 拼成一张对比图
    W = 600
    H = len(imgs) * 300
    out = Image.new("L", (W, H), WHITE)
    for i, (_, p) in enumerate(imgs):
        out.paste(Image.open(p), (0, i * 300))
    out.save("/tmp/brick_compare.png")
    print("\n".join(f"{i}: {n}" for i, (n, _) in enumerate(imgs)))
    print("-> /tmp/brick_compare.png  (A/B/C/D 自上而下)")


if __name__ == "__main__":
    main()
