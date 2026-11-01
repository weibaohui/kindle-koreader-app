--[[--
国际象棋插件的无头逻辑测试台 (headless harness)

把 KOReader 的依赖全部 mock 掉，只跑纯游戏逻辑：
初始局面 / 各类棋子走法 / 特殊规则（易位·吃过路兵·升变·将军将死和棋·三次重复）
/ 悔棋 / 存档往返 / 脏区刷新。

用法: lua tools/sim_chess.lua [插件路径]
--]]

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
local SAVE_DIR = "/tmp/chess_sim"
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
local SRC = arg[1] or "plugins/chess.koplugin/chessdialog.lua"
local ChessDialog = assert(loadfile(SRC))()
local Engine = ChessDialog.Engine

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

-- ======================= 测试辅助 =======================
--- 造一个干净的局面（先删存档，避免上一个用例污染下一个用例）
local function freshDialog()
    os.remove(SAVE_DIR .. "/chess_save.txt")
    return ChessDialog:new()
end

--- 自定义局面：pos({{"k","a1"},{"R","a8"}}, "w", {w_k=true})
local function pos(list, turn, castle)
    return Engine.stateFromMap(list, turn or "w", castle)
end

local function hasMove(st, from, to)
    return Engine.findMove(st, from, to) ~= nil
end

local function moveCountFrom(st, from)
    local r, f = Engine.parseSquare(from)
    return #Engine.movesFrom(st, r, f)
end

--- 把局面拍平成一行字符串，方便比较
local function boardStr(st)
    local s = ""
    for r = 1, 8 do
        for f = 1, 8 do s = s .. st.board[r][f] end
    end
    return s
end

--- 让对话框走一步（找不到合法着法就报错）
local function play(d, from, to)
    local mv = Engine.findMove(d.st, from, to)
    assert(mv, ("没有合法着法 %s→%s"):format(from, to))
    d:makeMove(mv)
    return mv
end

-- ======================= 场景 1: 初始局面 =======================
section("场景 1: 初始局面")
local d0 = freshDialog()
local st0 = d0.st
local pieces = 0
for r = 1, 8 do
    for f = 1, 8 do
        if st0.board[r][f] ~= "." then pieces = pieces + 1 end
    end
end
check("初始局面共 32 子", pieces == 32, "实际 " .. pieces)

local whiteBack = "rnbqkbnr"
local blackBack = "RNBQKBNR"
local backOk = true
for f = 1, 8 do
    if st0.board[1][f] ~= whiteBack:sub(f, f) then backOk = false end
    if st0.board[8][f] ~= blackBack:sub(f, f) then backOk = false end
end
check("双方底线棋子位置正确", backOk)
check("白王在 e1，黑王在 e8", st0.board[1][5] == "k" and st0.board[8][5] == "K")
check("白后在 d1，黑后在 d8", st0.board[1][4] == "q" and st0.board[8][4] == "Q")

local pawnOk = true
for f = 1, 8 do
    if st0.board[2][f] ~= "p" or st0.board[7][f] ~= "P" then pawnOk = false end
end
for r = 3, 6 do
    for f = 1, 8 do
        if st0.board[r][f] ~= "." then pawnOk = false end
    end
end
check("白兵在第 2 级、黑兵在第 7 级，中间四排为空", pawnOk)
check("初始轮到白方走", st0.turn == "w")
check("初始四方王车易位权都在",
    st0.castling.w_k and st0.castling.w_q and st0.castling.b_k and st0.castling.b_q)

-- ======================= 场景 2: 各棋子的走法 =======================
section("场景 2: 各棋子的走法")

-- 马：走日 + 蹩马腿
local stN = pos({ { "n", "e4" }, { "K", "h8" } })
check("马可以走日字 e4→g5", hasMove(stN, "e4", "g5"))
check("马可以走日字 e4→c3", hasMove(stN, "e4", "c3"))
check("马不能走 e4→g6（非日字）", not hasMove(stN, "e4", "g6"))
-- 国际象棋规则：马可以跳过棋子（初始局面的 Nf3/Nc3 都合法）
local stInit = Engine.newState()
check("马可以跳过己方棋子（初始局面 Nf3 合法）", hasMove(stInit, "g1", "f3"))
check("马可以跳过己方棋子（初始局面 Nc3 合法）", hasMove(stInit, "b1", "c3"))
-- 蹩马腿规则已实现，但默认关闭（国际象棋规则）
local stNBlock = pos({ { "n", "e4" }, { "p", "f5" }, { "K", "h8" } })
check("默认（国际象棋规则）马不被腿挡住 e4→g5", hasMove(stNBlock, "e4", "g5"))
Engine.knightLegBlock = true
check("打开蹩马腿开关后，马腿被占时不能跳（f5 挡住 e4→g5）",
    not hasMove(stNBlock, "e4", "g5"))
Engine.knightLegBlock = false
check("关闭开关后马恢复自由跳跃", hasMove(stNBlock, "e4", "g5"))

-- 王：只能走一格
local stK = pos({ { "k", "e4" }, { "K", "h8" } })
check("王可以斜走一格 e4→d5", hasMove(stK, "e4", "d5"))
check("王不能走两格 e4→d6", not hasMove(stK, "e4", "d6"))
check("王不能原地不动", not hasMove(stK, "e4", "e4"))

-- 车：直线
local stR = pos({ { "r", "a4" }, { "K", "h8" } })
check("车可以走直线 a4→a7", hasMove(stR, "a4", "a7"))
check("车不能拐弯 a4→c5", not hasMove(stR, "a4", "c5"))
local stRBlock = pos({ { "r", "a4" }, { "p", "a5" }, { "K", "h8" } })
check("车被挡住时不能穿子 a4→a7", not hasMove(stRBlock, "a4", "a7"))

-- 象：斜线，不能塞眼
local stB = pos({ { "b", "c4" }, { "K", "h8" } })
check("象可以走斜线 c4→f7", hasMove(stB, "c4", "f7"))
check("象不能走直线 c4→c7", not hasMove(stB, "c4", "c7"))
local stBBlock = pos({ { "b", "c4" }, { "n", "d5" }, { "K", "h8" } })
check("象被塞住眼时不能穿子 c4→f7", not hasMove(stBBlock, "c4", "f7"))

-- 后：直线 + 斜线
local stQ = pos({ { "q", "d4" }, { "K", "a1" } })
check("后可以走直线 d4→d7", hasMove(stQ, "d4", "d7"))
check("后可以走斜线 d4→h8", hasMove(stQ, "d4", "h8"))
check("后不能走折线 d4→f5", not hasMove(stQ, "d4", "f5"))

-- 兵：直走一格 / 初始两格 / 不能后退 / 斜吃
local stP = pos({ { "p", "e2" }, { "K", "h8" } })
check("兵可以直走一格 e2→e3", hasMove(stP, "e2", "e3"))
check("兵初始可以走两格 e2→e4", hasMove(stP, "e2", "e4"))
local stP3 = pos({ { "p", "e3" }, { "K", "h8" } })
check("兵不在初始位置不能走两格 e3→e5", not hasMove(stP3, "e3", "e5"))
check("兵可以直走一格 e3→e4", hasMove(stP3, "e3", "e4"))
local stPBack = pos({ { "p", "e4" }, { "K", "h8" } })
check("兵不能后退 e4→e3", not hasMove(stPBack, "e4", "e3"))
check("兵可以前进 e4→e5", hasMove(stPBack, "e4", "e5"))
local stPCap = pos({ { "p", "e4" }, { "R", "d5" }, { "K", "h8" } })
check("兵可以斜吃 e4×d5", hasMove(stPCap, "e4", "d5"))
check("兵不能斜走到空格 e4→d5", not hasMove(stPBack, "e4", "d5"))
check("兵不能直着吃子 e4×d5 方向错",
    not hasMove(pos({ { "p", "e4" }, { "r", "e5" }, { "K", "h8" } }), "e4", "e5"))

-- 自己的子不能吃
local stOwn = pos({ { "k", "d4" }, { "r", "d5" }, { "K", "h8" } })
check("不能吃自己的子", not hasMove(stOwn, "d4", "d5"))

-- 永远不生成吃王的着法
local stKingCap = pos({ { "k", "d4" }, { "K", "d5" } })
local kingTaken = false
for _, mv in ipairs(Engine.pseudoMoves(stKingCap)) do
    if mv.captured and Engine.pieceType(mv.captured) == "K" then kingTaken = true end
end
check("走法生成永不吃对方王", not kingTaken)

-- ======================= 场景 3: 送将与王的安全 =======================
section("场景 3: 送将与王的安全")
local stAtt = pos({ { "k", "e1" }, { "R", "f3" }, { "K", "h8" } })
check("王不能走进被攻击的格 e1→f1", not hasMove(stAtt, "e1", "f1"))
check("王不能走进被攻击的格 e1→f2", not hasMove(stAtt, "e1", "f2"))
check("王可以走到安全格 e1→e2", hasMove(stAtt, "e1", "e2"))

local stPin = pos({ { "k", "e1" }, { "n", "e2" }, { "R", "e8" }, { "K", "h8" } })
check("被钉住的马一步都不能走", moveCountFrom(stPin, "e2") == 0,
    "能走 " .. moveCountFrom(stPin, "e2") .. " 步")
check("被将军的一方必须应将（王仍可走 d1/f1）",
    hasMove(stPin, "e1", "d1") and hasMove(stPin, "e1", "f1"))

-- ======================= 场景 4: 王车易位 =======================
section("场景 4: 王车易位")
local stCK = pos({ { "k", "e1" }, { "r", "h1" }, { "K", "e8" } }, "w", { w_k = true })
check("白方短易位 e1→g1 合法", hasMove(stCK, "e1", "g1"))
local stCK2 = pos({ { "k", "e1" }, { "K", "e8" } }, "w", { w_k = true })
check("没有车时不能易位", not hasMove(stCK2, "e1", "g1"))
local stCK3 = pos({ { "k", "e1" }, { "r", "h1" }, { "n", "g1" }, { "K", "e8" } }, "w", { w_k = true })
check("易位路径被挡时不能易位", not hasMove(stCK3, "e1", "g1"))
local stCK4 = pos({ { "k", "e1" }, { "r", "h1" }, { "R", "e8" }, { "K", "h8" } }, "w", { w_k = true })
check("王正被将军时不能易位", not hasMove(stCK4, "e1", "g1"))
local stCK5 = pos({ { "k", "e1" }, { "r", "h1" }, { "R", "f8" }, { "K", "h8" } }, "w", { w_k = true })
check("经过的格子被攻击时不能易位（f1 被 f8 车攻击）", not hasMove(stCK5, "e1", "g1"))
local stCK6 = pos({ { "k", "e1" }, { "r", "h1" }, { "R", "g8" }, { "K", "h8" } }, "w", { w_k = true })
check("落点被攻击时不能易位（g1 被 g8 车攻击）", not hasMove(stCK6, "e1", "g1"))
local stCQ = pos({ { "k", "e1" }, { "r", "a1" }, { "K", "e8" } }, "w", { w_q = true })
check("白方长易位 e1→c1 合法", hasMove(stCQ, "e1", "c1"))
local stNoRight = pos({ { "k", "e1" }, { "r", "h1" }, { "K", "e8" } }, "w", {})
check("没有易位权时不能易位", not hasMove(stNoRight, "e1", "g1"))

-- 易位后王和车的位置
local castleState = Engine.applyMove(stCK, Engine.findMove(stCK, "e1", "g1"))
check("短易位后白王在 g1", castleState.board[1][7] == "k")
check("短易位后白车在 f1", castleState.board[1][6] == "r")
check("短易位后清空白方易位权",
    (not castleState.castling.w_k) and (not castleState.castling.w_q))

-- ======================= 场景 5: 吃过路兵 =======================
section("场景 5: 吃过路兵")
local stEP = pos({ { "p", "e5" }, { "P", "d5" }, { "k", "a1" }, { "K", "h8" } }, "w")
stEP.ep = { r = 6, f = 4 }
check("可以吃过路兵 e5×d6", hasMove(stEP, "e5", "d6"))
local epState = Engine.applyMove(stEP, Engine.findMove(stEP, "e5", "d6"))
check("吃过路兵后白兵在 d6", epState.board[6][4] == "p")
check("吃过路兵后黑兵被从 d5 吃掉", epState.board[5][4] == ".")
local stNoEP = pos({ { "p", "e5" }, { "P", "d5" }, { "k", "a1" }, { "K", "h8" } }, "w")
check("没有吃过路兵目标时不能斜吃空格", not hasMove(stNoEP, "e5", "d6"))

-- ======================= 场景 6: 升变 =======================
section("场景 6: 升变为后")
local stPro = pos({ { "p", "a7" }, { "k", "h1" }, { "K", "h8" } })
check("兵可以走到底线 a7→a8", hasMove(stPro, "a7", "a8"))
local proState = Engine.applyMove(stPro, Engine.findMove(stPro, "a7", "a8"))
check("到底线自动升变为后（q）", proState.board[8][1] == "q",
    "实际 " .. tostring(proState.board[8][1]))
local stProB = pos({ { "P", "a2" }, { "k", "h1" }, { "K", "h8" } }, "b")
local proStateB = Engine.applyMove(stProB, Engine.findMove(stProB, "a2", "a1"))
check("黑兵到底线升变为黑后（Q）", proStateB.board[1][1] == "Q",
    "实际 " .. tostring(proStateB.board[1][1]))

-- ======================= 场景 7: 将军 / 将死 / 和棋 =======================
section("场景 7: 将军 / 将死 / 和棋")
local stCheck = pos({ { "k", "e1" }, { "R", "e8" }, { "K", "h8" } })
check("e8 的车让白王被将军", Engine.inCheck(stCheck, "w"))
check("无子时不算将军", not Engine.inCheck(pos({ { "k", "e1" }, { "K", "h8" } }), "w"))

local stMate = pos({ { "k", "a1" }, { "R", "a8" }, { "R", "b8" }, { "K", "h8" } })
local mateStatus = Engine.gameStatus(stMate)
check("被将死时判定为黑方胜",
    mateStatus.over and mateStatus.result == "黑方胜" and mateStatus.reason == "将死",
    tostring(mateStatus.result) .. "/" .. tostring(mateStatus.reason))

local stStale = pos({ { "k", "a1" }, { "R", "c2" }, { "R", "b8" }, { "K", "h8" } })
local staleStatus = Engine.gameStatus(stStale)
check("无子可走又未被将军判为和棋（逼和）",
    staleStatus.over and staleStatus.result == "和棋",
    tostring(staleStatus.result) .. "/" .. tostring(staleStatus.reason))

local stPlaying = pos({ { "k", "e1" }, { "r", "a1" }, { "K", "h8" } })
check("正常局面不算结束", not Engine.gameStatus(stPlaying).over)

-- ======================= 场景 8: 对话框交互 =======================
section("场景 8: 对话框交互（选子 / 走子 / 非法提示）")
local d = freshDialog()
-- 棋盘坐标：e2 → 屏幕 (332, 472)，e4 → (332, 344)
check("屏幕坐标能换算回代数格",
    (function()
        local r, f = d:squareAt(332, 472)
        return r == 2 and f == 5
    end)())
d:onTap(nil, { pos = { x = 332, y = 472 } })
check("点自己的子会选中", d.sel ~= nil and d.sel.r == 2 and d.sel.f == 5)
check("选中后列出全部合法落点（e3/e4 共 2 个）", #d.sel_moves == 2,
    "实际 " .. #d.sel_moves)
d:onTap(nil, { pos = { x = 332, y = 344 } })
check("点落点后棋子走到 e4", d.st.board[4][5] == "p" and d.st.board[2][5] == ".")
check("走完之后轮到黑方", d.st.turn == "b")
check("走完之后取消选中", d.sel == nil)

-- 非法着法要给出原因，不能静默
local d2 = freshDialog()
d2:onTap(nil, { pos = { x = 332, y = 472 } })   -- 选 e2
d2:onTap(nil, { pos = { x = 332, y = 216 } })   -- 点 e5（兵不能走三格）
check("非法着法后状态条有提示文案", d2.message ~= "", "message=" .. tostring(d2.message))
check("非法着法不会改动棋盘", d2.st.board[2][5] == "p" and d2.st.board[5][5] == ".")

-- 长按棋子 = 悔棋
local d3 = freshDialog()
play(d3, "e2", "e4")
check("悔棋前白兵在 e4", d3.st.board[4][5] == "p")
d3:onHold(nil, { pos = { x = 332, y = 344 } })
check("长按棋子可以悔棋（白兵退回 e2）",
    d3.st.board[2][5] == "p" and d3.st.board[4][5] == ".")
check("悔棋后轮到白方", d3.st.turn == "w")

-- ======================= 场景 9: 悔棋 =======================
section("场景 9: 悔棋回退")
local d4 = freshDialog()
local before = boardStr(d4.st)
play(d4, "e2", "e4")
play(d4, "e7", "e5")
check("连走两步后棋盘变了", boardStr(d4.st) ~= before)
d4:undo()
check("悔棋一步后轮到黑方", d4.st.turn == "b")
d4:undo()
check("悔棋两步后完全回到初始局面", boardStr(d4.st) == before)
check("悔棋后步数归零", d4.st.half == 0)
check("悔棋到空时给出提示",
    (function()
        d4:undo()
        return d4.message ~= ""
    end)())

-- ======================= 场景 10: 三次重复局面 =======================
section("场景 10: 三次重复局面判和")
local d5 = freshDialog()
play(d5, "g1", "f3")
play(d5, "g8", "f6")
play(d5, "f3", "g1")
play(d5, "f6", "g8")
check("重复两次还不算和棋", not d5.game_status.over)
play(d5, "g1", "f3")
play(d5, "g8", "f6")
play(d5, "f3", "g1")
play(d5, "f6", "g8")
check("同一局面出现三次判和棋",
    d5.game_status.over and d5.game_status.result == "和棋",
    tostring(d5.game_status.result) .. "/" .. tostring(d5.game_status.reason))

-- ======================= 场景 11: 存档往返 =======================
section("场景 11: 存档往返")
local d6 = freshDialog()
play(d6, "e2", "e4")
play(d6, "a7", "a5")
play(d6, "e4", "e5")
play(d6, "d7", "d5")
play(d6, "e5", "d6")      -- 吃过路兵
play(d6, "g8", "f6")
play(d6, "g1", "f3")
play(d6, "b8", "c6")
play(d6, "b1", "c3")
play(d6, "f6", "g8")
play(d6, "f1", "c4")
play(d6, "g8", "f6")
play(d6, "e1", "g1")      -- 白方短易位
d6:saveGame()
local savedBoard = boardStr(d6.st)
local savedTurn = d6.st.turn
local savedHalf = d6.st.half
local function castleStr(c)
    return tostring(c.w_k) .. tostring(c.w_q) .. tostring(c.b_k) .. tostring(c.b_q)
end
local savedCastle = castleStr(d6.st.castling)
local savedLast = d6.last_move.fr .. "," .. d6.last_move.ff .. ","
    .. d6.last_move.tr .. "," .. d6.last_move.tf .. "," .. d6.last_move.piece
check("测试局面里真的走了易位", d6.last_move.castle == "K")

local d7 = ChessDialog:new()      -- 会自动读档
check("读档还原棋盘", boardStr(d7.st) == savedBoard)
check("读档还原行棋权", d7.st.turn == savedTurn)
check("读档还原步数", d7.st.half == savedHalf)
check("读档还原王车易位权", castleStr(d7.st.castling) == savedCastle)
check("读档还原最后一步", d7.last_move ~= nil and (
    d7.last_move.fr .. "," .. d7.last_move.ff .. ","
        .. d7.last_move.tr .. "," .. d7.last_move.tf .. ","
        .. d7.last_move.piece) == savedLast)

-- 吃过路兵目标格的存档
local d8 = freshDialog()
play(d8, "e2", "e4")
play(d8, "d7", "d5")
d8:saveGame()
local d9 = ChessDialog:new()
check("读档还原吃过路兵目标格",
    d9.st.ep ~= nil and d9.st.ep.r == 6 and d9.st.ep.f == 4,
    "ep=" .. tostring(d9.st.ep and d9.st.ep.r))

-- 损坏的存档要安全回落到初始局面
local f = io.open(SAVE_DIR .. "/chess_save.txt", "w")
f:write("v1\nturn=q\nhalf=xx\n这不是一个合法存档")
f:close()
local d10 = ChessDialog:new()
check("存档损坏时回落到初始局面", boardStr(d10.st) == boardStr(Engine.newState()))
local f2 = io.open(SAVE_DIR .. "/chess_save.txt", "w")
f2:write("v1\nturn=w\n")
f2:close()
local d11 = ChessDialog:new()
check("存档不完整时回落到初始局面", boardStr(d11.st) == boardStr(Engine.newState()))

-- ======================= 场景 12: 刷新脏区 =======================
section("场景 12: 刷新脏区")
local d12 = freshDialog()
dirty_regions = {}
play(d12, "e2", "e4")
d12:doRefresh()
local board_areas, max_area = 0, 0
for _, r in ipairs(dirty_regions) do
    if r.y and r.y >= 56 and r.y <= 568 then board_areas = board_areas + 1 end
    if r.w and r.h then max_area = math.max(max_area, r.w * r.h) end
end
check("走一步只刷起点格和终点格（2 个棋盘区）", board_areas == 2,
    "刷了 " .. board_areas .. " 个棋盘区")
local all_small = true
local non_board = 0
for _, r in ipairs(dirty_regions) do
    if r.y and r.y >= 56 and r.y <= 568 then
        -- 棋盘区：每个刷新块不超过一格（64px）
        if r.w and r.h and (r.w > 64 or r.h > 64) then all_small = false end
    else
        non_board = non_board + 1
    end
end
check("棋盘上的每个刷新块都不超过一格大小", all_small)
check("棋盘之外只刷状态条和操作区两个条", non_board == 2, "实际 " .. non_board .. " 个")
check("没有整屏级刷新", max_area < 600 * 800, "最大区域 " .. tostring(max_area))

-- 无操作时零刷新
dirty_regions = {}
d12:doRefresh()
check("无操作时不刷新", #dirty_regions == 0, "推了 " .. #dirty_regions .. " 个")

-- 再走一步，脏区仍然是几个小方块
dirty_regions = {}
play(d12, "e7", "e5")
d12:doRefresh()
local board2 = 0
for _, r in ipairs(dirty_regions) do
    if r.y and r.y >= 56 and r.y <= 568 then board2 = board2 + 1 end
end
check("第二步也只刷变化的几格（<= 4 个）", board2 >= 2 and board2 <= 4,
    "刷了 " .. board2 .. " 个棋盘区")

-- ======================= 场景 13: 顶栏按钮 =======================
section("场景 13: 顶栏按钮")
local db = freshDialog()
play(db, "e2", "e4")
db:onTap(nil, { pos = { x = 470, y = 22 } })      -- 悔棋按钮（x=436..508）
check("顶栏悔棋按钮能悔棋", db.st.board[2][5] == "p" and db.st.board[4][5] == ".")
play(db, "e2", "e4")
db:onTap(nil, { pos = { x = 396, y = 22 } })      -- 新局按钮（x=360..432）
check("顶栏新局按钮能重置棋盘", boardStr(db.st) == boardStr(Engine.newState()))
check("顶栏退出按钮不报错",
    (function()
        return (pcall(function() db:onTap(nil, { pos = { x = 548, y = 22 } }) end))
    end)())

-- ======================= 场景 14: 绘制冒烟（paintTo 不报错） =======================
section("场景 14: 绘制冒烟")
local dp = freshDialog()
check("初始局面 paintTo 不报错", (function()
    return (pcall(function() dp:paintTo(Blitbuffer, 0, 0) end))
end)())
dp:onTap(nil, { pos = { x = 332, y = 472 } })      -- 选中 e2（要画合法落点）
check("选中棋子（画落点）时 paintTo 不报错", (function()
    return (pcall(function() dp:paintTo(Blitbuffer, 0, 0) end))
end)())
dp:onTap(nil, { pos = { x = 332, y = 344 } })      -- 走到 e4（要画最后一步标记）
check("走子后（画最后一步标记）paintTo 不报错", (function()
    return (pcall(function() dp:paintTo(Blitbuffer, 0, 0) end))
end)())

local dchk = freshDialog()
dchk.st = pos({ { "k", "e1" }, { "R", "e8" }, { "K", "h8" } }, "w")
dchk:updateStatus()
check("被将军时状态条给出将军提示", dchk.message:find("将军") ~= nil,
    "message=" .. tostring(dchk.message))
check("将军状态 paintTo 不报错（要画双线圆环）", (function()
    return (pcall(function() dchk:paintTo(Blitbuffer, 0, 0) end))
end)())

local dm = freshDialog()
dm.st = pos({ { "k", "a1" }, { "R", "a8" }, { "R", "b8" }, { "K", "h8" } }, "w")
dm:updateStatus()
check("终局状态被识别", dm.game_status.over and dm.game_status.result == "黑方胜")
check("终局状态 paintTo 不报错（要画大字）", (function()
    return (pcall(function() dm:paintTo(Blitbuffer, 0, 0) end))
end)())

-- ======================= 结果 =======================
print(string.format("\n========== 结果: %d 通过, %d 失败 ==========", pass, fail))
os.exit(fail == 0 and 0 or 1)
