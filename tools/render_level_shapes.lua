--[[--
把关卡形状库渲染成图，用来肉眼验证"剪影到底像不像它叫的那个名字"。

做法和 render_powerup_icons.lua 一样：**直接调用插件里真正的 paintTo**，
用 mock blitbuffer 把绘图指令录成 JSON，再交给 Python 栅格化成 PNG。
验的是线上代码本身，不是副本。

用法：
  luajit tools/render_level_shapes.lua > /tmp/shapes_ops.json
  python3 tools/render_level_shapes.py /tmp/shapes_ops.json docs/screenshots/breakout_shapes.png
--]]--

-- ======================= Mock: Blitbuffer（只录指令） =======================
local ops = {}
local Blitbuffer = {
    COLOR_BLACK = 0x00, COLOR_WHITE = 0xFF,
    COLOR_GRAY_1 = 0x11, COLOR_GRAY_2 = 0x22, COLOR_GRAY_3 = 0x33,
    COLOR_GRAY_4 = 0x44, COLOR_GRAY_5 = 0x55, COLOR_GRAY_6 = 0x66,
    COLOR_GRAY_7 = 0x77, COLOR_GRAY_8 = 0x88, COLOR_GRAY_9 = 0x99,
    COLOR_GRAY_B = 0xBB, COLOR_LIGHT_GRAY = 0xCC, COLOR_GRAY_E = 0xEE,
}
-- 注意：插件里是 bb:paintRect(...) 冒号调用，第一个参数是 self
Blitbuffer.paintRect = function(_, x, y, w, h, color)
    ops[#ops + 1] = { op = "rect", x = x, y = y, w = w, h = h, c = color }
end
Blitbuffer.paintCircle = function(_, x, y, r, color, border)
    ops[#ops + 1] = { op = "circle", x = x, y = y, r = r, c = color, b = border }
end
Blitbuffer.paintRoundedRect = function(_, x, y, w, h, color, radius)
    ops[#ops + 1] = { op = "rr", x = x, y = y, w = w, h = h, c = color, r = radius }
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

-- ======================= 解析形状库 =======================
local f = assert(io.open(SRC, "r"))
local text = f:read("*a")
f:close()

local shapes = {}
for id, nm, body in text:gmatch('{ id = "([%w_]+)", name = "([^"]+)", mask = {(.-)} }') do
    local mask = {}
    for s in body:gmatch('"([.#]+)"') do mask[#mask + 1] = s end
    if #mask == 6 then
        shapes[#shapes + 1] = { id = id, name = nm, mask = mask }
    end
end

-- ======================= 逐个形状渲染 =======================
local frames = {}
for _, shape in ipairs(shapes) do
    local dlg = BreakoutDialog:new()
    -- 强制用这个形状：next_shape 是插件下一关要用的形状，这里塞进去就等于指定形状
    dlg.next_shape = shape
    dlg.level = 1
    dlg:loadLevel(1)
    -- 待发球状态：球停在挡板上，画面干净
    ops = {}
    dlg:paintTo(Blitbuffer, 0, 0)
    frames[#frames + 1] = {
        id = shape.id,
        name = shape.name,
        ops = ops,
        grid = { x = dlg.GRID_X, y = dlg.GRID_Y, w = dlg.GRID_W, h = dlg.GRID_H },
        n = dlg.bricks_left,
    }
end

-- ======================= 输出 JSON =======================
local function esc(s) return (string.gsub(s, '"', '\\"')) end
local buf = {}
buf[#buf + 1] = '{"frames":['
for fi, fr in ipairs(frames) do
    if fi > 1 then buf[#buf + 1] = "," end
    buf[#buf + 1] = string.format('{"id":"%s","name":"%s","n":%d,"grid":{"x":%d,"y":%d,"w":%d,"h":%d},"ops":[',
        esc(fr.id), esc(fr.name), fr.n, fr.grid.x, fr.grid.y, fr.grid.w, fr.grid.h)
    for i, o in ipairs(fr.ops) do
        if i > 1 then buf[#buf + 1] = "," end
        if o.op == "rect" then
            buf[#buf + 1] = string.format('{"o":"rect","x":%d,"y":%d,"w":%d,"h":%d,"c":%d}',
                o.x, o.y, o.w, o.h, o.c)
        elseif o.op == "circle" then
            buf[#buf + 1] = string.format('{"o":"circle","x":%d,"y":%d,"r":%d,"c":%d,"b":%d}',
                o.x, o.y, o.r, o.c, o.b or 0)
        else
            buf[#buf + 1] = string.format('{"o":"rr","x":%d,"y":%d,"w":%d,"h":%d,"c":%d,"r":%d}',
                o.x, o.y, o.w, o.h, o.c, o.r or 0)
        end
    end
    buf[#buf + 1] = ']}'
end
buf[#buf + 1] = ']}'
print(table.concat(buf))
