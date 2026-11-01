#!/usr/bin/env python3
"""把关卡形状库渲染成 PNG（每格一个形状，裁到砖阵区域）。

灰阶映射按 KOReader 的 16 级灰度走：0x00 = 全黑，0xFF = 全白。

用法：
  python3 tools/render_level_shapes.py ops.json out.png [每行个数]
"""
import json
import sys

from PIL import Image, ImageDraw, ImageFont


def draw_ops(draw, ops, ox=0, oy=0, s=1):
    for o in ops:
        x, y = ox + o["x"] * s, oy + o["y"] * s
        if o["o"] == "rect":
            ww, hh = o["w"] * s, o["h"] * s
            draw.rectangle([x, y, x + ww - 1, y + hh - 1], fill=o["c"])
        elif o["o"] == "circle":
            cx, cy, r = x, y, o["r"] * s
            border = o.get("b", 0)
            if border and border > 0:
                draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=o["c"])
                ir = max(0, r - border * s)
                draw.ellipse([cx - ir, cy - ir, cx + ir, cy + ir], fill=255)
            else:
                draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=o["c"])
        else:
            ww, hh, rad = o["w"] * s, o["h"] * s, o.get("r", 0) * s
            draw.rounded_rectangle([x, y, x + ww - 1, y + hh - 1], radius=rad, fill=o["c"])


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    data = json.load(open(sys.argv[1]))
    out_path = sys.argv[2]
    cols = int(sys.argv[3]) if len(sys.argv) > 3 else 4

    frames = data["frames"]
    # 先渲染每一帧的砖阵区域
    tiles = []
    for fr in frames:
        g = fr["grid"]
        pad = 6
        cw, ch = g["w"] + pad * 2, g["h"] + pad * 2
        tile = Image.new("L", (cw, ch), 255)
        draw_ops(ImageDraw.Draw(tile), fr["ops"], ox=-(g["x"] - pad), oy=-(g["y"] - pad))
        tiles.append((fr, tile))

    tw, th = tiles[0][1].size
    label_h = 22
    rows = (len(tiles) + cols - 1) // cols
    canvas = Image.new("L", (cols * tw, rows * (th + label_h)), 255)
    d = ImageDraw.Draw(canvas)

    try:
        font = ImageFont.truetype("/System/Library/Fonts/STHeiti Light.ttc", 16)
    except Exception:
        font = None

    for i, (fr, tile) in enumerate(tiles):
        cx = (i % cols) * tw
        cy = (i // cols) * (th + label_h)
        canvas.paste(tile, (cx, cy))
        d.rectangle([cx, cy, cx + tw - 1, cy + th - 1], outline=200)
        if font:
            d.text((cx + 6, cy + th + 3), f'{fr["name"]}  ({fr["id"]})  {fr["n"]} 砖',
                   fill=0, font=font)

    canvas.save(out_path)
    print(f"wrote {out_path} ({canvas.width}x{canvas.height}), {len(frames)} 个形状")


if __name__ == "__main__":
    main()
