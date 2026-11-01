#!/usr/bin/env python3
"""把 render_powerup_icons.lua 录下的绘图指令栅格化成 PNG。

灰阶映射按 KOReader 的 16 级灰度走：0x00 = 全黑，0xFF = 全白，
中间按 0x11/0x22/... 线性映射到 0-255。

用法：
  python3 tools/render_powerup_icons.py ops.json out.png [放大倍数]
"""
import json
import sys

from PIL import Image, ImageDraw


def gray(v: int) -> int:
    """KOReader 灰阶字节 -> PIL 灰度值（0 黑, 255 白）"""
    return v


def rounded(draw, box, radius, fill):
    draw.rounded_rectangle(box, radius=radius, fill=fill)


def render(ops, labels, w, h, scale=3):
    img = Image.new("L", (w * scale, h * scale), 255)
    d = ImageDraw.Draw(img)

    for o in ops:
        s = scale
        bg = o.get("bg", 255)
        if o["o"] == "rect":
            x, y, ww, hh, c = o["x"] * s, o["y"] * s, o["w"] * s, o["h"] * s, o["c"]
            d.rectangle([x, y, x + ww - 1, y + hh - 1], fill=gray(c))
        elif o["o"] == "circle":
            cx, cy, r, c = o["x"] * s, o["y"] * s, o["r"] * s, o["c"]
            border = o.get("b", 0)
            if border and border > 0:
                # KOReader 的 paintCircle 带 border 时画的是空心环，
                # 环内透出的是徽章底色（不是白色）
                d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=gray(c))
                ir = max(0, r - border * s)
                d.ellipse([cx - ir, cy - ir, cx + ir, cy + ir], fill=gray(bg))
            else:
                d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=gray(c))
        else:
            x, y, ww, hh, c, rad = (
                o["x"] * s, o["y"] * s, o["w"] * s, o["h"] * s, o["c"], o.get("r", 0) * s,
            )
            rounded(d, [x, y, x + ww - 1, y + hh - 1], rad, gray(c))

    # 标签用真字体更好读，但设备上没字体文件时就退回用方块标号
    for l in labels:
        x, y, s = l["x"] * scale, l["y"] * scale, l["s"] * scale
        d.rectangle([x - 2, y - 2, x + s + 1, y + s + 1], outline=160)

    return img


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    data = json.load(open(sys.argv[1]))
    out_path = sys.argv[2]
    scale = int(sys.argv[3]) if len(sys.argv) > 3 else 3

    img = render(data["ops"], data["labels"], data["w"], data["h"], scale)

    # 下面拼一张带中文标签的版本
    from PIL import ImageDraw as ID
    canvas = Image.new("L", (img.width + 220, img.height + 40), 255)
    canvas.paste(img, (0, 0))
    d = ID.Draw(canvas)
    try:
        from PIL import ImageFont
        font = ImageFont.truetype("/System/Library/Fonts/STHeiti Light.ttc", 15)
        small = ImageFont.truetype("/System/Library/Fonts/STHeiti Light.ttc", 12)
    except Exception:
        font = None
        small = None

    y = 6
    for l in data["labels"]:
        tag = "减益" if l["b"] else "增益"
        if font:
            d.text((img.width + 8, y), f'{l["n"]}  ({l["id"]})  {tag}  {l["s"]}px',
                   fill=0, font=small)
        y += 17
        if y > img.height:
            break

    canvas.save(out_path)
    print(f"wrote {out_path} ({canvas.width}x{canvas.height})")


if __name__ == "__main__":
    main()
