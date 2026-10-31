#!/usr/bin/env python3
"""真机截图里逐砖清点道具砖（纯黑底 + 中央白色菱形 pip）。

判定规则（与 breakoutdialog.lua 的绘制一致）：
  - 砖块区域以纯黑为主（value < 40）
  - 中央白色 pip 的高度 >= 13 px → 菱形（道具砖）
  - 中央白色 pip 的高度 == 8 px  → 方形（2 血砖 / 3 血精英砖）

用法: python3 tools/count_power_bricks.py <screenshot.png> [关卡行数]
"""
import sys
from PIL import Image

COLS, ROWS = 10, 6
BRICK_W, BRICK_H, GAP = 52, 24, 3
GRID_X, GRID_Y = 26, 84


def analyze(path, rows=ROWS):
    im = Image.open(path).convert("L")
    px = im.load()
    power, hp2, hp3, steel, plain = [], [], [], [], []
    for r in range(1, rows + 1):
        for c in range(1, COLS + 1):
            bx = GRID_X + (c - 1) * (BRICK_W + GAP)
            by = GRID_Y + (r - 1) * (BRICK_H + GAP)
            # 砖块主体是否纯黑
            body = [px[bx + dx, by + dy]
                    for dy in range(2, BRICK_H - 2, 3)
                    for dx in range(2, BRICK_W - 2, 3)]
            black = sum(1 for v in body if v < 40)
            if black < len(body) * 0.6:
                # 非纯黑：可能是空位(白) / 钢砖(浅灰) / 普通砖(深灰 51)
                avg = sum(body) / len(body)
                if avg > 245:
                    pass                      # 空位
                elif avg > 120:
                    steel.append((r, c))      # 浅灰钢砖
                else:
                    plain.append((r, c))      # 深灰普通砖
                continue
            # 中央白色 pip 的包围盒
            ccx, ccy = bx + BRICK_W // 2, by + BRICK_H // 2
            pts = [(x, y) for y in range(ccy - 10, ccy + 11)
                   for x in range(ccx - 20, ccx + 21) if px[x, y] > 200]
            if not pts:
                plain.append((r, c))
                continue
            h = max(p[1] for p in pts) - min(p[1] for p in pts) + 1
            xs = sorted({p[0] for p in pts})
            groups = 1
            for i in range(1, len(xs)):
                if xs[i] - xs[i - 1] > 3:
                    groups += 1
            if h >= 13:
                power.append((r, c))
            elif groups >= 2:
                hp3.append((r, c))
            else:
                hp2.append((r, c))
    return power, hp2, hp3, steel, plain


if __name__ == "__main__":
    path = sys.argv[1]
    rows = int(sys.argv[2]) if len(sys.argv) > 2 else ROWS
    power, hp2, hp3, steel, plain = analyze(path, rows)
    print(f"道具砖(菱形pip) {len(power):2d} 块 @ {power}")
    print(f"2血砖(方形pip)   {len(hp2):2d} 块")
    print(f"3血砖(双pip)    {len(hp3):2d} 块")
    print(f"钢砖(浅灰)      {len(steel):2d} 块")
    print(f"普通砖(深灰)    {len(plain):2d} 块")
