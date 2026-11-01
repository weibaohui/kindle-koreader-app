--[[--
军棋插件的无头逻辑测试台 (headless harness)

把 KOReader 的依赖全部 mock 掉，只跑纯游戏逻辑：
初始阵型 / 走法 / 吃子与大小比较 / 工兵挖雷 / 炮打炮架 / 炸弹同归于尽 /
吃旗获胜 / 隐藏信息（揭示与记忆）/ 悔棋回滚 / 存档往返 / 刷新脏区 / 绘制不崩。

用法: lua tools/sim_junqi.lua [插件路径]
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
Blitbuffer.paintRect = noop
Blitbuffer.paintCircle = noop
Blitbuffer.paintRoundedRect = noop

-- ======================= Mock: 其它 KOReader 模块 =======================
local SAVE_DIR = "/tmp/junqi_sim"
os.execute("mkdir -p " .. SAVE_DIR)
local FTS = 1e6
local clock = 0
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
package.loaded["ui/time"] = {
    now = function() clock = clock + 1000; return clock end,
    s = function(x) return math.floor(x * FTS) end,
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
local SRC = arg[1] or "plugins/junqi.koplugin/junqidialog.lua"
local JunqiDialog = assert(loadfile(SRC))()

local RED = JunqiDialog.RED
local BLACK = JunqiDialog.BLACK
local ROWS = JunqiDialog.ROWS
local COLS = JunqiDialog.COLS
local ROSTER = JunqiDialog.ROSTER

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

-- ======================= 场景辅助 =======================
--- 造一份干净对局（先删存档，避免上一个用例污染下一个）
local function fresh()
    os.remove(SAVE_DIR .. "/junqi_save.txt")
    return JunqiDialog:new()
end

local autoId = 1000
--- 在棋盘上摆一枚棋子（测试用）
local function put(d, r, c, t, s)
    autoId = autoId + 1
    d.board[r][c] = { t = t, s = s, id = autoId }
    return d.board[r][c]
end

--- 清空棋盘（只留自己要的棋子）
local function clearBoard(d)
    for r = 1, ROWS do
        for c = 1, COLS do
            d.board[r][c] = nil
        end
    end
end

local function countSide(d, side)
    local n = 0
    for r = 1, ROWS do
        for c = 1, COLS do
            local cell = d.board[r][c]
            if cell and cell.s == side then n = n + 1 end
        end
    end
    return n
end

local function typeCount(d, side, t)
    local n = 0
    for r = 1, ROWS do
        for c = 1, COLS do
            local cell = d.board[r][c]
            if cell and cell.s == side and cell.t == t then n = n + 1 end
        end
    end
    return n
end

local function boardDump(d)
    local parts = {}
    for r = 1, ROWS do
        local row = {}
        for c = 1, COLS do
            local cell = d.board[r][c]
            row[c] = cell and (cell.t .. ":" .. cell.s .. ":" .. cell.id) or "-"
        end
        parts[#parts + 1] = table.concat(row, ",")
    end
    return table.concat(parts, "|")
end

local function knownDump(tbl)
    local ids = {}
    for id, v in pairs(tbl) do
        if v then ids[#ids + 1] = id end
    end
    table.sort(ids)
    return table.concat(ids, ",")
end

--- 消息里是否包含某段文字
local function hasMsg(msg, text)
    return string.find(msg or "", text, 1, true) ~= nil
end

-- ======================= 场景 1: 初始阵型 =======================
section("场景 1: 初始阵型")
local d = fresh()

check("红方 16 枚棋子", countSide(d, RED) == 16, "实际 " .. countSide(d, RED))
check("黑方 16 枚棋子", countSide(d, BLACK) == 16, "实际 " .. countSide(d, BLACK))
check("双方合计 32 枚", countSide(d, RED) + countSide(d, BLACK) == 32)

local roster_ok_r, roster_ok_b = true, true
for t, n in pairs(ROSTER) do
    if typeCount(d, RED, t) ~= n then roster_ok_r = false end
    if typeCount(d, BLACK, t) ~= n then roster_ok_b = false end
end
check("红方兵种数量符合配置", roster_ok_r)
check("黑方兵种数量符合配置", roster_ok_b)

check("红方军旗在 (5,6)", d.board[5][6] and d.board[5][6].t == "军旗" and d.board[5][6].s == RED)
check("红方司令在 (5,7)", d.board[5][7] and d.board[5][7].t == "司令")
check("红方地雷在 (4,1)", d.board[4][1] and d.board[4][1].t == "地雷")
check("黑方军旗在 (1,6)", d.board[1][6] and d.board[1][6].t == "军旗" and d.board[1][6].s == BLACK)
check("黑方司令在 (1,7)", d.board[1][7] and d.board[1][7].t == "司令")
check("黑方前排在 (2,10)", d.board[2][10] and d.board[2][10].t == "工兵")

local camps_empty = true
for c = 1, COLS do
    if JunqiDialog.CAMP_COLS[c] then
        if d.board[3][c] then camps_empty = false end
    end
end
check("4 个行营 (row3: 2/5/8/11) 初始为空", camps_empty)
check("中间行初始无子", d.board[3][1] == nil and d.board[3][12] == nil)
check("初始无已揭示敌子", knownDump(d.known[RED]) == "" and knownDump(d.known[BLACK]) == "")
check("红方先行", d.turn == RED)

-- ======================= 场景 2: 走法 =======================
section("场景 2: 走法（普通棋子 / 工兵 / 不可动子）")
local m = fresh()
local ok, msg = m:tryMove(5, 8, 4, 8)   -- 师长向上一格
check("普通棋子可向上走一格", ok == true, tostring(msg))
check("走完后师长在新位置", m.board[4][8] and m.board[4][8].t == "师长")
check("原位置变空", m.board[5][8] == nil)

m = fresh()
ok, msg = m:tryMove(5, 8, 4, 9)         -- 师长斜走
check("普通棋子不能斜走", ok == false and hasMsg(msg, "只有工兵能斜走"), tostring(msg))

m = fresh()
ok, msg = m:tryMove(5, 8, 3, 8)         -- 师长走两格
check("普通棋子不能走两格", ok == false and hasMsg(msg, "只能走一格"), tostring(msg))

m = fresh()
ok, msg = m:tryMove(5, 8, 5, 7)         -- 走到自己的司令上
check("不能吃自己的棋子", ok == false and hasMsg(msg, "不能吃自己的棋子"), tostring(msg))

m = fresh()
ok, msg = m:tryMove(4, 3, 3, 2)         -- 工兵斜走一格（进入行营格）
check("工兵可斜走一格", ok == true, tostring(msg))
check("工兵落在斜向目标格", m.board[3][2] and m.board[3][2].t == "工兵")

m = fresh()
ok, msg = m:tryMove(4, 3, 2, 5)         -- 工兵斜走两格
check("工兵斜走两格被拒", ok == false, tostring(msg))

m = fresh()
ok, msg = m:tryMove(4, 1, 3, 1)         -- 地雷
check("地雷不能移动", ok == false and hasMsg(msg, "地雷不能移动"), tostring(msg))

m = fresh()
ok, msg = m:tryMove(5, 12, 4, 12)       -- 炸弹
check("炸弹不能移动", ok == false and hasMsg(msg, "炸弹不能移动"), tostring(msg))

m = fresh()
ok, msg = m:tryMove(5, 6, 4, 6)         -- 军旗
check("军旗不能移动", ok == false and hasMsg(msg, "军旗不能移动"), tostring(msg))

m = fresh()
m:tryMove(5, 8, 4, 8)                   -- 红走一步，轮到黑
ok, msg = m:tryMove(4, 8, 3, 8)         -- 红方再走
check("轮到黑方时红方不能走", ok == false and hasMsg(msg, "还没轮到"), tostring(msg))

-- ======================= 场景 3: 炮 =======================
section("场景 3: 炮（炮架规则）")
m = fresh()
clearBoard(m)
put(m, 3, 5, "炮", RED)
put(m, 3, 7, "排长", BLACK)
ok, msg = m:tryMove(3, 5, 3, 7)
check("炮没有炮架不能吃", ok == false and hasMsg(msg, "炮没有炮架"), tostring(msg))

m = fresh()
clearBoard(m)
put(m, 3, 5, "炮", RED)
put(m, 3, 6, "工兵", RED)
put(m, 3, 7, "排长", BLACK)
ok, msg = m:tryMove(3, 5, 3, 7)
check("炮隔一个炮架能吃子", ok == true, tostring(msg))
check("炮吃子后落在目标格", m.board[3][7] and m.board[3][7].t == "炮")
check("炮架留在原地", m.board[3][6] and m.board[3][6].t == "工兵")
check("被吃的子消失", m.board[3][7].t == "炮")

m = fresh()
clearBoard(m)
put(m, 3, 5, "炮", RED)
put(m, 3, 6, "排长", BLACK)
ok, msg = m:tryMove(3, 5, 3, 6)
check("炮不能直接吃相邻的子", ok == false and hasMsg(msg, "炮架"), tostring(msg))

m = fresh()
clearBoard(m)
put(m, 3, 5, "炮", RED)
ok, msg = m:tryMove(3, 5, 3, 6)
check("炮走空格和普通棋子一样走一格", ok == true, tostring(msg))

-- ======================= 场景 4: 大小比较 =======================
section("场景 4: 大小比较（大吃小 / 小吃大）")
m = fresh()
clearBoard(m)
put(m, 3, 5, "师长", RED)
put(m, 3, 6, "排长", BLACK)
ok, msg = m:tryMove(3, 5, 3, 6)
check("大棋子吃小棋子可以", ok == true, tostring(msg))
check("被吃子从棋盘消失", m.board[3][6].t == "师长")

m = fresh()
clearBoard(m)
put(m, 3, 5, "排长", RED)
put(m, 3, 6, "师长", BLACK)
ok, msg = m:tryMove(3, 5, 3, 6)
check("小棋子吃大棋子被拒", ok == false and hasMsg(msg, "排长吃不了师长"), tostring(msg))
check("被拒后棋盘不变", m.board[3][5].t == "排长" and m.board[3][6].t == "师长")

m = fresh()
m:tryMove(5, 8, 4, 8)
check("红走完轮到黑", m.turn == BLACK)
m:tryMove(1, 8, 2, 8)
check("黑走完轮到红", m.turn == RED)

-- ======================= 场景 5: 炸弹 =======================
section("场景 5: 炸弹（同归于尽）")
m = fresh()
clearBoard(m)
put(m, 3, 5, "师长", RED)
put(m, 3, 6, "炸弹", BLACK)
ok, msg = m:tryMove(3, 5, 3, 6)
check("撞上炸弹允许走这一步", ok == true, tostring(msg))
check("炸弹同归于尽：攻方消失", m.board[3][5] == nil)
check("炸弹同归于尽：守方消失", m.board[3][6] == nil)

-- ======================= 场景 6: 地雷 / 军旗 =======================
section("场景 6: 地雷与军旗")
m = fresh()
clearBoard(m)
put(m, 3, 5, "工兵", RED)
put(m, 3, 6, "地雷", BLACK)
ok, msg = m:tryMove(3, 5, 3, 6)
check("工兵挖雷成功", ok == true and hasMsg(msg, "挖雷"), tostring(msg))
check("地雷被挖掉", m.board[3][6] and m.board[3][6].t == "工兵" and m.board[3][5] == nil)

m = fresh()
clearBoard(m)
put(m, 3, 5, "师长", RED)
put(m, 3, 6, "地雷", BLACK)
ok, msg = m:tryMove(3, 5, 3, 6)
check("非工兵不能挖雷", ok == false and hasMsg(msg, "只有工兵能挖雷"), tostring(msg))

m = fresh()
clearBoard(m)
put(m, 3, 5, "师长", RED)
put(m, 3, 6, "军旗", BLACK)
ok, msg = m:tryMove(3, 5, 3, 6)
check("吃到军旗立即获胜", ok == true and m.winner == RED, tostring(msg) .. " winner=" .. tostring(m.winner))

m = fresh()
clearBoard(m)
put(m, 3, 5, "工兵", RED)
put(m, 3, 6, "军旗", BLACK)
ok, msg = m:tryMove(3, 5, 3, 6)
check("工兵挖旗也算获胜", ok == true and m.winner == RED, tostring(msg))

-- ======================= 场景 7: 隐藏信息 =======================
section("场景 7: 隐藏信息（？）")
m = fresh()
check("未相邻的敌子显示「？」", m:displayType(1, 6, RED) == "？")
check("自己的棋子永远显示真实兵种", m:displayType(5, 6, RED) == "军旗")

m = fresh()
clearBoard(m)
local redGeneral = put(m, 5, 6, "军长", RED)
local blackTeacher = put(m, 4, 6, "师长", BLACK)
local redRegt = put(m, 5, 8, "团长", RED)
local farBlack = put(m, 1, 1, "排长", BLACK)
check("相邻前敌子显示「？」", m:displayType(4, 6, RED) == "？")
ok = m:tryMove(5, 8, 5, 9)
check("走子后触发相邻揭示", ok == true and m.known[RED][blackTeacher.id] == true)
check("相邻后敌子显示真实兵种", m:displayType(4, 6, RED) == "师长")
check("未相邻的敌子仍是「？」", m:displayType(1, 1, RED) == "？")
check("揭示信息永久记住", m.known[RED][blackTeacher.id] == true)
-- 黑方把已揭示的子移走，身份跟着子走
m:tryMove(4, 6, 4, 7)
check("揭示的信息跟着棋子走", m:displayType(4, 7, RED) == "师长")

-- ======================= 场景 8: 悔棋 =======================
section("场景 8: 悔棋（含揭示信息回滚）")
m = fresh()
clearBoard(m)
put(m, 5, 6, "军长", RED)
local blackTeacher2 = put(m, 4, 6, "师长", BLACK)
put(m, 5, 8, "团长", RED)
m:tryMove(5, 8, 5, 9)
check("走子后已揭示敌子", m.known[RED][blackTeacher2.id] == true)
m:undo()
check("悔棋后棋子回到原位", m.board[5][8] and m.board[5][8].t == "团长" and m.board[5][9] == nil)
check("悔棋后轮次还原", m.turn == RED)
check("悔棋后步数还原", m.moves == 0)
check("悔棋回滚揭示信息", m.known[RED][blackTeacher2.id] == nil)
check("悔棋后敌子重新变回「？」", m:displayType(4, 6, RED) == "？")

m = fresh()
clearBoard(m)
put(m, 3, 5, "师长", RED)
put(m, 3, 6, "排长", BLACK)
m:tryMove(3, 5, 3, 6)
check("吃子后被吃的子消失", m.board[3][6].t == "师长")
m:undo()
check("悔棋恢复被吃的子", m.board[3][6] and m.board[3][6].t == "排长")
check("悔棋恢复攻方原位", m.board[3][5] and m.board[3][5].t == "师长")

-- ======================= 场景 9: 存档 =======================
section("场景 9: 存档往返")
local sd = fresh()
clearBoard(sd)
put(sd, 5, 6, "军长", RED)
local bEnemy = put(sd, 4, 6, "师长", BLACK)
put(sd, 5, 8, "团长", RED)
sd:tryMove(5, 8, 5, 9)
sd:saveGame()
local saved_board = boardDump(sd)
local saved_known = knownDump(sd.known[RED])
local saved_turn = sd.turn
local saved_moves = sd.moves
local saved_hist = #sd.history

local ld = JunqiDialog:new()          -- 直接读档
check("读档还原棋盘", boardDump(ld) == saved_board)
check("读档还原当前方", ld.turn == saved_turn)
check("读档还原步数", ld.moves == saved_moves)
check("读档还原已揭示信息", knownDump(ld.known[RED]) == saved_known)
check("读档还原悔棋栈", #ld.history == saved_hist)

-- 损坏存档 → 安全回落到初始阵型
local f = io.open(SAVE_DIR .. "/junqi_save.txt", "w")
f:write("v1\n乱写的\n")
f:close()
local bd = JunqiDialog:new()
check("损坏存档安全回落到初始阵型", countSide(bd, RED) == 16 and countSide(bd, BLACK) == 16)
check("损坏存档后步数归零", bd.moves == 0)

-- ======================= 场景 10: 刷新脏区 =======================
section("场景 10: 刷新脏区")
local rd = fresh()
dirty_regions = {}
rd:tryMove(5, 8, 4, 8)
rd:doRefresh()
local max_area = 0
for _, r in ipairs(dirty_regions) do
    if r.w and r.h then max_area = math.max(max_area, r.w * r.h) end
end
check("走一步只刷少量区域", #dirty_regions <= 4, "推了 " .. #dirty_regions .. " 个")
check("没有整屏级刷新", max_area < 600 * 800, "最大区域 " .. tostring(max_area))

-- 普通走子（没吃子）不该重画棋子清单面板
local rd2 = fresh()
dirty_regions = {}
rd2:tryMove(5, 8, 4, 8)               -- 红方普通走子（未吃子）
rd2:doRefresh()
check("普通走子只刷棋盘与状态条", #dirty_regions == 2, "推了 " .. #dirty_regions .. " 个")

dirty_regions = {}
rd:doRefresh()
check("无操作时不刷新", #dirty_regions == 0, "推了 " .. #dirty_regions .. " 个")

dirty_regions = {}
rd:tryMove(4, 8, 3, 8)
rd:doRefresh()
local buckets_left = 0
for _k, v in pairs(rd._dr) do
    if v then buckets_left = buckets_left + 1 end
end
check("脏区用完即清", buckets_left == 0, "还剩 " .. buckets_left .. " 个桶")

-- ======================= 场景 11: 绘制 =======================
section("场景 11: 绘制")
local pd = fresh()
local mockbb = { paintRect = function() end, paintCircle = function() end }
local painted = pcall(function() pd:paintTo(mockbb, 0, 0) end)
check("paintTo 不报错", painted)

-- ======================= 场景 12: 手势交互 =======================
section("场景 12: 手势交互（点选 / 走子 / 长按悔棋）")
local X0, Y0, CELL = JunqiDialog.X0, JunqiDialog.Y0, JunqiDialog.CELL

--- 模拟点击某个格子
local function tapCell(d, r, c)
    d:onTap(nil, { pos = { x = X0 + (c - 1) * CELL + 22, y = Y0 + (r - 1) * CELL + 22 } })
end
--- 模拟长按某个格子
local function holdCell(d, r, c)
    d:onHold(nil, { pos = { x = X0 + (c - 1) * CELL + 22, y = Y0 + (r - 1) * CELL + 22 } })
end

local ui = fresh()
tapCell(ui, 5, 8)                       -- 师长
check("点己方棋子即选中", ui.sel and ui.sel.r == 5 and ui.sel.c == 8)
check("选中后标出可走空格", #ui._targets > 0)
tapCell(ui, 4, 8)
check("点目标格完成走子", ui.board[4][8] and ui.board[4][8].t == "师长" and ui.board[5][8] == nil)
check("走子后清空选择", ui.sel == nil)
check("走子后换边", ui.turn == BLACK)

local ui2 = fresh()
tapCell(ui2, 5, 8)
tapCell(ui2, 3, 8)                     -- 目标太远
check("非法目标被拒绝", ui2.board[5][8] and ui2.board[5][8].t == "师长")
check("拒绝时保留选中", ui2.sel ~= nil)
check("拒绝时状态条给出原因", hasMsg(ui2.msg, "只能走一格"), tostring(ui2.msg))

local ui3 = fresh()
tapCell(ui3, 1, 6)                     -- 黑方军旗（未侦察）
check("点敌方子给出提示", hasMsg(ui3.msg, "黑方"), tostring(ui3.msg))

local ui4 = fresh()
tapCell(ui4, 5, 8)
tapCell(ui4, 4, 8)
check("长按前已走一步", ui4.moves == 1)
holdCell(ui4, 4, 8)
check("长按棋子触发悔棋", ui4.moves == 0 and ui4.board[5][8] and ui4.board[5][8].t == "师长")

local ui5 = fresh()
tapCell(ui5, 5, 8)
tapCell(ui5, 4, 8)
ui5:onTap(nil, { pos = { x = 440, y = 20 } })   -- 顶栏「新局」
check("顶栏新局重开一局", ui5.moves == 0 and ui5.turn == RED and countSide(ui5, RED) == 16)

-- ======================= 场景 13: 随机对局模糊测试 =======================
section("场景 13: 随机对局（不变量检查）")
math.randomseed(20261101)
local fz = fresh()
local steps = 0
for i = 1, 400 do
    local cand = {}
    for r = 1, ROWS do
        for c = 1, COLS do
            local cell = fz.board[r][c]
            if cell and cell.s == fz.turn then cand[#cand + 1] = { r = r, c = c } end
        end
    end
    if #cand == 0 then break end
    local from = cand[math.random(#cand)]
    local ok2 = fz:tryMove(from.r, from.c, math.random(ROWS), math.random(COLS))
    if ok2 then steps = steps + 1 end
    if fz.winner then break end
end
check("随机对局不崩溃", true)
check("步数与悔棋栈一致", fz.moves == #fz.history,
    "moves=" .. tostring(fz.moves) .. " history=" .. tostring(#fz.history))

local inv_ok = true
local detail = ""
for _, side in ipairs({ RED, BLACK }) do
    for t, n in pairs(ROSTER) do
        local got = typeCount(fz, side, t)
        if got > n then
            inv_ok = false
            detail = "side=" .. tostring(side) .. " " .. t .. "=" .. got
        end
    end
end
check("每方兵种数不超过初始配置", inv_ok, detail)
check("棋盘上总子数不超过 32", countSide(fz, RED) + countSide(fz, BLACK) <= 32)
check("随机对局产生了有效步数", steps > 0, "有效步 " .. steps)

-- ======================= 结果 =======================
print(string.format("\n========== 结果: %d 通过, %d 失败 ==========", pass, fail))
os.exit(fail == 0 and 0 or 1)