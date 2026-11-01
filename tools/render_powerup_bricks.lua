--[[--
把 17 种道具砖（黑砖 + 白色道具图标）渲染成图，用来肉眼验证
"在 52x24 的砖上，图标能不能一眼分清是哪种道具"。

不重画一遍砖，而是**直接调用插件里真正的 drawBrick**：
用一个 mock blitbuffer 把绘图指令录成 JSON，再交给 Python 栅格化成 PNG。
这样验的就是线上代码本身，不是副本。

用法：
  luajit tools/render_powerup_bricks.lua > /tmp/pb_ops.json
  python3 tools/render_powerup_icons.py /tmp/pb_ops.json docs/screenshots/breakout_powerup_bricks.png 3
--]]--

-- ======================= Mock: Blitbuffer（只录指令，不真的画） =======================
local ops = {}
local Blitbuffer = {
    COLOR_BLACK = 0x00, COLOR_WHITE = 0xFF,
    COLOR_GRAY_1 = 0x11, COLOR_GRAY_2 = 0x22, COLOR_GRAY_3 = 0x33,
    COLOR_GRAY_4 = 0x44, COLOR_GRAY_5 = 0x55, COLOR_GRAY_6 = 0x66,
    COLOR_GRAY_7 = 0x77, COLOR_GRAY_8 = 0x88, COLOR_GRAY_9 = 0x99,
    COLOR_GRAY_B = 0xBB, COLOR_LIGHT_GRAY = 0xCC, COLOR_GRAY_E = 0xEE,
}
-- 插件里是 bb:paintRect(...) 这种冒号调用，第一个参数是 self，mock 要吃掉它。
-- cur_bg 记录"当前底色"：砖是黑的，所以砖面上画出来的圆环内部要透出黑色，
-- 否则"减速"的钟面会被渲染成一块实心白饼。
local cur_bg = 0xFF
Blitbuffer.paintRect = function(_, x, y, w, h, color)
    ops[#ops + 1] = { op = "rect", x = x, y = y, w = w, h = h, c = color, bg = cur_bg }
end
Blitbuffer.paintCircle = function(_, x, y, r, color, border)
    ops[#ops + 1] = { op = "circle", x = x, y = y, r = r, c = color, b = border, bg = cur_bg }
end
Blitbuffer.paintRoundedRect = function(_, x, y, w, h, color, radius)
    cur_bg = color
    ops[#ops + 1] = { op = "rr", x = x, y = y, w = w, h = h, c = color, r = radius, bg = color }
end

-- ======================= Mock: 其它 KOReader 模块 =======================
package.loaded["device"] = {
    screen = {
        getWidth = function() return 600 end,
        getHeight = function() return 800 end,
    },
}
package.loaded["ui/font"] = { getFace = function() return {} end }
package.loaded["ui/geometry"] = { new = function(a, b) return b or a end }
package.loaded["datastorage"] = { getSettingsDir = function() return "/tmp" end }
package.loaded["ffi/blitbuffer"] = Blitbuffer
package.loaded["ui/rendertext"] = {
    renderUtf8Text = function() end,
    sizeUtf8Text = function() return { x = 10 } end,
}
package.loaded["ui/time"] = { now = function() return 0 end, s = function(x) return x end }
local InputContainer = {}
InputContainer.__index = InputContainer
function InputContainer:extend(t)
    t.__index = t
    return setmetatable(t, { __index = InputContainer })
end
function InputContainer:new()
    local o = setmetatable({}, self)
    if o.init then o:init() end
    return o
end
function InputContainer:registerTouchZones(zones) self._zones = zones end
package.loaded["ui/widget/container/inputcontainer"] = InputContainer
package.loaded["ui/uimanager"] = {
    setDirty = function() end,
    scheduleIn = function() end,
    unschedule = function() end,
    show = function() end,
    close = function() end,
}

local SRC = arg[1] or "plugins/breakout.koplugin/breakoutdialog.lua"
local BreakoutDialog = assert(loadfile(SRC))()

-- ======================= 渲染 =======================
local BRICK_W = tonumber(assert(io.open(SRC)):read("*a"):match("local BRICK_W%s*=%s*(%d+)"))
local BRICK_H = tonumber(assert(io.open(SRC)):read("*a"):match("local BRICK_H%s*=%s*(%d+)"))

local dlg = BreakoutDialog:new()

-- 道具表直接从源码解析，保证和插件同源
local f = assert(io.open(SRC, "r"))
local text = f:read("*a")
f:close()
local items = {}
for line in text:gmatch("[^\n]+") do
    local norm = line:gsub("%s+", " ")
    local id, nm, rest = norm:match('{ id = "(%w+)", name = "([^"]+)", dur = %d+(.*) }')
    if id then
        items[#items + 1] = { id = id, name = nm, bad = rest:match("bad = true") ~= nil }
    end
end

local COLS = 3
local PAD = 8
local CELL_W = BRICK_W + PAD * 2
local CELL_H = BRICK_H + PAD * 2
local rows = math.ceil(#items / COLS)

local out = { ops = {}, labels = {}, w = COLS * CELL_W, h = rows * CELL_H }
for idx, it in ipairs(items) do
    local col = (idx - 1) % COLS
    local row = math.floor((idx - 1) / COLS)
    local x = col * CELL_W + PAD
    local y = row * CELL_H + PAD
    local before = #ops
    -- 线上代码：道具砖 = 黑砖 + 白图标
    dlg:drawBrick(Blitbuffer, { hp = 1, base = 1, power = true, item = it.id }, x, y)
    for i = before + 1, #ops do out.ops[#out.ops + 1] = ops[i] end
    out.labels[#out.labels + 1] = {
        x = x, y = y, size = BRICK_W, name = it.name, id = it.id, bad = it.bad,
        label_y = y + BRICK_H + 1,
    }
end

-- 输出 JSON（手写序列化，避开额外依赖）
local function esc(s) return (string.gsub(s, '"', '\\"')) end
local buf = {}
buf[#buf + 1] = '{"w":' .. out.w .. ',"h":' .. out.h .. ',"ops":['
for i, o in ipairs(out.ops) do
    if i > 1 then buf[#buf + 1] = "," end
    if o.op == "rect" then
        buf[#buf + 1] = string.format('{"o":"rect","x":%d,"y":%d,"w":%d,"h":%d,"c":%d,"bg":%d}',
            o.x, o.y, o.w, o.h, o.c, o.bg or 255)
    elseif o.op == "circle" then
        buf[#buf + 1] = string.format('{"o":"circle","x":%d,"y":%d,"r":%d,"c":%d,"b":%d,"bg":%d}',
            o.x, o.y, o.r, o.c, o.b or 0, o.bg or 255)
    else
        buf[#buf + 1] = string.format('{"o":"rr","x":%d,"y":%d,"w":%d,"h":%d,"c":%d,"r":%d,"bg":%d}',
            o.x, o.y, o.w, o.h, o.c, o.r or 0, o.bg or 255)
    end
end
buf[#buf + 1] = '],"labels":['
for i, l in ipairs(out.labels) do
    if i > 1 then buf[#buf + 1] = "," end
    buf[#buf + 1] = string.format('{"x":%d,"y":%d,"s":%d,"n":"%s","id":"%s","b":%d,"ly":%d}',
        l.x, l.y, l.size, esc(l.name), esc(l.id), l.bad and 1 or 0, l.label_y)
end
buf[#buf + 1] = ']}'
print(table.concat(buf))
