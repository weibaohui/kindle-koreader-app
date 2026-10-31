--[[--
数独 (Sudoku) - Kindle 墨水屏定制版

针对 Amazon Kindle Basic（第 7 代 / KT2, 600x800, 16 级灰度, 无前光）的墨水屏特性设计：
- 静态优先：数独本来就没有连续动画，所有交互都是"点一格 → 点一个数字"，
  天然适配墨水屏，不需要任何刷新预算上的妥协
- 灰阶语义化：题目给定的数字 = 纯黑；玩家填入的数字 = 纯黑 + 数字下方一条短横线（形状线索，
  不依赖颜色，在 16 级灰度上依然一眼可分）；笔记得用小号浅灰字退到背景层
- 冲突提示用"删除线"（横穿数字的细横线）而不是红色，墨水屏上红绿不可用
- 数字键盘会"灰掉"当前格所在行/列/宫里已经用掉的数字 —— 等价于"哪些数字还能填"，
  墨水屏上比高亮整行整列便宜得多（只刷 9 个小按钮）
- 刷新层：整局游戏几乎不产生连续刷新（只有计时器每秒刷一次时间格），
  每次操作只刷真正变化的格子，绝不整屏重刷

架构参照本仓库《砖石战场 (打砖块)》与《方块战争 (俄罗斯方块)》插件。
--]]--

local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local Screen = Device.screen
local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local RenderText = require("ui/rendertext")

-- ======================= 布局常量 =======================
local TOPBAR_H = 44

local CELL = 52                 -- 格子边长：9*52 = 468，正好横向居中
local GRID_X0 = 66              -- (600 - 468) / 2
local GRID_Y0 = 54

local STATUS_Y0 = 530           -- 状态条：难度 / 用时 / 空格
local STATUS_H = 28

local PAD_Y0 = 566              -- 数字键盘 1-9
local PAD_H = 80
local PAD_X0 = 16
local PAD_BW = 57
local PAD_GAP = 6

local ACT_Y0 = 654              -- 操作行：擦除 / 笔记 / 撤销
local ACT_H = 68

local HINT_Y0 = 732             -- 底部提示行

-- 难度：给定数字越多越简单
local DIFFS = {
    { name = "简单", givens = 42 },
    { name = "普通", givens = 32 },
    { name = "困难", givens = 25 },
}

-- ======================= 数独核心算法 =======================
-- 棋盘用 81 长的一维数组（下标 1..81），第 i 格 = (r-1)*9 + c
-- 值为 0 表示空，1..9 表示数字

-- 笔记用 9 位掩码存（每位代表一个数字）。
-- 注意：设备端是 LuaJIT 5.1，没有 & | << 这些 5.3 位运算符，
-- 所以这里用 2 的幂做算术位运算，本地 Lua 5.3/5.4 与设备都能跑。
local BIT = {}
for d = 1, 9 do BIT[d] = 2 ^ (d - 1) end

local function bitHas(mask, d)
    return math.floor(mask / BIT[d]) % 2 == 1
end

local function boxIndex(r, c)
    return math.floor((r - 1) / 3) * 3 + math.floor((c - 1) / 3) + 1
end

--- 统计解的个数（最多数到 limit 个就停）
--- @param grid 81 长数组
--- @param limit 数到几个解就停（1 = 判唯一解，2 = 判是否唯一）
local function countSolutions(grid, limit)
    local rows, cols, boxes = {}, {}, {}
    for i = 1, 9 do
        rows[i], cols[i], boxes[i] = {}, {}, {}
        for d = 1, 9 do
            rows[i][d], cols[i][d], boxes[i][d] = false, false, false
        end
    end
    for i = 1, 81 do
        local v = grid[i]
        if v ~= 0 then
            local r = math.floor((i - 1) / 9) + 1
            local c = (i - 1) % 9 + 1
            local b = boxIndex(r, c)
            rows[r][v], cols[c][v], boxes[b][v] = true, true, true
        end
    end

    local count = 0
    local function rec()
        if count >= limit then return end
        -- 选候选最少的空格（MRV），大幅剪枝
        local best, bestn, br, bc, bb = nil, 10, nil, nil, nil
        for i = 1, 81 do
            if grid[i] == 0 then
                local r = math.floor((i - 1) / 9) + 1
                local c = (i - 1) % 9 + 1
                local b = boxIndex(r, c)
                local n = 0
                for d = 1, 9 do
                    if not rows[r][d] and not cols[c][d] and not boxes[b][d] then n = n + 1 end
                end
                if n < bestn then
                    bestn, best, br, bc, bb = n, i, r, c, b
                    if n == 0 then break end
                end
            end
        end
        if not best then
            count = count + 1
            return
        end
        for d = 1, 9 do
            if not rows[br][d] and not cols[bc][d] and not boxes[bb][d] then
                rows[br][d], cols[bc][d], boxes[bb][d] = true, true, true
                grid[best] = d
                rec()
                grid[best] = 0
                rows[br][d], cols[bc][d], boxes[bb][d] = false, false, false
                if count >= limit then return end
            end
        end
    end
    rec()
    return count
end

--- 生成一个完整合法解（随机化）
local function generateSolution()
    local grid = {}
    for i = 1, 81 do grid[i] = 0 end
    local rows, cols, boxes = {}, {}, {}
    for i = 1, 9 do
        rows[i], cols[i], boxes[i] = {}, {}, {}
        for d = 1, 9 do rows[i][d], cols[i][d], boxes[i][d] = false, false, false end
    end

    local function rec(pos)
        if pos > 81 then return true end
        local r = math.floor((pos - 1) / 9) + 1
        local c = (pos - 1) % 9 + 1
        local b = boxIndex(r, c)
        -- 把 1..9 洗牌，保证每局解都不一样
        local cand = {}
        for d = 1, 9 do cand[d] = d end
        for d = 9, 2, -1 do
            local j = math.random(d)
            cand[d], cand[j] = cand[j], cand[d]
        end
        for k = 1, 9 do
            local d = cand[k]
            if not rows[r][d] and not cols[c][d] and not boxes[b][d] then
                rows[r][d], cols[c][d], boxes[b][d] = true, true, true
                grid[pos] = d
                if rec(pos + 1) then return true end
                grid[pos] = 0
                rows[r][d], cols[c][d], boxes[b][d] = false, false, false
            end
        end
        return false
    end
    rec(1)
    return grid
end

--- 由完整解挖出题目
--- 策略：先无脑挖到目标数量，再检查唯一解；不唯一就按逆序把最后挖掉的格子恢复回去，
--- 直到唯一。这样只跑少数几次求解器，比"每挖一格都验一次"快得多。
local function generatePuzzle(target_givens)
    local solution = generateSolution()
    local grid = {}
    for i = 1, 81 do grid[i] = solution[i] end

    local order = {}
    for i = 1, 81 do order[i] = i end
    for i = 81, 2, -1 do
        local j = math.random(i)
        order[i], order[j] = order[j], order[i]
    end

    local removed = {}
    local want = 81 - target_givens
    for k = 1, want do
        local i = order[k]
        grid[i] = 0
        removed[#removed + 1] = i
    end

    -- 保证唯一解：恢复最后挖掉的格子
    local guard = 0
    while countSolutions(grid, 2) > 1 and #removed > 0 and guard < 60 do
        guard = guard + 1
        local i = table.remove(removed)
        grid[i] = solution[i]
    end

    return grid, solution
end

-- ======================= 对话框 =======================
local SudokuDialog = InputContainer:extend{
    name = "sudoku_dialog",
    dimen = Geom:new{ x = 0, y = 0, w = 600, h = 800 },
    modal = true,
    -- 必须关闭原生 double_tap：否则单次 tap 会被延迟 300ms 才下发，
    -- "点一格再点数字"这种高频操作不能忍受延迟。
    disable_double_tap = true,
}

-- ======================= 初始化 =======================
function SudokuDialog:init()
    self.show_parent = self

    self.W = Screen:getWidth()
    self.H = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }

    -- 字体缓存（paintTo 每帧调用，避免重复取）
    self.font_title = Font:getFace("tfont", 20)
    self.font_btn = Font:getFace("cfont", 15)
    self.font_num = Font:getFace("cfont", 30)
    self.font_note = Font:getFace("cfont", 11)
    self.font_small = Font:getFace("cfont", 13)
    self.font_mini = Font:getFace("cfont", 11)

    -- 状态
    self.given = {}       -- 题目给定的数字（不可改）
    self.val = {}         -- 当前盘面数字
    self.notes = {}       -- 笔记位掩码，第 d-1 位代表数字 d
    self.conflict = {}    -- 冲突标记
    self.sel = nil        -- 选中的格子
    self.notes_mode = false
    self.difficulty = 2   -- 默认"普通"
    self.elapsed = 0      -- 已用秒数
    self.hints = 0        -- 用了几次提示
    self.history = {}     -- 撤销栈
    self.won = false
    self.solved_count = 0
    self.best_time = {}

    self.save_file = DataStorage:getSettingsDir() .. "/sudoku_save.txt"
    self.stats_file = DataStorage:getSettingsDir() .. "/sudoku_stats.txt"

    self:loadStats()

    -- 脏区分桶：棋盘格 / 数字键盘 / 顶栏 / 状态条 / 浮层，各自独立推送
    self._dr = {}

    if not self:loadGame() then
        self:newGame(self.difficulty)
    end

    self:scheduleClock()
    self:refreshAll()
end

-- ======================= 存档 =======================
function SudokuDialog:saveGame()
    local f = io.open(self.save_file, "w")
    if not f then return end
    local function rowstr(t)
        -- 注意：逗号要加在每个格子后面。
        -- 以前只在每行末尾加逗号，一行 9 个数字会被拼成 "214000700" 这样一个数，
        -- 读回来只有 9 个值，存档直接废掉。
        local s = ""
        for i = 1, 81 do
            s = s .. tostring(t[i] or 0) .. ","
        end
        return s
    end
    f:write("v1\n")
    f:write(self.difficulty .. "\n")
    f:write(tostring(self.elapsed) .. "\n")
    f:write(tostring(self.hints or 0) .. "\n")
    f:write(rowstr(self.given) .. "\n")
    f:write(rowstr(self.val) .. "\n")
    local ns = ""
    for i = 1, 81 do ns = ns .. tostring(self.notes[i] or 0) .. "," end
    f:write(ns .. "\n")
    f:write(rowstr(self.solution or {}) .. "\n")
    f:close()
end

function SudokuDialog:loadGame()
    local f = io.open(self.save_file, "r")
    if not f then return false end
    local lines = {}
    for line in f:lines() do lines[#lines + 1] = line end
    f:close()
    if #lines < 8 then return false end

    local function parseRow(line)
        local vals = {}
        for token in string.gmatch(line, "([^,]+)") do
            vals[#vals + 1] = tonumber(token) or 0
        end
        return vals
    end

    local diff = tonumber(lines[2]) or 2
    local elapsed = tonumber(lines[3]) or 0
    local hints = tonumber(lines[4]) or 0
    local given = parseRow(lines[5])
    local val = parseRow(lines[6])
    local notes = parseRow(lines[7])
    local solution = parseRow(lines[8])
    if #given ~= 81 or #val ~= 81 or #notes ~= 81 then return false end

    self.difficulty = diff
    self.elapsed = elapsed
    self.hints = hints
    self.given, self.val, self.notes = given, val, notes
    if #solution == 81 then self.solution = solution end
    self:computeConflicts()
    return true
end

function SudokuDialog:loadStats()
    local f = io.open(self.stats_file, "r")
    if not f then return end
    for line in f:lines() do
        local d, n, t = line:match("^(%d+)%s+(%d+)%s+(%d+)$")
        if d then
            self.solved_count = self.solved_count + tonumber(n)
            local best = tonumber(t)
            if not self.best_time[tonumber(d)] or best < self.best_time[tonumber(d)] then
                self.best_time[tonumber(d)] = best
            end
        end
    end
    f:close()
end

function SudokuDialog:saveStats()
    local f = io.open(self.stats_file, "w")
    if not f then return end
    f:write(self.solved_count .. " " .. (self.best_time[1] or 0) .. "\n")
    f:write("2 " .. (self.best_time[2] or 0) .. "\n")
    f:write("3 " .. (self.best_time[3] or 0) .. "\n")
    f:close()
end

-- ======================= 局面操作 =======================
function SudokuDialog:newGame(difficulty)
    self.difficulty = difficulty or self.difficulty
    local target = DIFFS[self.difficulty].givens
    local puzzle, solution = generatePuzzle(target)
    self.given = puzzle
    self.solution = solution
    self.val = {}
    self.notes = {}
    for i = 1, 81 do
        self.val[i] = puzzle[i]
        self.notes[i] = 0
    end
    self.sel = nil
    self.elapsed = 0
    self.hints = 0
    self.history = {}
    self.won = false
    self:computeConflicts()
    self:saveGame()
    self:refreshAll()
end

--- 提示：把选中格（或第一个空格）填成正确答案
function SudokuDialog:giveHint()
    if not self.solution then return end
    local i = self.sel
    if not i or self.given[i] ~= 0 or self.val[i] ~= 0 then
        i = nil
        for k = 1, 81 do
            if self.given[k] == 0 and self.val[k] == 0 then i = k break end
        end
    end
    if not i then return end
    self.sel = i
    self.hints = (self.hints or 0) + 1
    self:setCell(i, self.solution[i], 0)
end

--- 重新计算冲突：同一行/列/宫里出现相同数字就互相标记
function SudokuDialog:computeConflicts()
    self.conflict = {}
    for i = 1, 81 do
        local v = self.val[i]
        if v ~= 0 then
            local r = math.floor((i - 1) / 9) + 1
            local c = (i - 1) % 9 + 1
            local b = boxIndex(r, c)
            for j = 1, 81 do
                if j ~= i and self.val[j] == v then
                    local r2 = math.floor((j - 1) / 9) + 1
                    local c2 = (j - 1) % 9 + 1
                    local b2 = boxIndex(r2, c2)
                    if r2 == r or c2 == c or b2 == b then
                        self.conflict[i] = true
                        self.conflict[j] = true
                    end
                end
            end
        end
    end
end

--- 选中格所在行/列/宫已经用掉的数字
function SudokuDialog:usedDigits(idx)
    local used = {}
    local r = math.floor((idx - 1) / 9) + 1
    local c = (idx - 1) % 9 + 1
    local b = boxIndex(r, c)
    for i = 1, 81 do
        local v = self.val[i]
        if v ~= 0 then
            local r2 = math.floor((i - 1) / 9) + 1
            local c2 = (i - 1) % 9 + 1
            local b2 = boxIndex(r2, c2)
            if r2 == r or c2 == c or b2 == b then used[v] = true end
        end
    end
    return used
end

--- 往选中的格填数字（普通模式）
function SudokuDialog:placeNumber(d)
    local i = self.sel
    if not i then return end
    if self.given[i] ~= 0 then return end   -- 题目给定的不能改
    if self.val[i] == d then
        self:setCell(i, 0, self.notes[i])  -- 再点一次同一个数字 = 擦掉
        return
    end
    self:setCell(i, d, 0)
    -- 顺带把同数字的笔记从相关格子里清掉（经典便利功能）
    local r = math.floor((i - 1) / 9) + 1
    local c = (i - 1) % 9 + 1
    local b = boxIndex(r, c)
    for j = 1, 81 do
        if j ~= i and self.val[j] == 0 and bitHas(self.notes[j] or 0, d) then
            local r2 = math.floor((j - 1) / 9) + 1
            local c2 = (j - 1) % 9 + 1
            local b2 = boxIndex(r2, c2)
            if r2 == r or c2 == c or b2 == b then
                self.notes[j] = (self.notes[j] or 0) - BIT[d]
                self:markCellDirty(j)
            end
        end
    end
end

--- 笔记模式：切换某个笔记数字
function SudokuDialog:toggleNote(d)
    local i = self.sel
    if not i then return end
    if self.given[i] ~= 0 then return end
    local old = self.notes[i] or 0
    local new
    if bitHas(old, d) then
        new = old - BIT[d]
    else
        new = old + BIT[d]
    end
    self:setCell(i, self.val[i], new)
end

function SudokuDialog:setCell(i, v, notes)
    self.history[#self.history + 1] = { i = i, v = self.val[i], n = self.notes[i] }
    if #self.history > 200 then table.remove(self.history, 1) end
    self.val[i] = v
    self.notes[i] = notes or 0
    self:computeConflicts()
    self:markCellDirty(i)
    self:checkWin()
    self:saveGame()
end

function SudokuDialog:undo()
    local m = table.remove(self.history)
    if not m then return end
    self.val[m.i] = m.v
    self.notes[m.i] = m.n
    self.won = false
    self:computeConflicts()
    self:markCellDirty(m.i)
    self:refreshOverlay()
    self:saveGame()
end

function SudokuDialog:erase()
    local i = self.sel
    if not i then return end
    if self.given[i] ~= 0 then return end
    if self.val[i] == 0 and (self.notes[i] or 0) == 0 then return end
    self:setCell(i, 0, 0)
end

function SudokuDialog:checkWin()
    for i = 1, 81 do
        if self.val[i] == 0 then return false end
        if self.conflict[i] then return false end
    end
    self.won = true
    self.solved_count = self.solved_count + 1
    local best = self.best_time[self.difficulty]
    if not best or self.elapsed < best then self.best_time[self.difficulty] = self.elapsed end
    self:saveStats()
    self:saveGame()
    self:refreshOverlay()
    return true
end

function SudokuDialog:emptyCount()
    local n = 0
    for i = 1, 81 do
        if self.val[i] == 0 then n = n + 1 end
    end
    return n
end

-- ======================= 几何 =======================
function SudokuDialog:cellRect(i)
    local r = math.floor((i - 1) / 9)
    local c = (i - 1) % 9
    return GRID_X0 + c * CELL, GRID_Y0 + r * CELL, GRID_X0 + (c + 1) * CELL, GRID_Y0 + (r + 1) * CELL
end

function SudokuDialog:cellAt(x, y)
    if x < GRID_X0 or x >= GRID_X0 + 9 * CELL then return nil end
    if y < GRID_Y0 or y >= GRID_Y0 + 9 * CELL then return nil end
    local c = math.floor((x - GRID_X0) / CELL)
    local r = math.floor((y - GRID_Y0) / CELL)
    return r * 9 + c + 1
end

-- 顶栏按钮定义：难度 / 新局 / 退出
local BTN_DEF = {
    { label = "难度", x = 382, w = 64, action = "diff" },
    { label = "新局", x = 454, w = 64, action = "new" },
    { label = "退出", x = 526, w = 64, action = "quit" },
}

-- 操作行按钮：擦除 / 笔记 / 撤销 / 提示
local ACT_DEF = {
    { label = "擦除", x = 12, w = 138, action = "erase" },
    { label = "笔记", x = 158, w = 138, action = "notes" },
    { label = "撤销", x = 304, w = 138, action = "undo" },
    { label = "提示", x = 450, w = 138, action = "hint" },
}

-- ======================= 脏区 =======================
--- 标脏一个格子（含边框，避免留下半个边框的残影）
function SudokuDialog:markCellDirty(i)
    local x1, y1, x2, y2 = self:cellRect(i)
    self:markRect(x1 - 2, y1 - 2, x2 + 2, y2 + 2, "grid")
end

function SudokuDialog:markRect(x1, y1, x2, y2, bucket)
    local key = bucket or "field"
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

function SudokuDialog:pushRect(d, pad)
    if not d then return end
    pad = pad or 2
    local x = math.max(0, math.floor(d.x1 - pad))
    local y = math.max(0, math.floor(d.y1 - pad))
    local w = math.min(self.W - x, math.ceil(d.x2 + pad - x))
    local h = math.min(self.H - y, math.ceil(d.y2 + pad - y))
    if w > 0 and h > 0 then
        UIManager:setDirty(self, "ui", Geom:new{ x = x, y = y, w = w, h = h })
    end
end

function SudokuDialog:refreshAll()
    self._dr = {}
    UIManager:setDirty(self, "ui", Geom:new{ x = 0, y = 0, w = self.W, h = self.H })
end

--- 只刷键盘（选格变化时"哪些数字还能填"会变）
function SudokuDialog:refreshPad()
    self:markRect(PAD_X0 - 2, PAD_Y0 - 2, PAD_X0 + 9 * PAD_BW + 8 * PAD_GAP + 2, PAD_Y0 + PAD_H + 2, "pad")
end

--- 只刷状态条（用时每分钟变一次）
function SudokuDialog:refreshStatus()
    self:markRect(0, STATUS_Y0 - 2, self.W, STATUS_Y0 + STATUS_H + 2, "status")
end

function SudokuDialog:refreshOverlay()
    self:markRect(0, 0, self.W, self.H, "overlay")
end

function SudokuDialog:doRefresh()
    -- 棋盘格
    if self._dr.grid then
        self:pushRect(self._dr.grid, 0)
        self._dr.grid = nil
    end
    -- 数字键盘
    if self._dr.pad then
        self:pushRect(self._dr.pad, 1)
        self._dr.pad = nil
    end
    -- 状态条
    if self._dr.status then
        self:pushRect(self._dr.status, 1)
        self._dr.status = nil
    end
    -- 顶栏（难度名会变）
    if self._dr.top then
        self:pushRect(self._dr.top, 1)
        self._dr.top = nil
    end
    -- 操作行（笔记按钮的按下状态）
    if self._dr.act then
        self:pushRect(self._dr.act, 1)
        self._dr.act = nil
    end
    -- 浮层
    if self._dr.overlay then
        self:pushRect(self._dr.overlay, 2)
        self._dr.overlay = nil
    end
end

-- ======================= 计时器 =======================
--- 计时器：只用它刷"用时"那一格
--- 注意 UIManager:scheduleIn 没有返回值，必须自己留住 action 引用才能 unschedule
function SudokuDialog:scheduleClock()
    if self.is_closed then return end
    self:stopClock()
    local clock
    clock = function()
        if self.is_closed then return end
        if not self.won then
            self.elapsed = self.elapsed + 1
            self:refreshStatus()
            self:doRefresh()
            self:saveGame()
        end
        self:scheduleClock()
    end
    self.clock_action = clock
    UIManager:scheduleIn(1, clock)
end

function SudokuDialog:stopClock()
    if self.clock_action then
        UIManager:unschedule(self.clock_action)
        self.clock_action = nil
    end
end

-- ======================= 绘制 =======================
local function fmtTime(sec)
    local m = math.floor(sec / 60)
    local s = sec % 60
    return string.format("%02d:%02d", m, s)
end

--- 居中画一个字符串，返回它占的宽度
function SudokuDialog:drawCentered(bb, cx, baseline, font, text, color, bold)
    local sz = RenderText:sizeUtf8Text(0, self.W, font, text, false, bold)
    local x = cx - math.floor(sz.x / 2)
    RenderText:renderUtf8Text(bb, x, baseline, font, text, false, bold, color)
    return sz.x
end

function SudokuDialog:drawButton(bb, x, y, w, h, label, pressed)
    if pressed then
        bb:paintRect(x, y, w, h, Blitbuffer.COLOR_BLACK)
        local sz = RenderText:sizeUtf8Text(0, self.W, self.font_btn, label, false, true)
        RenderText:renderUtf8Text(bb, x + math.floor((w - sz.x) / 2), y + math.floor(h / 2) + 7,
            self.font_btn, label, false, true, Blitbuffer.COLOR_WHITE)
    else
        bb:paintRect(x, y, w, h, Blitbuffer.COLOR_GRAY_D)
        bb:paintRect(x + 2, y + 2, w - 4, h - 4, Blitbuffer.COLOR_WHITE)
        local sz = RenderText:sizeUtf8Text(0, self.W, self.font_btn, label, false, false)
        RenderText:renderUtf8Text(bb, x + math.floor((w - sz.x) / 2), y + math.floor(h / 2) + 7,
            self.font_btn, label, false, false, Blitbuffer.COLOR_BLACK)
    end
end

function SudokuDialog:paintTo(bb, x, y)
    -- ---------- 全屏底色 ----------
    -- 必须先铺满整屏，否则下面的文件管理器会透出来
    bb:paintRect(0, 0, self.W, self.H, Blitbuffer.COLOR_WHITE)

    -- ---------- 顶栏 ----------
    bb:paintRect(0, 0, self.W, TOPBAR_H, Blitbuffer.COLOR_BLACK)
    RenderText:renderUtf8Text(bb, 12, 30, self.font_title, "数独", false, false, Blitbuffer.COLOR_WHITE)
    for _, b in ipairs(BTN_DEF) do
        -- 先画底色再画文字（反了会被底色盖住）
        bb:paintRect(b.x, 8, b.w - 4, TOPBAR_H - 16, Blitbuffer.COLOR_GRAY_5)
        local sz = RenderText:sizeUtf8Text(0, self.W, self.font_btn, b.label, false, false)
        RenderText:renderUtf8Text(bb, b.x + math.floor((b.w - sz.x) / 2), 30,
            self.font_btn, b.label, false, false, Blitbuffer.COLOR_WHITE)
    end

    -- ---------- 棋盘 ----------
    bb:paintRect(GRID_X0 - 3, GRID_Y0 - 3, 9 * CELL + 6, 9 * CELL + 6, Blitbuffer.COLOR_BLACK)
    bb:paintRect(GRID_X0, GRID_Y0, 9 * CELL, 9 * CELL, Blitbuffer.COLOR_WHITE)

    -- 细网格线（宫分隔线留到最后画粗线）
    for i = 1, 8 do
        local gx = GRID_X0 + i * CELL
        local gy = GRID_Y0 + i * CELL
        local thick = (i % 3 == 0)
        local w = thick and 3 or 1
        if not thick then
            bb:paintRect(gx, GRID_Y0, w, 9 * CELL, Blitbuffer.COLOR_GRAY)
        end
        if not thick then
            bb:paintRect(GRID_X0, gy, 9 * CELL, w, Blitbuffer.COLOR_GRAY)
        end
    end
    -- 3x3 宫粗线
    for i = 1, 2 do
        local gx = GRID_X0 + i * 3 * CELL
        local gy = GRID_Y0 + i * 3 * CELL
        bb:paintRect(gx - 1, GRID_Y0, 3, 9 * CELL, Blitbuffer.COLOR_BLACK)
        bb:paintRect(GRID_X0, gy - 1, 9 * CELL, 3, Blitbuffer.COLOR_BLACK)
    end

    -- 格子内容
    for i = 1, 81 do
        local r = math.floor((i - 1) / 9)
        local c = (i - 1) % 9
        local cx = GRID_X0 + c * CELL
        local cy = GRID_Y0 + r * CELL
        local v = self.val[i]
        if v ~= 0 then
            local is_given = self.given[i] ~= 0
            local baseline = cy + math.floor(CELL / 2) + 11
            self:drawCentered(bb, cx + math.floor(CELL / 2), baseline, self.font_num, tostring(v),
                Blitbuffer.COLOR_BLACK, true)
            if not is_given then
                -- 玩家填入的数字加一条短横线做形状区分（题目给定的没有）
                bb:paintRect(cx + 12, cy + CELL - 12, CELL - 24, 2, Blitbuffer.COLOR_BLACK)
            end
            if self.conflict[i] then
                -- 冲突：横穿数字的删除线
                bb:paintRect(cx + 8, cy + math.floor(CELL / 2) - 1, CELL - 16, 2, Blitbuffer.COLOR_BLACK)
            end
        else
            local mask = self.notes[i] or 0
            if mask ~= 0 then
                for d = 1, 9 do
                    if bitHas(mask, d) then
                        local nr = math.floor((d - 1) / 3)
                        local nc = (d - 1) % 3
                        local nx = cx + 5 + nc * 14
                        local ny = cy + 5 + nr * 14
                        RenderText:renderUtf8Text(bb, nx, ny + 11, self.font_note, tostring(d),
                            false, false, Blitbuffer.COLOR_GRAY_6)
                    end
                end
            end
        end
    end

    -- 选中的格子：内嵌粗框（不做整行整列反白，省刷新）
    if self.sel then
        local cx1, cy1, cx2, cy2 = self:cellRect(self.sel)
        bb:paintRect(cx1 + 1, cy1 + 1, cx2 - cx1 - 2, 3, Blitbuffer.COLOR_BLACK)
        bb:paintRect(cx1 + 1, cy2 - 4, cx2 - cx1 - 2, 3, Blitbuffer.COLOR_BLACK)
        bb:paintRect(cx1 + 1, cy1 + 1, 3, cy2 - cy1 - 2, Blitbuffer.COLOR_BLACK)
        bb:paintRect(cx2 - 4, cy1 + 1, 3, cy2 - cy1 - 2, Blitbuffer.COLOR_BLACK)
    end

    -- ---------- 状态条 ----------
    bb:paintRect(0, STATUS_Y0, self.W, STATUS_H, Blitbuffer.COLOR_WHITE)
    bb:paintRect(0, STATUS_Y0, self.W, 1, Blitbuffer.COLOR_GRAY_6)
    local sy = STATUS_Y0 + 19
    RenderText:renderUtf8Text(bb, 12, sy, self.font_small, "难度:" .. DIFFS[self.difficulty].name,
        false, false, Blitbuffer.COLOR_GRAY_5)
    local tstr = "用时:" .. fmtTime(self.elapsed)
    local tsz = RenderText:sizeUtf8Text(0, self.W, self.font_small, tstr, false, false)
    RenderText:renderUtf8Text(bb, math.floor((self.W - tsz.x) / 2), sy, self.font_small, tstr,
        false, false, Blitbuffer.COLOR_BLACK)
    local estr = "空格:" .. self:emptyCount()
    local esz = RenderText:sizeUtf8Text(0, self.W, self.font_small, estr, false, false)
    RenderText:renderUtf8Text(bb, self.W - esz.x - 12, sy, self.font_small, estr,
        false, false, Blitbuffer.COLOR_GRAY_5)

    -- ---------- 数字键盘 ----------
    local used = {}
    if self.sel then used = self:usedDigits(self.sel) end
    for d = 1, 9 do
        local bx = PAD_X0 + (d - 1) * (PAD_BW + PAD_GAP)
        local dim = (self.sel ~= nil and used[d] and self.val[self.sel] ~= d)
        if dim then
            bb:paintRect(bx, PAD_Y0, PAD_BW, PAD_H, Blitbuffer.COLOR_GRAY_D)
            bb:paintRect(bx + 2, PAD_Y0 + 2, PAD_BW - 4, PAD_H - 4, Blitbuffer.COLOR_GRAY_E)
            local sz = RenderText:sizeUtf8Text(0, self.W, self.font_num, tostring(d), false, true)
            RenderText:renderUtf8Text(bb, bx + math.floor((PAD_BW - sz.x) / 2),
                PAD_Y0 + math.floor(PAD_H / 2) + 12, self.font_num, tostring(d),
                false, true, Blitbuffer.COLOR_GRAY_7)
        else
            bb:paintRect(bx, PAD_Y0, PAD_BW, PAD_H, Blitbuffer.COLOR_BLACK)
            bb:paintRect(bx + 2, PAD_Y0 + 2, PAD_BW - 4, PAD_H - 4, Blitbuffer.COLOR_WHITE)
            local sz = RenderText:sizeUtf8Text(0, self.W, self.font_num, tostring(d), false, true)
            RenderText:renderUtf8Text(bb, bx + math.floor((PAD_BW - sz.x) / 2),
                PAD_Y0 + math.floor(PAD_H / 2) + 12, self.font_num, tostring(d),
                false, true, Blitbuffer.COLOR_BLACK)
        end
    end

    -- ---------- 操作行 ----------
    for _, b in ipairs(ACT_DEF) do
        local pressed = (b.action == "notes" and self.notes_mode)
        self:drawButton(bb, b.x, ACT_Y0, b.w, ACT_H, b.label, pressed)
    end

    -- ---------- 提示 ----------
    local hint
    if self.won then
        hint = "完成！用时 " .. fmtTime(self.elapsed) .. " · 点「新局」再来一盘"
    elseif self.notes_mode then
        hint = "笔记模式：点数字加/取消候选 · 再点「笔记」退出"
    elseif not self.sel then
        hint = "先点一个格子，再点下方数字填入"
    else
        hint = "点数字填入 · 长按格子清空 · 灰掉的数字本行/列/宫已用"
    end
    if (self.hints or 0) > 0 then
        hint = hint .. " · 已用提示 " .. self.hints
    end
    local hsz = RenderText:sizeUtf8Text(0, self.W, self.font_small, hint, false, false)
    RenderText:renderUtf8Text(bb, math.floor((self.W - hsz.x) / 2), HINT_Y0 + 12, self.font_small,
        hint, false, false, Blitbuffer.COLOR_GRAY_5)

    -- ---------- 完成浮层 ----------
    if self.won then
        local ox, oy, ow, oh = 90, 280, 420, 200
        bb:paintRect(ox, oy, ow, oh, Blitbuffer.COLOR_WHITE)
        bb:paintRect(ox, oy, ow, 3, Blitbuffer.COLOR_BLACK)
        bb:paintRect(ox, oy + oh - 3, ow, 3, Blitbuffer.COLOR_BLACK)
        bb:paintRect(ox, oy, 3, oh, Blitbuffer.COLOR_BLACK)
        bb:paintRect(ox + ow - 3, oy, 3, oh, Blitbuffer.COLOR_BLACK)
        self:drawCentered(bb, self.W / 2, oy + 70, self.font_title, "完成！", Blitbuffer.COLOR_BLACK, false)
        local info = "用时 " .. fmtTime(self.elapsed)
        self:drawCentered(bb, self.W / 2, oy + 110, self.font_small, info, Blitbuffer.COLOR_GRAY_4, false)
        local best = self.best_time[self.difficulty]
        if best then
            self:drawCentered(bb, self.W / 2, oy + 140, self.font_small,
                DIFFS[self.difficulty].name .. "最佳 " .. fmtTime(best), Blitbuffer.COLOR_GRAY_5, false)
        end
        self:drawButton(bb, ox + 60, oy + 160, 140, 34, "新局", false)
        self:drawButton(bb, ox + 220, oy + 160, 140, 34, "退出", false)
    end
end

-- ======================= 交互 =======================
function SudokuDialog:onTap(arg, ges)
    ges = ges or arg
    if not ges or not ges.pos then return true end
    local x, y = ges.pos.x, ges.pos.y

    -- 1) 完成浮层优先
    if self.won then
        local ox, oy = 90, 280
        if y >= oy + 160 and y <= oy + 194 then
            if x >= ox + 60 and x <= ox + 200 then
                self:newGame(self.difficulty)
                return true
            end
            if x >= ox + 220 and x <= ox + 360 then
                self:onClose()
                return true
            end
        end
        return true
    end

    -- 2) 顶栏按钮
    if y >= 2 and y <= TOPBAR_H then
        for _, b in ipairs(BTN_DEF) do
            if x >= b.x and x <= b.x + b.w then
                self:doButton(b.action)
                return true
            end
        end
        return true
    end

    -- 3) 数字键盘
    if y >= PAD_Y0 and y <= PAD_Y0 + PAD_H then
        for d = 1, 9 do
            local bx = PAD_X0 + (d - 1) * (PAD_BW + PAD_GAP)
            if x >= bx and x <= bx + PAD_BW then
                if self.notes_mode then
                    self:toggleNote(d)
                else
                    self:placeNumber(d)
                end
                self:refreshPad()
                self:doRefresh()
                return true
            end
        end
        return true
    end

    -- 4) 操作行
    if y >= ACT_Y0 and y <= ACT_Y0 + ACT_H then
        for _, b in ipairs(ACT_DEF) do
            if x >= b.x and x <= b.x + b.w then
                if b.action == "erase" then
                    self:erase()
                    self:refreshPad()
                elseif b.action == "notes" then
                    self.notes_mode = not self.notes_mode
                    self:markRect(b.x - 2, ACT_Y0 - 2, b.x + b.w + 2, ACT_Y0 + ACT_H + 2, "act")
                elseif b.action == "undo" then
                    self:undo()
                    self:refreshPad()
                elseif b.action == "hint" then
                    self:giveHint()
                    self:refreshPad()
                end
                self:doRefresh()
                return true
            end
        end
        return true
    end

    -- 5) 棋盘
    local idx = self:cellAt(x, y)
    if idx then
        if self.given[idx] == 0 then
            self.sel = idx
            self:markCellDirty(idx)
            self:refreshPad()
            self:doRefresh()
        end
        return true
    end

    return true
end

function SudokuDialog:doButton(action)
    if action == "quit" then
        self:onClose()
    elseif action == "new" then
        self:newGame(self.difficulty)
    elseif action == "diff" then
        local d = self.difficulty % 3 + 1
        self:newGame(d)
        self:markRect(BTN_DEF[1].x - 2, 2, BTN_DEF[1].x + BTN_DEF[1].w + 2, TOPBAR_H - 2, "top")
        self:refreshStatus()
        self:doRefresh()
    end
end

function SudokuDialog:onClose()
    self:stopClock()
    self:saveGame()
    self.is_closed = true
    self:onCloseWidget()
    UIManager:close(self)
end

-- ======================= 长按清空 =======================
function SudokuDialog:onHold(arg, ges)
    ges = ges or arg
    if not ges or not ges.pos then return false end
    local idx = self:cellAt(ges.pos.x, ges.pos.y)
    if idx and self.given[idx] == 0 then
        if self.val[idx] ~= 0 or (self.notes[idx] or 0) ~= 0 then
            self.sel = idx
            self:setCell(idx, 0, 0)
            self:refreshPad()
            self:doRefresh()
            return true
        end
    end
    return false
end

-- 算法函数挂到类上，方便无头测试台直接调用（tools/sim_sudoku.lua）
SudokuDialog.countSolutions = countSolutions
SudokuDialog.generatePuzzle = generatePuzzle
SudokuDialog.generateSolution = generateSolution

return SudokuDialog
