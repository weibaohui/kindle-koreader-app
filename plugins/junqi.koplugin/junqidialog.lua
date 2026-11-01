--[[--
军棋 (Junqi / 陆战棋) - Kindle 墨水屏定制版

针对 Amazon Kindle Basic（第 7 代 / KT2, 600x800, 16 级灰度, 无前光）的墨水屏特性设计：
- 棋子直接用汉字表示（司令/军长/师长/旅长/团长/营长/连长/排长/炮/工兵/地雷/炸弹/军旗），
  汉字天然适合墨水屏，不需要任何颜色语义，也不会出现"颜色在 16 级灰度上分不出来"的问题
- 敌我用「底色深浅 + 汉字本身」双编码：红方浅灰底黑字，黑方深灰底白字；
  未侦察到的敌方棋子只显示一个「？」占位（军棋的灵魂：隐藏信息）
- 棋盘 12 列 × 5 行，格子 44px；中间行的 4 个行营用双线方框标出
- 刷新层：回合制，一步只改几个格子 → 只刷变化的格子 + 状态条 + 双方棋子清单，静止时零刷新

本文件是游戏主体：棋盘逻辑（走法/吃子/隐藏信息/悔棋/存档）+ 绘制 + 手势交互。
菜单注册见 main.lua，插件元信息见 _meta.lua。
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

local COLS, ROWS = 12, 5      -- 12 列 × 5 行
local CELL = 44               -- 格子边长：12 * 44 = 528，左右各留 36
local X0 = 36                 -- 棋盘左边界
local Y0 = 64                 -- 棋盘上边界

local STATUS_Y0 = 292         -- 状态条（两行）
local STATUS_H = 56
local PANEL_Y0 = 356          -- 双方棋子清单
local HINT_Y0 = 622           -- 操作提示行
local LEGEND_Y0 = 652         -- 规则速查

-- ======================= 棋盘规则常量 =======================
local RED, BLACK = 1, 2
local SIDE_NAME = { [RED] = "红方", [BLACK] = "黑方" }

-- 军衔大小：司令 > 军长 > 师长 > 旅长 > 团长 > 营长 > 连长 > 排长 > 炮 > 工兵
-- （工兵最小，但能挖雷挖旗、能斜走；地雷/炸弹/军旗无军衔，走特殊规则）
local RANK = {
    ["司令"] = 10, ["军长"] = 9, ["师长"] = 8, ["旅长"] = 7, ["团长"] = 6,
    ["营长"] = 5, ["连长"] = 4, ["排长"] = 3, ["炮"] = 2, ["工兵"] = 1,
}

-- 每方配置（经典陆战棋单方 16 枚）
local ROSTER = {
    ["司令"] = 1, ["军长"] = 1, ["师长"] = 1, ["旅长"] = 1,
    ["团长"] = 1, ["营长"] = 1, ["连长"] = 1, ["排长"] = 1,
    ["炮"] = 2, ["工兵"] = 2, ["地雷"] = 2, ["炸弹"] = 1, ["军旗"] = 1,
}

-- 面板显示顺序
local PANEL_ORDER = {
    "军旗", "司令", "军长", "师长", "旅长", "团长",
    "营长", "连长", "排长", "炮", "工兵", "地雷", "炸弹",
}

-- 初始阵型（双方同阵型，行镜像）：最后一行是后方，第 4 行是前线
local INIT_BACK = { "排长", "连长", "营长", "团长", "军长", "军旗", "司令", "师长", "旅长", "炮", "炮", "炸弹" }
local INIT_FRONT = { "地雷", "地雷", "工兵", nil, nil, nil, nil, nil, nil, "工兵", nil, nil }

-- 行营：中间行（row 3）的第 2、5、8、11 列
local CAMP_COLS = { [2] = true, [5] = true, [8] = true, [11] = true }

-- 四方向 / 含斜向
local DIRS = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }
local DIRS8 = {
    { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 },
    { -1, -1 }, { -1, 1 }, { 1, -1 }, { 1, 1 },
}

-- 顶栏按钮
local BTN_DEF = {
    { label = "新局", x = 420, w = 56, action = "new" },
    { label = "悔棋", x = 480, w = 56, action = "undo" },
    { label = "退出", x = 540, w = 56, action = "quit" },
}

-- 胜负浮层
local OVERLAY = { x = 90, y = 100, w = 420, h = 150 }
local OVERLAY_BTN_Y = 105
local OVERLAY_BTN_H = 36

-- ======================= 棋盘构造 =======================
--- 生成初始棋盘：每枚棋子带唯一 id（隐藏信息按 id 记账，避免"子走了身份还留在原地"）
local function newBoard()
    local board = {}
    for r = 1, ROWS do board[r] = {} end
    local id = 0
    local function put(r, c, t, s)
        id = id + 1
        board[r][c] = { t = t, s = s, id = id }
    end
    for c = 1, COLS do
        local back = INIT_BACK[c]
        local front = INIT_FRONT[c]
        if back then put(5, c, back, RED) end
        if front then put(4, c, front, RED) end
        if back then put(1, c, back, BLACK) end
        if front then put(2, c, front, BLACK) end
    end
    return board
end

local function inBoard(r, c)
    return r >= 1 and r <= ROWS and c >= 1 and c <= COLS
end

local function isCamps(r, c)
    return r == 3 and CAMP_COLS[c] == true
end

-- ======================= 存档序列化 =======================
local function cellToString(cell)
    if not cell then return "-" end
    return cell.t .. "/" .. cell.s .. "/" .. cell.id
end

local function stringToCell(s)
    if not s or s == "-" or s == "" then return nil end
    local t, side, id = s:match("^([^/]+)/(%d+)/(%d+)$")
    if not t then return nil end
    if not RANK[t] and t ~= "地雷" and t ~= "炸弹" and t ~= "军旗" then return nil end
    side = tonumber(side)
    id = tonumber(id)
    if (side ~= RED and side ~= BLACK) or not id or id < 1 then return nil end
    return { t = t, s = side, id = id }
end

local function idList(tbl)
    local ids = {}
    for id, v in pairs(tbl) do
        if v then ids[#ids + 1] = id end
    end
    table.sort(ids)
    if #ids == 0 then return "-" end
    return table.concat(ids, ",")
end

local function revIds(list)
    local ids = {}
    for _, e in ipairs(list or {}) do ids[#ids + 1] = e.id end
    if #ids == 0 then return "-" end
    return table.concat(ids, ",")
end

local function historyToString(rec)
    return table.concat({
        tostring(rec.fr), tostring(rec.fc), tostring(rec.tr), tostring(rec.tc),
        tostring(rec.kind), tostring(rec.capType or "-"), tostring(rec.capSide or 0),
        tostring(rec.capId or 0), revIds(rec.rev1), revIds(rec.rev2),
    }, ",")
end

local function stringToHistory(line)
    local parts = {}
    for token in string.gmatch(line, "([^,]+)") do parts[#parts + 1] = token end
    if #parts < 10 then return nil end
    local rec = {
        fr = tonumber(parts[1]), fc = tonumber(parts[2]),
        tr = tonumber(parts[3]), tc = tonumber(parts[4]),
        kind = parts[5],
        capType = (parts[6] ~= "-") and parts[6] or nil,
        capSide = tonumber(parts[7]),
        capId = tonumber(parts[8]),
        rev1 = {}, rev2 = {},
    }
    if not rec.fr or not rec.fc or not rec.tr or not rec.tc or not rec.kind then return nil end
    for token in string.gmatch(parts[9] .. ",", "([^,]+)") do
        local id = tonumber(token)
        if id then rec.rev1[#rec.rev1 + 1] = { id = id } end
    end
    for token in string.gmatch(parts[10] .. ",", "([^,]+)") do
        local id = tonumber(token)
        if id then rec.rev2[#rec.rev2 + 1] = { id = id } end
    end
    return rec
end

-- ======================= 对话框 =======================
local JunqiDialog = InputContainer:extend{
    name = "junqi_dialog",
    dimen = Geom:new{ x = 0, y = 0, w = 600, h = 800 },
    modal = true,
    -- 必须关闭原生 double_tap：否则单次 tap 会被延迟下发，"点子 → 点目标格"受不了这个延迟
    disable_double_tap = true,
}

function JunqiDialog:init()
    self.show_parent = self

    self.W = Screen:getWidth()
    self.H = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }

    -- ⚠️ 必须显式注册手势！
    -- InputContainer:onGesture 只会把事件分发给 registerTouchZones 与 ges_events，
    -- 不会自动调用我们重写的 onTap / onHold。
    local full_range = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }
    self.ges_events = {
        Tap  = { GestureRange:new{ ges = "tap",  range = full_range } },
        Hold = { GestureRange:new{ ges = "hold", range = full_range } },
    }

    -- 字体：优先用带汉字的字体，逐个尝试，找不到就退到下一个
    self.font_title = self:face(20)
    self.font_btn = self:face(15)
    self.font_piece = self:face(19)
    self.font_small = self:face(13)
    self.font_mini = self:face(12)

    self.save_file = DataStorage:getSettingsDir() .. "/junqi_save.txt"

    -- 脏区分桶：棋盘 / 状态条 / 棋子面板 / 顶栏 / 提示区
    self._dr = {}

    if not self:loadGame() then
        self:newGame()
    else
        self:refreshAll()
    end
end

--- 取一个字体（带 pcall 兜底：设备上某个 face 不存在时不会崩）
function JunqiDialog:face(size)
    local names = { "cfont", "tfont", "dfont", "nfont", "bfont" }
    for i = 1, #names do
        local ok, face = pcall(Font.getFace, Font, names[i], size)
        if ok and face then return face end
    end
    return Font:getFace("cfont", size)
end

-- ======================= 新局 / 局面 =======================
function JunqiDialog:newGame()
    self.board = newBoard()
    self.known = { [RED] = {}, [BLACK] = {} }   -- 已知敌子：id → true
    self.turn = RED
    self.moves = 0
    self.history = {}
    self.sel = nil
    self._targets = {}
    self.winner = nil
    self.msg = "红方先行 · 点自己的棋子开始"
    self:saveGame()
    self:refreshAll()
end

--- 取某格的棋子
function JunqiDialog:pieceAt(r, c)
    if not inBoard(r, c) then return nil end
    return self.board[r][c]
end

--- 观战方（当前行棋方）看到的该格内容：己方显示真实兵种，敌方未侦察显示「？」
function JunqiDialog:displayType(r, c, viewer)
    local cell = self:pieceAt(r, c)
    if not cell then return nil end
    viewer = viewer or self.turn
    if cell.s == viewer then return cell.t end
    if self.known[viewer][cell.id] then return cell.t end
    return "？"
end

--- 某方各类棋子还剩多少
function JunqiDialog:remaining(side)
    local cnt = {}
    for r = 1, ROWS do
        for c = 1, COLS do
            local cell = self.board[r][c]
            if cell and cell.s == side then cnt[cell.t] = (cnt[cell.t] or 0) + 1 end
        end
    end
    return cnt
end

-- ======================= 走法判定 =======================
--- 兵种 t 能否以 (dr,dc) 的位移走到空位
function JunqiDialog:canStep(t, dr, dc)
    local ar, ac = math.abs(dr), math.abs(dc)
    if t == "工兵" then
        if ar + ac == 1 then return true end
        if ar == 1 and ac == 1 then return true end   -- 工兵可斜走一格
        return false, "工兵只能走一格"
    end
    if ar + ac ~= 1 then
        if ar == 1 and ac == 1 then return false, "只有工兵能斜走" end
        return false, "只能走一格"
    end
    return true
end

--- 吃子结算：返回 true, msg
function JunqiDialog:tryCapture(fr, fc, tr, tc, cell, target)
    local t = cell.t
    local dr, dc = tr - fr, tc - fc
    if t == "炮" then
        -- 炮吃子必须隔一个子（炮架），即目标在同一直线上距离 2
        local straight = (dr == 0 and math.abs(dc) == 2) or (dc == 0 and math.abs(dr) == 2)
        if not straight then
            if math.abs(dr) + math.abs(dc) == 1 then
                return false, "炮要隔一个子（炮架）才能打"
            end
            return false, "炮只能隔一格打子"
        end
        local midR = fr + math.floor(dr / 2)
        local midC = fc + math.floor(dc / 2)
        if not (self.board[midR] and self.board[midR][midC]) then
            return false, "炮没有炮架"
        end
    else
        local ok, why = self:canStep(t, dr, dc)
        if not ok then return false, why end
    end

    local tt = target.t
    if tt == "地雷" then
        if t ~= "工兵" then return false, "只有工兵能挖雷" end
        return self:doMove(fr, fc, tr, tc, "dig", tt, target)
    elseif tt == "军旗" then
        return self:doMove(fr, fc, tr, tc, "flag", tt, target)
    elseif tt == "炸弹" then
        return self:doMove(fr, fc, tr, tc, "bomb", tt, target)
    end
    if t == "炮" then
        -- 炮不吃军衔：规格里的军衔链只列了司令~排长，炮只受「炮架」约束
        -- （地雷/炸弹/军旗在上面已经走特殊规则）
        return self:doMove(fr, fc, tr, tc, "cap", tt, target)
    end
    if RANK[t] > RANK[tt] then
        return self:doMove(fr, fc, tr, tc, "cap", tt, target)
    end
    return false, t .. "吃不了" .. tt
end

--- 从 (fr,fc) 走到 (tr,tc)。返回 ok, msg
function JunqiDialog:tryMove(fr, fc, tr, tc)
    if self.winner then return false, "本局已结束，点「新局」再来" end
    local cell = self:pieceAt(fr, fc)
    if not cell then return false, "这里没有棋子" end
    if cell.s ~= self.turn then return false, "还没轮到" .. SIDE_NAME[self.turn] .. "走棋" end
    if fr == tr and fc == tc then return false, "已经选中这枚棋子了" end

    local t = cell.t
    if t == "地雷" then return false, "地雷不能移动" end
    if t == "炸弹" then return false, "炸弹不能移动" end
    if t == "军旗" then return false, "军旗不能移动" end

    local target = self:pieceAt(tr, tc)
    if target and target.s == cell.s then return false, "不能吃自己的棋子" end

    if target then
        return self:tryCapture(fr, fc, tr, tc, cell, target)
    end

    local ok, why = self:canStep(t, tr - fr, tc - fc)
    if not ok then return false, why end
    return self:doMove(fr, fc, tr, tc, "move", nil, nil)
end

--- 执行一次移动并结算
--- kind: move 普通移动 / cap 吃掉敌子 / dig 工兵挖雷 / flag 夺旗 / bomb 炸弹同归于尽
function JunqiDialog:doMove(fr, fc, tr, tc, kind, capType, capCell)
    local mover = self.board[fr][fc]
    local moverSide = mover.s

    local rec = {
        fr = fr, fc = fc, tr = tr, tc = tc, kind = kind,
        moverId = mover.id, moverSide = moverSide,
        capType = capType, capSide = capCell and capCell.s or 0,
        capId = capCell and capCell.id or 0,
        rev1 = {}, rev2 = {},
    }

    -- 1) 移动棋子（炸弹同归于尽时，攻方也一起消失）
    self.board[fr][fc] = nil
    if kind == "bomb" then
        self.board[tr][tc] = nil
    else
        self.board[tr][tc] = mover
    end

    -- 2) 揭示信息：本回合新揭示的敌子（按 id 记账，悔棋时精确回滚）
    local newRed, newBlack = {}, {}
    local function addRev(side, id, r, c)
        if side == RED then
            newRed[#newRed + 1] = { id = id, r = r, c = c }
        else
            newBlack[#newBlack + 1] = { id = id, r = r, c = c }
        end
    end

    -- 2a) 吃到敌子 → 该子被揭示（只有攻方学到）
    if capCell and capCell.s ~= moverSide then
        if not self.known[moverSide][capCell.id] then
            self.known[moverSide][capCell.id] = true
            addRev(moverSide, capCell.id, tr, tc)
        end
    end
    -- 2b) 同归于尽 → 爆炸暴露了攻方身份，对方也学到
    if kind == "bomb" then
        local other = (moverSide == RED) and BLACK or RED
        if not self.known[other][mover.id] then
            self.known[other][mover.id] = true
            addRev(other, mover.id, fr, fc)
        end
    end
    -- 2c) 相邻揭示：双方棋子上下左右相邻 → 对方那枚子被看清
    local adjRed = self:revealAdjacent(RED)
    local adjBlack = self:revealAdjacent(BLACK)
    for _, e in ipairs(adjRed) do newRed[#newRed + 1] = e end
    for _, e in ipairs(adjBlack) do newBlack[#newBlack + 1] = e end
    rec.rev1 = newRed
    rec.rev2 = newBlack

    -- 3) 落子完成
    self.history[#self.history + 1] = rec
    self.moves = self.moves + 1

    if kind == "flag" then
        self.winner = moverSide
        self.msg = SIDE_NAME[moverSide] .. "夺得军旗，获胜！"
        self:markOverlay()
    else
        self.turn = (moverSide == RED) and BLACK or RED
        if kind == "move" then
            self.msg = SIDE_NAME[moverSide] .. "走了" .. mover.t
        elseif kind == "cap" then
            self.msg = mover.t .. "吃掉" .. capType
        elseif kind == "dig" then
            self.msg = "工兵挖雷！"
        elseif kind == "bomb" then
            self.msg = "炸弹同归于尽！"
        end
    end

    -- 4) 刷新：变化的格子 + 状态条（棋子清单只在吃子时才变）
    self:markCell(fr, fc)
    self:markCell(tr, tc)
    for _, e in ipairs(newRed) do self:markCell(e.r, e.c) end
    for _, e in ipairs(newBlack) do self:markCell(e.r, e.c) end
    self:markStatus()
    if kind ~= "move" then self:markPanel() end

    self:saveGame()
    return true, self.msg
end

--- 揭示与 side 的棋子相邻的敌子，返回本回合新揭示的列表
function JunqiDialog:revealAdjacent(side)
    local newly = {}
    local known = self.known[side]
    for r = 1, ROWS do
        for c = 1, COLS do
            local cell = self.board[r][c]
            if cell and cell.s == side then
                for i = 1, 4 do
                    local nr = r + DIRS[i][1]
                    local nc = c + DIRS[i][2]
                    if inBoard(nr, nc) then
                        local o = self.board[nr][nc]
                        if o and o.s ~= side and not known[o.id] then
                            known[o.id] = true
                            newly[#newly + 1] = { id = o.id, r = nr, c = nc }
                        end
                    end
                end
            end
        end
    end
    return newly
end

--- 选中棋子后可以走到的空格子
function JunqiDialog:legalTargets(r, c)
    local res = {}
    local cell = self:pieceAt(r, c)
    if not cell then return res end
    if cell.t == "地雷" or cell.t == "炸弹" or cell.t == "军旗" then return res end
    local dirs = (cell.t == "工兵") and DIRS8 or DIRS
    for i = 1, #dirs do
        local nr = r + dirs[i][1]
        local nc = c + dirs[i][2]
        if inBoard(nr, nc) and not self.board[nr][nc] then
            res[#res + 1] = { r = nr, c = nc }
        end
    end
    return res
end

-- ======================= 悔棋 =======================
function JunqiDialog:undo()
    local rec = table.remove(self.history)
    if not rec then return false, "没有可以悔的棋" end

    -- 撤回本回合揭示的信息
    for _, e in ipairs(rec.rev1) do self.known[RED][e.id] = nil end
    for _, e in ipairs(rec.rev2) do self.known[BLACK][e.id] = nil end

    -- 恢复棋盘：棋子回原位，被吃的子放回被吃的那格
    if rec.kind == "bomb" then
        self.board[rec.fr][rec.fc] = nil
    else
        self.board[rec.fr][rec.fc] = self.board[rec.tr][rec.tc]
    end
    self.board[rec.tr][rec.tc] = nil
    if rec.capId and rec.capId > 0 then
        self.board[rec.tr][rec.tc] = { t = rec.capType, s = rec.capSide, id = rec.capId }
    end

    self.moves = self.moves - 1
    self.winner = nil
    self.turn = rec.moverSide
    self.msg = "悔棋 · 回到第 " .. self.moves .. " 步"
    self:markOverlay()

    self:markCell(rec.fr, rec.fc)
    self:markCell(rec.tr, rec.tc)
    for _, e in ipairs(rec.rev1) do self:markCell(e.r, e.c) end
    for _, e in ipairs(rec.rev2) do self:markCell(e.r, e.c) end
    self:markStatus()
    if rec.kind ~= "move" then self:markPanel() end
    self:saveGame()
    return true, self.msg
end

-- ======================= 存档 =======================
function JunqiDialog:saveGame()
    local f = io.open(self.save_file, "w")
    if not f then return end
    f:write("v1\n")
    f:write("turn=" .. tostring(self.turn or RED) .. "\n")
    f:write("moves=" .. tostring(self.moves or 0) .. "\n")
    f:write("winner=" .. tostring(self.winner or 0) .. "\n")
    f:write("board\n")
    for r = 1, ROWS do
        local parts = {}
        for c = 1, COLS do parts[#parts + 1] = cellToString(self.board[r][c]) end
        f:write(table.concat(parts, " ") .. "\n")
    end
    f:write("known\n")
    f:write(idList(self.known[RED]) .. "\n")
    f:write(idList(self.known[BLACK]) .. "\n")
    f:write("hist\n")
    for i = 1, #self.history do
        f:write(historyToString(self.history[i]) .. "\n")
    end
    f:close()
end

function JunqiDialog:loadGame()
    local f = io.open(self.save_file, "r")
    if not f then return false end
    local lines = {}
    for line in f:lines() do lines[#lines + 1] = line end
    f:close()
    if #lines < 4 or lines[1] ~= "v1" then return false end

    local idx = 2
    local turn = tonumber(string.match(lines[idx] or "", "^turn=(%d+)$")); idx = idx + 1
    local moves = tonumber(string.match(lines[idx] or "", "^moves=(%d+)$")); idx = idx + 1
    local winner = tonumber(string.match(lines[idx] or "", "^winner=(%d+)$")); idx = idx + 1
    if not turn or (turn ~= RED and turn ~= BLACK) then return false end
    if lines[idx] ~= "board" then return false end
    idx = idx + 1

    local board = {}
    local seenId = {}
    for r = 1, ROWS do
        if idx > #lines then return false end
        local row = {}
        local n = 0
        for token in string.gmatch(lines[idx] .. " ", "([^ ]+)") do
            n = n + 1
            if n > COLS then return false end
            local cell = stringToCell(token)
            if token ~= "-" and not cell then return false end
            if cell then
                if seenId[cell.id] then return false end
                seenId[cell.id] = true
                row[n] = cell
            end
        end
        if n ~= COLS then return false end
        board[r] = row
        idx = idx + 1
    end

    if lines[idx] ~= "known" then return false end
    idx = idx + 1
    local known = { [RED] = {}, [BLACK] = {} }
    if idx > #lines then return false end
    for token in string.gmatch(lines[idx] .. ",", "([^,]+)") do
        local id = tonumber(token)
        if id then known[RED][id] = true end
    end
    idx = idx + 1
    if idx > #lines then return false end
    for token in string.gmatch(lines[idx] .. ",", "([^,]+)") do
        local id = tonumber(token)
        if id then known[BLACK][id] = true end
    end
    idx = idx + 1

    if lines[idx] ~= "hist" then return false end
    idx = idx + 1
    local history = {}
    while idx <= #lines do
        local rec = stringToHistory(lines[idx])
        if not rec then return false end
        history[#history + 1] = rec
        idx = idx + 1
    end

    -- 完整性校验：每方兵种数量不能超过初始配置
    local counts = { [RED] = {}, [BLACK] = {} }
    for r = 1, ROWS do
        for c = 1, COLS do
            local cell = board[r][c]
            if cell then
                local n = (counts[cell.s][cell.t] or 0) + 1
                counts[cell.s][cell.t] = n
                if n > (ROSTER[cell.t] or 0) then return false end
            end
        end
    end

    self.board = board
    self.known = known
    self.turn = turn
    self.moves = moves or 0
    self.winner = (winner == RED or winner == BLACK) and winner or nil
    self.history = history
    self.sel = nil
    self._targets = {}
    self.msg = "读取存档 · 第 " .. self.moves .. " 步"
    return true
end

-- ======================= 脏区 =======================
--- 标脏一个格子（含边框，避免留下半个边框的残影）
function JunqiDialog:markCell(r, c)
    if not inBoard(r, c) then return end
    self:markRect(X0 + (c - 1) * CELL - 2, Y0 + (r - 1) * CELL - 2,
        X0 + c * CELL + 2, Y0 + r * CELL + 2, "board")
end

function JunqiDialog:markStatus()
    self:markRect(0, STATUS_Y0 - 2, self.W, STATUS_Y0 + STATUS_H + 2, "status")
end

function JunqiDialog:markPanel()
    self:markRect(6, PANEL_Y0 - 2, self.W - 6, PANEL_Y0 + 13 * 18 + 26, "panel")
end

--- 胜负浮层：整块重画（浮层比变化格子大，不标脏会留残影）
function JunqiDialog:markOverlay()
    self:markRect(OVERLAY.x - 2, OVERLAY.y - 2,
        OVERLAY.x + OVERLAY.w + 2, OVERLAY.y + OVERLAY.h + 2, "overlay")
end

function JunqiDialog:markHint()
    self:markRect(0, HINT_Y0 - 2, self.W, LEGEND_Y0 + 5 * 26 + 6, "hint")
end

function JunqiDialog:markTop()
    self:markRect(0, 0, self.W, TOPBAR_H, "top")
end

function JunqiDialog:markRect(x1, y1, x2, y2, bucket)
    local key = bucket or "board"
    local d = self._dr[key]
    if not d then
        self._dr[key] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
        return
    end
    if x1 < d.x1 then d.x1 = x1 end
    if y1 < d.y1 then d.y1 = y1 end
    if x2 > d.x2 then d.x2 = x2 end
    if y2 > d.y2 then d.y2 = y2 end
end

function JunqiDialog:pushRect(d, pad)
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

function JunqiDialog:refreshAll()
    self._dr = {}
    UIManager:setDirty(self, "ui", Geom:new{ x = 0, y = 0, w = self.W, h = self.H })
end

function JunqiDialog:doRefresh()
    -- 棋盘（变化的几格）
    if self._dr.board then
        self:pushRect(self._dr.board, 1)
        self._dr.board = nil
    end
    -- 状态条
    if self._dr.status then
        self:pushRect(self._dr.status, 1)
        self._dr.status = nil
    end
    -- 双方棋子清单
    if self._dr.panel then
        self:pushRect(self._dr.panel, 1)
        self._dr.panel = nil
    end
    -- 提示与规则
    if self._dr.hint then
        self:pushRect(self._dr.hint, 1)
        self._dr.hint = nil
    end
    -- 顶栏
    if self._dr.top then
        self:pushRect(self._dr.top, 1)
        self._dr.top = nil
    end
    -- 胜负浮层
    if self._dr.overlay then
        self:pushRect(self._dr.overlay, 1)
        self._dr.overlay = nil
    end
end

-- ======================= 几何 =======================
function JunqiDialog:cellRect(r, c)
    return X0 + (c - 1) * CELL, Y0 + (r - 1) * CELL,
        X0 + c * CELL, Y0 + r * CELL
end

function JunqiDialog:cellAt(x, y)
    if x < X0 or x >= X0 + COLS * CELL then return nil end
    if y < Y0 or y >= Y0 + ROWS * CELL then return nil end
    local c = math.floor((x - X0) / CELL) + 1
    local r = math.floor((y - Y0) / CELL) + 1
    return r, c
end

-- ======================= 绘制 =======================
function JunqiDialog:drawCentered(bb, cx, baseline, font, text, color, bold)
    local sz = RenderText:sizeUtf8Text(0, self.W, font, text, false, bold)
    local x = cx - math.floor(sz.x / 2)
    RenderText:renderUtf8Text(bb, x, baseline, font, text, false, bold, color)
    return sz.x
end

function JunqiDialog:drawButton(bb, x, y, w, h, label)
    -- 浅灰底 + 黑字（墨水屏上对比最清楚的按钮样式）
    bb:paintRect(x, y, w, h, Blitbuffer.COLOR_GRAY_D)
    bb:paintRect(x + 2, y + 2, w - 4, h - 4, Blitbuffer.COLOR_WHITE)
    local sz = RenderText:sizeUtf8Text(0, self.W, self.font_btn, label, false, false)
    RenderText:renderUtf8Text(bb, x + math.floor((w - sz.x) / 2), y + math.floor(h / 2) + 6,
        self.font_btn, label, false, false, Blitbuffer.COLOR_BLACK)
end

function JunqiDialog:paintTo(bb, x, y)
    -- ---------- 全屏底色（必须铺满，否则下层文件管理器透出来） ----------
    bb:paintRect(0, 0, self.W, self.H, Blitbuffer.COLOR_WHITE)

    -- ---------- 顶栏 ----------
    bb:paintRect(0, 0, self.W, TOPBAR_H, Blitbuffer.COLOR_BLACK)
    RenderText:renderUtf8Text(bb, 12, 30, self.font_title, "军棋", false, false, Blitbuffer.COLOR_WHITE)
    for i = 1, #BTN_DEF do
        local b = BTN_DEF[i]
        self:drawButton(bb, b.x, 8, b.w, TOPBAR_H - 16, b.label)
    end

    -- ---------- 棋盘 ----------
    -- 棋盘底板 + 网格线（浅灰，不抢棋子）
    bb:paintRect(X0 - 2, Y0 - 2, COLS * CELL + 4, ROWS * CELL + 4, Blitbuffer.COLOR_BLACK)
    bb:paintRect(X0, Y0, COLS * CELL, ROWS * CELL, Blitbuffer.COLOR_WHITE)
    for i = 1, COLS - 1 do
        bb:paintRect(X0 + i * CELL, Y0, 1, ROWS * CELL, Blitbuffer.COLOR_GRAY)
    end
    for i = 1, ROWS - 1 do
        bb:paintRect(X0, Y0 + i * CELL, COLS * CELL, 1, Blitbuffer.COLOR_GRAY)
    end

    -- 行营：双线方框（用形状而不是颜色标示）
    for c = 1, COLS do
        if CAMP_COLS[c] then
            local cx1, cy1, cx2, cy2 = self:cellRect(3, c)
            bb:paintRect(cx1 + 1, cy1 + 1, cx2 - cx1 - 2, cy2 - cy1 - 2, Blitbuffer.COLOR_GRAY_4)
            bb:paintRect(cx1 + 4, cy1 + 4, cx2 - cx1 - 8, cy2 - cy1 - 8, Blitbuffer.COLOR_GRAY_4)
        end
    end

    -- 棋子（先底色后文字）
    for r = 1, ROWS do
        for c = 1, COLS do
            local cell = self.board[r][c]
            if cell then
                local cx1, cy1 = self:cellRect(r, c)
                local label = self:displayType(r, c, self.turn)
                -- 未侦察的敌子：只显示「？」，底色同黑方（深灰底白字）
                local unknown = (label == "？")
                local isRed = (cell.s == RED) and not unknown
                local bg = isRed and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_GRAY_4
                local fg = isRed and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
                bb:paintRect(cx1 + 2, cy1 + 2, CELL - 4, CELL - 4, bg)
                if label then
                    self:drawCentered(bb, cx1 + math.floor(CELL / 2), cy1 + 29,
                        self.font_piece, label, fg, false)
                end
            end
        end
    end

    -- 可走到的空格子：灰色圆点
    for i = 1, #self._targets do
        local t = self._targets[i]
        local cx1, cy1 = self:cellRect(t.r, t.c)
        bb:paintCircle(cx1 + math.floor(CELL / 2), cy1 + math.floor(CELL / 2), 5,
            Blitbuffer.COLOR_GRAY_6)
    end

    -- 选中的棋子：内嵌粗框（不整块反白，省刷新）
    if self.sel then
        local cx1, cy1, cx2, cy2 = self:cellRect(self.sel.r, self.sel.c)
        bb:paintRect(cx1 + 1, cy1 + 1, cx2 - cx1 - 2, 3, Blitbuffer.COLOR_BLACK)
        bb:paintRect(cx1 + 1, cy2 - 4, cx2 - cx1 - 2, 3, Blitbuffer.COLOR_BLACK)
        bb:paintRect(cx1 + 1, cy1 + 1, 3, cy2 - cy1 - 2, Blitbuffer.COLOR_BLACK)
        bb:paintRect(cx2 - 4, cy1 + 1, 3, cy2 - cy1 - 2, Blitbuffer.COLOR_BLACK)
    end

    -- ---------- 状态条 ----------
    bb:paintRect(0, STATUS_Y0, self.W, STATUS_H, Blitbuffer.COLOR_WHITE)
    bb:paintRect(0, STATUS_Y0, self.W, 1, Blitbuffer.COLOR_GRAY_5)
    local turnText = self.winner
        and (SIDE_NAME[self.winner] .. "获胜！")
        or ("轮到" .. SIDE_NAME[self.turn] .. "走棋")
    RenderText:renderUtf8Text(bb, 12, STATUS_Y0 + 20, self.font_small, turnText,
        false, false, Blitbuffer.COLOR_BLACK)
    local stepText = "步数 " .. tostring(self.moves)
    local ssz = RenderText:sizeUtf8Text(0, self.W, self.font_small, stepText, false, false)
    RenderText:renderUtf8Text(bb, self.W - ssz.x - 12, STATUS_Y0 + 20, self.font_small, stepText,
        false, false, Blitbuffer.COLOR_GRAY_5)
    local msg = self.msg or ""
    local msz = RenderText:sizeUtf8Text(0, self.W, self.font_small, msg, false, false)
    RenderText:renderUtf8Text(bb, math.max(6, math.floor((self.W - msz.x) / 2)),
        STATUS_Y0 + 42, self.font_small, msg, false, false, Blitbuffer.COLOR_GRAY_4)

    -- ---------- 双方棋子清单 ----------
    self:drawPanel(bb)

    -- ---------- 操作提示 + 规则速查 ----------
    local hint = "点自己的棋子选中 → 点目标格走棋；长按棋子 = 悔棋"
    local hsz = RenderText:sizeUtf8Text(0, self.W, self.font_small, hint, false, false)
    RenderText:renderUtf8Text(bb, math.floor((self.W - hsz.x) / 2), HINT_Y0 + 16,
        self.font_small, hint, false, false, Blitbuffer.COLOR_GRAY_5)
    local legend = {
        "？ = 未侦察的敌子（相邻或被吃后揭示真实兵种）",
        "灰点 = 可走到的空格 · 粗框 = 已选中",
        "工兵可斜走、能挖雷挖旗；地雷/炸弹/军旗不动",
        "炮要隔一个子（炮架）才能打；大棋子吃小棋子",
        "炸弹同归于尽；吃到对方军旗立即获胜",
    }
    for i = 1, #legend do
        RenderText:renderUtf8Text(bb, 12, LEGEND_Y0 + 14 + (i - 1) * 26, self.font_mini,
            legend[i], false, false, Blitbuffer.COLOR_GRAY_6)
    end

    -- ---------- 胜负浮层 ----------
    if self.winner then
        local ox, oy, ow, oh = OVERLAY.x, OVERLAY.y, OVERLAY.w, OVERLAY.h
        bb:paintRect(ox, oy, ow, oh, Blitbuffer.COLOR_WHITE)
        bb:paintRect(ox, oy, ow, 3, Blitbuffer.COLOR_BLACK)
        bb:paintRect(ox, oy + oh - 3, ow, 3, Blitbuffer.COLOR_BLACK)
        bb:paintRect(ox, oy, 3, oh, Blitbuffer.COLOR_BLACK)
        bb:paintRect(ox + ow - 3, oy, 3, oh, Blitbuffer.COLOR_BLACK)
        self:drawCentered(bb, self.W / 2, oy + 60, self.font_title,
            SIDE_NAME[self.winner] .. "胜！", Blitbuffer.COLOR_BLACK, false)
        self:drawCentered(bb, self.W / 2, oy + 92, self.font_small,
            "共 " .. tostring(self.moves) .. " 步",
            Blitbuffer.COLOR_GRAY_5, false)
        self:drawButton(bb, ox + 40, oy + OVERLAY_BTN_Y, 140, OVERLAY_BTN_H, "新局")
        self:drawButton(bb, ox + 240, oy + OVERLAY_BTN_Y, 140, OVERLAY_BTN_H, "退出")
    end
end

--- 双方棋子清单面板
function JunqiDialog:drawPanel(bb)
    local redCnt = self:remaining(RED)
    local blackCnt = self:remaining(BLACK)
    local totalRed, totalBlack = 0, 0
    for i = 1, #PANEL_ORDER do
        totalRed = totalRed + (redCnt[PANEL_ORDER[i]] or 0)
        totalBlack = totalBlack + (blackCnt[PANEL_ORDER[i]] or 0)
    end

    local cols = {
        { x = 12, name = "红方", cnt = redCnt, total = totalRed },
        { x = 308, name = "黑方", cnt = blackCnt, total = totalBlack },
    }

    for i = 1, #cols do
        local col = cols[i]
        -- 列标题
        RenderText:renderUtf8Text(bb, col.x + 4, PANEL_Y0 + 15, self.font_small,
            col.name .. "（剩 " .. col.total .. "）", false, false, Blitbuffer.COLOR_BLACK)
        bb:paintRect(col.x, PANEL_Y0 + 22, 276, 1, Blitbuffer.COLOR_GRAY_5)
        -- 逐行兵种
        for k = 1, #PANEL_ORDER do
            local t = PANEL_ORDER[k]
            local n = col.cnt[t] or 0
            local baseline = PANEL_Y0 + 40 + (k - 1) * 18
            local color = (n > 0) and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY_6
            RenderText:renderUtf8Text(bb, col.x + 4, baseline, self.font_mini, t,
                false, false, color)
            RenderText:renderUtf8Text(bb, col.x + 58, baseline, self.font_mini,
                "剩 " .. tostring(n), false, false, color)
            -- 折损数（初始配置 - 剩余）
            local lost = (ROSTER[t] or 0) - n
            if lost > 0 then
                RenderText:renderUtf8Text(bb, col.x + 120, baseline, self.font_mini,
                    "损 " .. tostring(lost), false, false, Blitbuffer.COLOR_GRAY_6)
            end
        end
    end
end

-- ======================= 交互 =======================
-- 手势入口：转发给 InputContainer，并吞掉所有手势，避免冒泡到下层文件管理器
function JunqiDialog:onGesture(ev)
    InputContainer.onGesture(self, ev)
    return true
end

--- 清除选择（并把画过圆点的格子标脏）
function JunqiDialog:clearSel()
    if self.sel then
        self:markCell(self.sel.r, self.sel.c)
    end
    for i = 1, #self._targets do
        self:markCell(self._targets[i].r, self._targets[i].c)
    end
    self.sel = nil
    self._targets = {}
end

--- 选中某个格子
function JunqiDialog:setSel(r, c)
    self:clearSel()
    self.sel = { r = r, c = c }
    self._targets = self:legalTargets(r, c)
    self:markCell(r, c)
    for i = 1, #self._targets do
        self:markCell(self._targets[i].r, self._targets[i].c)
    end
end

function JunqiDialog:onTap(arg, ges)
    ges = ges or arg
    if not ges or not ges.pos then return true end
    local x, y = ges.pos.x, ges.pos.y

    -- 1) 顶栏按钮
    if y >= 0 and y <= TOPBAR_H then
        for i = 1, #BTN_DEF do
            local b = BTN_DEF[i]
            if x >= b.x and x <= b.x + b.w then
                self:doButton(b.action)
                return true
            end
        end
        return true
    end

    -- 2) 胜负浮层：只允许点「新局 / 退出」
    if self.winner then
        local ox, oy = OVERLAY.x, OVERLAY.y
        local by = oy + OVERLAY_BTN_Y
        if y >= by and y <= by + OVERLAY_BTN_H then
            if x >= ox + 40 and x <= ox + 180 then
                self:newGame()
                return true
            end
            if x >= ox + 240 and x <= ox + 380 then
                self:onClose()
                return true
            end
        end
        return true
    end

    -- 3) 棋盘
    local r, c = self:cellAt(x, y)
    if not r then
        if self.sel then
            self:clearSel()
            self:markStatus()
            self:doRefresh()
        end
        return true
    end

    if self.sel and self.sel.r == r and self.sel.c == c then
        -- 再点自己 = 取消选中
        self:clearSel()
        self:markStatus()
        self:doRefresh()
        return true
    end

    if self.sel then
        local ok, msg = self:tryMove(self.sel.r, self.sel.c, r, c)
        if ok then
            self:clearSel()
        else
            self.msg = msg
            self:markStatus()
        end
        self:doRefresh()
        return true
    end

    -- 没有选中：点自己的棋子 = 选中
    local cell = self:pieceAt(r, c)
    if cell and cell.s == self.turn then
        self:setSel(r, c)
        self.msg = "已选中" .. cell.t .. " · 点目标格走棋"
        self:markStatus()
    elseif cell then
        local known = self:displayType(r, c, self.turn)
        self.msg = "那是" .. SIDE_NAME[cell.s] .. "的" .. known
        self:markStatus()
    else
        self.msg = "点自己的棋子开始走棋"
        self:markStatus()
    end
    self:doRefresh()
    return true
end

function JunqiDialog:doButton(action)
    if action == "quit" then
        self:onClose()
    elseif action == "new" then
        self:newGame()
    elseif action == "undo" then
        self:clearSel()
        local ok, msg = self:undo()
        self.msg = msg
        self:markStatus()
        self:doRefresh()
    end
end

function JunqiDialog:onClose()
    self:saveGame()
    self.is_closed = true
    self:onCloseWidget()
    UIManager:close(self)
end

--- 长按棋子 = 悔棋
function JunqiDialog:onHold(arg, ges)
    ges = ges or arg
    if not ges or not ges.pos then return false end
    local r, c = self:cellAt(ges.pos.x, ges.pos.y)
    if r and self.board[r][c] then
        self:clearSel()
        local ok, msg = self:undo()
        self.msg = msg
        self:markStatus()
        self:doRefresh()
        return true
    end
    return false
end

-- 规则常量与构造函数挂到类上，方便无头测试台直接引用（tools/sim_junqi.lua）
JunqiDialog.RED = RED
JunqiDialog.BLACK = BLACK
JunqiDialog.RANK = RANK
JunqiDialog.ROSTER = ROSTER
JunqiDialog.PANEL_ORDER = PANEL_ORDER
JunqiDialog.COLS = COLS
JunqiDialog.ROWS = ROWS
JunqiDialog.CELL = CELL
JunqiDialog.X0 = X0
JunqiDialog.Y0 = Y0
JunqiDialog.CAMP_COLS = CAMP_COLS
JunqiDialog.newBoard = newBoard

return JunqiDialog
