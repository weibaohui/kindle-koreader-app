#!/usr/bin/env python3
"""把"真机截图里的道具徽章"和"离线渲染的道具徽章"拼成一张对照图。

上排 = 真机截图（Kindle 16 级灰度实拍）
下排 = 离线渲染（直接调用插件里的 drawPowerIcon 录指令后栅格化）

两张图用同一套标签，竖着对齐，方便一眼看出
"离线看着清楚 / 真机也清楚" 还是 "离线清楚但真机糊成一团"。

用法：
  luajit tools/render_powerup_icons.lua > /tmp/pu_ops.json
  python3 tools/render_powerup_compare.py /tmp/pu_ops.json /tmp/pu_shots out.png
其中 /tmp/pu_shots 是目录，里面放 <道具id>.png 的真机截图。
"""
import json
import os
import sys

from PIL import Image, ImageDraw, ImageFont

FONT_PATH = "/System/Library/Fonts/Supplemental/Songti.ttc"

# 真机徽章的搜索窗口（真机 600x800，徽章 28px，钉在 x=300）
SEARCH_X0, SEARCH_X1 = 278, 322
SEARCH_Y0, SEARCH_Y1 = 290, 420


def load_font(size):
    for idx in range(6):
        try:
            return ImageFont.truetype(FONT_PATH, size, index=idx)
        except Exception:
            break
    return ImageFont.load_default()


def gray(v):
    return v


def detect_badge(img):
    """在真机截图里找出道具徽章的包围盒。

    徽章固定 28px、居中在 x=300（注入时被钉住），所以 x 范围是确定的，
    只需要在 y 方向找到那一段连续行。

    两个坑：
    1) 底色有两种：增益是纯黑(0)，减益是浅灰(187)，
       所以判定必须用"非白"(<245)而不是"暗色"，否则减益道具会被漏掉。
    2) 黑底白图标的徽章中间有一条白色横条，那几行只有 8 个非白像素。
       不能按"每行非白数达标"来切段，否则会把徽章拦腰截断成半张。
       改成按"横向跨度 >= 24px"判定行属于徽章，并允许中间有 <=4 行的空洞。
    """
    px = img.load()
    x0, x1 = 286, 314
    rows = []
    for y in range(SEARCH_Y0, SEARCH_Y1):
        xs = [x for x in range(x0, x1) if px[x, y] < 245]
        if xs and (max(xs) - min(xs)) >= 24:
            rows.append(y)
        elif rows and (y - rows[-1]) > 4:
            break
    if not rows:
        return None
    return (x0, rows[0], x1, rows[-1] + 1)


def render_offline(data):
    """按 render_powerup_icons.lua 录下的指令画一排徽章，返回 {id: Image}。

    直接复用 render_powerup_icons.py 的渲染实现（同一套指令语义），
    以 scale=1 画原尺寸图，再按 labels 里的坐标裁出每个 28px 徽章。
    """
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import render_powerup_icons as rpi

    img = rpi.render(data["ops"], data["labels"], data["w"], data["h"], 1)
    out = {}
    for lb in data["labels"]:
        if lb.get("s") != 28:
            continue
        box = (lb["x"], lb["y"], lb["x"] + lb["s"], lb["y"] + lb["s"])
        out[lb["id"]] = img.crop(box)
    return out


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        return 1
    ops_file, shot_dir, out_path = sys.argv[1], sys.argv[2], sys.argv[3]

    with open(ops_file) as f:
        data = json.load(f)
    offline = render_offline(data)
    names = {lb["id"]: lb["n"] for lb in data["labels"] if lb.get("s") == 28}
    bad = {lb["id"]: bool(lb.get("b")) for lb in data["labels"] if lb.get("s") == 28}

    good = [lb["id"] for lb in data["labels"] if lb.get("s") == 28 and not lb.get("b")]
    evil = [lb["id"] for lb in data["labels"] if lb.get("s") == 28 and lb.get("b")]

    # 徽章放大到 2.5x（28 -> 70px）：原始 28px 徽章里的白色细条只有 4px 高，
    # 直接贴进拼图会在缩略图里彻底消失，看上去像"图标没画出来"——
    # 这是一次真机验收时踩过的坑：差点误判成渲染 bug。
    cell = 76
    badge = 70
    left = 66
    ncol = max(len(good), len(evil))
    width = left + ncol * cell
    block_h = badge * 2 + 78
    height = 40 + block_h * 2

    sheet = Image.new("L", (width, height), 255)
    dr = ImageDraw.Draw(sheet)
    f_title = load_font(18)
    f_sub = load_font(15)
    f_name = load_font(16)
    f_id = load_font(11)

    missing = []

    def draw_block(ids, title, y0):
        dr.text((10, y0), title, font=f_sub, fill=0)
        for i, pid in enumerate(ids):
            x = left + i * cell
            p = os.path.join(shot_dir, "%s.png" % pid)
            if os.path.exists(p):
                im = Image.open(p).convert("L")
                box = detect_badge(im)
                if box:
                    crop = im.crop(box).resize((badge, badge), Image.NEAREST)
                    sheet.paste(crop, (x, y0 + 22))
                else:
                    missing.append(pid)
            else:
                missing.append(pid)
            if pid in offline:
                sheet.paste(offline[pid].resize((badge, badge), Image.NEAREST), (x, y0 + 22 + badge + 10))
            dr.text((x, y0 + 22 + badge * 2 + 16), names.get(pid, pid), font=f_name, fill=0)
            dr.text((x, y0 + 22 + badge * 2 + 36), pid, font=f_id, fill=100)

    dr.text((10, 10), "道具图标：真机实拍 vs 离线渲染", font=f_title, fill=0)
    draw_block(good, "增益道具（上排=真机 600x800 16级灰度实拍，下排=离线 drawPowerIcon 渲染）", 40)
    draw_block(evil, "减益道具（上排=真机实拍，下排=离线渲染）", 40 + block_h)

    sheet.save(out_path)
    print("已写出 %s (%dx%d)" % (out_path, width, height))
    if missing:
        print("⚠️ 缺少真机截图: %s" % ", ".join(missing))
    return 0

if __name__ == "__main__":
    sys.exit(main())
