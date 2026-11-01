--[[--
围棋 (Go / Baduk) - Amazon Kindle 墨水屏定制版
适配设备：Kindle Basic 第 7 代 (KT2)，600x800，16 级灰度，无前光。

本文件包含：
  1) 规则内核（纯逻辑，无 UI 依赖，tools/sim_go.lua 可直接调用）
     - 棋链/气的计算、提子、禁自杀（禁空点）、简单打劫、停着、悔棋、面积法算分
  2) 墨水屏适配的绘制
     - 黑子 = 实心黑圆；白子 = 白圆 + 黑色描边环（墨水屏区分黑白子的标准做法，
       绝不靠灰度深浅区分，低对比度在阳光下看不清）
     - 最后一手 = 棋子上叠一个异色小圆点，一眼可辨
     - 棋盘线浅灰、星位深灰小点；所有语义靠形状/深浅，不靠颜色
  3) 刷新预算
     - 脏区分桶（board / status / act / overlay），只刷真正变化的交叉点；
       静止时零刷新；脏区推送后立刻清空
  4) 存档：DataStorage:getSettingsDir() .. "/go_save.txt"（棋盘/手数/当前方/
     提子数/最后一手/打劫点/停着次数/悔棋栈），读档损坏安全回落到空盘黑先

规则实现范围（明确声明）：
  - 提子：落子后对方相邻的无气整链被全部提掉（标准提子）
  - 自杀：自己这条链落子后无气 = 非法（禁空点，禁自杀）
  - 禁手：**只实现"禁空点"（禁自杀）**；**不实现**禁全局同形（superko），
    也不实现禁全局同形的"打劫"变体
  - 打劫：**简单劫**——上一手恰好只提掉 1 子、且提子方自己那块棋只剩 1 口气
    （正是那个被提点）时，把被提点记为劫点，对方**不能立即**下在那里；
    隔一手（或该方先停着）后劫点自动解除。已连成一片的大棋不构成劫
  - 停着：双方各可停一手，连续两次停着 = 终局（盘面下满也自动终局）
  - 算分：**面积法**（盘上活子 + 己方围的空点），无贴目（KOMI = 0），
    差值 = 黑 - 白；差值 > 0 黑胜，< 0 白胜，= 0 和棋
    （面积法不处理死子清理：对方死子仍按对方活子算，玩家需自行判断）
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

local N = 9                   -- 9 路棋盘
local SPACING = 56            -- 相邻交叉点间距
local X0 = 76                 -- 第一条竖线（交叉点 (1,1)）的 x
local Y0 = 60                 -- 第一条横线（交叉点 (1,1)）的 y
local BOARD_SPAN = SPACING * (N - 1)   -- 448：最后一条线 = X0 + 448 = 524

local STONE_R = 22            -- 棋子半径
local RING_R = 23             -- 白子描边：先画 RING_R 黑圆再画 STONE_R 白圆 → 2px 黑环
local HIT_TOL = 28            -- 命中容差 = 半个线距（轴向），盲操友好
local MARK_R = 6              -- 最后一手标记的小圆点半径

-- 棋盘可点击范围（顶栏之下、状态条之上）
local BOARD_TOP_LIMIT = 46
local BOARD_BOTTOM_LIMIT = 512

-- 下半屏
local STATUS_Y0 = 540         -- 状态条：手数 / 轮到谁 / 提子数
local STATUS_H = 34
local INFO_Y0 = 580           -- 最后一手 / 劫点 / 停着次数
local INFO_H = 30
local HINT_Y0 = 614           -- 提示行（非法原因等）
local HINT_H = 28
local BIG_Y0 = 660            -- 大按钮行（盲操主入口，48px 高）
local BIG_H = 48

-- 终局面板
local PANEL_X = 40
local PANEL_Y = 578
local PANEL_W = 520
local PANEL_H = 74

-- 算分用贴目（0 = 无贴目）
local KOMI = 0

-- 顶栏按钮（紧凑）
local TOP_BTN = {
    { label = "新局", x = 306, w = 66 },
    { label = "停着", x = 378, w = 66 },
    { label = "悔棋", x = 450, w = 66 },
    { label = "退出", x = 522, w = 66 },
}

-- 下方大按钮（与顶栏同功能，按钮高 48px 便于盲操）
local BIG_BTN = {
    { label = "新局", x = 24, w = 132 },
    { label = "停着", x = 164, w = 132 },
    { label = "悔棋", x = 304, w = 132 },
    { label = "退出", x = 444, w = 132 },
}

-- ======================= 纯规则内核 =======================
-- 棋盘用 81 长的一维数组，下标 1..81，第 i 点 = (r-1)*9 + c（r/c 从 1 开始）
-- 值：0 = 空，1 = 黑，2 = 白

local function rowOf(i) return math.floor((i - 1) / N) + 1 end
local function colOf(i) return (i - 1) % N + 1 end
local function idxOf(r, c) return (r - 1) * N + c end

-- 预计算每个点的上下左右邻居（越界的不放进去）
local NB = {}
for i = 1, N * N do
    local r, c = rowOf(i), colOf(i)
    local t = {}
    if r > 1 then t[#t + 1] = i - N end
    if r < N then t[#t + 1] = i + N end
    if c > 1 then t[#t + 1] = i - 1 end
    if c < N then t[#t + 1] = i + 1 end
    NB[i] = t
end

--- 取 i 点所在的同色棋链（flood fill）
local function collectChain(board, i)
    local color = board[i]
    local seen = {}
    local stack = { i }
    local chain = {}
    seen[i] = true
    while #stack > 0 do
        local cur = table.remove(stack)
        chain[#chain + 1] = cur
        for _, n in ipairs(NB[cur]) do
            if board[n] == color and not seen[n] then
                seen[n] = true
                stack[#stack + 1] = n
            end
        end
    end
    return chain
end

--- 棋链是否有气（存在一个空着的相邻点）
local function chainHasLiberty(board, chain)
    for _, cur in ipairs(chain) do
        for _, n in ipairs(NB[cur]) do
            if board[n] == 0 then return true end
        end
    end
    return false
end

--- 棋链的气数
local function chainLibertyCount(board, chain)
    local libs = {}
    for _, cur in ipairs(chain) do
        for _, n in ipairs(NB[cur]) do
            if board[n] == 0 then libs[n] = true end
        end
    end
    local cnt = 0
    for _ in pairs(libs) do cnt = cnt + 1 end
    return cnt
end

--- 面积法算分：盘上活子 + 己方围的空点
--- 返回 { black=, white=, diff=, winner= }（winner: 1 黑胜 / 2 白胜 / 0 和棋）
local function computeScore(board)
    local b_stones, w_stones = 0, 0
    for i = 1, N * N do
        local v = board[i]
        if v == 1 then
            b_stones = b_stones + 1
        elseif v == 2 then
            w_stones = w_stones + 1
        end
    end

    -- 空点归属：整块空区只挨着一种颜色 = 那个颜色的地；同时挨着两种 = 双方不计
    local b_terr, w_terr = 0, 0
    local seen = {}
    for i = 1, N * N do
        if board[i] == 0 and not seen[i] then
            local region = { i }
            local stack = { i }
            local touchB, touchW = false, false
            seen[i] = true
            while #stack > 0 do
                local cur = table.remove(stack)
                for _, n in ipairs(NB[cur]) do
                    if board[n] == 0 then
                        if not seen[n] then
                            seen[n] = true
                            stack[#stack + 1] = n
                            region[#region + 1] = n
                        end
                    elseif board[n] == 1 then
                        touchB = true
                    else
                        touchW = true
                    end
                end
            end
            if touchB and not touchW then
                b_terr = b_terr + #region
            elseif touchW and not touchB then
                w_terr = w_terr + #region
            end
        end
    end

    local black = b_stones + b_terr
    local white = w_stones + w_terr
    local diff = black - white - KOMI
    local winner = 0
    if diff > 0 then winner = 1 elseif diff < 0 then winner = 2 end
    return { black = black, white = white, diff = diff, winner = winner }
end

-- ======================= 对话框 =======================
local GoDialog = InputContainer:extend{
    name = "go_dialog",
    dimen = Geom:new{ x = 0, y = 0, w = 600, h = 800 },
    modal = true,
    -- 必须关闭原生 double_tap：否则单次 tap 被延迟 300ms 才下发，
    -- 围棋落子这种"一点即中"的操作不能忍受延迟。
    disable_double_tap = true,
}

-- ======================= 初始化 =======================
function GoDialog:init()
    self.show_parent = self

    self.W = Screen:getWidth()
    self.H = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }

    -- ⚠️ 必须显式注册手势！
    -- InputContainer:onGesture 只会把事件分发给 registerTouchZones 注册的触摸区
    -- 和 ges_events 里声明的手势，**不会**自动调用我们重写的 onTap/onHold。
    -- 只写 onTap = onTap 方法的话，手势永远到不了插件（表现为"点不动"）。
    local full_range = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }
    self.ges_events = {
        Tap  = { GestureRange:new{ ges = "tap",  range = full_range } },
        Hold = { GestureRange:new{ ges = "hold", range = full_range } },
    }

    -- 字体
    self.font_title = Font:getFace("tfont", 20)
    self.font_btn = Font:getFace("cfont", 15)
    self.font_small = Font:getFace("cfont", 13)

    -- 局面状态
    self.board = {}
    self.history = {}
    self.turn = 1        -- 1 黑 / 2 白，黑先
    self.move_no = 0     -- 手数（含停着）
    self.caps = { [1] = 0, [2] = 0 }   -- caps[1] = 黑提掉的白子数
    self.last = 0        -- 最后一手落子点（0 = 还没落过子）
    self.ko = 0          -- 打劫禁着点（0 = 无）
    self.passes = 0      -- 连续停着次数
    self.over = false    -- 是否终局
    self.result = nil    -- 终局算分结果
    self.msg = ""        -- 提示行文案（非法原因等）

    self.save_file = DataStorage:getSettingsDir() .. "/go_save.txt"

    -- 脏区分桶：board（交叉点）/ status（状态条+信息+提示）/ act（大按钮行）/ overlay（终局面板）
    self._dr = {}

    if not self:loadGame() then
        self:newGame()
    end

    self:refreshAll()
end

-- ======================= 局面操作 =======================
function GoDialog:newGame()
    self.board = {}
    for i = 1, N * N do self.board[i] = 0 end
    self.history = {}
    self.turn = 1
    self.move_no = 0
    self.caps = { [1] = 0, [2] = 0 }
    self.last = 0
    self.ko = 0
    self.passes = 0
    self.over = false
    self.result = nil
    self.msg = ""
    self:saveGame()
    self:refreshAll()
end

--- 落子。返回 true = 成功，false = 非法（原因写进 self.msg）
function GoDialog:playMove(idx)
    if self.over then
        self.msg = "本局已终局，点「新局」重开"
        self:refreshStatus()
        self:doRefresh()
        return false
    end
    if not idx or idx < 1 or idx > N * N then return false end
    if self.board[idx] ~= 0 then
        self.msg = "该点已有棋子"
        self:refreshStatus()
        self:doRefresh()
        return false
    end
    if self.ko ~= 0 and idx == self.ko then
        self.msg = "打劫：不能立即回提"
        self:refreshStatus()
        self:doRefresh()
        return false
    end

    local color = self.turn
    local opp = 3 - color

    -- 悔棋信息（提子、打劫点、提子数、手数、停着数、最后一手全部一起记）
    local entry = {
        idx = idx,
        color = color,
        captured = {},
        ko_before = self.ko,
        capb = self.caps[1],
        capw = self.caps[2],
        move_no_before = self.move_no,
        passes_before = self.passes,
        last_before = self.last,
    }

    self.board[idx] = color

    -- 提掉相邻的对方无气棋链
    local seen = {}
    for _, n in ipairs(NB[idx]) do
        if self.board[n] == opp and not seen[n] then
            local chain = collectChain(self.board, n)
            for _, ci in ipairs(chain) do seen[ci] = true end
            if not chainHasLiberty(self.board, chain) then
                for _, ci in ipairs(chain) do
                    self.board[ci] = 0
                    entry.captured[#entry.captured + 1] = ci
                end
            end
        end
    end

    -- 自杀检查（禁空点）：自己这条链没有气 = 非法，回滚
    local mychain = collectChain(self.board, idx)
    if not chainHasLiberty(self.board, mychain) then
        self.board[idx] = 0
        for _, ci in ipairs(entry.captured) do self.board[ci] = opp end
        self.msg = "禁着点：不能自杀"
        self:refreshStatus()
        self:doRefresh()
        return false
    end

    -- 接受这一手
    self.caps[color] = self.caps[color] + #entry.captured
    self.move_no = self.move_no + 1
    self.last = idx
    self.turn = opp
    self.passes = 0
    self.msg = ""

    -- 打劫点：恰好只提 1 子，且提子方那块棋只剩 1 口气（就是被提点）→ 简单劫
    self.ko = 0
    if #entry.captured == 1 and chainLibertyCount(self.board, mychain) == 1 then
        self.ko = entry.captured[1]
    end

    self.history[#self.history + 1] = entry

    -- 脏区：只刷落子点和被提掉的子
    self:markPointDirty(idx)
    for _, ci in ipairs(entry.captured) do self:markPointDirty(ci) end

    if self:isBoardFull() then
        self:finishGame()
    end

    self:saveGame()
    self:refreshStatus()
    self:doRefresh()
    return true
end

--- 停着
function GoDialog:doPass()
    if self.over then
        self.msg = "本局已终局，点「新局」重开"
        self:refreshStatus()
        self:doRefresh()
        return false
    end
    local entry = {
        idx = 0,           -- 0 = 停着（没有落子）
        color = self.turn,
        captured = {},
        ko_before = self.ko,
        capb = self.caps[1],
        capw = self.caps[2],
        move_no_before = self.move_no,
        passes_before = self.passes,
        last_before = self.last,
    }
    self.history[#self.history + 1] = entry
    self.move_no = self.move_no + 1
    self.passes = self.passes + 1
    self.ko = 0          -- 停着之后劫点解除
    self.turn = 3 - self.turn
    self.msg = ""

    if self.passes >= 2 then
        self:finishGame()
    end

    self:saveGame()
    self:refreshStatus()
    self:doRefresh()
    return true
end

--- 悔棋：撤销上一手（含提子与打劫记录一起回滚）
function GoDialog:undo()
    local e = table.remove(self.history)
    if not e then
        self.msg = "没有可悔的棋了"
        self:refreshStatus()
        self:doRefresh()
        return false
    end

    -- 棋盘回滚：撤销落子，把被提掉的子放回去
    if e.idx ~= 0 then self.board[e.idx] = 0 end
    local opp = 3 - e.color
    for _, ci in ipairs(e.captured) do self.board[ci] = opp end

    self.ko = e.ko_before
    self.caps[1] = e.capb
    self.caps[2] = e.capw
    self.move_no = e.move_no_before
    self.passes = e.passes_before
    self.turn = e.color
    self.last = e.last_before
    self.over = false
    self.result = nil
    self.msg = ""

    -- 脏区：撤销点 + 被提子复原点 + 最后一手标记可能移动的点
    if e.idx ~= 0 then self:markPointDirty(e.idx) end
    for _, ci in ipairs(e.captured) do self:markPointDirty(ci) end
    if e.last_before ~= 0 and e.last_before ~= e.idx then
        self:markPointDirty(e.last_before)
    end
    self:refreshAct()   -- 从终局悔棋回来，「停着」按钮恢复可用

    self:saveGame()
    self:refreshStatus()
    self:doRefresh()
    return true
end

--- 盘面是否已下满
function GoDialog:isBoardFull()
    for i = 1, N * N do
        if self.board[i] == 0 then return false end
    end
    return true
end

--- 终局：算分并显示结果
function GoDialog:finishGame()
    self.over = true
    self.result = computeScore(self.board)
    self:markRect(PANEL_X - 3, PANEL_Y - 3, PANEL_X + PANEL_W + 3, PANEL_Y + PANEL_H + 3, "overlay")
    self:refreshAct()   -- 「停着」按钮变灰
    self:refreshStatus()
end

-- ======================= 几何 =======================
--- 交叉点的屏幕坐标
function GoDialog:pointXY(idx)
    local r, c = rowOf(idx), colOf(idx)
    return X0 + (c - 1) * SPACING, Y0 + (r - 1) * SPACING
end

--- 命中判定：取离触点最近的交叉点（轴向容差半个线距 = 28px，盲操友好）
function GoDialog:hitTest(x, y)
    if y < BOARD_TOP_LIMIT or y > BOARD_BOTTOM_LIMIT then return nil end
    local col = math.floor((x - X0 + HIT_TOL) / SPACING)
    local row = math.floor((y - Y0 + HIT_TOL) / SPACING)
    if col < 0 or col >= N or row < 0 or row >= N then return nil end
    local cx = X0 + col * SPACING
    local cy = Y0 + row * SPACING
    if math.abs(x - cx) > HIT_TOL or math.abs(y - cy) > HIT_TOL then return nil end
    return row * N + col + 1
end

-- ======================= 脏区 =======================
--- 标脏一个交叉点（含棋子半径 + 余量，避免留下残影）
function GoDialog:markPointDirty(idx)
    local cx, cy = self:pointXY(idx)
    local pad = STONE_R + 3
    self:markRect(cx - pad, cy - pad, cx + pad, cy + pad, "board")
end

function GoDialog:markRect(x1, y1, x2, y2, bucket)
    local key = bucket or "field"
    local list = self._dr[key]
    if not list then
        list = {}
        self._dr[key] = list
    end
    list[#list + 1] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
end

--- 推送一个桶里的所有脏矩形，推完立刻清空（脏区用完即清）
function GoDialog:pushBucket(name, pad)
    local list = self._dr[name]
    if not list then return end
    pad = pad or 1
    for _, d in ipairs(list) do
        local x = math.max(0, math.floor(d.x1 - pad))
        local y = math.max(0, math.floor(d.y1 - pad))
        local w = math.min(self.W - x, math.ceil(d.x2 + pad - x))
        local h = math.min(self.H - y, math.ceil(d.y2 + pad - y))
        if w > 0 and h > 0 then
            UIManager:setDirty(self, "ui", Geom:new{ x = x, y = y, w = w, h = h })
        end
    end
    self._dr[name] = nil
end

function GoDialog:refreshAll()
    self._dr = {}
    UIManager:setDirty(self, "ui", Geom:new{ x = 0, y = 0, w = self.W, h = self.H })
end

--- 状态条 / 信息行 / 提示行
function GoDialog:refreshStatus()
    self:markRect(0, STATUS_Y0 - 2, self.W, HINT_Y0 + HINT_H + 2, "status")
end

--- 下方大按钮行
function GoDialog:refreshAct()
    self:markRect(0, BIG_Y0 - 3, self.W, BIG_Y0 + BIG_H + 3, "act")
end

function GoDialog:doRefresh()
    self:pushBucket("board", 1)
    self:pushBucket("status", 1)
    self:pushBucket("act", 1)
    self:pushBucket("overlay", 1)
end

-- ======================= 存档 =======================
function GoDialog:saveGame()
    local f = io.open(self.save_file, "w")
    if not f then return end
    local b = {}
    for i = 1, N * N do b[i] = tostring(self.board[i] or 0) end
    f:write("v1\n")
    f:write("board " .. table.concat(b, ",") .. "\n")
    f:write("move " .. tostring(self.move_no or 0) .. "\n")
    f:write("turn " .. tostring(self.turn or 1) .. "\n")
    f:write("caps " .. tostring(self.caps[1] or 0) .. "," .. tostring(self.caps[2] or 0) .. "\n")
    f:write("last " .. tostring(self.last or 0) .. "\n")
    f:write("ko " .. tostring(self.ko or 0) .. "\n")
    f:write("passes " .. tostring(self.passes or 0) .. "\n")
    f:write("over " .. (self.over and 1 or 0) .. "\n")
    f:write("hist " .. tostring(#self.history) .. "\n")
    for _, e in ipairs(self.history) do
        local parts = {
            tostring(e.idx), tostring(e.color), tostring(e.ko_before),
            tostring(e.capb), tostring(e.capw), tostring(e.move_no_before),
            tostring(e.passes_before), tostring(e.last_before),
        }
        for _, ci in ipairs(e.captured) do parts[#parts + 1] = tostring(ci) end
        f:write("H " .. table.concat(parts, ",") .. "\n")
    end
    f:close()
end

local function parseCSV(line)
    local vals = {}
    for token in string.gmatch(line, "([^,]+)") do
        vals[#vals + 1] = tonumber(token) or 0
    end
    return vals
end

function GoDialog:loadGame()
    local f = io.open(self.save_file, "r")
    if not f then return false end
    local lines = {}
    for line in f:lines() do lines[#lines + 1] = line end
    f:close()

    if #lines < 10 then return false end
    if lines[1] ~= "v1" then return false end

    local function field(line)
        local k, v = line:match("^([%w_]+)%s+(.*)$")
        if k then return k, v end
        return nil
    end

    local board, move_no, turn, caps, last, ko, passes, over, hist_n
    local hist = {}
    local i = 2
    while i <= #lines do
        local k, v = field(lines[i])
        if k == "board" then
            board = parseCSV(v)
        elseif k == "move" then
            move_no = tonumber(v)
        elseif k == "turn" then
            turn = tonumber(v)
        elseif k == "caps" then
            local c = parseCSV(v)
            caps = { [1] = c[1] or 0, [2] = c[2] or 0 }
        elseif k == "last" then
            last = tonumber(v)
        elseif k == "ko" then
            ko = tonumber(v)
        elseif k == "passes" then
            passes = tonumber(v)
        elseif k == "over" then
            over = tonumber(v)
        elseif k == "hist" then
            hist_n = tonumber(v)
        elseif k == "H" then
            local p = parseCSV(v)
            if #p < 8 then return false end
            local e = {
                idx = p[1], color = p[2], ko_before = p[3], capb = p[4],
                capw = p[5], move_no_before = p[6], passes_before = p[7],
                last_before = p[8], captured = {},
            }
            for j = 9, #p do e.captured[#e.captured + 1] = p[j] end
            hist[#hist + 1] = e
        end
        i = i + 1
    end

    -- 健壮性检查：任何一项不对就回落到空盘黑先
    if not board or #board ~= N * N then return false end
    for j = 1, N * N do
        if board[j] ~= 0 and board[j] ~= 1 and board[j] ~= 2 then return false end
    end
    if not move_no or move_no < 0 then return false end
    if not turn or (turn ~= 1 and turn ~= 2) then return false end
    if not caps then return false end
    if not last or last < 0 or last > N * N then return false end
    if not ko or ko < 0 or ko > N * N then return false end
    if not passes or passes < 0 then return false end
    if not hist_n or hist_n ~= #hist then return false end
    if #hist > 0 then
        for _, e in ipairs(hist) do
            if e.idx < 0 or e.idx > N * N then return false end
            if e.color ~= 1 and e.color ~= 2 then return false end
            for _, ci in ipairs(e.captured) do
                if ci < 1 or ci > N * N then return false end
            end
        end
        -- 只有最后一条记录的子必须还在盘上（更早的子可能已被提掉）
        local le = hist[#hist]
        if le.idx ~= 0 and board[le.idx] == 0 then return false end
    end

    self.board = board
    self.move_no = move_no
    self.turn = turn
    self.caps = caps
    self.last = last
    self.ko = ko
    self.passes = passes
    self.history = hist
    self.over = (over == 1)
    self.result = nil
    if self.over then self.result = computeScore(self.board) end
    self.msg = ""
    return true
end

-- ======================= 绘制 =======================
--- 居中画一个字符串
function GoDialog:drawCentered(bb, cx, baseline, font, text, color, bold)
    local sz = RenderText:sizeUtf8Text(0, self.W, font, text, false, bold)
    RenderText:renderUtf8Text(bb, cx - math.floor(sz.x / 2), baseline, font, text, false, bold, color)
    return sz.x
end

--- 画一个按钮：浅灰底 + 黑字；按下用深灰底白字；禁用用灰底灰字
function GoDialog:drawButton(bb, x, y, w, h, label, pressed, dim)
    if pressed then
        bb:paintRect(x, y, w, h, Blitbuffer.COLOR_BLACK)
        local sz = RenderText:sizeUtf8Text(0, self.W, self.font_btn, label, false, true)
        RenderText:renderUtf8Text(bb, x + math.floor((w - sz.x) / 2), y + math.floor(h / 2) + 6,
            self.font_btn, label, false, true, Blitbuffer.COLOR_WHITE)
    elseif dim then
        bb:paintRect(x, y, w, h, Blitbuffer.COLOR_GRAY_D)
        bb:paintRect(x + 2, y + 2, w - 4, h - 4, Blitbuffer.COLOR_GRAY_E)
        local sz = RenderText:sizeUtf8Text(0, self.W, self.font_btn, label, false, false)
        RenderText:renderUtf8Text(bb, x + math.floor((w - sz.x) / 2), y + math.floor(h / 2) + 6,
            self.font_btn, label, false, false, Blitbuffer.COLOR_GRAY_7)
    else
        bb:paintRect(x, y, w, h, Blitbuffer.COLOR_LIGHT_GRAY)
        bb:paintRect(x + 2, y + 2, w - 4, h - 4, Blitbuffer.COLOR_WHITE)
        local sz = RenderText:sizeUtf8Text(0, self.W, self.font_btn, label, false, false)
        RenderText:renderUtf8Text(bb, x + math.floor((w - sz.x) / 2), y + math.floor(h / 2) + 6,
            self.font_btn, label, false, false, Blitbuffer.COLOR_BLACK)
    end
end

--- 画一个棋子
---   黑子 = 实心黑圆
---   白子 = 白圆 + 黑色描边环（2px）
---   最后一手 = 棋子上叠一个异色小圆点（黑子配白点，白子配黑点）
function GoDialog:drawStone(bb, idx, value, is_last)
    local cx, cy = self:pointXY(idx)
    if value == 1 then
        bb:paintCircle(cx, cy, STONE_R, Blitbuffer.COLOR_BLACK)
        if is_last then
            bb:paintCircle(cx, cy, MARK_R, Blitbuffer.COLOR_WHITE)
        end
    else
        bb:paintCircle(cx, cy, RING_R, Blitbuffer.COLOR_BLACK)
        bb:paintCircle(cx, cy, STONE_R, Blitbuffer.COLOR_WHITE)
        if is_last then
            bb:paintCircle(cx, cy, MARK_R, Blitbuffer.COLOR_BLACK)
        end
    end
end

function GoDialog:paintTo(bb, x, y)
    -- ---------- 全屏底色（必须铺满，否则下层文件管理器会透出来）----------
    bb:paintRect(0, 0, self.W, self.H, Blitbuffer.COLOR_WHITE)

    -- ---------- 顶栏 ----------
    bb:paintRect(0, 0, self.W, TOPBAR_H, Blitbuffer.COLOR_WHITE)
    bb:paintRect(0, TOPBAR_H - 2, self.W, 2, Blitbuffer.COLOR_BLACK)
    RenderText:renderUtf8Text(bb, 12, 30, self.font_title, "围棋 9路", false, false, Blitbuffer.COLOR_BLACK)
    for _, b in ipairs(TOP_BTN) do
        -- 先画底色再画文字
        bb:paintRect(b.x, 6, b.w, TOPBAR_H - 12, Blitbuffer.COLOR_LIGHT_GRAY)
        local sz = RenderText:sizeUtf8Text(0, self.W, self.font_btn, b.label, false, false)
        RenderText:renderUtf8Text(bb, b.x + math.floor((b.w - sz.x) / 2), 30,
            self.font_btn, b.label, false, false, Blitbuffer.COLOR_BLACK)
    end

    -- ---------- 棋盘线（浅灰）+ 星位（深灰小点）----------
    for i = 0, N - 1 do
        local gx = X0 + i * SPACING
        local gy = Y0 + i * SPACING
        bb:paintRect(gx, Y0, 1, BOARD_SPAN, Blitbuffer.COLOR_GRAY)
        bb:paintRect(X0, gy, BOARD_SPAN, 1, Blitbuffer.COLOR_GRAY)
    end
    -- 9 路棋盘星位：(3,3) (3,7) (7,3) (7,7) 与中心 (5,5)
    local stars = { { 3, 3 }, { 3, 7 }, { 7, 3 }, { 7, 7 }, { 5, 5 } }
    for _, s in ipairs(stars) do
        local cx = X0 + (s[2] - 1) * SPACING
        local cy = Y0 + (s[1] - 1) * SPACING
        bb:paintCircle(cx, cy, 3, Blitbuffer.COLOR_GRAY_2)
    end

    -- ---------- 棋子 ----------
    for i = 1, N * N do
        local v = self.board[i]
        if v ~= 0 then
            self:drawStone(bb, i, v, self.last == i)
        end
    end

    -- ---------- 状态条 ----------
    bb:paintRect(0, STATUS_Y0, self.W, STATUS_H, Blitbuffer.COLOR_WHITE)
    bb:paintRect(0, STATUS_Y0, self.W, 1, Blitbuffer.COLOR_GRAY_6)
    local turn_text
    if self.over then
        turn_text = "终局"
    else
        turn_text = (self.turn == 1) and "黑方落子" or "白方落子"
    end
    RenderText:renderUtf8Text(bb, 12, STATUS_Y0 + 23, self.font_small,
        "第 " .. self.move_no .. " 手", false, false, Blitbuffer.COLOR_BLACK)
    self:drawCentered(bb, self.W / 2, STATUS_Y0 + 23, self.font_small, turn_text, Blitbuffer.COLOR_BLACK)
    local cap_text = "提子 黑" .. self.caps[1] .. " 白" .. self.caps[2]
    local csz = RenderText:sizeUtf8Text(0, self.W, self.font_small, cap_text, false, false)
    RenderText:renderUtf8Text(bb, self.W - csz.x - 12, STATUS_Y0 + 23, self.font_small,
        cap_text, false, false, Blitbuffer.COLOR_GRAY_4)

    -- ---------- 信息行：最后一手 / 劫点 / 停着 ----------
    local function coordText(idx)
        if not idx or idx == 0 then return "-" end
        return "(" .. rowOf(idx) .. "," .. colOf(idx) .. ")"
    end
    local last_color = ""
    if self.last ~= 0 then
        last_color = (self.board[self.last] == 1) and "黑" or "白"
    end
    local info = "最后 " .. coordText(self.last) .. last_color .. " · 劫点 " .. coordText(self.ko)
        .. " · 停着 " .. self.passes .. " 次"
    self:drawCentered(bb, self.W / 2, INFO_Y0 + 20, self.font_small, info, Blitbuffer.COLOR_GRAY_4)

    -- ---------- 提示行 ----------
    local hint = self.msg
    if hint == "" then
        if self.over then
            hint = "本局已终局 · 点「新局」重开"
        else
            hint = "点交叉点落子 · 长按棋盘悔棋 · 顶栏可停着"
        end
    end
    self:drawCentered(bb, self.W / 2, HINT_Y0 + 20, self.font_small, hint, Blitbuffer.COLOR_GRAY_4)

    -- ---------- 大按钮行 ----------
    for _, b in ipairs(BIG_BTN) do
        -- 终局后「停着」不可用，用灰字标出来
        local dim = (b.label == "停着" and self.over)
        self:drawButton(bb, b.x, BIG_Y0, b.w, BIG_H, b.label, false, dim)
    end

    -- ---------- 终局面板 ----------
    if self.over and self.result then
        local r = self.result
        bb:paintRect(PANEL_X, PANEL_Y, PANEL_W, PANEL_H, Blitbuffer.COLOR_WHITE)
        bb:paintRect(PANEL_X, PANEL_Y, PANEL_W, 3, Blitbuffer.COLOR_BLACK)
        bb:paintRect(PANEL_X, PANEL_Y + PANEL_H - 3, PANEL_W, 3, Blitbuffer.COLOR_BLACK)
        bb:paintRect(PANEL_X, PANEL_Y, 3, PANEL_H, Blitbuffer.COLOR_BLACK)
        bb:paintRect(PANEL_X + PANEL_W - 3, PANEL_Y, 3, PANEL_H, Blitbuffer.COLOR_BLACK)
        self:drawCentered(bb, self.W / 2, PANEL_Y + 24, self.font_title, "终局", Blitbuffer.COLOR_BLACK, false)
        self:drawCentered(bb, self.W / 2, PANEL_Y + 46, self.font_small,
            "黑 " .. r.black .. " : " .. r.white .. " 白", Blitbuffer.COLOR_BLACK, false)
        local verdict
        if r.winner == 1 then
            verdict = "黑胜 " .. r.diff .. " 目"
        elseif r.winner == 2 then
            verdict = "白胜 " .. (-r.diff) .. " 目"
        else
            verdict = "和棋"
        end
        self:drawCentered(bb, self.W / 2, PANEL_Y + 66, self.font_small, verdict, Blitbuffer.COLOR_GRAY_4, false)
    end
end

-- ======================= 交互 =======================
-- 手势入口：转发给 InputContainer（它按 ges_events 分发），并吞掉所有手势，
-- 避免冒泡到下层的文件管理器。
function GoDialog:onGesture(ev)
    InputContainer.onGesture(self, ev)
    return true
end

function GoDialog:onTap(arg, ges)
    ges = ges or arg
    if not ges or not ges.pos then return true end
    local x, y = ges.pos.x, ges.pos.y

    -- 1) 顶栏按钮
    if y >= 2 and y <= TOPBAR_H then
        for _, b in ipairs(TOP_BTN) do
            if x >= b.x and x <= b.x + b.w then
                self:doAction(b.label)
                return true
            end
        end
        return true
    end

    -- 2) 下方大按钮行
    if y >= BIG_Y0 and y <= BIG_Y0 + BIG_H then
        for _, b in ipairs(BIG_BTN) do
            if x >= b.x and x <= b.x + b.w then
                self:doAction(b.label)
                return true
            end
        end
        return true
    end

    -- 3) 棋盘：落子
    local idx = self:hitTest(x, y)
    if idx then
        self:playMove(idx)
        return true
    end

    return true
end

--- 顶栏/大按钮的统一动作分发
function GoDialog:doAction(label)
    if label == "新局" then
        self:newGame()
    elseif label == "停着" then
        self:doPass()
    elseif label == "悔棋" then
        self:undo()
    elseif label == "退出" then
        self:onClose()
    end
end

function GoDialog:onClose()
    self:saveGame()
    self.is_closed = true
    self:onCloseWidget()
    UIManager:close(self)
end

-- 长按棋盘 = 悔棋（与其它游戏一致的手势语义）
function GoDialog:onHold(arg, ges)
    ges = ges or arg
    if not ges or not ges.pos then return false end
    local idx = self:hitTest(ges.pos.x, ges.pos.y)
    if idx then
        self:undo()
        return true
    end
    return false
end

-- 算法函数挂到类上，方便无头测试台直接调用（tools/sim_go.lua）
GoDialog.collectChain = collectChain
GoDialog.chainHasLiberty = chainHasLiberty
GoDialog.chainLibertyCount = chainLibertyCount
GoDialog.computeScore = computeScore
GoDialog.idxOf = idxOf
GoDialog.rowOf = rowOf
GoDialog.colOf = colOf

return GoDialog
