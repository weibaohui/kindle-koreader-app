# KOReader 墨水屏游戏插件 —— 统一开发规范

> 本文件是四个游戏（国际象棋 / 中国象棋 / 围棋 / 军棋）共用的**硬性约束**。
> 每个游戏一个独立目录，一个开发者（worker）独占一个目录，不要改别人的文件。

---

## 0. 设备与运行环境

| 项 | 值 |
| :--- | :--- |
| 设备 | Amazon Kindle Basic 第 7 代（KT2），**600 × 800**，**16 级灰度**，**无前光** |
| 运行时 | KOReader 内置 **LuaJIT 5.1**（不是 Lua 5.3！） |
| 输入 | 红外触控 zforce2，**evdev 注入无效**，真机验证走 KOReader 插件注入 |
| 字体 | `Font:getFace("cfont", size)` / `"tfont"` / `"dfont"` / `"nfont"` / `"bfont"` |

### Lua 5.1 语法禁令（用错直接语法错误）

- 不能用 `&`、`|`、`<<`、`>>`、`//`、位运算符 `~`
- 不能用 `goto`
- 不能用 `table.unpack`（用 `unpack`）
- 不能用 `#` 之外的新增语法糖

**位运算用算术替代**：`2^(d-1)` 算第 d 位的掩码。

### 字符串遍历禁令

`string.gmatch` 返回的是**迭代函数**，不能塞进 `ipairs`：

```lua
-- ✅ 正确
for w in line:gmatch("%S+") do t[#t+1] = w end
-- ❌ 错误：bad argument #1 to 'ipairs' (table expected, got function)
for _, w in ipairs(line:gmatch("%S+")) do end
```

---

## 1. 插件结构

```
plugins/<name>.koplugin/
├── _meta.lua          -- { fullname = "...", description = "..." }
├── main.lua           -- 菜单注册，**必须 return 一个模块**
└── <name>dialog.lua   -- 游戏主体
```

### `_meta.lua`

```lua
return {
    fullname = "国际象棋 (Chess)",
    description = "一句话说清玩法与墨水屏适配点。",
}
```

### `main.lua`（照抄数独的结构）

```lua
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local reader_order = require("ui/elements/reader_menu_order")
local filemanager_order = require("ui/elements/filemanager_menu_order")

table.insert(reader_order.tools, 1, "<name>_game")
table.insert(filemanager_order.tools, 1, "<name>_game")

local XPlugin = WidgetContainer:extend{
    name = "<name>",
    is_doc_only = false,
}

function XPlugin:init()
    self.ui.menu:registerToMainMenu(self)
end

function XPlugin:addToMainMenu(menu_items)
    menu_items.<name>_game = {
        text = "国际象棋 (Chess)",
        sorting_hint = "tools",
        callback = function()
            package.loaded["<name>dialog"] = nil
            local Dialog = require("<name>dialog")
            UIManager:show(Dialog:new())
        end,
    }
end

return XPlugin
```

> 菜单项 key 必须**全局唯一**（数独用 `sudoku_game`，打砖块/方块战争各用自己的），
> 否则会互相覆盖。

---

## 2. ⭐ 手势注册（不写就"完全点不动"，且不报错）

KOReader 的 `InputContainer:onGesture` **只**分发两类注册项：
`registerTouchZones` 注册的触摸区，和 `self.ges_events` 里用 `GestureRange` 声明的手势。
它**不会**自动调用你重写的 `onTap` / `onHold`。

所以必须：

```lua
local GestureRange = require("ui/gesturerange")
local Geom = require("ui/geometry")

function Dialog:init()
    -- ⚠️ 必须关掉原生 double_tap
    self.disable_double_tap = true

    local full_range = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }
    self.ges_events = {
        Tap  = { GestureRange:new{ ges = "tap",  range = full_range } },
        Hold = { GestureRange:new{ ges = "hold", range = full_range } },
    }
end

-- 转发并吞掉，避免事件冒泡到下层的文件管理器
function Dialog:onGesture(ev)
    InputContainer.onGesture(self, ev)
    return true
end
```

（`InputContainer` 用 `require("ui/widget/container/inputcontainer")` 拿。）

---

## 3. 墨水屏设计铁律

### 3.1 视觉：不依赖颜色，灰阶 + 形状双编码

- 16 级灰度 + 无前光 → 颜色语义全部失效，**任何"靠颜色区分"的设计都不合格**。
- 敌我用**形状 / 底色深浅 / 字符本身**区分（见各游戏规格）。
- 棋盘格线用浅灰（`COLOR_GRAY_LIGHT` 级别），选中格用**内嵌粗框**，不要整行反白。

### 3.2 刷新预算（这是墨水屏插件的命门）

| 规则 | 说明 |
| :--- | :--- |
| **静止时零刷新** | 只有"真的变了"才标脏。位置/大小/增删变了才标。 |
| **脏区用完即清** | 刷新推送后置 nil，否则矩形会随物体跑过的范围越滚越大。 |
| **分桶且桶名原样使用** | `UIManager:setDirty(self, "ui", Geom:new{...})`；出队时逐条执行，矩形落在别的桶的钳制范围外会被**静默丢弃**（高度算成负数），没有任何报错。 |
| **相邻刷新块留 1px 以上间隙** | KOReader 用 `Geom:openIntersectWith` 判冲突，**共享边界的两个矩形也会被合并**。 |

推荐实现（照抄数独）：

```lua
function Dialog:refreshRegion(x, y, w, h)
    UIManager:setDirty(self, "ui", Geom:new{ x = x, y = y, w = w, h = h })
end
function Dialog:refreshAll()
    UIManager:setDirty(self, "ui", Geom:new{ x = 0, y = 0, w = self.W, h = self.H })
end
```

### 3.3 定时器

```lua
-- ⚠️ UIManager:scheduleIn 没有返回值，必须自己留引用，否则无法 unschedule
self.timer = UIManager:scheduleIn(1, function() ... end)
```

---

## 4. 绘制

```lua
-- 文本：y 是**基线**，不是顶边
RenderText:renderUtf8Text(bb, x, baseline_y, face, text, kerning, bold, fgcolor, width, char_pads)
-- 尺寸：返回 { x = 宽, y_top = 上方留白, y_bottom = 下方留白 }
local w, _, top, bottom = unpack(RenderText:sizeUtf8Text(face, text))
```

### 可用颜色（Blitbuffer）

```
COLOR_BLACK  COLOR_WHITE
COLOR_GRAY_1 .. COLOR_GRAY_9        (0x11 .. 0x99)
COLOR_GRAY(0xAA)  COLOR_GRAY_B(0xBB)
COLOR_LIGHT_GRAY(0xCC)  COLOR_GRAY_D(0xDD)  COLOR_GRAY_E(0xEE)
```

**没有** `COLOR_GRAY_A`（别用，会报错）。

画圆：`bb:paintCircle(x, y, radius, color)`。
画矩形：`bb:paintRect(x, y, w, h, color)`。

### paintTo 必须自己铺满全屏底色

```lua
function Dialog:paintTo(bb, x, y)
    bb:paintRect(0, 0, self.W, self.H, Blitbuffer.COLOR_WHITE)  -- 不铺的话下层文件管理器会透出来
    ...
end
```

### 绘制顺序：**先画底色、再画文字**

先 `renderUtf8Text` 再 `paintRect(灰底)` 的话，文字会被灰底盖住。

---

## 5. 统一屏幕布局（600 × 800）

```
y=0   ┌──────────────────────────────┐
      │  顶栏 44px：标题 + 按钮       │  ← 按钮：至少"新局"和"退出"
y=44  ├──────────────────────────────┤
      │                              │
      │        棋盘 / 棋面区          │  ← 主体
      │                              │
y=?   ├──────────────────────────────┤
      │  状态条（约 30px）            │  ← 当前选中 / 轮到谁 / 提示文案
y=?   ├──────────────────────────────┤
      │  操作区 / 棋子面板（约 130px） │  ← 可选
y=800 └──────────────────────────────┘
```

- 顶栏按钮用**浅灰底 + 黑字**，按下用深灰底白字；按钮之间留 4px 间隙。
- 所有可点区域**至少 44px 高**（手指盲操）。

---

## 6. 统一交互模型

| 操作 | 行为 |
| :--- | :--- |
| 点格子 | 选中它（粗框高亮）；若已有选中且点的是另一格 → 尝试执行动作 |
| 点第二格 | 执行（移动 / 落子 / 吃子） |
| 再点自己 | 取消选中 |
| **长按格子** | 清空该格 / 取消选中（每个游戏自己定，行为要一致地写在提示行） |
| 点棋子面板 | 选中要放置的棋子类型 |
| 顶栏按钮 | 新局 / 悔棋 / 退出 |

**每一步都要有可见反馈**：状态条要显示当前处于什么模式、下一步该做什么、或者为什么非法。

---

## 7. 存档

```lua
local DataStorage = require("datastorage")
local dir = DataStorage:getSettingsDir()
local path = dir .. "/<name>_save.txt"
```

- 用 Lua 表序列化（`table.concat` 拼 KV 行），不要用 JSON 库（设备上不一定有）。
- 读档要做健壮性检查（文件不存在 / 内容损坏 → 回到初始局面，别崩）。
- 存档文件写到 `DataStorage:getSettingsDir()`，**不要**写 `/mnt/us/` 根目录。

---

## 8. 无头测试台（必须交）

每个游戏配一个 `tools/sim_<name>.lua`：

- **完全 mock 掉 KOReader 依赖**（Blitbuffer / Font / RenderText / UIManager / DataStorage / InputContainer / GestureRange / Device / Time）。
- **参考 `tools/sim_sudoku.lua` 的骨架**，直接照抄改。
- 跑纯游戏逻辑，**断言 ≥ 25 条**，覆盖：
  - 初始局面正确
  - 走法生成合法性（每种棋子都覆盖）
  - 特殊规则（将军/将死/易位/过路兵/提子/打劫/比较大小…）
  - 非法走法被拒绝
  - 悔棋回退正确
  - 存档往返
  - 胜负判定
- 必须在 `lua tools/sim_<name>.lua` 下**全绿**，并把输出贴进交付说明。

```bash
lua tools/sim_<name>.lua
```

---

## 9. 交付检查清单

- [ ] `plugins/<name>.koplugin/` 三个文件齐全，`main.lua` 有 `return`
- [ ] `disable_double_tap = true`
- [ ] 注册了 `ges_events`（Tap / Hold）并重写 `onGesture`
- [ ] 没有 Lua 5.3 语法
- [ ] `paintTo` 铺满全屏底色，先底色后文字
- [ ] 静止时零刷新，脏区分桶且用完即清
- [ ] 没有用 `COLOR_GRAY_A`
- [ ] `lua tools/sim_<name>.lua` 全绿，断言 ≥ 25 条
- [ ] 每个文件顶部有中文注释说明这个文件干什么

---

## 10. 仓库礼仪

- **只改自己那个游戏目录** + 自己的 `tools/sim_<name>.lua`。
- 不要改 `README.md`、`docs/`、其它游戏的目录。
- 不要 `git commit` / `git push`（由主控统一提交）。
- 不要动设备（真机安装与截图由主控统一做）。
