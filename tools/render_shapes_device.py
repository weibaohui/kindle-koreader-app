#!/usr/bin/env python3
"""把真机上拍到的不同关卡形状拼成一张取证图。

用法：
  python3 tools/render_shapes_device.py <名字:截图.png> ... out.png
其中名字是形状 id（如 letter_c / circle），截图是 KOReader 上的实拍。
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

FONT_PATH = "/System/Library/Fonts/Supplemental/Songti.ttc"

# 砖阵在真机上的位置（600x800，GRID_X=26 / GRID_Y=84 / 10 列 6 行）
GRID_X, GRID_Y = 26, 84
BRICK_W, BRICK_H, GAP = 52, 24, 3
COLS, ROWS = 10, 6
GRID_W = COLS * BRICK_W + (COLS - 1) * GAP
GRID_H = ROWS * BRICK_H + (ROWS - 1) * GAP

NAMES = {
    "circle": "圆形", "diamond": "菱形", "heart": "心形", "triangle": "三角形",
    "cross": "十字", "arrow": "箭头", "smiley": "笑脸", "hourglass": "沙漏",
    "letter_a": "字母A", "letter_h": "字母H", "letter_t": "字母T",
    "letter_u": "字母U", "letter_x": "字母X", "letter_e": "字母E",
    "letter_b": "字母B", "letter_c": "字母C", "letter_o": "字母O",
    "letter_s": "字母S", "letter_v": "字母V", "letter_y": "字母Y",
}


def load_font(size):
    for idx in range(6):
        try:
            return ImageFont.truetype(FONT_PATH, size, index=idx)
        except Exception:
            break
    return ImageFont.load_default()


def grid_of(img):
    """从真机截图反推出砖阵占位（10x6 的 #/. 网格）。"""
    px = img.load()
    rows = []
    for r in range(ROWS):
        y0 = GRID_Y + r * (BRICK_H + GAP)
        line = ""
        for c in range(COLS):
            x0 = GRID_X + c * (BRICK_W + GAP)
            dark = tot = 0
            for y in range(y0, y0 + BRICK_H):
                for x in range(x0, x0 + BRICK_W):
                    tot += 1
                    if px[x, y] < 170:
                        dark += 1
            line += "#" if dark / tot > 0.35 else "."
        rows.append(line)
    return rows


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        print(__doc__)
        return 1
    out_path = args[-1]
    items = []
    for a in args[:-1]:
        name, path = a.split(":", 1)
        items.append((name, path))

    pad, label_h, title_h = 12, 30, 34
    cell_w, cell_h = GRID_W, GRID_H
    ncol = min(2, len(items))
    nrow = (len(items) + ncol - 1) // ncol
    width = ncol * (cell_w + pad) + pad
    height = title_h + nrow * (cell_h + label_h + pad) + pad

    sheet = Image.new("L", (width, height), 255)
    dr = ImageDraw.Draw(sheet)
    f_title = load_font(19)
    f_name = load_font(16)

    dr.text((pad, 8), "真机关卡形状（每关随机，开局重抽）", font=f_title, fill=0)

    for i, (name, path) in enumerate(items):
        cx = pad + (i % ncol) * (cell_w + pad)
        cy = title_h + (i // ncol) * (cell_h + label_h + pad)
        im = Image.open(path).convert("L")
        sheet.paste(im.crop((GRID_X, GRID_Y, GRID_X + GRID_W, GRID_Y + GRID_H)), (cx, cy))
        dr.rectangle([cx, cy, cx + cell_w - 1, cy + cell_h - 1], outline=180)
        rows = grid_of(im)
        desc = "%s (%s)  %d 砖" % (NAMES.get(name, name), name, sum(r.count('#') for r in rows))
        dr.text((cx, cy + cell_h + 6), desc, font=f_name, fill=0)

    sheet.save(out_path)
    print("已写出 %s (%dx%d)" % (out_path, width, height))
    return 0


if __name__ == "__main__":
    sys.exit(main())
