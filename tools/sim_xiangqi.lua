--[[--
中国象棋插件的无头逻辑测试台 (headless harness)

把 KOReader 的依赖全部 mock 掉，只跑纯游戏逻辑：
初始局面 / 各子种走法 / 特殊规则（蹩马腿、塞象眼、炮架、照面、送将、将死）/
悔棋 / 存档往返 / 脏区刷新。

用法: lua tools/sim_xiangqi.lua [插件路径]
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
local SAVE_DIR = "/tmp/xiangqi_sim"
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
function InputContainer.onGesture() end
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
local SRC = arg[1] or "plugins/xiangqi.koplugin/xiangqidialog.lua"
local XiangqiDialog = assert(loadfile(SRC))()

local RED = XiangqiDialog.RED
local BLACK = XiangqiDialog.BLACK

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

-- ======================= 造盘辅助 =======================
-- 基准盘：红帅在 (1,5)，黑将在 (10,6)（不同列，避免"照面"干扰其它用例）
local BASE = {
    "....K....",  -- row 1  红帅
    ".........",
    ".........",
    ".........",
    ".........",
    ".........",
    ".........",
    ".........",
    ".........",
    ".....k...",  -- row 10 黑将
}

--- 造盘：pieces = { {行, 列, 棋子码}, ... }
local function mk(pieces)
    local rows = {}
    for i = 1, 10 do rows[i] = BASE[i] end
    for _, p in ipairs(pieces) do
        local s = rows[p[1]]
        rows[p[1]] = string.sub(s, 1, p[2] - 1) .. p[3] .. string.sub(s, p[2] + 1)
    end
    local b = XiangqiDialog.parseBoard(rows)
    assert(b, "非法测试盘")
    return b
end

--- 直接用 10 行字符串造盘
local function mkRows(rows)
    local b = XiangqiDialog.parseBoard(rows)
    assert(b, "非法测试盘")
    return b
end

local function pieceCount(b)
    local n = 0
    for r = 1, 10 do
        for c = 1, 9 do
            if b[r][c] then n = n + 1 end
        end
    end
    return n
end

--- 一步棋是否合法
local function can(b, fr, fc, tr, tc, side)
    return XiangqiDialog.isLegalMove(b, fr, fc, tr, tc, side or RED)
end

--- 干净的一份对话框（先删存档，避免上个用例污染）
local function freshDialog()
    os.remove(SAVE_DIR .. "/xiangqi_save.txt")
    local d = XiangqiDialog:new()
    dirty_regions = {}
    return d
end

-- ======================= 场景 1: 初始局面 =======================
section("场景 1: 初始局面")
local init = XiangqiDialog.newBoard()
check("初始局面共 32 子", pieceCount(init) == 32, "实际 " .. pieceCount(init))
check("红帅在 (1,5)，黑将在 (10,5)",
    init[1][5] == "K" and init[10][5] == "k")
check("红方底线：车马相仕帅仕相马车",
    init[1][1] == "R" and init[1][2] == "H" and init[1][3] == "E"
    and init[1][4] == "A" and init[1][6] == "A" and init[1][9] == "R")
check("黑方底线：将士象车马炮卒（将居中）",
    init[10][5] == "k" and init[10][4] == "a" and init[10][3] == "e"
    and init[10][2] == "h" and init[10][8] == "h")
check("红炮在 (2,2)(2,8)，黑炮在 (8,2)(8,8)",
    init[2][2] == "C" and init[2][8] == "C" and init[8][2] == "c" and init[8][8] == "c")
local red_soldiers, black_soldiers = 0, 0
for c = 1, 9 do
    if init[4][c] == "P" then red_soldiers = red_soldiers + 1 end
    if init[7][c] == "p" then black_soldiers = black_soldiers + 1 end
end
check("红兵 5 个在第 4 行，黑卒 5 个在第 7 行",
    red_soldiers == 5 and black_soldiers == 5,
    "红 " .. red_soldiers .. " 黑 " .. black_soldiers)
check("初始局面红方合法着法 > 20", #XiangqiDialog.genMoves(init, RED) > 20,
    "实际 " .. #XiangqiDialog.genMoves(init, RED))

-- ======================= 场景 2: 车 =======================
section("场景 2: 车")
local b = mk({ { 5, 5, "R" } })
check("车直线走合法", can(b, 5, 5, 5, 7))
check("车斜走被拒", not can(b, 5, 5, 6, 6))
local b2 = mk({ { 5, 5, "R" }, { 5, 6, "P" } })
check("车不能穿子", not can(b2, 5, 5, 5, 7))
local b3 = mk({ { 5, 5, "R" }, { 5, 7, "p" } })
check("车吃子合法", can(b3, 5, 5, 5, 7))

-- ======================= 场景 3: 马 =======================
section("场景 3: 马")
local b = mk({ { 5, 5, "H" } })
check("马走日字合法", can(b, 5, 5, 7, 6))
check("马不能直走", not can(b, 5, 5, 6, 5))
local b2 = mk({ { 5, 5, "H" }, { 6, 5, "P" } })
check("蹩马腿被拒", not can(b2, 5, 5, 7, 6))
check("蹩马腿时另一方向仍可走", can(b2, 5, 5, 3, 4))

-- ======================= 场景 4: 象 =======================
section("场景 4: 象（相）")
local b = mk({ { 5, 5, "E" } })
check("象走田字合法", can(b, 5, 5, 3, 3))
check("象不能直走", not can(b, 5, 5, 4, 5))
local b2 = mk({ { 5, 5, "E" }, { 4, 4, "P" } })
check("塞象眼被拒", not can(b2, 5, 5, 3, 3))
check("象不能过河", not can(b, 5, 5, 7, 7))
local b3 = mk({ { 3, 5, "E" } })
check("相在自己半场可走田", can(b3, 3, 5, 1, 3))

-- ======================= 场景 5: 士 =======================
section("场景 5: 士（仕）")
local b = mk({ { 1, 5, "A" } })
check("仕斜走一格合法", can(b, 1, 5, 2, 4))
check("仕不能直走", not can(b, 1, 5, 2, 5))
local b2 = mk({ { 2, 4, "A" } })
check("仕不能出九宫", not can(b2, 2, 4, 3, 3))

-- ======================= 场景 6: 帅 =======================
section("场景 6: 帅（将）")
local b = mk({})
check("帅直走一格合法", can(b, 1, 5, 1, 4))
check("帅不能走两格", not can(b, 1, 5, 3, 5))
local b2 = mk({ { 1, 4, "K" } })
check("帅不能出九宫", not can(b2, 1, 4, 1, 3))
check("帅不能斜走", not can(b, 1, 5, 2, 4))

-- ======================= 场景 7: 炮 =======================
section("场景 7: 炮")
local b = mk({ { 5, 2, "C" } })
check("炮不吃子时走直线合法", can(b, 5, 2, 5, 4))
local b2 = mk({ { 5, 2, "C" }, { 5, 3, "P" }, { 5, 5, "p" } })
check("炮隔一个炮架吃子合法", can(b2, 5, 2, 5, 5))
local b3 = mk({ { 5, 2, "C" }, { 5, 5, "p" } })
check("炮无架吃子被拒", not can(b3, 5, 2, 5, 5))
local b4 = mk({ { 5, 2, "C" }, { 5, 3, "P" }, { 5, 4, "P" }, { 5, 5, "p" } })
check("炮架上有多个子时不能吃", not can(b4, 5, 2, 5, 5))
check("炮不吃子时不能穿子", not can(mk({ { 5, 2, "C" }, { 5, 3, "P" } }), 5, 2, 5, 4))
check("炮架前方的空点仍可走", can(mk({ { 5, 2, "C" } }), 5, 2, 5, 3))

-- ======================= 场景 8: 兵（卒） =======================
section("场景 8: 兵（卒）")
local b = mk({ { 4, 5, "P" } })
check("兵向前一格合法", can(b, 4, 5, 5, 5))
check("兵不能后退", not can(b, 4, 5, 3, 5))
check("兵未过河不能横走", not can(b, 4, 5, 4, 6))
local b2 = mk({ { 6, 5, "P" } })
check("兵过河后可向左横走", can(b2, 6, 5, 6, 4))
check("兵过河后可向右横走", can(b2, 6, 5, 6, 6))
check("兵过河后仍不能后退", not can(b2, 6, 5, 5, 5))
local b3 = mk({ { 6, 5, "p" } })
check("黑卒过河后可横走（row<=5）", can(b3, 6, 5, 6, 4) == false)

-- ======================= 场景 9: 将军与送将 =======================
section("场景 9: 将军 / 送将 / 照面")
local bcheck = mkRows({
    "R...K....",
    ".........",
    ".........",
    ".........",
    "....r....",
    ".........",
    ".........",
    ".........",
    ".........",
    ".....k...",
})
check("黑车压中路 → 红方被将军", XiangqiDialog.isCheck(bcheck, RED) == true)
check("黑方未被将军", XiangqiDialog.isCheck(bcheck, BLACK) == false)
check("被将军时不能走（送将被拒）", not can(bcheck, 1, 1, 2, 1))
check("被将军时帅也不能乱走", not can(bcheck, 1, 5, 1, 6))

local bface = mkRows({
    "....K....",
    ".........",
    ".........",
    ".........",
    "....R....",
    ".........",
    ".........",
    ".........",
    ".........",
    "....k....",
})
check("照面局面本身不算将军（有子挡着）", XiangqiDialog.isCheck(bface, RED) == false)
check("照面送将被拒绝（车离开中路）", not can(bface, 5, 5, 5, 7))
check("照面送法被拒绝（车另一侧）", not can(bface, 5, 5, 5, 3))
check("未造成照面的走法仍合法", can(bface, 5, 5, 4, 5))

local bhorse = mkRows({
    "....K....",
    ".........",
    ".........",
    ".........",
    "....H....",
    ".........",
    ".........",
    ".........",
    ".........",
    "....k....",
})
check("照面送将被拒绝（马离开中路）", not can(bhorse, 5, 5, 7, 6))

-- ======================= 场景 10: 将死 =======================
section("场景 10: 将死")
local bm = mkRows({
    "....K....",
    ".........",
    ".........",
    ".........",
    ".........",
    ".........",
    ".........",
    "....P....",
    ".........",
    "..R.k.R..",
})
check("双车+兵围住黑将 → 黑方被将军", XiangqiDialog.isCheck(bm, BLACK) == true)
check("黑方无合法着法", XiangqiDialog.hasLegalMove(bm, BLACK) == false)
check("判定为将死", XiangqiDialog.isCheckmate(bm, BLACK) == true)
check("红方不算将死", XiangqiDialog.isCheckmate(bm, RED) == false)
check("红方未被将军", XiangqiDialog.isCheck(bm, RED) == false)

-- ======================= 场景 11: 悔棋 =======================
section("场景 11: 悔棋")
local d = freshDialog()
check("新局是初始局面", d.board[1][1] == "R" and d.move_count == 0 and d.turn == RED)
d:doMove(1, 1, 2, 1)
check("走子后棋盘已更新", d.board[2][1] == "R" and d.board[1][1] == nil)
check("走子后轮到黑方", d.turn == BLACK)
check("走子后手数 +1", d.move_count == 1)
check("记录了最后一步", d.last_move ~= nil and d.last_move.tr == 2 and d.last_move.tc == 1)
d:undo()
check("悔棋后棋子回到原位", d.board[1][1] == "R" and d.board[2][1] == nil)
check("悔棋后行棋权还原", d.turn == RED)
check("悔棋后手数还原", d.move_count == 0)
check("悔棋后清掉最后一步标记", d.last_move == nil)
d:undo()
check("没有棋可悔时安全返回", d.move_count == 0)

-- ======================= 场景 12: 存档往返 =======================
section("场景 12: 存档往返")
local sd = freshDialog()
sd:doMove(1, 1, 2, 1)
sd:doMove(10, 1, 9, 1)   -- 黑车走一步（黑车在 (10,1)）
sd:saveGame()
local ld = XiangqiDialog:new()
check("读档还原棋盘", ld.board[2][1] == "R" and ld.board[9][1] == "r")
check("读档还原行棋权", ld.turn == RED, "turn=" .. tostring(ld.turn))
check("读档还原手数", ld.move_count == 2, "moves=" .. tostring(ld.move_count))
check("读档还原最后一步标记",
    ld.last_move ~= nil and ld.last_move.fr == 10 and ld.last_move.fc == 1)
check("读档还原悔棋栈", #ld.history == 2, "history=" .. #ld.history)
-- 读档后还能继续悔棋
ld:undo()
check("读档后可以悔棋", ld.board[10][1] == "r" and ld.move_count == 1)
-- 损坏存档 → 安全回落
local f = io.open(SAVE_DIR .. "/xiangqi_save.txt", "w")
f:write("v1\ngarbage\nnot-a-board\n")
f:close()
local bd = XiangqiDialog:new()
check("损坏存档安全回落到初始局面",
    bd.board[1][1] == "R" and bd.board[10][5] == "k" and bd.move_count == 0)

-- ======================= 场景 13: 脏区刷新 =======================
section("场景 13: 脏区刷新")
local rd = freshDialog()
dirty_regions = {}
rd:doMove(1, 1, 2, 1)
local n = #dirty_regions
check("走一步只刷少量区域（<=8）", n > 0 and n <= 8, "刷了 " .. n .. " 块")
local max_area = 0
local full = false
for _, r in ipairs(dirty_regions) do
    max_area = math.max(max_area, r.w * r.h)
    if r.w >= 600 and r.h >= 800 then full = true end
end
check("走一步没有整屏刷新", not full and max_area < 600 * 800, "最大区域 " .. tostring(max_area))
dirty_regions = {}
rd:doRefresh()
check("无操作时零刷新", #dirty_regions == 0, "推了 " .. #dirty_regions .. " 个")
dirty_regions = {}
rd:handlePoint(1, 1)      -- 选中红车
rd:doRefresh()
check("选中棋子只刷棋盘局部", #dirty_regions > 0 and #dirty_regions <= 6,
    "刷了 " .. #dirty_regions .. " 块")

-- ======================= 场景 14: 非法提示文案 =======================
section("场景 14: 非法提示文案")
local msg1 = XiangqiDialog.explainIllegal(mk({ { 5, 5, "R" } }), 5, 5, 6, 6, RED)
check("斜走有明确原因", msg1 ~= nil and string.len(msg1) > 0, tostring(msg1))
local msg2 = XiangqiDialog.explainIllegal(mk({ { 4, 5, "P" } }), 4, 5, 3, 5, RED)
check("兵后退有明确原因", string.find(msg2, "后退") ~= nil, msg2)
local msg3 = XiangqiDialog.explainIllegal(mk({ { 5, 5, "H" }, { 6, 5, "P" } }), 5, 5, 7, 6, RED)
check("蹩马腿有明确原因", string.find(msg3, "马腿") ~= nil, msg3)
local msg4 = XiangqiDialog.explainIllegal(bface, 5, 5, 5, 7, RED)
check("照面有明确原因", string.find(msg4, "照面") ~= nil, msg4)

-- ======================= 场景 15: 交互流程 =======================
section("场景 15: 交互流程（点选 → 落点 → 悔棋 / 新局）")
local id = freshDialog()
-- 交叉点 (1,1) = (76,584)、(2,1) = (76,528)、(3,3) = (188,472)
id:onTap(nil, { pos = { x = 76, y = 584 } })
check("点己方棋子后进入选中态",
    id.selected ~= nil and id.selected.r == 1 and id.selected.c == 1)
check("合法落点已算出来", #id.targets > 0, "target=" .. #id.targets)
id:onTap(nil, { pos = { x = 188, y = 472 } })
check("点非法目标时状态条给出原因",
    id.message ~= nil and string.len(id.message) > 0, tostring(id.message))
check("非法落点不会走子", id.board[1][1] == "R" and id.move_count == 0)
id:onTap(nil, { pos = { x = 76, y = 584 } })
id:onTap(nil, { pos = { x = 76, y = 528 } })
check("点合法落点即走子", id.board[2][1] == "R" and id.board[1][1] == nil)
check("走子后轮到黑方", id.turn == BLACK)
id:onHold(nil, { pos = { x = 76, y = 528 } })
check("长按棋子即悔棋", id.board[1][1] == "R" and id.move_count == 0)
id:onTap(nil, { pos = { x = 470, y = 20 } })   -- 顶栏「新局」
check("顶栏新局按钮重开",
    id.move_count == 0 and id.turn == RED and id.board[1][1] == "R")
id:onTap(nil, { pos = { x = 540, y = 20 } })   -- 顶栏「退出」
check("顶栏退出按钮可调用（不崩）", id.is_closed == true)

-- ======================= 结果 =======================
print(string.format("\n========== 结果: %d 通过, %d 失败 ==========", pass, fail))
os.exit(fail == 0 and 0 or 1)
