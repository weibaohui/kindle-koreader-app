--[[--
中国象棋 (Xiangqi) - Kindle 墨水屏定制版

针对 Amazon Kindle Basic（第 7 代 / KT2, 600x800, 16 级灰度, 无前光）的墨水屏特性设计：
- 汉字即棋子：直接用「帅仕相马车炮兵 / 将士象车马炮卒」这 14 个汉字当棋子，
  不需要画具象棋子的造型，16 级灰度上笔画依然清晰 —— 这是中国象棋相对国际象棋
  在墨水屏上的天然优势（不需要识别"车的轮子"这种灰度下糊成一团的细节）
- 敌我用「汉字本身 + 底色深浅」双编码：红方 = 浅灰底 + 黑字，黑方 = 深灰底 + 白字，
  完全不依赖颜色（墨水屏无前光，红/蓝/黑全是同一种灰）
- 形状线索（全部与颜色无关）：
  · 最后一步走过的子，顶部有一条短横线
  · 被将军的一方，「帅/将」外面套一圈双线框
  · 合法落点用小灰点标出；可吃的敌子外面套一圈粗框
  · 选中子用一圈更粗的方框
- 静态优先：象棋是回合制，走一步刷一次；只在真正变化的交叉点、状态条、
  被吃子栏、提示行上标脏，绝不整屏重刷
- 交互：同机双人对弈。点己方棋子 → 所有合法落点标灰点 → 点落点走子；
  点非法目标时状态条说明原因；长按任意棋子 = 悔棋；顶栏「新局 / 悔棋 / 退出」

架构参照本仓库《数独 (Sudoku)》插件：同样的 ges_events 手势注册、
分桶脏区（用完即清）、paintTo 先铺底色再画字、存档走 DataStorage:getSettingsDir()。
--]]--

local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local Screen = Device.screen
local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local RenderText = require("ui/rendertext")

-- ======================= 布局常量 =======================
local TOPBAR_H = 44

local COLS = 9                -- 9 列
local ROWS = 10               -- 10 行
local CELL = 56               -- 格子边长（交叉点间距）
local BOARD_X0 = 48           -- 棋盘左边 9*56 = 504 → 48..552
local BOARD_Y0 = 52           -- 棋盘上边 10*56 = 560 → 52..612
local BOARD_W = COLS * CELL
local BOARD_H = ROWS * CELL
local BOARD_X1 = BOARD_X0 + BOARD_W
local BOARD_Y1 = BOARD_Y0 + BOARD_H

-- 棋盘按 9 列 × 10 行的 56px 格子铺开（区域 48..552 × 52..612），
-- 每个格子中心放一个交叉点：9 个竖线 × 10 个横线。
local LINE_X0 = BOARD_X0 + CELL / 2      -- 76  第 1 列
local LINE_X1 = BOARD_X0 + 8.5 * CELL    -- 524 第 9 列
local LINE_W = LINE_X1 - LINE_X0        -- 448
local LINE_Y_TOP = BOARD_Y0 + CELL / 2  -- 80  row 10（黑方底线）
local LINE_Y_BOT = BOARD_Y0 + 9.5 * CELL-- 584 row 1（红方底线）
local RIVER_Y_TOP = BOARD_Y0 + 4.5 * CELL -- 304 row 6
local RIVER_Y_BOT = BOARD_Y0 + 5.5 * CELL -- 360 row 5

local STATUS_Y0 = 616         -- 状态条：轮到谁 / 选中 / 手数
local STATUS_H = 30

local PANEL_Y0 = 652          -- 被吃子栏
local PANEL_H = 48

local HINT_Y0 = 704           -- 提示行（原因 / 操作说明 / 图例）

-- ======================= 棋子编码 =======================
-- 红方（浅灰底黑字）用大写：K帅 A仕 E相 R车 H马 C炮 P兵
-- 黑方（深灰底白字）用小写：k将 a士 e象 r车 h马 c炮 p卒
-- sideOf() 取红黑，typeOf() 取种类（统一大写）。
local RED = "red"
local BLACK = "black"

local PIECE_CHAR = {
    K = "帅", A = "仕", E = "相", R = "车", H = "马", C = "炮", P = "兵",
    k = "将", a = "士", e = "象", r = "车", h = "马", c = "炮", p = "卒",
}
local VALID_PIECE = {}
for kk in pairs(PIECE_CHAR) do VALID_PIECE[kk] = true end

local SIDE_NAME = { [RED] = "红方", [BLACK] = "黑方" }

local function sideOf(ch)
    if not ch then return nil end
    local u = string.upper(ch)
    if not VALID_PIECE[u] then return nil end
    if ch == u then return RED else return BLACK end
end

local function typeOf(ch)
    if not ch then return nil end
    return string.upper(ch)
end

--- 棋子名，如「红车」「黑马」
local function pieceName(ch)
    if not ch then return "" end
    local prefix = (sideOf(ch) == RED) and "红" or "黑"
    return prefix .. (PIECE_CHAR[ch] or "?")
end

--- 初始局面：row 1 = 红方底线（屏幕最下），row 10 = 黑方底线（屏幕最上）
local INITIAL_ROWS = {
    "RHEAKAEHR",   -- row 1  车马相仕帅仕相马车
    ".C.....C.",   -- row 2  炮 炮
    ".........",   -- row 3
    "P.P.P.P.P",   -- row 4  兵 兵 兵 兵 兵
    ".........",   -- row 5
    ".........",   -- row 6  ← 河界在这两行之间（row 5 与 row 6 之间）
    "p.p.p.p.p",   -- row 7  卒 卒 卒 卒 卒
    ".c.....c.",   -- row 8  炮 炮
    ".........",   -- row 9
    "rheakaehr",   -- row 10 车马象士将士象马车
}

-- ======================= 棋盘几何 =======================
local ORTH = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }
local DIAG = { { -1, -1 }, { -1, 1 }, { 1, -1 }, { 1, 1 } }
local KNIGHT = { { -2, -1 }, { -2, 1 }, { -1, -2 }, { -1, 2 },
                 { 1, -2 }, { 1, 2 }, { 2, -1 }, { 2, 1 } }
local ELEPH = { { -2, -2 }, { -2, 2 }, { 2, -2 }, { 2, 2 } }

--- 九宫（帅/将/士/仕的活动范围）
local function inPalace(r, c, side)
    if side == RED then
        return r >= 1 and r <= 3 and c >= 4 and c <= 6
    end
    return r >= 8 and r <= 10 and c >= 4 and c <= 6
end

--- 是否还在自己半场（象/相不能过河）
local function ownHalf(r, side)
    if side == RED then return r <= 5 end
    return r >= 6
end

--- 兵/卒是否已过河（过河后才可以横走）
local function soldierCrossed(r, side)
    if side == RED then return r >= 6 end
    return r <= 5
end

--- 越界安全的取子（马腿/象眼可能落在棋盘外）
local function at(board, r, c)
    if r < 1 or r > ROWS or c < 1 or c > COLS then return nil end
    return board[r][c]
end

--- 两点之间（同行或同列）的子数
local function countBetween(board, r1, c1, r2, c2)
    local n = 0
    if r1 == r2 then
        local lo, hi = c1, c2
        if lo > hi then lo, hi = hi, lo end
        for c = lo + 1, hi - 1 do
            if board[r1][c] then n = n + 1 end
        end
    elseif c1 == c2 then
        local lo, hi = r1, r2
        if lo > hi then lo, hi = hi, lo end
        for r = lo + 1, hi - 1 do
            if board[r][c1] then n = n + 1 end
        end
    end
    return n
end

-- ======================= 棋盘构造 =======================
local function newBoard()
    local b = {}
    for r = 1, ROWS do
        b[r] = {}
        for c = 1, COLS do b[r][c] = nil end
    end
    for r = 1, ROWS do
        local row = INITIAL_ROWS[r]
        for c = 1, COLS do
            local ch = string.sub(row, c, c)
            if ch ~= "." then b[r][c] = ch end
        end
    end
    return b
end

local function cloneBoard(b)
    local o = {}
    for r = 1, ROWS do
        o[r] = {}
        for c = 1, COLS do o[r][c] = b[r][c] end
    end
    return o
end

--- 由 10 行字符串构造棋盘（row 1 = 红方底线）。非法返回 nil
local function parseBoard(rows)
    if type(rows) ~= "table" or #rows ~= ROWS then return nil end
    local b = {}
    for r = 1, ROWS do
        local row = rows[r]
        if type(row) ~= "string" or #row ~= COLS then return nil end
        b[r] = {}
        for c = 1, COLS do
            local ch = string.sub(row, c, c)
            if ch ~= "." then
                if not VALID_PIECE[ch] then return nil end
                b[r][c] = ch
            end
        end
    end
    return b
end

local function boardToRows(b)
    local out = {}
    for r = 1, ROWS do
        local row = ""
        for c = 1, COLS do
            row = row .. (b[r][c] or ".")
        end
        out[r] = row
    end
    return out
end

-- ======================= 走法生成 =======================
--- 棋子在 (r,c) 的伪合法落点（不含"走后自己被将军"检查）
local function pseudoTargets(board, r, c)
    local res = {}
    local pc = board[r][c]
    if not pc then return res end
    local side = sideOf(pc)
    local t = typeOf(pc)

    local function add(tr, tc)
        if tr < 1 or tr > ROWS or tc < 1 or tc > COLS then return end
        local target = board[tr][tc]
        if target then
            if sideOf(target) == side then return end   -- 不能吃自己的子
            if typeOf(target) == "K" then return end      -- 不吃将/帅（输赢走将死判定）
        end
        res[#res + 1] = { tr = tr, tc = tc }
    end

    if t == "R" or t == "C" then
        -- 车：直线任意格，不穿子；炮：不吃子时同车，吃子必须隔且只隔一个炮架
        for _, d in ipairs(ORTH) do
            local nr, nc = r + d[1], c + d[2]
            local screen = false
            while nr >= 1 and nr <= ROWS and nc >= 1 and nc <= COLS do
                local target = board[nr][nc]
                if not target then
                    if t == "R" or not screen then
                        add(nr, nc)
                    end
                else
                    if t == "R" then
                        add(nr, nc)
                        break
                    else
                        if not screen then
                            screen = true          -- 遇到炮架
                        else
                            add(nr, nc)            -- 炮吃架后的第一个子
                            break
                        end
                    end
                end
                nr = nr + d[1]
                nc = nc + d[2]
            end
        end
    elseif t == "H" then
        for _, d in ipairs(KNIGHT) do
            local nr, nc = r + d[1], c + d[2]
            local lr, lc
            if math.abs(d[1]) == 2 then lr, lc = r + d[1] / 2, c
            else lr, lc = r, c + d[2] / 2 end
            if at(board, lr, lc) == nil then add(nr, nc) end   -- 蹩马腿
        end
    elseif t == "E" then
        for _, d in ipairs(ELEPH) do
            local nr, nc = r + d[1], c + d[2]
            local er, ec = r + d[1] / 2, c + d[2] / 2
            if at(board, er, ec) == nil and ownHalf(nr, side) then
                add(nr, nc)                              -- 塞象眼 / 象不过河
            end
        end
    elseif t == "A" then
        for _, d in ipairs(DIAG) do
            local nr, nc = r + d[1], c + d[2]
            if inPalace(nr, nc, side) then add(nr, nc) end -- 仕不出九宫
        end
    elseif t == "K" then
        for _, d in ipairs(ORTH) do
            local nr, nc = r + d[1], c + d[2]
            if inPalace(nr, nc, side) then add(nr, nc) end -- 帅不出九宫
        end
    elseif t == "P" then
        local fwd = (side == RED) and 1 or -1
        add(r + fwd, c)                                  -- 兵/卒只向前
        if soldierCrossed(r, side) then
            add(r, c - 1)
            add(r, c + 1)                                -- 过河后才可以横走
        end
    end
    return res
end

local function findKing(board, side)
    local want = (side == RED) and "K" or "k"
    for r = 1, ROWS do
        for c = 1, COLS do
            if board[r][c] == want then return r, c end
        end
    end
    return nil
end

--- 格子 (tr,tc) 是否被 bySide 的棋子攻击（含"照面"）
local function isAttacked(board, tr, tc, bySide)
    for r = 1, ROWS do
        for c = 1, COLS do
            local pc = board[r][c]
            if pc and sideOf(pc) == bySide and not (r == tr and c == tc) then
                local t = typeOf(pc)
                local dr, dc = tr - r, tc - c
                if t == "R" then
                    if (r == tr or c == tc) and countBetween(board, r, c, tr, tc) == 0 then
                        return true
                    end
                elseif t == "C" then
                    if (r == tr or c == tc) and countBetween(board, r, c, tr, tc) == 1 then
                        return true
                    end
                elseif t == "H" then
                    for _, d in ipairs(KNIGHT) do
                        if dr == d[1] and dc == d[2] then
                            local lr, lc
                            if math.abs(d[1]) == 2 then lr, lc = r + d[1] / 2, c
                            else lr, lc = r, c + d[2] / 2 end
                            if at(board, lr, lc) == nil then return true end
                        end
                    end
                elseif t == "E" then
                    for _, d in ipairs(ELEPH) do
                        if dr == d[1] and dc == d[2] then
                            local er, ec = r + d[1] / 2, c + d[2] / 2
                            if at(board, er, ec) == nil and ownHalf(tr, bySide) then return true end
                        end
                    end
                elseif t == "A" then
                    for _, d in ipairs(DIAG) do
                        if dr == d[1] and dc == d[2] then return true end
                    end
                elseif t == "K" then
                    -- 直走一格（九宫内）+ 照面
                    if math.abs(dr) + math.abs(dc) == 1 then return true end
                    if c == tc and countBetween(board, r, c, tr, tc) == 0 then return true end
                elseif t == "P" then
                    local fwd = (bySide == RED) and 1 or -1
                    if dr == fwd and dc == 0 then return true end
                    if soldierCrossed(r, bySide) and dr == 0 and math.abs(dc) == 1 then
                        return true
                    end
                end
            end
        end
    end
    return false
end

--- side 是否正被将军
local function isCheck(board, side)
    local kr, kc = findKing(board, side)
    if not kr then return false end
    local other = (side == RED) and BLACK or RED
    return isAttacked(board, kr, kc, other)
end

--- 试着走一步，返回新的棋盘
local function applyMove(board, fr, fc, tr, tc)
    local b = cloneBoard(board)
    b[tr][tc] = b[fr][fc]
    b[fr][fc] = nil
    return b
end

--- 完整合法性判断（走法 + 走后自己不被将军 + 不照面）
local function isLegalMove(board, fr, fc, tr, tc, side)
    local pc = board[fr][fc]
    if not pc then return false end
    local pside = sideOf(pc)
    if side and pside ~= side then return false end
    local target = board[tr][tc]
    if target and sideOf(target) == pside then return false end
    if fr == tr and fc == tc then return false end
    local ok = false
    for _, d in ipairs(pseudoTargets(board, fr, fc)) do
        if d.tr == tr and d.tc == tc then ok = true break end
    end
    if not ok then return false end
    local b2 = applyMove(board, fr, fc, tr, tc)
    if isCheck(b2, pside) then return false end   -- 不能送将给自己，也不能造成照面
    return true
end

--- side 的全部合法着法
local function genMoves(board, side)
    local moves = {}
    for r = 1, ROWS do
        for c = 1, COLS do
            local pc = board[r][c]
            if pc and sideOf(pc) == side then
                for _, d in ipairs(pseudoTargets(board, r, c)) do
                    if isLegalMove(board, r, c, d.tr, d.tc, side) then
                        moves[#moves + 1] = { fr = r, fc = c, tr = d.tr, tc = d.tc }
                    end
                end
            end
        end
    end
    return moves
end

--- side 是否已无路可走（被将军＝将死；未被将军＝困毙，同样判负）
local function isCheckmate(board, side)
    if not isCheck(board, side) then return false end
    return #genMoves(board, side) == 0
end

local function hasLegalMove(board, side)
    return #genMoves(board, side) > 0
end

--- 走完之后两个将/帅是否照面（同列中间无子）
local function causesFacing(board, fr, fc, tr, tc)
    local b = applyMove(board, fr, fc, tr, tc)
    local kr, kc = findKing(b, RED)
    local bk, bc = findKing(b, BLACK)
    if not kr or not bk then return false end
    if kc ~= bc then return false end
    return countBetween(b, kr, kc, bk, bc) == 0
end

--- 说明一步棋为什么非法（状态条文案）
local function explainIllegal(board, fr, fc, tr, tc, side)
    local pc = board[fr][fc]
    local target = board[tr][tc]
    if not pc then return "这里没有棋子" end
    local pside = sideOf(pc)
    if side and pside ~= side then
        return "还没轮到" .. SIDE_NAME[pside] .. "走"
    end
    if fr == tr and fc == tc then return "请选择另一个落点" end
    if target and sideOf(target) == pside then return "不能吃自己的棋子" end

    local t = typeOf(pc)
    local dr, dc = tr - fr, tc - fc
    if t == "R" then
        if dr ~= 0 and dc ~= 0 then return "车只能走直线，不能斜走" end
        if countBetween(board, fr, fc, tr, tc) > 0 then return "车不能穿子" end
    elseif t == "H" then
        local matched = false
        for _, d in ipairs(KNIGHT) do
            if dr == d[1] and dc == d[2] then matched = true break end
        end
        if not matched then return "马走日字，不能直走或斜走一格" end
        local lr, lc
        if math.abs(dr) == 2 then lr, lc = fr + dr / 2, fc else lr, lc = fr, fc + dc / 2 end
        if at(board, lr, lc) then return "蹩马腿了，马走不了这里" end
    elseif t == "E" then
        local matched = false
        for _, d in ipairs(ELEPH) do
            if dr == d[1] and dc == d[2] then matched = true break end
        end
        if not matched then return "象走田字，不能直走或斜走一格" end
        if at(board, fr + dr / 2, fc + dc / 2) then return "塞象眼了，象走不了这里" end
        if not ownHalf(tr, pside) then return "象不能过河" end
    elseif t == "A" then
        if math.abs(dr) ~= 1 or math.abs(dc) ~= 1 then return "仕只走斜一格" end
        if not inPalace(tr, tc, pside) then return "仕不能出九宫" end
    elseif t == "K" then
        if math.abs(dr) + math.abs(dc) ~= 1 then return "帅只走直一格" end
        if not inPalace(tr, tc, pside) then return "帅不能出九宫" end
    elseif t == "C" then
        if dr ~= 0 and dc ~= 0 then return "炮走直线，不能斜走" end
        local n = countBetween(board, fr, fc, tr, tc)
        if target then
            if n ~= 1 then return "炮吃子必须隔且只隔一个棋子（炮架）" end
        else
            if n > 0 then return "炮不吃子时不能穿子" end
        end
    elseif t == "P" then
        local fwd = (pside == RED) and 1 or -1
        if dr == fwd and dc == 0 then
            -- 向前一格，合法
        elseif dr == 0 and math.abs(dc) == 1 then
            if not soldierCrossed(fr, pside) then return "兵（卒）过河后才能横走" end
        else
            return "兵（卒）只能向前一格，不能后退"
        end
    end

    if causesFacing(board, fr, fc, tr, tc) then
        return "这样会让将（帅）照面，不合法"
    end
    if isCheck(applyMove(board, fr, fc, tr, tc), pside) then
        local king_code = (pside == RED) and "K" or "k"
        return "走后自己的" .. pieceName(king_code) .. "会被将军"
    end
    return "这一步不合法"
end

-- ======================= 对话框 =======================
local XiangqiDialog = InputContainer:extend{
    name = "xiangqi_dialog",
    dimen = Geom:new{ x = 0, y = 0, w = 600, h = 800 },
    modal = true,
    -- 必须关闭原生 double_tap：否则单次 tap 会被延迟 300ms 才下发，
    -- "点己方子 → 点落点"这种高频操作不能忍受延迟。
    disable_double_tap = true,
}

-- ======================= 初始化 =======================
function XiangqiDialog:init()
    self.show_parent = self

    self.W = Screen:getWidth()
    self.H = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }

    -- ⚠️ 必须显式注册手势！InputContainer:onGesture 只会把事件分发给
    -- registerTouchZones 注册的触摸区和 ges_events 里声明的手势，
    -- 不会自动调用我们重写的 onTap / onHold。
    local full_range = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = full_range } },
        Hold = { GestureRange:new{ ges = "hold", range = full_range } },
    }

    -- 字体：汉字一律用 cfont（CJK 字体），保证「帅仕相马车炮兵」都能渲染
    self.font_title = Font:getFace("cfont", 22)
    self.font_btn = Font:getFace("cfont", 15)
    self.font_piece = Font:getFace("cfont", 26)
    self.font_mid = Font:getFace("cfont", 16)
    self.font_small = Font:getFace("cfont", 13)
    self.font_tiny = Font:getFace("cfont", 12)

    -- 状态
    self.board = newBoard()
    self.turn = RED
    self.move_count = 0
    self.last_move = nil         -- { fr, fc, tr, tc } 最后一步，棋子上方加短横线
    self.selected = nil          -- { r, c } 当前选中的子
    self.targets = {}            -- 合法落点列表
    self.history = {}            -- 悔棋栈
    self.captured = { [RED] = {}, [BLACK] = {} }  -- [行棋方] = 被它吃掉的子
    self.message = "红方先走，点红方棋子开始"
    self.game_over = nil         -- "checkmate" / "stalemate"
    self.check_side = nil        -- 当前被将军的一方

    self.save_file = DataStorage:getSettingsDir() .. "/xiangqi_save.txt"

    -- 脏区分桶：board（交叉点）/ status / panel / hint / top
    self._dr = {}
    self._dr_keys = {}
    self._pts = {}               -- 需要重画的棋盘交叉点

    if not self:loadGame() then
        self:newGame()
    end
    self:refreshAll()
end

-- ======================= 存档 =======================
function XiangqiDialog:saveGame()
    local f = io.open(self.save_file, "w")
    if not f then return end
    f:write("v1\n")
    f:write("turn=" .. self.turn .. "\n")
    f:write("moves=" .. tostring(self.move_count) .. "\n")
    if self.last_move then
        local m = self.last_move
        f:write("last=" .. m.fr .. "," .. m.fc .. "," .. m.tr .. "," .. m.tc .. "\n")
    else
        f:write("last=-\n")
    end
    local rows = boardToRows(self.board)
    for r = 1, ROWS do
        f:write("row=" .. rows[r] .. "\n")
    end
    local hs = ""
    for _, m in ipairs(self.history) do
        hs = hs .. m.fr .. "," .. m.fc .. "," .. m.tr .. "," .. m.tc .. ";"
    end
    f:write("hist=" .. hs .. "\n")
    f:close()
end

function XiangqiDialog:loadGame()
    local f = io.open(self.save_file, "r")
    if not f then return false end
    local lines = {}
    for line in f:lines() do lines[#lines + 1] = line end
    f:close()
    -- v1 + turn + moves + last + 10 行棋盘 + hist = 15 行
    if #lines < 15 then return false end
    if lines[1] ~= "v1" then return false end

    -- ⚠️ Lua 模式没有 "|" 分支，只能取出来再判断
    local turn = string.match(lines[2] or "", "^turn=(.*)$")
    if turn ~= "red" and turn ~= "black" then turn = nil end
    local moves = tonumber(string.match(lines[3] or "", "^moves=(%d+)$"))
    if not turn or not moves then return false end

    local last = nil
    local lm = string.match(lines[4] or "", "^last=(.*)$")
    if lm and lm ~= "-" then
        local a, b, c, d = string.match(lm, "^(%d+),(%d+),(%d+),(%d+)$")
        if a then
            local fr, fc, tr, tc = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
            if fr and fc and tr and tc and fr >= 1 and fr <= ROWS and fc >= 1 and fc <= COLS
                and tr >= 1 and tr <= ROWS and tc >= 1 and tc <= COLS then
                last = { fr = fr, fc = fc, tr = tr, tc = tc }
            end
        end
    end

    local rows = {}
    for i = 1, ROWS do
        local row = string.match(lines[4 + i] or "", "^row=(.*)$")
        if not row or #row ~= COLS then return false end
        rows[i] = row
    end
    local board = parseBoard(rows)
    if not board then return false end
    -- 两个将/帅都必须还在
    if not findKing(board, RED) or not findKing(board, BLACK) then return false end

    -- 历史：从初始局面重放，拿到被吃子与行棋方；与存档棋盘不一致就丢弃历史
    local hist = {}
    local hs = string.match(lines[15] or "", "^hist=(.*)$") or ""
    for entry in string.gmatch(hs, "([^;]+)") do
        local a, b, c, d = string.match(entry, "^(%d+),(%d+),(%d+),(%d+)$")
        if a then
            hist[#hist + 1] = { fr = tonumber(a), fc = tonumber(b), tr = tonumber(c), tc = tonumber(d) }
        end
    end
    local rebuilt = {}
    local b0 = newBoard()
    local turn0 = RED
    local mc = 0
    local lastm = nil
    local ok = true
    for _, m in ipairs(hist) do
        local pc = b0[m.fr] and b0[m.fr][m.fc]
        if not pc or typeOf(pc) == "K" then ok = false break end
        local cap = b0[m.tr][m.tc]
        b0[m.tr][m.tc] = pc
        b0[m.fr][m.fc] = nil
        m.captured = cap
        m.turn = turn0
        m.moves = mc
        m.last = lastm
        mc = mc + 1
        lastm = { fr = m.fr, fc = m.fc, tr = m.tr, tc = m.tc }
        turn0 = (turn0 == RED) and BLACK or RED
        rebuilt[#rebuilt + 1] = m
    end
    if ok then
        local same = true
        for r = 1, ROWS do
            for c = 1, COLS do
                if b0[r][c] ~= board[r][c] then same = false break end
            end
            if not same then break end
        end
        if not same then rebuilt = {} end
    else
        rebuilt = {}
    end

    local captured = { [RED] = {}, [BLACK] = {} }
    for _, m in ipairs(rebuilt) do
        if m.captured then
            local list = captured[m.turn]
            list[#list + 1] = m.captured
        end
    end

    self.board = board
    self.turn = turn
    self.move_count = moves
    self.last_move = last
    self.history = rebuilt
    self.captured = captured
    self.selected = nil
    self.targets = {}
    self.game_over = nil
    self.check_side = nil
    self:updateStatus()
    return true
end

-- ======================= 局面操作 =======================
function XiangqiDialog:newGame()
    self.board = newBoard()
    self.turn = RED
    self.move_count = 0
    self.last_move = nil
    self.selected = nil
    self.targets = {}
    self.history = {}
    self.captured = { [RED] = {}, [BLACK] = {} }
    self.game_over = nil
    self.check_side = nil
    self.message = "红方先走，点红方棋子开始"
    self:updateStatus()
    self:saveGame()
    self:refreshAll()
end

--- 重新计算将军 / 将死状态
function XiangqiDialog:updateStatus()
    self.check_side = nil
    self.game_over = nil
    if not hasLegalMove(self.board, self.turn) then
        local other = (self.turn == RED) and BLACK or RED
        if isCheck(self.board, self.turn) then
            self.game_over = "checkmate"
            self.message = "将死！" .. SIDE_NAME[self.turn] .. "无路可走，" .. SIDE_NAME[other] .. "胜"
        else
            self.game_over = "stalemate"
            self.message = SIDE_NAME[self.turn] .. "无子可动（困毙），判" .. SIDE_NAME[other] .. "胜"
        end
    elseif isCheck(self.board, self.turn) then
        self.check_side = self.turn
        self.message = SIDE_NAME[self.turn] .. "被将军！必须解将"
    end
end

--- 某个交叉点上，所有合法落点
function XiangqiDialog:legalTargets(r, c)
    local out = {}
    if not self.board[r][c] then return out end
    if sideOf(self.board[r][c]) ~= self.turn then return out end
    for _, m in ipairs(genMoves(self.board, self.turn)) do
        if m.fr == r and m.fc == c then
            out[#out + 1] = { tr = m.tr, tc = m.tc }
        end
    end
    return out
end

function XiangqiDialog:isTarget(r, c)
    for _, t in ipairs(self.targets) do
        if t.tr == r and t.tc == c then return true end
    end
    return false
end

--- 走一步
function XiangqiDialog:doMove(fr, fc, tr, tc)
    local pc = self.board[fr][fc]
    if not pc then return false end
    -- 兜底校验：即使调用方算错，也不能把不合法的着法写进局面
    if not isLegalMove(self.board, fr, fc, tr, tc, self.turn) then
        self.message = explainIllegal(self.board, fr, fc, tr, tc, self.turn)
        self:refreshHint()
        self:doRefresh()
        return false
    end
    local captured = self.board[tr][tc]
    self.history[#self.history + 1] = {
        fr = fr, fc = fc, tr = tr, tc = tc, captured = captured,
        turn = self.turn, moves = self.move_count, last = self.last_move,
    }
    self.board[tr][tc] = pc
    self.board[fr][fc] = nil
    if captured then
        local list = self.captured[self.turn]
        list[#list + 1] = captured
    end
    self.move_count = self.move_count + 1
    self.last_move = { fr = fr, fc = fc, tr = tr, tc = tc }
    self.turn = (self.turn == RED) and BLACK or RED
    self.selected = nil
    self.targets = {}
    self:updateStatus()
    if not self.game_over and not self.check_side then
        self.message = SIDE_NAME[self.turn] .. "走"
    end
    self:saveGame()

    self:markPoint(fr, fc)
    self:markPoint(tr, tc)
    self:markKings()
    self:refreshStatus()
    self:refreshPanel()
    self:refreshHint()
    self:doRefresh()
    return true
end

--- 悔棋
function XiangqiDialog:undo()
    local m = table.remove(self.history)
    if not m then
        self.message = "没有可以悔的棋"
        self:refreshHint()
        self:doRefresh()
        return false
    end
    self.board[m.fr][m.fc] = self.board[m.tr][m.tc]
    self.board[m.tr][m.tc] = m.captured
    if m.captured then
        local list = self.captured[m.turn]
        table.remove(list)
    end
    self.turn = m.turn
    self.move_count = m.moves
    self.last_move = m.last
    self.selected = nil
    self.targets = {}
    self:updateStatus()
    if not self.game_over and not self.check_side then
        self.message = "已悔棋，回到第 " .. self.move_count .. " 手"
    end
    self:saveGame()

    self:markPoint(m.fr, m.fc)
    self:markPoint(m.tr, m.tc)
    self:markKings()
    self:refreshStatus()
    self:refreshPanel()
    self:refreshHint()
    self:doRefresh()
    return true
end

--- 点击棋盘交叉点
function XiangqiDialog:handlePoint(r, c)
    if self.game_over then
        self.message = "本局已结束，点顶栏「新局」重开"
        self:refreshHint()
        self:doRefresh()
        return
    end
    local piece = self.board[r][c]

    if not self.selected then
        if not piece then
            self.message = "请点自己的棋子开始走"
            self:refreshHint()
            self:doRefresh()
            return
        end
        if sideOf(piece) ~= self.turn then
            self.message = "还没轮到" .. SIDE_NAME[sideOf(piece)] .. "走"
            self:refreshHint()
            self:doRefresh()
            return
        end
        self.selected = { r = r, c = c }
        self.targets = self:legalTargets(r, c)
        self.message = "已选" .. pieceName(piece) .. "，点灰点落子"
        self:markPoint(r, c)
        self:refreshStatus()
        self:refreshHint()
        self:doRefresh()
        return
    end

    -- 已选中：再点自己 → 取消
    if r == self.selected.r and c == self.selected.c then
        self.selected = nil
        self.targets = {}
        self.message = "已取消选择"
        self:markPoint(r, c)
        self:refreshStatus()
        self:refreshHint()
        self:doRefresh()
        return
    end

    -- 合法落点 → 走
    if self:isTarget(r, c) then
        self:doMove(self.selected.r, self.selected.c, r, c)
        return
    end

    -- 非法：给原因
    self.message = explainIllegal(self.board, self.selected.r, self.selected.c, r, c, self.turn)
    if piece and sideOf(piece) == self.turn then
        -- 点的是自己另一枚子 → 改选它
        self.selected = { r = r, c = c }
        self.targets = self:legalTargets(r, c)
        self.message = "已选" .. pieceName(piece) .. "，点灰点落子"
    else
        self.selected = nil
        self.targets = {}
    end
    self:markPoint(r, c)
    self:refreshStatus()
    self:refreshHint()
    self:doRefresh()
end

-- ======================= 几何 =======================
--- 交叉点屏幕坐标：交叉点在格子中心
function XiangqiDialog:pointXY(r, c)
    return BOARD_X0 + (c - 0.5) * CELL, BOARD_Y0 + (ROWS - r + 0.5) * CELL
end

--- 屏幕坐标 → 棋盘交叉点（按最近交叉点判定，容差半格）
function XiangqiDialog:pointAt(x, y)
    local c = math.floor((x - BOARD_X0) / CELL) + 1
    local r = ROWS - math.floor((y - BOARD_Y0) / CELL)
    if c < 1 or c > COLS or r < 1 or r > ROWS then return nil end
    local px, py = self:pointXY(r, c)
    if math.abs(x - px) > 28 or math.abs(y - py) > 28 then return nil end
    return r, c
end
-- ======================= 脏区 =======================
function XiangqiDialog:markRect(x1, y1, x2, y2, bucket)
    local key = bucket or "field"
    local d = self._dr[key]
    if not d then
        self._dr[key] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
        self._dr_keys[#self._dr_keys + 1] = key
        return
    end
    if x1 < d.x1 then d.x1 = x1 end
    if y1 < d.y1 then d.y1 = y1 end
    if x2 > d.x2 then d.x2 = x2 end
    if y2 > d.y2 then d.y2 = y2 end
end

--- 标脏一个交叉点（连棋子外框、标记一起刷干净）
function XiangqiDialog:markPoint(r, c)
    local px, py = self:pointXY(r, c)
    self._pts[#self._pts + 1] = { x = px, y = py }
end

--- 两个将/帅的位置（将军标记会变）
function XiangqiDialog:markKings()
    for _, side in ipairs({ RED, BLACK }) do
        local kr, kc = findKing(self.board, side)
        if kr then self:markPoint(kr, kc) end
    end
end

function XiangqiDialog:pushRect(d, pad)
    if not d then return end
    pad = pad or 1
    local x = math.max(0, math.floor(d.x1 - pad))
    local y = math.max(0, math.floor(d.y1 - pad))
    local w = math.min(self.W - x, math.ceil(d.x2 + pad - x))
    local h = math.min(self.H - y, math.ceil(d.y2 + pad - y))
    if w > 0 and h > 0 then
        UIManager:setDirty(self, "ui", Geom:new{ x = x, y = y, w = w, h = h })
    end
end

function XiangqiDialog:refreshAll()
    self._dr = {}
    self._dr_keys = {}
    self._pts = {}
    UIManager:setDirty(self, "ui", Geom:new{ x = 0, y = 0, w = self.W, h = self.H })
end

function XiangqiDialog:refreshStatus()
    self:markRect(0, STATUS_Y0 - 2, self.W, STATUS_Y0 + STATUS_H, "status")
end

function XiangqiDialog:refreshPanel()
    self:markRect(0, PANEL_Y0 - 2, self.W, PANEL_Y0 + PANEL_H, "panel")
end

function XiangqiDialog:refreshHint()
    self:markRect(0, HINT_Y0, self.W, HINT_Y0 + 90, "hint")
end

function XiangqiDialog:doRefresh()
    -- 棋盘交叉点：每点一个矩形（用完即清）
    for _, p in ipairs(self._pts) do
        local x = math.max(0, math.floor(p.x - 30))
        local y = math.max(TOPBAR_H + 2, math.floor(p.y - 30))
        local w = math.min(self.W - x, 61)
        -- 下边界不越过状态条（与状态条留 1px 以上间隙）
        local h = math.min(self.H - y, 61, STATUS_Y0 - 1 - y)
        if w > 0 and h > 0 then
            UIManager:setDirty(self, "ui", Geom:new{ x = x, y = y, w = w, h = h })
        end
    end
    self._pts = {}
    -- 分桶矩形：逐条推送，用完即清（否则矩形会越滚越大）
    for _, key in ipairs(self._dr_keys) do
        local d = self._dr[key]
        if d then self:pushRect(d, 1) end
        self._dr[key] = nil
    end
    self._dr_keys = {}
end

-- ======================= 绘制 =======================
-- 顶栏按钮：新局 / 悔棋 / 退出
local BTN_DEF = {
    { label = "悔棋", x = 392, w = 64, action = "undo" },
    { label = "新局", x = 460, w = 64, action = "new" },
    { label = "退出", x = 528, w = 64, action = "quit" },
}

--- 画一个方框（4 根线）
local function drawFrame(bb, cx, cy, half, thick, color)
    bb:paintRect(cx - half, cy - half, half * 2, thick, color)
    bb:paintRect(cx - half, cy + half - thick, half * 2, thick, color)
    bb:paintRect(cx - half, cy - half, thick, half * 2, color)
    bb:paintRect(cx + half - thick, cy - half, thick, half * 2, color)
end

--- 画 1:1 斜线（九宫斜线）
local function drawDiag(bb, x1, y1, x2, y2, color)
    local dx = x2 - x1
    local dy = y2 - y1
    local steps = math.floor(math.max(math.abs(dx), math.abs(dy)) / 4)
    if steps <= 0 then return end
    local sx = dx / steps
    local sy = dy / steps
    for i = 0, steps do
        bb:paintRect(math.floor(x1 + sx * i) - 1, math.floor(y1 + sy * i) - 1, 4, 4, color)
    end
end

--- 画棋盘位置标记（兵位/炮位的四角小勾）
local function drawMarks(bb, cx, cy, col, color)
    local d = 12
    local len = 7
    if col > 1 then
        bb:paintRect(cx - d, cy - d, len, 1, color)
        bb:paintRect(cx - d, cy - d, 1, len, color)
        bb:paintRect(cx - d, cy + d, len, 1, color)
        bb:paintRect(cx - d, cy + d - len, 1, len, color)
    end
    if col < COLS then
        bb:paintRect(cx + d - len, cy - d, len, 1, color)
        bb:paintRect(cx + d, cy - d, 1, len, color)
        bb:paintRect(cx + d - len, cy + d, len, 1, color)
        bb:paintRect(cx + d, cy + d - len, 1, len, color)
    end
end

function XiangqiDialog:drawCentered(bb, cx, baseline, font, text, color, bold)
    local sz = RenderText:sizeUtf8Text(0, self.W, font, text, false, bold)
    local x = cx - math.floor(sz.x / 2)
    RenderText:renderUtf8Text(bb, x, baseline, font, text, false, bold, color)
    return sz.x
end

function XiangqiDialog:drawButton(bb, x, y, w, h, label)
    bb:paintRect(x, y, w, h, Blitbuffer.COLOR_GRAY_D)
    bb:paintRect(x + 2, y + 2, w - 4, h - 4, Blitbuffer.COLOR_GRAY_5)
    local sz = RenderText:sizeUtf8Text(0, self.W, self.font_btn, label, false, false)
    RenderText:renderUtf8Text(bb, x + math.floor((w - sz.x) / 2), y + math.floor(h / 2) + 6,
        self.font_btn, label, false, false, Blitbuffer.COLOR_WHITE)
end

function XiangqiDialog:paintTo(bb, x, y)
    -- ---------- 全屏底色（不铺的话下层文件管理器会透出来） ----------
    bb:paintRect(0, 0, self.W, self.H, Blitbuffer.COLOR_WHITE)

    -- ---------- 顶栏 ----------
    bb:paintRect(0, 0, self.W, TOPBAR_H, Blitbuffer.COLOR_BLACK)
    RenderText:renderUtf8Text(bb, 12, 30, self.font_title, "中国象棋", false, false, Blitbuffer.COLOR_WHITE)
    for _, b in ipairs(BTN_DEF) do
        -- 先画底色再画文字（反了会被底色盖住）
        bb:paintRect(b.x, 8, b.w - 4, TOPBAR_H - 16, Blitbuffer.COLOR_GRAY_5)
        local sz = RenderText:sizeUtf8Text(0, self.W, self.font_btn, b.label, false, false)
        RenderText:renderUtf8Text(bb, b.x + math.floor((b.w - sz.x) / 2), 30,
            self.font_btn, b.label, false, false, Blitbuffer.COLOR_WHITE)
    end

    -- ---------- 棋盘线 ----------
    local line_col = Blitbuffer.COLOR_GRAY          -- 0xAA 浅灰
    local strong = Blitbuffer.COLOR_GRAY_6          -- 0x66 深一点：外框/九宫/标记

    -- 横线：10 条全部画满 9 列宽（河界上下也是满的）
    for r = 1, ROWS do
        local ly = BOARD_Y0 + (ROWS - r + 0.5) * CELL
        bb:paintRect(LINE_X0, ly, LINE_W, 1, line_col)
    end
    -- 竖线：只有左右边线贯通，中间 7 条在河界处断开
    -- （上段 row 10..6，下段 row 5..1，中间留出河界）
    for c = 1, COLS do
        local lx = BOARD_X0 + (c - 0.5) * CELL
        if c == 1 or c == COLS then
            bb:paintRect(lx, LINE_Y_TOP, 1, LINE_Y_BOT - LINE_Y_TOP, strong)
        else
            bb:paintRect(lx, LINE_Y_TOP, 1, RIVER_Y_TOP - LINE_Y_TOP, line_col)
            bb:paintRect(lx, RIVER_Y_BOT, 1, LINE_Y_BOT - RIVER_Y_BOT, line_col)
        end
    end
    -- 棋盘区域外框（48..552 × 52..612）
    bb:paintRect(BOARD_X0, BOARD_Y0, BOARD_W, 1, Blitbuffer.COLOR_GRAY_4)
    bb:paintRect(BOARD_X0, BOARD_Y1 - 1, BOARD_W, 1, Blitbuffer.COLOR_GRAY_4)
    bb:paintRect(BOARD_X0, BOARD_Y0, 1, BOARD_H, Blitbuffer.COLOR_GRAY_4)
    bb:paintRect(BOARD_X1 - 1, BOARD_Y0, 1, BOARD_H, Blitbuffer.COLOR_GRAY_4)

    -- 九宫斜线
    local p_c = { BOARD_X0 + 3.5 * CELL, BOARD_X0 + 4.5 * CELL, BOARD_X0 + 5.5 * CELL }
    local red_y = { BOARD_Y0 + 9.5 * CELL, BOARD_Y0 + 8.5 * CELL, BOARD_Y0 + 7.5 * CELL }  -- row 1..3
    local blk_y = { BOARD_Y0 + 0.5 * CELL, BOARD_Y0 + 1.5 * CELL, BOARD_Y0 + 2.5 * CELL }  -- row 10..8
    drawDiag(bb, p_c[1], red_y[1], p_c[3], red_y[3], strong)
    drawDiag(bb, p_c[3], red_y[1], p_c[1], red_y[3], strong)
    drawDiag(bb, p_c[1], blk_y[1], p_c[3], blk_y[3], strong)
    drawDiag(bb, p_c[3], blk_y[1], p_c[1], blk_y[3], strong)

    -- 炮位 / 兵位标记
    for _, r in ipairs({ 2, 8 }) do
        for _, c in ipairs({ 2, 8 }) do
            local mx, my = self:pointXY(r, c)
            drawMarks(bb, mx, my, c, strong)
        end
    end
    for _, r in ipairs({ 4, 7 }) do
        for _, c in ipairs({ 1, 3, 5, 7, 9 }) do
            local mx, my = self:pointXY(r, c)
            drawMarks(bb, mx, my, c, strong)
        end
    end

    -- 楚河汉界
    local river_y = (RIVER_Y_TOP + RIVER_Y_BOT) / 2 + 8
    self:drawCentered(bb, BOARD_X0 + 2.5 * CELL, river_y, self.font_mid, "楚河",
        Blitbuffer.COLOR_GRAY_5, false)
    self:drawCentered(bb, BOARD_X0 + 6.5 * CELL, river_y, self.font_mid, "汉界",
        Blitbuffer.COLOR_GRAY_5, false)

    -- ---------- 棋子 ----------
    for r = 1, ROWS do
        for c = 1, COLS do
            local pc = self.board[r][c]
            if pc then
                local px, py = self:pointXY(r, c)
                local isred = (sideOf(pc) == RED)
                local fill = isred and Blitbuffer.COLOR_GRAY_E or Blitbuffer.COLOR_GRAY_3
                local bord = isred and Blitbuffer.COLOR_GRAY_6 or Blitbuffer.COLOR_BLACK
                local fg = isred and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
                -- 先底色后字
                bb:paintRect(px - 23, py - 23, 46, 46, bord)
                bb:paintRect(px - 21, py - 21, 42, 42, fill)
                self:drawCentered(bb, px, py + 9, self.font_piece, PIECE_CHAR[pc], fg, true)
                -- 最后一步走过的子：顶部一条短横线
                if self.last_move and r == self.last_move.tr and c == self.last_move.tc then
                    local my = (py - 29 >= BOARD_Y0) and (py - 29) or (py + 26)
                    bb:paintRect(px - 13, my, 26, 2, Blitbuffer.COLOR_BLACK)
                end
            end
        end
    end

    -- ---------- 被将军一方的帅/将：外面套一圈双线框 ----------
    if self.check_side then
        local kr, kc = findKing(self.board, self.check_side)
        if kr then
            local px, py = self:pointXY(kr, kc)
            drawFrame(bb, px, py, 28, 2, Blitbuffer.COLOR_BLACK)
        end
    end

    -- ---------- 可吃的敌子：外面套一圈粗框 ----------
    for _, t in ipairs(self.targets) do
        if self.board[t.tr][t.tc] then
            local px, py = self:pointXY(t.tr, t.tc)
            drawFrame(bb, px, py, 25, 3, Blitbuffer.COLOR_BLACK)
        end
    end

    -- ---------- 选中子：更粗的方框 ----------
    if self.selected then
        local px, py = self:pointXY(self.selected.r, self.selected.c)
        drawFrame(bb, px, py, 24, 3, Blitbuffer.COLOR_BLACK)
    end

    -- ---------- 合法落点：小灰点 ----------
    for _, t in ipairs(self.targets) do
        if not self.board[t.tr][t.tc] then
            local px, py = self:pointXY(t.tr, t.tc)
            bb:paintCircle(px, py, 5, Blitbuffer.COLOR_GRAY_2)
        end
    end

    -- ---------- 状态条 ----------
    bb:paintRect(0, STATUS_Y0, self.W, STATUS_H, Blitbuffer.COLOR_WHITE)
    bb:paintRect(0, STATUS_Y0, self.W, 1, Blitbuffer.COLOR_GRAY_6)
    local sy = STATUS_Y0 + 20
    local turn_txt = SIDE_NAME[self.turn] .. "走"
    RenderText:renderUtf8Text(bb, 12, sy, self.font_mid, turn_txt, false, true, Blitbuffer.COLOR_BLACK)
    local sel_txt = self.selected and ("选中 " .. pieceName(self.board[self.selected.r][self.selected.c]))
        or "未选中"
    local ssz = RenderText:sizeUtf8Text(0, self.W, self.font_small, sel_txt, false, false)
    RenderText:renderUtf8Text(bb, math.floor((self.W - ssz.x) / 2), sy, self.font_small, sel_txt,
        false, false, Blitbuffer.COLOR_GRAY_5)
    local m_txt = "第" .. self.move_count .. "手"
    local msz = RenderText:sizeUtf8Text(0, self.W, self.font_small, m_txt, false, false)
    RenderText:renderUtf8Text(bb, self.W - msz.x - 12, sy, self.font_small, m_txt,
        false, false, Blitbuffer.COLOR_GRAY_5)
    if self.check_side then
        local c_txt = "将军!"
        local csz = RenderText:sizeUtf8Text(0, self.W, self.font_small, c_txt, false, false)
        RenderText:renderUtf8Text(bb, self.W - csz.x - 12, sy - 17, self.font_small, c_txt,
            false, true, Blitbuffer.COLOR_BLACK)
    end

    -- ---------- 被吃子栏 ----------
    bb:paintRect(0, PANEL_Y0, self.W, PANEL_H, Blitbuffer.COLOR_WHITE)
    bb:paintRect(0, PANEL_Y0, self.W, 1, Blitbuffer.COLOR_GRAY_6)
    local function drawCaptured(bb, x, baseline, side, label)
        RenderText:renderUtf8Text(bb, x, baseline, self.font_small, label, false, false,
            Blitbuffer.COLOR_GRAY_5)
        local list = self.captured[side] or {}
        if #list == 0 then
            RenderText:renderUtf8Text(bb, x + 66, baseline, self.font_small, "无", false, false,
                Blitbuffer.COLOR_GRAY_E)
            return
        end
        local cx = x + 66
        for _, pc in ipairs(list) do
            local isred = (sideOf(pc) == RED)
            local fill = isred and Blitbuffer.COLOR_GRAY_E or Blitbuffer.COLOR_GRAY_3
            local fg = isred and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
            bb:paintRect(cx, baseline - 14, 18, 18, fill)
            bb:paintRect(cx, baseline - 14, 18, 1, Blitbuffer.COLOR_GRAY_6)
            bb:paintRect(cx, baseline + 3, 18, 1, Blitbuffer.COLOR_GRAY_6)
            bb:paintRect(cx, baseline - 14, 1, 18, Blitbuffer.COLOR_GRAY_6)
            bb:paintRect(cx + 17, baseline - 14, 1, 18, Blitbuffer.COLOR_GRAY_6)
            local psz = RenderText:sizeUtf8Text(0, self.W, self.font_small, PIECE_CHAR[pc], false, false)
            RenderText:renderUtf8Text(bb, cx + math.floor((18 - psz.x) / 2), baseline, self.font_small,
                PIECE_CHAR[pc], false, false, fg)
            cx = cx + 22
            if cx > self.W - 30 then break end
        end
    end
    drawCaptured(bb, 12, PANEL_Y0 + 20, RED, "红吃黑:")
    drawCaptured(bb, 12, PANEL_Y0 + 42, BLACK, "黑吃红:")

    -- ---------- 提示行 ----------
    local msg = self.message or ""
    RenderText:renderUtf8Text(bb, 12, HINT_Y0 + 16, self.font_mid, msg, false, false, Blitbuffer.COLOR_BLACK)
    RenderText:renderUtf8Text(bb, 12, HINT_Y0 + 42, self.font_small,
        "点己方棋子 → 点灰点落子 ｜ 长按棋子 = 悔棋 ｜ 顶栏：新局 / 悔棋 / 退出",
        false, false, Blitbuffer.COLOR_GRAY_5)
    RenderText:renderUtf8Text(bb, 12, HINT_Y0 + 64, self.font_tiny,
        "红方：帅 仕 相 车 马 炮 兵    黑方：将 士 象 车 马 炮 卒    浅灰底=红，深灰底=黑",
        false, false, Blitbuffer.COLOR_GRAY_5)
end

-- ======================= 交互 =======================
-- 手势入口：转发给 InputContainer（它按 ges_events / touch zones 分发），
-- 并吞掉所有手势，避免冒泡到下层的文件管理器。
function XiangqiDialog:onGesture(ev)
    InputContainer.onGesture(self, ev)
    return true
end

function XiangqiDialog:onTap(arg, ges)
    ges = ges or arg
    if not ges or not ges.pos then return true end
    local x, y = ges.pos.x, ges.pos.y

    -- 1) 顶栏按钮（整条 44px 顶栏都是可点区）
    if y >= 0 and y <= TOPBAR_H then
        for _, b in ipairs(BTN_DEF) do
            if x >= b.x and x <= b.x + b.w then
                self:doButton(b.action)
                return true
            end
        end
        return true
    end

    -- 2) 棋盘
    local r, c = self:pointAt(x, y)
    if r then
        self:handlePoint(r, c)
        return true
    end
    return true
end

function XiangqiDialog:doButton(action)
    if action == "quit" then
        self:onClose()
    elseif action == "new" then
        self:newGame()
    elseif action == "undo" then
        self:undo()
    end
end

function XiangqiDialog:onClose()
    self:saveGame()
    self.is_closed = true
    self:onCloseWidget()
    UIManager:close(self)
end

-- ======================= 长按 = 悔棋 =======================
function XiangqiDialog:onHold(arg, ges)
    ges = ges or arg
    if not ges or not ges.pos then return false end
    local r, c = self:pointAt(ges.pos.x, ges.pos.y)
    if r and self.board[r][c] then
        self:undo()
        return true
    end
    return false
end

-- 算法函数挂到类上，方便无头测试台直接调用（tools/sim_xiangqi.lua）
XiangqiDialog.newBoard = newBoard
XiangqiDialog.cloneBoard = cloneBoard
XiangqiDialog.parseBoard = parseBoard
XiangqiDialog.boardToRows = boardToRows
XiangqiDialog.sideOf = sideOf
XiangqiDialog.typeOf = typeOf
XiangqiDialog.pieceName = pieceName
XiangqiDialog.inPalace = inPalace
XiangqiDialog.ownHalf = ownHalf
XiangqiDialog.soldierCrossed = soldierCrossed
XiangqiDialog.countBetween = countBetween
XiangqiDialog.pseudoTargets = pseudoTargets
XiangqiDialog.isAttacked = isAttacked
XiangqiDialog.isCheck = isCheck
XiangqiDialog.isLegalMove = isLegalMove
XiangqiDialog.genMoves = genMoves
XiangqiDialog.isCheckmate = isCheckmate
XiangqiDialog.hasLegalMove = hasLegalMove
XiangqiDialog.explainIllegal = explainIllegal
XiangqiDialog.findKing = findKing
XiangqiDialog.RED = RED
XiangqiDialog.BLACK = BLACK

return XiangqiDialog
