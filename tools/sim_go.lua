--[[--
围棋插件的无头逻辑测试台 (headless harness)

把 KOReader 的依赖全部 mock 掉，只跑纯游戏逻辑：
落子 / 提子（单子 + 整链）/ 禁自杀 / 简单打劫 / 停着与终局 / 面积法算分 /
悔棋（含提子与打劫回滚）/ 存档往返与损坏回落 / 脏区刷新。

用法: lua tools/sim_go.lua [插件路径]
--]]--

-- ======================= Mock: Blitbuffer =======================
local Blitbuffer = {
    COLOR_BLACK = 0x00, COLOR_WHITE = 0xFF,
    COLOR_GRAY_1 = 0x11, COLOR_GRAY_2 = 0x22, COLOR_GRAY_3 = 0x33,
    COLOR_GRAY_4 = 0x44, COLOR_GRAY_5 = 0x55, COLOR_GRAY_6 = 0x66,
    COLOR_GRAY_7 = 0x77, COLOR_GRAY_8 = 0x88, COLOR_GRAY_9 = 0x99,
    COLOR_GRAY = 0xAA, COLOR_GRAY_B = 0xBB, COLOR_LIGHT_GRAY = 0xCC,
    COLOR_GRAY_D = 0xDD, COLOR_GRAY_E = 0xEE,
}
local function noop() end
-- 记录绘制调用，供"绘制冒烟测试"检查（paintTo 里的坐标错误是上机才炸的坑）
local paint_log = {}
Blitbuffer.paintRect = function(bb, x, y, w, h, color)
    paint_log[#paint_log + 1] = { op = "rect", x = x, y = y, w = w, h = h, color = color }
end
Blitbuffer.paintCircle = function(bb, x, y, r, color)
    paint_log[#paint_log + 1] = { op = "circle", x = x, y = y, r = r, color = color }
end
Blitbuffer.paintRoundedRect = noop

-- ======================= Mock: 其它 KOReader 模块 =======================
local SAVE_DIR = "/tmp/go_sim"
os.execute("mkdir -p " .. SAVE_DIR)
package.loaded["device"] = {
    screen = {
        getWidth = function() return 600 end,
        getHeight = function() return 800 end,
    },
}
package.loaded["ui/font"] = { getFace = function() return {} end }
package.loaded["ui/geometry"] = { new = function(a, b) return b or a end }
-- GestureRange mock：插件用它声明 tap/hold 手势（见 ges_events）
package.loaded["ui/gesturerange"] = {
    new = function(_, o) return o end,
}
package.loaded["datastorage"] = { getSettingsDir = function() return SAVE_DIR end }
package.loaded["ffi/blitbuffer"] = Blitbuffer
package.loaded["ui/rendertext"] = {
    renderUtf8Text = function() end,
    sizeUtf8Text = function() return { x = 10, y_top = 8, y_bottom = 2 } end,
}

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
function InputContainer:onCloseWidget() end
package.loaded["ui/widget/container/inputcontainer"] = InputContainer

local dirty_regions = {}
package.loaded["ui/uimanager"] = {
    setDirty = function(_, widget, mode, region)
        if region then
            dirty_regions[#dirty_regions + 1] =
                { x = region.x, y = region.y, w = region.w, h = region.h }
        end
    end,
    scheduleIn = function() return {} end,
    unschedule = function() end,
    show = function() end,
    close = function() end,
}

-- ======================= 加载被测代码 =======================
local SRC = arg[1] or "plugins/go.koplugin/godialog.lua"
local GoDialog = assert(loadfile(SRC))()

-- ======================= 测试框架 =======================
local pass, fail = 0, 0
local function check(name, cond, detail)
    if cond then
        pass = pass + 1
        print(string.format("  ✅ %s", name))
    else
        fail = fail + 1
        print(string.format("  ❌ %s   %s", name, detail or ""))
    end
end
local function section(t) print("\n== " .. t .. " ==") end

--- 坐标 (r,c) → 棋盘下标（与插件内部一致：1..81）
local function I(r, c) return (r - 1) * 9 + c end

--- 造一份干净棋盘：先删存档，避免上一个用例的盘面污染下一个用例
local function freshDialog()
    os.remove(SAVE_DIR .. "/go_save.txt")
    local d = GoDialog:new()
    dirty_regions = {}
    return d
end

--- 统计"交叉点级"的脏区数量（棋盘脏区宽 52px，状态条/按钮/面板都是整行宽）
local function countPointRects()
    local n = 0
    for _, r in ipairs(dirty_regions) do
        if r.w and r.w <= 60 then n = n + 1 end
    end
    return n
end

local function boardEmpty(d)
    for i = 1, 81 do
        if d.board[i] ~= 0 then return false end
    end
    return true
end

-- ======================= 场景 1: 初始局面 =======================
section("场景 1: 初始局面")
local d = freshDialog()
check("棋盘 81 点全空", boardEmpty(d))
check("黑先（turn == 1）", d.turn == 1, "turn=" .. tostring(d.turn))
check("手数为 0", d.move_no == 0, "move_no=" .. tostring(d.move_no))
check("提子数 0:0", d.caps[1] == 0 and d.caps[2] == 0)
check("无劫点、无停着", d.ko == 0 and d.passes == 0)
check("悔棋栈为空", #d.history == 0)

-- ======================= 场景 2: 落子与换手 =======================
section("场景 2: 落子与换手")
local ok = d:playMove(I(5, 5))
check("黑方落子成功", ok == true and d.board[I(5, 5)] == 1)
check("手数变为 1", d.move_no == 1)
check("轮到白方", d.turn == 2, "turn=" .. tostring(d.turn))
check("最后一手记录在案", d.last == I(5, 5))
ok = d:playMove(I(4, 5))
check("白方落子成功", ok == true and d.board[I(4, 5)] == 2)
check("落子后回到黑方", d.turn == 1)
check("同一手不能连下（点已有子被拒）", d:playMove(I(5, 5)) == false)
check("非法落子后手数不变", d.move_no == 2)

-- ======================= 场景 3: 命中判定 =======================
section("场景 3: 命中判定（最近交叉点）")
local hd = freshDialog()
check("交叉点正中命中该点", hd:hitTest(76, 60) == I(1, 1))
check("偏移 20px 仍命中同一交叉点", hd:hitTest(96, 80) == I(1, 1))
check("第二个交叉点正确区分", hd:hitTest(132, 60) == I(1, 2))
check("棋盘外不命中", hd:hitTest(20, 20) == nil)
check("顶栏区域不命中", hd:hitTest(76, 30) == nil)
check("状态条区域不命中", hd:hitTest(300, 530) == nil)

-- ======================= 场景 4: 提子（单子） =======================
section("场景 4: 提子（单子）")
local c1 = freshDialog()
c1.board[I(5, 5)] = 2                 -- 白子只剩 (5,4) 一口气
c1.board[I(4, 5)] = 1
c1.board[I(6, 5)] = 1
c1.board[I(5, 6)] = 1
c1.turn = 1
ok = c1:playMove(I(5, 4))
check("落子提掉对方一子", ok == true and c1.board[I(5, 5)] == 0)
check("提子后提子数 +1", c1.caps[1] == 1, "caps=" .. tostring(c1.caps[1]))
check("提子后换手", c1.turn == 2)
check("非劫局面不产生劫点", c1.ko == 0)

-- ======================= 场景 5: 提子（整链） =======================
section("场景 5: 提子（整链）")
local c2 = freshDialog()
c2.board[I(5, 5)] = 2                 -- 两子相连的一整块
c2.board[I(5, 6)] = 2
c2.board[I(4, 5)] = 1
c2.board[I(4, 6)] = 1
c2.board[I(6, 5)] = 1
c2.board[I(6, 6)] = 1
c2.board[I(5, 4)] = 1
c2.turn = 1
ok = c2:playMove(I(5, 7))
check("整链两子被提掉", ok == true and c2.board[I(5, 5)] == 0 and c2.board[I(5, 6)] == 0)
check("提子数 +2", c2.caps[1] == 2, "caps=" .. tostring(c2.caps[1]))
check("提子后盘上只剩 7 个黑子 + 0 白子", (function()
    local b, w = 0, 0
    for i = 1, 81 do
        if c2.board[i] == 1 then b = b + 1 elseif c2.board[i] == 2 then w = w + 1 end
    end
    return b == 6 and w == 0
end)(), "盘面棋子数不对")

-- ======================= 场景 6: 禁着点（禁自杀） =======================
section("场景 6: 禁着点（禁自杀）")
local s1 = freshDialog()
s1.board[I(1, 2)] = 2
s1.board[I(2, 1)] = 2
s1.turn = 1
ok = s1:playMove(I(1, 1))
check("自杀点被拒绝", ok == false)
check("自杀后棋盘不变", s1.board[I(1, 1)] == 0)
check("自杀后手数不变", s1.move_no == 0)
check("自杀后换手不变（仍黑方）", s1.turn == 1)
check("自杀给出提示文案", string.find(s1.msg, "自杀") ~= nil, s1.msg)

-- ======================= 场景 7: 简单打劫 =======================
section("场景 7: 简单打劫")
-- 标准劫形：
--   白 (1,2)(2,1)(3,2) 围住 (2,2)，白 (2,3) 只剩 (2,2) 一口气
--   黑 (1,3)(3,3)(2,4)，黑下 (2,2) 提掉白 (2,3) 形成劫
local function koSetup()
    local k = freshDialog()
    k.board[I(2, 3)] = 2
    k.board[I(1, 2)] = 2
    k.board[I(3, 2)] = 2
    k.board[I(2, 1)] = 2
    k.board[I(1, 3)] = 1
    k.board[I(3, 3)] = 1
    k.board[I(2, 4)] = 1
    k.turn = 1
    return k
end
local k1 = koSetup()
ok = k1:playMove(I(2, 2))
check("黑提一子形成劫", ok == true and k1.board[I(2, 3)] == 0)
check("劫点记在被提点", k1.ko == I(2, 3), "ko=" .. tostring(k1.ko))
local ko_before = k1.ko
ok = k1:playMove(I(2, 3))
check("立即回提被拒绝", ok == false)
check("回提被拒后棋盘不变", k1.board[I(2, 3)] == 0 and k1.board[I(2, 2)] == 1)
check("回提被拒后换手不变", k1.turn == 2)
check("回提被拒后劫点不变", k1.ko == ko_before)
check("回提被拒有提示文案", string.find(k1.msg, "打劫") ~= nil, k1.msg)

-- 隔一手（白走别处、黑再走别处）后劫点解除
ok = k1:playMove(I(9, 9))
check("白方可以在别处落子", ok == true)
check("黑方落子后劫点解除", k1:playMove(I(9, 8)) == true and k1.ko == 0)
ok = k1:playMove(I(2, 3))
check("隔一手后可以回提", ok == true)
check("回提提掉黑子", k1.board[I(2, 2)] == 0)
check("回提后提子数白 +1", k1.caps[2] == 1, "caps=" .. tostring(k1.caps[2]))

-- ======================= 场景 8: 悔棋 =======================
section("场景 8: 悔棋")
local u1 = freshDialog()
u1:playMove(I(5, 5))
u1:playMove(I(4, 5))
u1:undo()
check("撤销后该点变空", u1.board[I(4, 5)] == 0)
check("撤销后手数回退", u1.move_no == 1)
check("撤销后轮到被撤销那一方", u1.turn == 2, "turn=" .. tostring(u1.turn))
check("撤销后最后一手回退", u1.last == I(5, 5))

-- 撤销提子：被提的子要放回去
local u2 = freshDialog()
u2.board[I(5, 5)] = 2
u2.board[I(4, 5)] = 1
u2.board[I(6, 5)] = 1
u2.board[I(5, 6)] = 1
u2.turn = 1
u2:playMove(I(5, 4))
check("先确认提子发生", u2.board[I(5, 5)] == 0)
u2:undo()
check("撤销提子后白子被放回", u2.board[I(5, 5)] == 2)
check("撤销提子后落子点变空", u2.board[I(5, 4)] == 0)
check("撤销提子后提子数回退", u2.caps[1] == 0)

-- 撤销打劫：劫点要一起回滚
local u3 = koSetup()
u3:playMove(I(2, 2))
check("先形成劫点", u3.ko == I(2, 3))
u3:undo()
check("撤销后劫点回滚为 0", u3.ko == 0)
check("撤销后被提的白子复原", u3.board[I(2, 3)] == 2)
check("撤销后落子点变空", u3.board[I(2, 2)] == 0)
check("撤销后回到黑方", u3.turn == 1)

-- ======================= 场景 9: 停着与终局 =======================
section("场景 9: 停着与终局")
local p1 = freshDialog()
p1:doPass()
check("停着后连续停着计数 = 1", p1.passes == 1)
check("停着后手数 +1", p1.move_no == 1)
check("停着后换手", p1.turn == 2)
p1:doPass()
check("连续两次停着 = 终局", p1.over == true)
check("终局给出算分结果", p1.result ~= nil)
check("终局后不能再落子", p1:playMove(I(5, 5)) == false)
check("终局后棋盘不变", p1.board[I(5, 5)] == 0)
p1:undo()
check("终局后可以悔棋重开", p1.over == false and p1.passes == 1)

-- ======================= 场景 10: 面积法算分 =======================
section("场景 10: 面积法算分")
-- 黑: (4,5)(5,4)(5,6)(6,5) 围住 (5,5) 一只眼；白: 右下 2x2
-- 盘上其余空区同时挨着黑白 → 中立
local sc = freshDialog()
sc.board[I(4, 5)] = 1
sc.board[I(5, 4)] = 1
sc.board[I(5, 6)] = 1
sc.board[I(6, 5)] = 1
sc.board[I(8, 8)] = 2
sc.board[I(8, 9)] = 2
sc.board[I(9, 8)] = 2
sc.board[I(9, 9)] = 2
local r = GoDialog.computeScore(sc.board)
check("黑目数 = 4 子 + 1 眼 = 5", r.black == 5, "black=" .. tostring(r.black))
check("白目数 = 4 子 + 0 地 = 4", r.white == 4, "white=" .. tostring(r.white))
check("目数差 = 1", r.diff == 1, "diff=" .. tostring(r.diff))
check("黑胜", r.winner == 1)
local r0 = GoDialog.computeScore({})
check("空盘算分 0:0 和棋", r0.black == 0 and r0.white == 0 and r0.winner == 0)

-- ======================= 场景 11: 存档往返 =======================
section("场景 11: 存档往返")
local sd = freshDialog()
sd:playMove(I(5, 5))
sd:playMove(I(4, 5))
sd:playMove(I(6, 5))
sd:playMove(I(3, 5))
local saved_board = table.concat(sd.board, ",")
local ld = GoDialog:new()
dirty_regions = {}
check("读档还原棋盘", table.concat(ld.board, ",") == saved_board)
check("读档还原手数", ld.move_no == sd.move_no)
check("读档还原当前方", ld.turn == sd.turn)
check("读档还原提子数", ld.caps[1] == sd.caps[1] and ld.caps[2] == sd.caps[2])
check("读档还原最后一手", ld.last == sd.last)
check("读档还原悔棋栈", #ld.history == #sd.history)
check("读档还原悔棋栈内容", #ld.history == 4 and ld.history[1].idx == I(5, 5))

-- ======================= 场景 12: 损坏存档 =======================
section("场景 12: 损坏存档安全回落")
local bad = freshDialog()
local bf = io.open(SAVE_DIR .. "/go_save.txt", "w")
bf:write("这不是一个存档文件\n而且只有一行\n")
bf:close()
check("损坏存档 loadGame 返回 false", bad:loadGame() == false)
local bad2 = GoDialog:new()
check("损坏存档回落到空盘", boardEmpty(bad2))
check("损坏存档回落到黑先", bad2.turn == 1)
check("损坏存档回落到手数 0", bad2.move_no == 0)

-- ======================= 场景 13: 脏区刷新 =======================
section("场景 13: 脏区刷新")
local rd = freshDialog()
dirty_regions = {}
rd:playMove(I(5, 5))
check("落子只刷 1 个交叉点", countPointRects() == 1, "刷了 " .. countPointRects() .. " 个")
local max_area = 0
for _, r in ipairs(dirty_regions) do
    if r.w and r.h then max_area = math.max(max_area, r.w * r.h) end
end
check("没有整屏级刷新", max_area < 600 * 800, "最大区域 " .. tostring(max_area))

dirty_regions = {}
rd:doRefresh()
check("无操作时不刷新", #dirty_regions == 0, "推了 " .. #dirty_regions .. " 个")

-- 提子时：落子点 + 被提子的点都要刷
local rc = freshDialog()
rc.board[I(5, 5)] = 2
rc.board[I(4, 5)] = 1
rc.board[I(6, 5)] = 1
rc.board[I(5, 6)] = 1
rc.turn = 1
dirty_regions = {}
rc:playMove(I(5, 4))
check("提子刷 2 个交叉点（落子点 + 被提点）", countPointRects() == 2,
    "刷了 " .. countPointRects() .. " 个")

-- 悔棋也要刷对应的点
dirty_regions = {}
rc:undo()
check("悔棋刷回落子点与被提点", countPointRects() == 2, "刷了 " .. countPointRects() .. " 个")

-- ======================= 场景 14: 盘满自动终局 =======================
section("场景 14: 盘满自动终局")
local full = freshDialog()
for i = 1, 81 do full.board[i] = 1 end
check("盘面已满检测正确", full:isBoardFull() == true)
full:finishGame()
check("盘满后终局并给出算分", full.over == true and full.result ~= nil)
check("盘满算分黑 81 : 0 白", full.result.black == 81 and full.result.white == 0,
    "black=" .. tostring(full.result.black) .. " white=" .. tostring(full.result.white))

-- ======================= 场景 15: 绘制冒烟测试 =======================
section("场景 15: 绘制冒烟测试（paintTo 不炸、坐标合法）")
local pd = freshDialog()
pd.board[I(1, 1)] = 1          -- 黑子（左上角，非星位）
pd.board[I(4, 5)] = 2          -- 白子（最后一手）
pd.last = I(4, 5)
paint_log = {}
local ok_paint, err_paint = pcall(function() pd:paintTo(Blitbuffer, 0, 0) end)
check("paintTo 不报错", ok_paint, tostring(err_paint))
check("绘制有内容", #paint_log > 20, "只画了 " .. #paint_log .. " 个元素")
local first = paint_log[1]
check("先铺满全屏底色", first and first.op == "rect" and first.x == 0 and first.y == 0
    and first.w == 600 and first.h == 800,
    first and (tostring(first.op) .. " " .. tostring(first.w) .. "x" .. tostring(first.h)) or "无")
local out_of_screen = 0
local bad_size = 0
for _, e in ipairs(paint_log) do
    if e.op == "rect" then
        if e.w <= 0 or e.h <= 0 then bad_size = bad_size + 1 end
        if e.x < 0 or e.y < 0 or e.x + e.w > 601 or e.y + e.h > 801 then out_of_screen = out_of_screen + 1 end
    else
        if e.r <= 0 then bad_size = bad_size + 1 end
        if e.x - e.r < -1 or e.x + e.r > 601 or e.y - e.r < -1 or e.y + e.r > 801 then
            out_of_screen = out_of_screen + 1
        end
    end
end
check("没有零尺寸/负尺寸图元", bad_size == 0, "有 " .. bad_size .. " 个")
check("没有画到屏幕外", out_of_screen == 0, "有 " .. out_of_screen .. " 个")

--- 取某个屏幕坐标上画的所有圆
local function circlesAt(px, py)
    local t = {}
    for _, e in ipairs(paint_log) do
        if e.op == "circle" and e.x == px and e.y == py then t[#t + 1] = e end
    end
    return t
end
--- 是否存在某个 (半径, 颜色) 的圆
local function hasCircle(list, r, color)
    for _, e in ipairs(list) do
        if e.r == r and e.color == color then return true end
    end
    return false
end

-- 黑子 = 实心黑圆（单个圆）
local bx, by = 76, 60
local bcs = circlesAt(bx, by)
check("黑子 = 实心黑圆", #bcs == 1 and hasCircle(bcs, 22, Blitbuffer.COLOR_BLACK),
    "画了 " .. #bcs .. " 个圆")
-- 白子 = 黑圆打底 + 白圆盖上（2px 黑描边环）+ 最后一手黑点标记
local wx, wy = 76 + 4 * 56, 60 + 3 * 56
local wcs = circlesAt(wx, wy)
check("白子 = 黑底圆 + 白面圆（描边环）", hasCircle(wcs, 23, Blitbuffer.COLOR_BLACK)
    and hasCircle(wcs, 22, Blitbuffer.COLOR_WHITE),
    "画了 " .. #wcs .. " 个圆")
check("最后一手在白子上叠黑点标记", hasCircle(wcs, 6, Blitbuffer.COLOR_BLACK),
    "没有标记点")
-- 终局面板也要能画出来
pd:finishGame()
paint_log = {}
local ok_paint2, err_paint2 = pcall(function() pd:paintTo(Blitbuffer, 0, 0) end)
check("终局面板 paintTo 不报错", ok_paint2, tostring(err_paint2))

-- ======================= 结果 =======================
print(string.format("\n========== 结果: %d 通过, %d 失败 ==========", pass, fail))
os.exit(fail == 0 and 0 or 1)
