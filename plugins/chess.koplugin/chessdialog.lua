--[[--
国际象棋 (Chess) - Kindle 墨水屏定制版

针对 Amazon Kindle Basic（第 7 代 / KT2, 600x800, 16 级灰度, 无前光）的墨水屏特性设计：
- 敌我**不靠颜色**区分（16 级灰度 + 无前光下颜色语义全失效）：
    黑方 = 实心黑圆 + 白色字母，白方 = 白圆 + 黑色字母 + 黑色圆环描边。
- 棋子用**拉丁字母** KQRBNP（黑方）/ kqrbnp（白方），
  绝不使用 Unicode 棋类符号（♔♕♖♘…）：设备字体大概率没有这些字形，会渲染成豆腐块。
- 用**形状**补充状态线索（灰度屏上一眼可辨）：
    · 最后一步走过的子 → 子上方一条短横线；该步起点格 → 四个角括号
    · 被将军的王       → 双线圆环（两个黑环之间留一圈格子底色）
    · 合法落点         → 小灰点；可吃的目标 → 灰色圆环
- 刷新预算：整局**没有任何定时器**，静止时零刷新；
  每次走子只刷「起点格 + 终点格 + 旧标记格」几个 64px 小方块，绝不整屏重刷。
- 交互：同机双人轮流对弈（不做 AI）。
    点自己的子 → 画出全部合法落点 → 点落点走子；
    点非法目标 → 状态条给出**具体原因**（不静默）；
    长按棋子 = 悔棋。

规则范围：完整走子规则 + 王车易位 + 吃过路兵 + 兵到底线自动升变（后）
          + 将军 / 将死 / 逼和 / 三次重复局面和棋。

架构参照本仓库《数独 (Sudoku)》插件（同一套开发规范 docs/design/GAME_PLUGIN_SPEC.md）。
--]]

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

local CELL = 64                 -- 格子边长：8*64 = 512
local BOARD_X0 = 44             -- 棋盘左边：600-512 = 88，左右各留 44
local BOARD_Y0 = 56             -- 棋盘上边：顶栏 44 + 12
local BOARD_W = 8 * CELL        -- 512
local BOARD_H = 8 * CELL        -- 512 → 棋盘底边 568

local STATUS_Y0 = 572           -- 状态条：轮到谁走 / 选中 / 上一步 / 提示原因
local STATUS_H = 34

local PANEL_Y0 = 610            -- 操作区：信息行 + 棋子图例 + 提示
local LINE_A_Y = 628            -- 信息行基线
local LEGEND_CY = 664           -- 棋子图例圆心
local LEGEND_CAPTION_Y = 700    -- 图例说明基线
local HINT_Y = 728              -- 操作提示基线
local OVER_Y = 766              -- 终局大字基线

local PIECE_R = 21              -- 棋子圆半径（直径 42，格子 64）
local RING_T = 2                -- 白子描边厚度

-- 顶栏按钮：至少"新局 / 悔棋 / 退出"，按钮之间留 4px 间隙
-- （必须定义在 onTap 之前，否则函数体里取不到这个局部变量）
local BTN_DEF = {
    { label = "新局", x = 360, w = 72, action = "new" },
    { label = "悔棋", x = 436, w = 72, action = "undo" },
    { label = "退出", x = 512, w = 72, action = "quit" },
}

-- ======================= 棋规引擎（纯逻辑，可被无头测试台直接调用） =======================
-- 局面 state：
--   board[rank][file]，rank 1..8（rank 1 = 白方底线），file 1..8（a..h，白方视角从左到右）
--   turn = "w"(白) / "b"(黑)
--   castling = { w_k, w_q, b_k, b_q }  王车易位权
--   ep = { r, f }  吃过路兵目标格（对方兵刚走两格时"跳过"的那一格），无则 nil
--   half = 已走半回合数
-- 棋子字符：黑方大写 KQRBNP，白方小写 kqrbnp，空格 "."
local Engine = {}
Engine.__index = Engine

--- 蹩马腿开关（默认关闭 = 国际象棋规则）。
--- 国际象棋规则里马是唯一可以跳过棋子的棋子（FIDE 3.9："马不能被任何棋子挡住"），
--- 初始局面的 Nf3/Nc3 都是合法着法；"蹩马腿"是中国象棋的规则。
--- 这里把"腿"（起点朝终点方向斜走一格的那个拐角格）被占时禁止跳出的规则实现出来，
--- 需要时把开关置 true 即可，默认关闭以保证对局符合国际象棋规则。
Engine.knightLegBlock = false

local EMPTY = "."
local FILES = "abcdefgh"

local KNIGHT_OFFSETS = {
    { -2, -1 }, { -2, 1 }, { -1, -2 }, { -1, 2 },
    { 1, -2 }, { 1, 2 }, { 2, -1 }, { 2, 1 },
}
local KING_OFFSETS = {
    { -1, -1 }, { -1, 0 }, { -1, 1 },
    { 0, -1 }, { 0, 1 },
    { 1, -1 }, { 1, 0 }, { 1, 1 },
}
local ROOK_DIRS = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }
local BISHOP_DIRS = { { -1, -1 }, { -1, 1 }, { 1, -1 }, { 1, 1 } }

local function inBoard(r, f)
    return r >= 1 and r <= 8 and f >= 1 and f <= 8
end

--- 棋子颜色：黑方 = 大写，白方 = 小写
function Engine.pieceColor(pc)
    if pc == EMPTY then return nil end
    if string.lower(pc) == pc then return "w" end
    return "b"
end

--- 棋子种类（不分敌我）：K/Q/R/B/N/P
function Engine.pieceType(pc)
    return string.upper(pc)
end

--- (rank,file) -> 代数记法，如 (2,5) -> "e2"
function Engine.algebraic(r, f)
    if not inBoard(r, f) then return "-" end
    return FILES:sub(f, f) .. tostring(r)
end

--- "e2" -> rank, file
function Engine.parseSquare(s)
    s = string.lower(s or "")
    if #s < 2 then return nil end
    local f = FILES:find(s:sub(1, 1), 1, true)
    local r = tonumber(s:sub(2))
    if not f or not r or not inBoard(r, f) then return nil end
    return r, f
end

--- 初始局面
function Engine.newState()
    local b = {}
    for r = 1, 8 do b[r] = {} end
    local wback = { "r", "n", "b", "q", "k", "b", "n", "r" }
    local bback = { "R", "N", "B", "Q", "K", "B", "N", "R" }
    for f = 1, 8 do
        b[1][f] = wback[f]
        b[2][f] = "p"
        b[7][f] = "P"
        b[8][f] = bback[f]
    end
    for r = 3, 6 do
        for f = 1, 8 do b[r][f] = EMPTY end
    end
    return {
        board = b,
        turn = "w",
        castling = { w_k = true, w_q = true, b_k = true, b_q = true },
        ep = nil,
        half = 0,
    }
end

function Engine.cloneState(st)
    local b = {}
    for r = 1, 8 do
        b[r] = {}
        for f = 1, 8 do b[r][f] = st.board[r][f] end
    end
    return {
        board = b,
        turn = st.turn,
        castling = {
            w_k = st.castling.w_k, w_q = st.castling.w_q,
            b_k = st.castling.b_k, b_q = st.castling.b_q,
        },
        ep = st.ep and { r = st.ep.r, f = st.ep.f } or nil,
        half = st.half or 0,
    }
end

--- 造一个自定义局面（测试台用）：list = { {"k","a1"}, {"R","a8"} }
--- turn = "w"/"b"，castle = { w_k=true, ... }（省略则全部为 false）
function Engine.stateFromMap(list, turn, castle)
    local st = Engine.newState()
    for r = 1, 8 do
        for f = 1, 8 do st.board[r][f] = EMPTY end
    end
    for _, item in ipairs(list or {}) do
        local r, f = Engine.parseSquare(item[2])
        if r and item[1] and item[1] ~= EMPTY then
            st.board[r][f] = item[1]
        end
    end
    st.turn = turn or "w"
    st.castling = { w_k = false, w_q = false, b_k = false, b_q = false }
    if castle then
        for k in pairs(castle) do st.castling[k] = castle[k] end
    end
    st.ep = nil
    st.half = 0
    return st
end

--- 王的位置
function Engine.kingSquare(st, side)
    local want = (side == "w") and "k" or "K"
    for r = 1, 8 do
        for f = 1, 8 do
            if st.board[r][f] == want then return r, f end
        end
    end
    return nil
end

--- (r,f) 是否被 bySide 一方攻击
function Engine.isSquareAttacked(st, r, f, bySide)
    local b = st.board
    -- 兵：白兵向上（rank+1）吃，黑兵向下吃
    local dir = (bySide == "w") and -1 or 1
    for _, df in ipairs({ -1, 1 }) do
        local ar, af = r + dir, f + df
        if inBoard(ar, af) then
            local pc = b[ar][af]
            if pc ~= EMPTY and Engine.pieceColor(pc) == bySide and Engine.pieceType(pc) == "P" then
                return true
            end
        end
    end
    -- 马
    for _, d in ipairs(KNIGHT_OFFSETS) do
        local ar, af = r + d[1], f + d[2]
        if inBoard(ar, af) then
            local pc = b[ar][af]
            if pc ~= EMPTY and Engine.pieceColor(pc) == bySide and Engine.pieceType(pc) == "N" then
                return true
            end
        end
    end
    -- 王
    for _, d in ipairs(KING_OFFSETS) do
        local ar, af = r + d[1], f + d[2]
        if inBoard(ar, af) then
            local pc = b[ar][af]
            if pc ~= EMPTY and Engine.pieceColor(pc) == bySide and Engine.pieceType(pc) == "K" then
                return true
            end
        end
    end
    -- 车 / 后（直线）
    for _, d in ipairs(ROOK_DIRS) do
        local ar, af = r + d[1], f + d[2]
        while inBoard(ar, af) do
            local pc = b[ar][af]
            if pc ~= EMPTY then
                if Engine.pieceColor(pc) == bySide then
                    local t = Engine.pieceType(pc)
                    if t == "R" or t == "Q" then return true end
                end
                break
            end
            ar, af = ar + d[1], af + d[2]
        end
    end
    -- 象 / 后（斜线）
    for _, d in ipairs(BISHOP_DIRS) do
        local ar, af = r + d[1], f + d[2]
        while inBoard(ar, af) do
            local pc = b[ar][af]
            if pc ~= EMPTY then
                if Engine.pieceColor(pc) == bySide then
                    local t = Engine.pieceType(pc)
                    if t == "B" or t == "Q" then return true end
                end
                break
            end
            ar, af = ar + d[1], af + d[2]
        end
    end
    return false
end

--- side 是否正被将军
function Engine.inCheck(st, side)
    local r, f = Engine.kingSquare(st, side)
    if not r then return false end
    return Engine.isSquareAttacked(st, r, f, (side == "w") and "b" or "w")
end

--- 生成"伪合法"着法（不检查自己是否被将军）
function Engine.pseudoMoves(st)
    local b = st.board
    local side = st.turn
    local moves = {}

    local function newMove(fr, ff, tr, tf)
        local mv = { fr = fr, ff = ff, tr = tr, tf = tf, piece = b[fr][ff] }
        moves[#moves + 1] = mv
        return mv
    end

    for r = 1, 8 do
        for f = 1, 8 do
            local pc = b[r][f]
            if pc ~= EMPTY and Engine.pieceColor(pc) == side then
                local t = Engine.pieceType(pc)

                if t == "P" then
                    local dir = (side == "w") and 1 or -1
                    local startRank = (side == "w") and 2 or 7
                    local lastRank = (side == "w") and 8 or 1
                    local nr = r + dir
                    -- 直走一格
                    if inBoard(nr, f) and b[nr][f] == EMPTY then
                        local mv = newMove(r, f, nr, f)
                        if nr == lastRank then mv.promotion = true end
                        -- 初始位置直走两格（目标格必须同时留出吃过路兵目标）
                        if r == startRank and b[r + 2 * dir][f] == EMPTY then
                            local mv2 = newMove(r, f, r + 2 * dir, f)
                            mv2.ep = { r = nr, f = f }
                        end
                    end
                    -- 斜吃 + 吃过路兵
                    for _, df in ipairs({ -1, 1 }) do
                        local nf = f + df
                        if inBoard(nr, nf) then
                            local tp = b[nr][nf]
                            if tp ~= EMPTY then
                                -- 永远不生成吃王的着法
                                if Engine.pieceColor(tp) ~= side and Engine.pieceType(tp) ~= "K" then
                                    local mv = newMove(r, f, nr, nf)
                                    mv.captured = tp
                                    mv.capturedSquare = { r = nr, f = nf }
                                    if nr == lastRank then mv.promotion = true end
                                end
                            elseif st.ep and st.ep.r == nr and st.ep.f == nf then
                                -- 吃过路兵：被吃的兵在目标格后一格
                                local cr = (side == "w") and (nr - 1) or (nr + 1)
                                local cp = b[cr][nf]
                                if cp ~= EMPTY and Engine.pieceColor(cp) ~= side
                                    and Engine.pieceType(cp) == "P" then
                                    local mv = newMove(r, f, nr, nf)
                                    mv.epCapture = true
                                    mv.captured = cp
                                    mv.capturedSquare = { r = cr, f = nf }
                                    if nr == lastRank then mv.promotion = true end
                                end
                            end
                        end
                    end

                elseif t == "N" then
                    for _, d in ipairs(KNIGHT_OFFSETS) do
                        local nr, nf = r + d[1], f + d[2]
                        if inBoard(nr, nf) then
                            local blocked = false
                            if Engine.knightLegBlock then
                                -- 蹩马腿（开关打开时生效）：L 形的拐角格被占就走不了
                                local sr = (d[1] > 0) and 1 or ((d[1] < 0) and -1 or 0)
                                local sf = (d[2] > 0) and 1 or ((d[2] < 0) and -1 or 0)
                                blocked = (b[r + sr][f + sf] ~= EMPTY)
                            end
                            if not blocked then
                                local tp = b[nr][nf]
                                if tp == EMPTY then
                                    newMove(r, f, nr, nf)
                                elseif Engine.pieceColor(tp) ~= side and Engine.pieceType(tp) ~= "K" then
                                    local mv = newMove(r, f, nr, nf)
                                    mv.captured = tp
                                    mv.capturedSquare = { r = nr, f = nf }
                                end
                            end
                        end
                    end

                elseif t == "K" then
                    for _, d in ipairs(KING_OFFSETS) do
                        local nr, nf = r + d[1], f + d[2]
                        if inBoard(nr, nf) then
                            local tp = b[nr][nf]
                            if tp == EMPTY then
                                newMove(r, f, nr, nf)
                            elseif Engine.pieceColor(tp) ~= side and Engine.pieceType(tp) ~= "K" then
                                local mv = newMove(r, f, nr, nf)
                                mv.captured = tp
                                mv.capturedSquare = { r = nr, f = nf }
                            end
                        end
                    end
                    -- 王车易位
                    local enemy = (side == "w") and "b" or "w"
                    local home = (side == "w") and 1 or 8
                    local kc = (side == "w") and "k" or "K"
                    local rc = (side == "w") and "r" or "R"
                    if b[home][5] == kc and not Engine.inCheck(st, side) then
                        -- 短易位（王翼）：f、g 两格空，且经过/落点都不被攻击
                        if st.castling[(side == "w") and "w_k" or "b_k"]
                            and b[home][8] == rc and b[home][6] == EMPTY and b[home][7] == EMPTY
                            and not Engine.isSquareAttacked(st, home, 6, enemy)
                            and not Engine.isSquareAttacked(st, home, 7, enemy) then
                            local mv = newMove(home, 5, home, 7)
                            mv.castle = (side == "w") and "K" or "k"
                        end
                        -- 长易位（后翼）：b、c、d 三格空，且 d、c 不被攻击
                        if st.castling[(side == "w") and "w_q" or "b_q"]
                            and b[home][1] == rc and b[home][2] == EMPTY and b[home][3] == EMPTY
                            and b[home][4] == EMPTY
                            and not Engine.isSquareAttacked(st, home, 4, enemy)
                            and not Engine.isSquareAttacked(st, home, 3, enemy) then
                            local mv = newMove(home, 5, home, 3)
                            mv.castle = (side == "w") and "Q" or "q"
                        end
                    end

                else -- R / B / Q
                    local dirs = {}
                    if t == "R" then
                        for _, d in ipairs(ROOK_DIRS) do dirs[#dirs + 1] = d end
                    elseif t == "B" then
                        for _, d in ipairs(BISHOP_DIRS) do dirs[#dirs + 1] = d end
                    else
                        for _, d in ipairs(ROOK_DIRS) do dirs[#dirs + 1] = d end
                        for _, d in ipairs(BISHOP_DIRS) do dirs[#dirs + 1] = d end
                    end
                    for _, d in ipairs(dirs) do
                        local nr, nf = r + d[1], f + d[2]
                        while inBoard(nr, nf) do
                            local tp = b[nr][nf]
                            if tp == EMPTY then
                                newMove(r, f, nr, nf)
                            else
                                if Engine.pieceColor(tp) ~= side and Engine.pieceType(tp) ~= "K" then
                                    local mv = newMove(r, f, nr, nf)
                                    mv.captured = tp
                                    mv.capturedSquare = { r = nr, f = nf }
                                end
                                break
                            end
                            nr, nf = nr + d[1], nf + d[2]
                        end
                    end
                end
            end
        end
    end
    return moves
end

--- 走一步棋（返回新局面，不修改原局面）
function Engine.applyMove(st, mv)
    local ns = Engine.cloneState(st)
    local b = ns.board
    local side = Engine.pieceColor(mv.piece)
    local t = Engine.pieceType(mv.piece)

    -- 移除被吃的子（吃过路兵时吃的是"旁边"那个兵）
    if mv.capturedSquare then
        b[mv.capturedSquare.r][mv.capturedSquare.f] = EMPTY
    end

    -- 原格清空
    b[mv.fr][mv.ff] = EMPTY

    -- 易位时把车也挪过去
    if mv.castle then
        local short = (mv.castle == "K" or mv.castle == "k")
        local rookFrom = short and 8 or 1
        local rookTo = short and 6 or 4
        b[mv.fr][rookFrom] = EMPTY
        b[mv.tr][rookTo] = (side == "w") and "r" or "R"
    end

    -- 落子（兵到底线自动升变为后）
    local placed = mv.piece
    if mv.promotion then
        placed = (side == "w") and "q" or "Q"
    end
    b[mv.tr][mv.tf] = placed

    -- 更新王车易位权
    if t == "K" then
        if side == "w" then
            ns.castling.w_k = false
            ns.castling.w_q = false
        else
            ns.castling.b_k = false
            ns.castling.b_q = false
        end
    elseif t == "R" then
        if mv.fr == 1 and mv.ff == 1 then ns.castling.w_q = false end
        if mv.fr == 1 and mv.ff == 8 then ns.castling.w_k = false end
        if mv.fr == 8 and mv.ff == 1 then ns.castling.b_q = false end
        if mv.fr == 8 and mv.ff == 8 then ns.castling.b_k = false end
    end
    if mv.captured and Engine.pieceType(mv.captured) == "R" then
        local cr, cf = mv.capturedSquare.r, mv.capturedSquare.f
        if cr == 1 and cf == 1 then ns.castling.w_q = false end
        if cr == 1 and cf == 8 then ns.castling.w_k = false end
        if cr == 8 and cf == 1 then ns.castling.b_q = false end
        if cr == 8 and cf == 8 then ns.castling.b_k = false end
    end

    -- 吃过路兵目标格
    ns.ep = nil
    if mv.ep then
        ns.ep = { r = mv.ep.r, f = mv.ep.f }
    end

    ns.turn = (side == "w") and "b" or "w"
    ns.half = (st.half or 0) + 1
    return ns
end

--- 合法着法（伪合法 + 不能让自己被将军）
function Engine.genMoves(st)
    local side = st.turn
    local out = {}
    for _, mv in ipairs(Engine.pseudoMoves(st)) do
        local ns = Engine.applyMove(st, mv)
        if not Engine.inCheck(ns, side) then
            out[#out + 1] = mv
        end
    end
    return out
end

--- 某格出发的全部合法着法
function Engine.movesFrom(st, r, f)
    local out = {}
    for _, mv in ipairs(Engine.genMoves(st)) do
        if mv.fr == r and mv.ff == f then out[#out + 1] = mv end
    end
    return out
end

--- 按代数记法找一步合法着法（找不到返回 nil）
function Engine.findMove(st, fromSq, toSq)
    local fr, ff = Engine.parseSquare(fromSq)
    local tr, tf = Engine.parseSquare(toSq)
    if not fr or not tr then return nil end
    for _, mv in ipairs(Engine.genMoves(st)) do
        if mv.fr == fr and mv.ff == ff and mv.tr == tr and mv.tf == tf then
            return mv
        end
    end
    return nil
end

--- 按代数记法找一步"伪合法"着法（用于解释"为什么这一步非法"）
function Engine.findPseudo(st, fromSq, toSq)
    local fr, ff = Engine.parseSquare(fromSq)
    local tr, tf = Engine.parseSquare(toSq)
    if not fr or not tr then return nil end
    for _, mv in ipairs(Engine.pseudoMoves(st)) do
        if mv.fr == fr and mv.ff == ff and mv.tr == tr and mv.tf == tf then
            return mv
        end
    end
    return nil
end

--- 局面的唯一标识（用于三次重复局面判定）
function Engine.positionKey(st)
    local s = ""
    for r = 1, 8 do
        for f = 1, 8 do s = s .. st.board[r][f] end
    end
    s = s .. st.turn
    local c = st.castling
    s = s .. (c.w_k and "1" or "0") .. (c.w_q and "1" or "0")
        .. (c.b_k and "1" or "0") .. (c.b_q and "1" or "0")
    -- 只有真能吃过路兵时，目标格才算同一局面的一部分
    if st.ep and Engine.epIsRelevant(st) then
        s = s .. "," .. tostring(st.ep.r) .. "," .. tostring(st.ep.f)
    end
    return s
end

--- 当前局面里是否真的存在吃过路兵的机会
function Engine.epIsRelevant(st)
    if not st.ep then return false end
    local side = st.turn
    local dir = (side == "w") and 1 or -1
    local r = st.ep.r - dir
    if not inBoard(r, st.ep.f) then return false end
    for _, df in ipairs({ -1, 1 }) do
        local f = st.ep.f + df
        if inBoard(r, f) then
            local pc = st.board[r][f]
            if pc ~= EMPTY and Engine.pieceColor(pc) == side and Engine.pieceType(pc) == "P" then
                return true
            end
        end
    end
    return false
end

--- 胜负判定：{ over=false } 或 { over=true, result="白方胜", reason="将死" }
function Engine.gameStatus(st)
    local moves = Engine.genMoves(st)
    if #moves == 0 then
        if Engine.inCheck(st, st.turn) then
            return {
                over = true,
                result = (st.turn == "w") and "黑方胜" or "白方胜",
                reason = "将死",
            }
        end
        return { over = true, result = "和棋", reason = "逼和（无子可走）" }
    end
    return { over = false }
end

-- ======================= 存档序列化 =======================
--- 局面 → 文本（Lua 表拼接，不用 JSON，设备上不一定有 JSON 库）
function Engine.serialize(st, last)
    local lines = {}
    lines[#lines + 1] = "v1"
    lines[#lines + 1] = "turn=" .. st.turn
    lines[#lines + 1] = "half=" .. tostring(st.half or 0)
    lines[#lines + 1] = "castle=" .. (st.castling.w_k and "1" or "0") .. ","
        .. (st.castling.w_q and "1" or "0") .. ","
        .. (st.castling.b_k and "1" or "0") .. ","
        .. (st.castling.b_q and "1" or "0")
    if st.ep then
        lines[#lines + 1] = "ep=" .. tostring(st.ep.r) .. "," .. tostring(st.ep.f)
    else
        lines[#lines + 1] = "ep=-"
    end
    if last and last.fr and last.piece then
        lines[#lines + 1] = "last=" .. tostring(last.fr) .. "," .. tostring(last.ff) .. ","
            .. tostring(last.tr) .. "," .. tostring(last.tf) .. "," .. tostring(last.piece)
    else
        lines[#lines + 1] = "last=-"
    end
    for r = 1, 8 do
        local row = ""
        for f = 1, 8 do row = row .. st.board[r][f] end
        lines[#lines + 1] = "r" .. r .. "=" .. row
    end
    return table.concat(lines, "\n") .. "\n"
end

--- 文本 → 局面（损坏时返回 nil，调用方回落到初始局面）
function Engine.deserialize(text)
    if not text or type(text) ~= "string" then return nil end
    local lines = {}
    for raw in text:gmatch("[^\n]+") do
        -- 去掉可能的 \r（Windows 换行），否则行尾多一个字符会导致读档失败
        local line = raw:gsub("\r", "")
        lines[#lines + 1] = line
    end
    if #lines < 14 then return nil end   -- v1 + turn + half + castle + ep + last + 8 行棋盘
    if lines[1] ~= "v1" then return nil end

    local st = { board = {}, castling = {}, ep = nil, half = 0, turn = "w" }
    for r = 1, 8 do st.board[r] = {} end

    local turn, half, castle, ep, last
    local seen_rows = 0
    for i = 2, #lines do
        local k, v = lines[i]:match("^([%w_]+)=(.*)$")
        if not k then return nil end
        if k == "turn" then
            turn = v
        elseif k == "half" then
            half = tonumber(v)
        elseif k == "castle" then
            castle = v
        elseif k == "ep" then
            ep = v
        elseif k == "last" then
            last = v
        elseif k:match("^r%d$") then
            local idx = tonumber(k:sub(2))
            if not idx or idx < 1 or idx > 8 then return nil end
            if #v ~= 8 then return nil end
            for i = 1, 8 do
                local ch = v:sub(i, i)
                if ch == EMPTY then
                    st.board[idx][i] = EMPTY
                elseif ch:match("[KQRBNPkqrbnp]") then
                    st.board[idx][i] = ch
                else
                    return nil
                end
            end
            seen_rows = seen_rows + 1
        else
            return nil
        end
    end
    if seen_rows ~= 8 then return nil end
    if turn ~= "w" and turn ~= "b" then return nil end
    if not half then return nil end

    -- 王车易位权
    local cw = { castle:match("^(%d)%D(%d)%D(%d)%D(%d)$") }
    if not cw[1] then return nil end
    st.castling.w_k = (cw[1] == "1")
    st.castling.w_q = (cw[2] == "1")
    st.castling.b_k = (cw[3] == "1")
    st.castling.b_q = (cw[4] == "1")

    -- 吃过路兵目标格
    if ep and ep ~= "-" then
        local er, ef = ep:match("^(%d+)%D(%d+)$")
        er, ef = tonumber(er), tonumber(ef)
        if not er or not ef or not inBoard(er, ef) then return nil end
        st.ep = { r = er, f = ef }
    end

    -- 每个王必须都在，且各只有一个
    local wk, bk = 0, 0
    for r = 1, 8 do
        for f = 1, 8 do
            local pc = st.board[r][f]
            if pc == "k" then wk = wk + 1 end
            if pc == "K" then bk = bk + 1 end
        end
    end
    if wk ~= 1 or bk ~= 1 then return nil end

    st.turn = turn
    st.half = half

    -- 最后一步
    local lastmv = nil
    if last and last ~= "-" then
        local fr, ff, tr, tf, pc = last:match("^(%d+)%D(%d+)%D(%d+)%D(%d+)%D(%a)$")
        fr, ff, tr, tf = tonumber(fr), tonumber(ff), tonumber(tr), tonumber(tf)
        if fr and ff and tr and tf and pc and inBoard(fr, ff) and inBoard(tr, tf) then
            lastmv = { fr = fr, ff = ff, tr = tr, tf = tf, piece = pc }
        end
    end
    return st, lastmv
end

-- ======================= 对话框 =======================
local ChessDialog = InputContainer:extend{
    name = "chess_dialog",
    dimen = Geom:new{ x = 0, y = 0, w = 600, h = 800 },
    modal = true,
    -- 必须关闭原生 double_tap：否则单次 tap 会被延迟 300ms 才下发，
    -- "点子 → 点落点"这种高频操作不能忍受延迟。
    disable_double_tap = true,
}

-- ======================= 初始化 =======================
function ChessDialog:init()
    self.show_parent = self

    self.W = Screen:getWidth()
    self.H = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }

    -- ⚠️ 必须显式注册手势！
    -- InputContainer:onGesture 只会把事件分发给 registerTouchZones 注册的触摸区
    -- 和 ges_events 里声明的手势，**不会**自动调用我们重写的 onTap/onHold。
    local full_range = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = full_range } },
        Hold = { GestureRange:new{ ges = "hold", range = full_range } },
    }

    -- 字体缓存
    self.font_title = Font:getFace("tfont", 20)
    self.font_big = Font:getFace("tfont", 22)
    self.font_btn = Font:getFace("cfont", 15)
    self.font_piece = Font:getFace("cfont", 22)
    self.font_mid = Font:getFace("cfont", 15)
    self.font_small = Font:getFace("cfont", 13)
    self.font_mini = Font:getFace("cfont", 11)
    self.font_micro = Font:getFace("cfont", 12)

    self.save_file = DataStorage:getSettingsDir() .. "/chess_save.txt"

    -- 脏区分桶：棋盘格 / 状态条 / 操作区
    self._dr = { sq = {} }

    -- 局面与状态
    self.st = Engine.newState()
    self.last_move = nil
    self.history = {}         -- 悔棋栈
    self.rep_keys = {}        -- 历史局面标识（三次重复用）
    self.sel = nil            -- 选中的子 {r,f}
    self.sel_moves = {}       -- 选中子的全部合法落点
    self.overlay_squares = {} -- 当前画了动态叠加标记的格子
    self.message = ""         -- 状态条中间的提示文案
    self.game_status = { over = false }

    if not self:loadGame() then
        self.st = Engine.newState()
        self.last_move = nil
        self.rep_keys = { Engine.positionKey(self.st) }
    end

    self:updateStatus()
    self:refreshAll()
end

-- ======================= 存档 =======================
function ChessDialog:saveGame()
    local f = io.open(self.save_file, "w")
    if not f then return end
    f:write(Engine.serialize(self.st, self.last_move))
    f:close()
end

function ChessDialog:loadGame()
    local f = io.open(self.save_file, "r")
    if not f then return false end
    local text = f:read("*a")
    f:close()
    local st, last = Engine.deserialize(text)
    if not st then return false end
    self.st = st
    self.last_move = last
    self.history = {}
    self.rep_keys = { Engine.positionKey(st) }
    return true
end

-- ======================= 局面操作 =======================
--- 新开一局
function ChessDialog:newGame()
    self.st = Engine.newState()
    self.last_move = nil
    self.history = {}
    self.rep_keys = { Engine.positionKey(self.st) }
    self.sel = nil
    self.sel_moves = {}
    self:updateStatus()
    self.message = "新局开始，白方先走"
    self:refreshAll()
    self:saveGame()
end

--- 悔棋：退回上一步
function ChessDialog:undo()
    local h = table.remove(self.history)
    if not h then
        self.message = "没有可悔的棋"
        self:markStatusDirty()
        self:doRefresh()
        return
    end
    self.st = h.st
    self.last_move = h.last
    while #self.rep_keys > h.rep_len do table.remove(self.rep_keys) end
    self.sel = nil
    self.sel_moves = {}
    self:updateStatus()
    self.message = "已悔棋，轮到" .. (self.st.turn == "w" and "白方" or "黑方") .. "走"
    self:syncOverlays()
    self:markStatusDirty()
    self:markPanelDirty()
    self:saveGame()
    self:doRefresh()
end

--- 走一步棋
function ChessDialog:makeMove(mv)
    if not mv then return end
    local h = {
        st = Engine.cloneState(self.st),
        last = self.last_move,
        rep_len = #self.rep_keys,
    }
    self.history[#self.history + 1] = h
    if #self.history > 200 then table.remove(self.history, 1) end

    self.st = Engine.applyMove(self.st, mv)
    self.last_move = mv
    self.rep_keys[#self.rep_keys + 1] = Engine.positionKey(self.st)
    self.sel = nil
    self.sel_moves = {}
    self:updateStatus()
    self:syncOverlays()
    self:markStatusDirty()
    self:markPanelDirty()
    self:saveGame()
end

--- 刷新状态文案（将军 / 将死 / 和棋 / 三次重复）
function ChessDialog:updateStatus()
    local st = self.st
    local status = Engine.gameStatus(st)
    self.game_status = status
    self.message = ""
    if status.over then
        self.message = status.reason .. "：" .. status.result
    else
        -- 三次重复局面
        local key = Engine.positionKey(st)
        local cnt = 0
        for _, k in ipairs(self.rep_keys) do
            if k == key then cnt = cnt + 1 end
        end
        if cnt >= 3 then
            self.game_status = { over = true, result = "和棋", reason = "三次重复局面" }
            self.message = "三次重复局面：和棋"
        elseif Engine.inCheck(st, st.turn) then
            self.message = (st.turn == "w") and "将军！白方必须应将" or "将军！黑方必须应将"
        end
    end
end

-- ======================= 几何 =======================
--- 屏幕坐标 → (rank, file)
function ChessDialog:squareAt(x, y)
    if x < BOARD_X0 or x >= BOARD_X0 + BOARD_W then return nil end
    if y < BOARD_Y0 or y >= BOARD_Y0 + BOARD_H then return nil end
    local f = math.floor((x - BOARD_X0) / CELL) + 1
    local r = 8 - math.floor((y - BOARD_Y0) / CELL)
    return r, f
end

--- (rank, file) → 格子中心
function ChessDialog:squareCenter(r, f)
    return BOARD_X0 + (f - 1) * CELL + math.floor(CELL / 2),
        BOARD_Y0 + (8 - r) * CELL + math.floor(CELL / 2)
end

--- 格子底色（深浅相间的棋盘格）
function ChessDialog:squareColor(r, f)
    if ((r + f) % 2) == 1 then return Blitbuffer.COLOR_WHITE end
    return Blitbuffer.COLOR_GRAY_C
end

-- ======================= 脏区 =======================
local function sqKey(r, f) return r .. "_" .. f end

--- 标脏一个格子（内缩 1px，相邻刷新块之间留出间隙，避免被合并成大矩形）
function ChessDialog:markSquareDirty(r, f)
    -- 脏区"用完即清"：doRefresh 会把 sq 桶置空，这里按需重建
    local sq = self._dr.sq
    if not sq then
        sq = {}
        self._dr.sq = sq
    end
    local x = BOARD_X0 + (f - 1) * CELL
    local y = BOARD_Y0 + (8 - r) * CELL
    sq[sqKey(r, f)] = { x = x + 1, y = y + 1, w = CELL - 2, h = CELL - 2 }
end

function ChessDialog:markSquareDirtyKey(k)
    local r, f = string.match(k, "^(%d+)_(%d+)$")
    if r and f then self:markSquareDirty(tonumber(r), tonumber(f)) end
end

function ChessDialog:markStatusDirty()
    self._dr.status = { x = 0, y = STATUS_Y0 - 2, w = self.W, h = STATUS_H + 4 }
end

function ChessDialog:markPanelDirty()
    self._dr.panel = { x = 0, y = PANEL_Y0, w = self.W, h = self.H - PANEL_Y0 }
end

function ChessDialog:markRect(x1, y1, x2, y2, bucket)
    local key = bucket or "field"
    local d = self._dr[key]
    if not d then
        self._dr[key] = { x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
        return
    end
    if x1 < d.x then d.x = x1 end
    if y1 < d.y then d.y = y1 end
    if x2 > d.x + d.w then d.w = x2 - d.x end
    if y2 > d.y + d.h then d.h = y2 - d.y end
end

--- 重新计算"哪些格子上画了动态标记"，并把这些格子标脏
function ChessDialog:syncOverlays()
    local old = self.overlay_squares or {}
    local new = {}
    if self.sel then new[sqKey(self.sel.r, self.sel.f)] = true end
    for _, mv in ipairs(self.sel_moves) do new[sqKey(mv.tr, mv.tf)] = true end
    if self.last_move then
        new[sqKey(self.last_move.fr, self.last_move.ff)] = true
        new[sqKey(self.last_move.tr, self.last_move.tf)] = true
    end
    for k in pairs(old) do self:markSquareDirtyKey(k) end
    self.overlay_squares = new
    for k in pairs(new) do self:markSquareDirtyKey(k) end
end

function ChessDialog:pushRect(d, pad)
    if not d then return end
    pad = pad or 0
    local x = math.max(0, math.floor(d.x - pad))
    local y = math.max(0, math.floor(d.y - pad))
    local w = math.min(self.W - x, math.ceil(d.x + d.w + pad - x))
    local h = math.min(self.H - y, math.ceil(d.y + d.h + pad - y))
    if w > 0 and h > 0 then
        UIManager:setDirty(self, "ui", Geom:new{ x = x, y = y, w = w, h = h })
    end
end

function ChessDialog:refreshAll()
    self._dr = { sq = {} }
    UIManager:setDirty(self, "ui", Geom:new{ x = 0, y = 0, w = self.W, h = self.H })
end

--- 推送所有脏区（脏区用完即清）
function ChessDialog:doRefresh()
    local d = self._dr
    if d.sq then
        for _, rect in pairs(d.sq) do
            self:pushRect(rect, 0)
        end
        d.sq = nil
    end
    if d.status then
        self:pushRect(d.status, 0)
        d.status = nil
    end
    if d.panel then
        self:pushRect(d.panel, 0)
        d.panel = nil
    end
end

-- ======================= 交互 =======================
--- 解释一步非法着法的原因（状态条要给出具体原因，不静默）
function ChessDialog:explainIllegal(fr, ff, tr, tf)
    local st = self.st
    local pc = st.board[fr][ff]
    local tp = st.board[tr][tf]
    local t = Engine.pieceType(pc)
    local side = Engine.pieceColor(pc)
    local from = Engine.algebraic(fr, ff)
    local to = Engine.algebraic(tr, tf)

    if fr == tr and ff == tf then
        return "不能原地不动"
    end

    -- 己方子不能吃；王永远不能被吃
    if tp ~= EMPTY then
        if Engine.pieceColor(tp) == side then
            return "不能吃自己的子（" .. to .. "）"
        end
        if Engine.pieceType(tp) == "K" then
            return "不能吃对方的王"
        end
    end

    -- 这一步本身合法、只是没有解将？
    local pseudo = Engine.findPseudo(st, from, to)
    if pseudo then
        local ns = Engine.applyMove(st, pseudo)
        if Engine.inCheck(ns, side) then
            return "将军未解除：必须先应将"
        end
    end

    local dr = tr - fr
    local df = tf - ff
    local adr = math.abs(dr)
    local adf = math.abs(df)

    if t == "P" then
        local dir = (side == "w") and 1 or -1
        if dr * dir < 0 then
            return "兵不能后退"
        end
        if adr == 0 and adf == 0 then
            return "兵不能这样走"
        end
        if adr == 0 then
            if adf ~= 1 then
                return "兵只能直走一格（初始位置可走两格）"
            end
            if tp ~= EMPTY then
                return "兵不能直着吃子"
            end
        else
            -- 斜走：只能吃子
            if adf ~= 1 then
                return "兵只能直走或斜吃一格"
            end
            if tp == EMPTY then
                return "兵只能斜吃有子的格子"
            end
        end
    elseif t == "N" then
        if not ((adr == 2 and adf == 1) or (adr == 1 and adf == 2)) then
            return "马只能走日字"
        end
        -- 蹩马腿（仅在开关打开时才是非法原因）
        if Engine.knightLegBlock then
            local sr = (dr > 0) and 1 or ((dr < 0) and -1 or 0)
            local sf = (df > 0) and 1 or ((df < 0) and -1 or 0)
            if sr ~= 0 and sf ~= 0 and st.board[fr + sr][ff + sf] ~= EMPTY then
                return "马被蹩住了腿"
            end
        end
    elseif t == "B" then
        if adr ~= adf then
            return "象只能走斜线"
        end
        return self:blockReason(st, fr, ff, tr, tf, "象被塞住了眼")
    elseif t == "R" then
        if dr ~= 0 and df ~= 0 then
            return "车只能走直线"
        end
        return self:blockReason(st, fr, ff, tr, tf, "车被挡住了路")
    elseif t == "Q" then
        if dr ~= 0 and df ~= 0 and adr ~= adf then
            return "后只能走直线或斜线"
        end
        return self:blockReason(st, fr, ff, tr, tf, "后被挡住了路")
    elseif t == "K" then
        if adr > 1 or adf > 1 then
            return "王只能走一格（易位请点 g1/c1 等落点）"
        end
        -- 王不能走进被攻击的格子
        local enemy = (side == "w") and "b" or "w"
        if Engine.isSquareAttacked(st, tr, tf, enemy) then
            return "那格被攻击：王不能走进被攻击的格子"
        end
        return "王只能走一格"
    end
    return "不能这样走（" .. from .. "-" .. to .. "）"
end

--- 直线/斜线棋子被挡住的提示
function ChessDialog:blockReason(st, fr, ff, tr, tf, msg)
    local dr = tr - fr
    local df = tf - ff
    local steps = math.max(math.abs(dr), math.abs(df))
    local sr = (dr == 0) and 0 or ((dr > 0) and 1 or -1)
    local sf = (df == 0) and 0 or ((df > 0) and 1 or -1)
    for i = 1, steps - 1 do
        if st.board[fr + sr * i][ff + sf * i] ~= EMPTY then
            return msg
        end
    end
    return "不能这样走"
end

--- 点了一个格子
function ChessDialog:onSquareTap(r, f)
    local st = self.st
    local pc = st.board[r][f]

    if self.game_status.over then
        self.message = self.game_status.reason .. "：" .. self.game_status.result .. "，点新局再来"
        self:markStatusDirty()
        self:doRefresh()
        return
    end

    if pc ~= EMPTY and Engine.pieceColor(pc) == st.turn then
        -- 点自己的子：选中 / 改选 / 取消
        if self.sel and self.sel.r == r and self.sel.f == f then
            self.sel = nil
            self.sel_moves = {}
            self.message = "已取消选择"
        else
            self.sel = { r = r, f = f }
            self.sel_moves = Engine.movesFrom(st, r, f)
            self.message = "已选 " .. Engine.algebraic(r, f) .. "，可走 " .. #self.sel_moves .. " 格"
        end
        self:syncOverlays()
        self:markStatusDirty()
        self:markPanelDirty()
        self:doRefresh()
        return
    end

    if self.sel then
        -- 点落点
        local mv = Engine.findMove(st, Engine.algebraic(self.sel.r, self.sel.f), Engine.algebraic(r, f))
        if mv then
            self:makeMove(mv)
            self:doRefresh()
            return
        end
        self.message = self:explainIllegal(self.sel.r, self.sel.f, r, f)
        self:markStatusDirty()
        self:doRefresh()
        return
    end

    -- 没选中任何子
    if pc ~= EMPTY then
        self.message = "轮到" .. (st.turn == "w" and "白方" or "黑方") .. "走，不能动对方的棋子"
    else
        self.message = "先点自己的棋子，再点落点"
    end
    self:markStatusDirty()
    self:doRefresh()
end

--- 手势入口：转发给 InputContainer 并吞掉，避免冒泡到下层的文件管理器
function ChessDialog:onGesture(ev)
    InputContainer.onGesture(self, ev)
    return true
end

function ChessDialog:onTap(arg, ges)
    ges = ges or arg
    if not ges or not ges.pos then return true end
    local x, y = ges.pos.x, ges.pos.y

    -- 顶栏按钮
    if y >= 0 and y <= TOPBAR_H then
        for _, b in ipairs(BTN_DEF) do
            if x >= b.x and x <= b.x + b.w then
                self:doButton(b.action)
                return true
            end
        end
        return true
    end

    -- 棋盘
    local r, f = self:squareAt(x, y)
    if r then
        self:onSquareTap(r, f)
        return true
    end
    return true
end

--- 长按棋子 = 悔棋
function ChessDialog:onHold(arg, ges)
    ges = ges or arg
    if not ges or not ges.pos then return false end
    local r, f = self:squareAt(ges.pos.x, ges.pos.y)
    if not r then return false end
    if self.st.board[r][f] == EMPTY then
        self.message = "长按棋盘上的棋子可悔棋"
        self:markStatusDirty()
        self:doRefresh()
        return false
    end
    self:undo()
    return true
end

-- 顶栏按钮定义见文件顶部（BTN_DEF）

function ChessDialog:doButton(action)
    if action == "quit" then
        self:onClose()
    elseif action == "new" then
        self:newGame()
    elseif action == "undo" then
        self:undo()
    end
end

function ChessDialog:onClose()
    self:saveGame()
    self.is_closed = true
    self:onCloseWidget()
    UIManager:close(self)
end

-- ======================= 绘制 =======================
--- 居中画一个字符串，返回它占的宽度
function ChessDialog:drawCentered(bb, cx, baseline, font, text, color, bold)
    local sz = RenderText:sizeUtf8Text(0, self.W, font, text, false, bold or false)
    local w = sz and sz.x or 0
    RenderText:renderUtf8Text(bb, cx - math.floor(w / 2), baseline, font, text,
        false, bold or false, color)
    return w
end

--- 画一个棋子：黑方=实心黑圆+白字，白方=白圆+黑字+黑环
--- checked = true 时额外套一圈"双线圆环"（被将军的王）
function ChessDialog:drawPiece(bb, pc, cx, cy, base, checked)
    local r = PIECE_R
    if checked then
        -- 先画大黑圆，再用格子底色填回中间一圈 → 两个黑环之间留出底色缝隙
        bb:paintCircle(cx, cy, r + 7, Blitbuffer.COLOR_BLACK)
        bb:paintCircle(cx, cy, r + 4, base)
    end
    if Engine.pieceColor(pc) == "w" then
        bb:paintCircle(cx, cy, r + RING_T, Blitbuffer.COLOR_BLACK)
        bb:paintCircle(cx, cy, r, Blitbuffer.COLOR_WHITE)
        self:drawPieceLetter(bb, pc, cx, cy, Blitbuffer.COLOR_BLACK)
    else
        bb:paintCircle(cx, cy, r, Blitbuffer.COLOR_BLACK)
        self:drawPieceLetter(bb, pc, cx, cy, Blitbuffer.COLOR_WHITE)
    end
end

function ChessDialog:drawPieceLetter(bb, pc, cx, cy, color)
    local sz = RenderText:sizeUtf8Text(0, self.W, self.font_piece, pc, false, true)
    local w = sz and sz.x or 0
    RenderText:renderUtf8Text(bb, cx - math.floor(w / 2), cy + 8,
        self.font_piece, pc, false, true, color)
end

--- 图例用的小棋子
function ChessDialog:drawMiniPiece(bb, pc, cx, cy)
    local r = 13
    if Engine.pieceColor(pc) == "w" then
        bb:paintCircle(cx, cy, r + 2, Blitbuffer.COLOR_BLACK)
        bb:paintCircle(cx, cy, r, Blitbuffer.COLOR_WHITE)
    else
        bb:paintCircle(cx, cy, r, Blitbuffer.COLOR_BLACK)
    end
    local sz = RenderText:sizeUtf8Text(0, self.W, self.font_mid, pc, false, true)
    local w = sz and sz.x or 0
    local color = (Engine.pieceColor(pc) == "w") and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    RenderText:renderUtf8Text(bb, cx - math.floor(w / 2), cy + 5,
        self.font_mid, pc, false, true, color)
end

--- 画一个格子上的全部内容（底色 → 标记 → 棋子）
function ChessDialog:paintSquare(bb, r, f)
    local x = BOARD_X0 + (f - 1) * CELL
    local y = BOARD_Y0 + (8 - r) * CELL
    local cx, cy = self:squareCenter(r, f)
    local base = self:squareColor(r, f)
    local pc = self.st.board[r][f]

    -- 底色
    bb:paintRect(x, y, CELL, CELL, base)

    -- 选中格：内嵌粗框（不整行反白）
    if self.sel and self.sel.r == r and self.sel.f == f then
        bb:paintRect(x + 2, y + 2, CELL - 4, 3, Blitbuffer.COLOR_BLACK)
        bb:paintRect(x + 2, y + CELL - 5, CELL - 4, 3, Blitbuffer.COLOR_BLACK)
        bb:paintRect(x + 2, y + 2, 3, CELL - 4, Blitbuffer.COLOR_BLACK)
        bb:paintRect(x + CELL - 5, y + 2, 3, CELL - 4, Blitbuffer.COLOR_BLACK)
    end

    -- 最后一步的起点格：四角括号
    if self.last_move and self.last_move.fr == r and self.last_move.ff == f then
        local L = 16
        local T = 3
        local o = 3
        bb:paintRect(x + o, y + o, L, T, Blitbuffer.COLOR_BLACK)
        bb:paintRect(x + o, y + o, T, L, Blitbuffer.COLOR_BLACK)
        bb:paintRect(x + CELL - o - L, y + o, L, T, Blitbuffer.COLOR_BLACK)
        bb:paintRect(x + CELL - o - T, y + o, T, L, Blitbuffer.COLOR_BLACK)
        bb:paintRect(x + o, y + CELL - o - T, L, T, Blitbuffer.COLOR_BLACK)
        bb:paintRect(x + o, y + CELL - o - L, T, L, Blitbuffer.COLOR_BLACK)
        bb:paintRect(x + CELL - o - L, y + CELL - o - T, L, T, Blitbuffer.COLOR_BLACK)
        bb:paintRect(x + CELL - o - T, y + CELL - o - L, T, L, Blitbuffer.COLOR_BLACK)
    end

    -- 合法落点：安静目标画小灰点，能吃的目标画灰圆环
    for _, mv in ipairs(self.sel_moves) do
        if mv.tr == r and mv.tf == f then
            if mv.captured or mv.epCapture then
                bb:paintCircle(cx, cy, 26, Blitbuffer.COLOR_GRAY_4)
                bb:paintCircle(cx, cy, 24, base)
            else
                bb:paintCircle(cx, cy, 6, Blitbuffer.COLOR_GRAY_5)
            end
        end
    end

    -- 棋子
    if pc ~= EMPTY then
        local checked = false
        if Engine.pieceType(pc) == "K" then
            local side = Engine.pieceColor(pc)
            checked = Engine.inCheck(self.st, side)
        end
        self:drawPiece(bb, pc, cx, cy, base, checked)

        -- 最后一步走过的子：上方一条短横线
        if self.last_move and self.last_move.tr == r and self.last_move.tf == f then
            bb:paintRect(cx - 11, cy - 30, 22, 3, Blitbuffer.COLOR_BLACK)
        end
    end
end

function ChessDialog:paintTo(bb, x, y)
    -- ---------- 全屏底色（不铺的话下层文件管理器会透出来）----------
    bb:paintRect(0, 0, self.W, self.H, Blitbuffer.COLOR_WHITE)

    -- ---------- 顶栏 ----------
    bb:paintRect(0, 0, self.W, TOPBAR_H, Blitbuffer.COLOR_BLACK)
    RenderText:renderUtf8Text(bb, 12, 30, self.font_title, "国际象棋",
        false, false, Blitbuffer.COLOR_WHITE)
    for _, b in ipairs(BTN_DEF) do
        local dim = (b.action == "undo" and #self.history == 0)
        -- 先画底色再画文字（反了文字会被底色盖住）
        bb:paintRect(b.x, 8, b.w, TOPBAR_H - 16,
            dim and Blitbuffer.COLOR_GRAY_7 or Blitbuffer.COLOR_GRAY_5)
        local sz = RenderText:sizeUtf8Text(0, self.W, self.font_btn, b.label, false, false)
        local w = sz and sz.x or 0
        RenderText:renderUtf8Text(bb, b.x + math.floor((b.w - w) / 2), 30,
            self.font_btn, b.label, false, false, Blitbuffer.COLOR_WHITE)
    end

    -- ---------- 棋盘 ----------
    bb:paintRect(BOARD_X0 - 3, BOARD_Y0 - 3, BOARD_W + 6, BOARD_H + 6, Blitbuffer.COLOR_BLACK)
    for r = 1, 8 do
        for f = 1, 8 do
            self:paintSquare(bb, r, f)
        end
    end
    -- 左侧留白里的等级标号（1 在最下面，白方视角）
    for r = 1, 8 do
        local cy = BOARD_Y0 + (8 - r) * CELL + math.floor(CELL / 2)
        local sz = RenderText:sizeUtf8Text(0, self.W, self.font_mini, tostring(r), false, false)
        local w = sz and sz.x or 0
        RenderText:renderUtf8Text(bb, BOARD_X0 - 8 - w, cy + 4, self.font_mini, tostring(r),
            false, false, Blitbuffer.COLOR_GRAY_4)
    end

    -- ---------- 状态条 ----------
    bb:paintRect(0, STATUS_Y0, self.W, STATUS_H, Blitbuffer.COLOR_WHITE)
    bb:paintRect(0, STATUS_Y0, self.W, 1, Blitbuffer.COLOR_GRAY_6)
    local sy = STATUS_Y0 + 23
    local white = (self.st.turn == "w")
    -- 轮次指示：白方=白圆黑环，黑方=实心黑圆
    if white then
        bb:paintCircle(20, sy - 5, 9, Blitbuffer.COLOR_BLACK)
        bb:paintCircle(20, sy - 5, 7, Blitbuffer.COLOR_WHITE)
    else
        bb:paintCircle(20, sy - 5, 9, Blitbuffer.COLOR_BLACK)
    end
    RenderText:renderUtf8Text(bb, 34, sy, self.font_mid, white and "白方走" or "黑方走",
        false, false, Blitbuffer.COLOR_BLACK)
    -- 状态条右侧：有提示时显示提示（非法原因/将军/终局），
    -- 否则显示"当前选中的子 + 最后一步"
    local msg = self.message
    if msg == "" then
        local selTxt = self.sel and Engine.algebraic(self.sel.r, self.sel.f) or "-"
        local lastTxt = "-"
        if self.last_move then
            lastTxt = Engine.algebraic(self.last_move.fr, self.last_move.ff) .. "-"
                .. Engine.algebraic(self.last_move.tr, self.last_move.tf)
        end
        if self.sel then
            msg = "选中 " .. selTxt .. "  上步 " .. lastTxt
        else
            msg = "点自己的棋子开始  上步 " .. lastTxt
        end
    end
    local msz = RenderText:sizeUtf8Text(0, self.W, self.font_small, msg, false, false)
    local mw = msz and msz.x or 0
    RenderText:renderUtf8Text(bb, self.W - 12 - mw, sy, self.font_small, msg,
        false, false, Blitbuffer.COLOR_BLACK)

    -- ---------- 操作区 ----------
    bb:paintRect(0, PANEL_Y0, self.W, self.H - PANEL_Y0, Blitbuffer.COLOR_WHITE)
    bb:paintRect(0, PANEL_Y0, self.W, 1, Blitbuffer.COLOR_GRAY_6)

    -- 信息行：选中 / 上一步 / 步数 / 将军
    local selTxt = self.sel and Engine.algebraic(self.sel.r, self.sel.f) or "无"
    local lastTxt = "-"
    if self.last_move then
        lastTxt = Engine.algebraic(self.last_move.fr, self.last_move.ff) .. "-"
            .. Engine.algebraic(self.last_move.tr, self.last_move.tf)
    end
    local info = "选中 " .. selTxt .. "   上一步 " .. lastTxt .. "   第 " .. (self.st.half or 0) .. " 步"
    if Engine.inCheck(self.st, self.st.turn) and not self.game_status.over then
        info = "将军！" .. info
    end
    RenderText:renderUtf8Text(bb, 12, LINE_A_Y, self.font_small, info,
        false, false, Blitbuffer.COLOR_GRAY_4)

    -- 棋子图例：大写 = 黑方，小写 = 白方
    local legend = { "K", "Q", "R", "B", "N", "P", "k", "q", "r", "b", "n", "p" }
    for i, pc in ipairs(legend) do
        local cx = 69 + (i - 1) * 42
        self:drawMiniPiece(bb, pc, cx, LEGEND_CY)
    end
    self:drawCentered(bb, self.W / 2, LEGEND_CAPTION_Y, self.font_micro,
        "K王 Q后 R车 B象 N马 P兵，大写=黑方，小写=白方",
        Blitbuffer.COLOR_GRAY_5, false)

    -- 操作提示
    self:drawCentered(bb, self.W / 2, HINT_Y, self.font_small,
        "点自己的子，再点落点移动；长按棋子可悔棋；顶栏也有悔棋按钮",
        Blitbuffer.COLOR_GRAY_5, false)

    -- 终局大字
    if self.game_status.over then
        self:drawCentered(bb, self.W / 2, OVER_Y, self.font_big,
            self.game_status.reason .. "！" .. self.game_status.result,
            Blitbuffer.COLOR_BLACK, true)
    end
end

-- 算法函数挂到类上，方便无头测试台直接调用（tools/sim_chess.lua）
ChessDialog.Engine = Engine

return ChessDialog
