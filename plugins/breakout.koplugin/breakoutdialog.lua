--[[--
砖石战场 (打砖块 / Breakout) - Kindle 墨水屏全屏触控定制版

针对 Amazon Kindle Basic（第 7 代 / KT2, 600x800, 16 级灰度, 无前光）的墨水屏物理特性重构：
- 格点步进物理：球以固定 tick 沿速度方向步进，子步细分(<=5px)杜绝穿模，
  击球点决定出射角的手感完整保留
- 静态预测代替连续动画：飞行中显示"落点十字标记"，待发时显示发射短射线，
  把不可读的连续动画换成可读的静态信息
- 灰阶语义化：普通砖=深灰底(退居背景层)，值得打的砖(多血/道具)=纯黑并用白色 pip 编码血量；
  钢砖用浅灰底+黑描边+菱形点阵，与可破砖双重区分
- 分区刷新：每帧只刷新"运动脏区"，砖阵区低频维护刷新，
  残影当作有预算的资源来管，避免频繁全屏黑闪
- 跟手触控：pan 手势持续发射，挡板用相对位移+锚点实时跟手且永不跳位
- 掉落道具：道具砖(白色菱形 pip)被击碎后掉落徽章，徽章慢速直落(100px/s)，
  底栏效果条显示剩余时间；多球最多 4 颗，落点只预测最迫近的一颗以控残影

架构参照本仓库《方块战争 (俄罗斯方块)》插件 (plugins/tetris.koplugin)。
设计文档见 docs/BREAKOUT_PLAN.md
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
local Time = require("ui/time")

-- ======================= 布局常量 =======================
local TOPBAR_H = 44
local BOTBAR_H = 92               -- 底部加高：多出一条"生效道具"效果条

local COLS = 10
local ROWS = 6
local BRICK_W = 52
local BRICK_H = 24
local BRICK_GAP = 3

local PADDLE_W = 96               -- 默认挡板宽
local PADDLE_W_LONG = 132         -- 加长道具
local PADDLE_W_SHORT = 64         -- 变短道具
local PADDLE_H = 12
local BALL_R = 7
local BALL_R_SMALL = 4            -- "细球"道具生效时的球半径
local MAX_LIVES = 3
local MAX_LIVES_CAP = 5           -- 加命道具的上限
local MAX_BALLS = 4               -- 多球道具的球数上限
local SHIELD_GAP = 22             -- 护盾线挂在挡板上方多少像素
local LASER_INTERVAL = 4          -- 激光发射间隔 (tick)
local LASER_SPEED = 420           -- 激光子弹速度 (px/s)
local LASER_BULLET_R = 3          -- 激光子弹的碰撞半径
local CHAOS_JITTER = 0.45         -- 混乱道具的出射角抖动 (rad)
local MAX_FX_SLOTS = 6            -- 底栏效果条最多同时显示几个道具

-- ======================= 掉落道具 =======================
local ITEM_SIZE = 28              -- 道具徽章边长
local ITEM_FALL_SPEED = 50        -- 道具下落速度 (px/s)：再慢一倍，太快接不到
local ITEM_MAX_COUNT = 4          -- 同屏最多掉落道具数 (道具砖变多后要留得住)
local ITEM_MARK_MAX = 3           -- 最多同时显示几个道具落点标记

-- 道具表。bad = 减益(浅灰底)，其余为增益(纯黑底)。
-- dur = 持续秒数，0 表示即时生效。
-- 谱系参考经典 Arkanoid / DX-Ball：加长、多球、减速、加命、吸盘之外，
-- 补上金币、穿透、爆裂、激光、护盾五类增益，与细球、反转、掉命、隐形、混乱五类减益。
local POWERUPS = {
    -- ---------- 增益(10 种) ----------
    { id = "extend", name = "加长", dur = 12 },
    { id = "multi",  name = "多球", dur = 0 },
    { id = "slow",   name = "减速", dur = 12 },
    { id = "life",   name = "加命", dur = 0 },
    { id = "catch",  name = "吸盘", dur = 10 },
    { id = "gold",   name = "金币", dur = 0 },
    { id = "pierce", name = "穿透", dur = 8 },
    { id = "bomb",   name = "爆裂", dur = 8 },
    { id = "laser",  name = "激光", dur = 8 },
    { id = "shield", name = "护盾", dur = 20 },
    -- ---------- 减益(7 种) ----------
    { id = "shrink", name = "变短", dur = 10, bad = true },
    { id = "fast",   name = "加速", dur = 8,  bad = true },
    { id = "narrow", name = "细球", dur = 12, bad = true },
    { id = "flip",   name = "反转", dur = 8,  bad = true },
    { id = "drop",   name = "掉命", dur = 0,  bad = true },
    { id = "blind",  name = "隐形", dur = 6,  bad = true },
    { id = "chaos",  name = "混乱", dur = 10, bad = true },
}
local POWERUP_BY_ID = {}
-- 增益/减益分开存一份：掉落时按 2:1 加权抽，17 种等概率的话减益占 41%，太惩罚
local POWERUPS_GOOD = {}
local POWERUPS_BAD = {}
for _, pu in ipairs(POWERUPS) do
    POWERUP_BY_ID[pu.id] = pu
    if pu.bad then
        POWERUPS_BAD[#POWERUPS_BAD + 1] = pu
    else
        POWERUPS_GOOD[#POWERUPS_GOOD + 1] = pu
    end
end

-- ======================= 物理与节奏常量 =======================
local TICK = 0.10              -- 游戏主循环周期 (10Hz)
local BASE_SPEED = 150         -- 第 1 关球速 (px/s)
local SPEED_STEP = 12          -- 每关提速
local MAX_SPEED = 265          -- 球速上限
local MAX_SPIN = 1.0           -- 出射角上限 (rad, ≈57°)
local MIN_VX_RATIO = 0.12      -- 横向分量下限，防垂直死循环
local SUBSTEP = 5              -- 单个子步最大位移 (px)
local BRICK_REFRESH_TICKS = 60 -- 砖阵区维护刷新间隔 (tick)：6s 一次，只在游戏中做

-- ======================= 游戏状态 =======================
local STATE_READY = 0          -- 球停在挡板上，等待发球
local STATE_PLAYING = 1
local STATE_PAUSED = 2
local STATE_LEVELCLEAR = 3
local STATE_GAMEOVER = 4

local BRICK_SCORE = { [1] = 10, [2] = 20, [3] = 30 }

-- ======================= 关卡形状库 =======================
-- 砖阵不再是固定的好几排长方形，而是从形状库里随机挑一个形状铺出来：
-- 圆形 / 菱形 / 心形 / 三角形 / 十字 / 箭头 / 笑脸 / 沙漏 / 若干字母。
-- 掩码按 10 列 x 6 行写：'#' = 该位置有砖，'.' = 空。
-- 每开一局重新随机，每关换一个形状，所以同一个形状不会连着出。
local SHAPE_LIBRARY = {
    { id = "circle", name = "圆形", mask = {
        "..######..", ".########.", "##########",
        "##########", ".########.", "..######..",
    } },
    { id = "diamond", name = "菱形", mask = {
        "...####...", "..######..", ".########.",
        ".########.", "..######..", "...####...",
    } },
    { id = "heart", name = "心形", mask = {
        ".##....##.", "####..####", "##########",
        ".########.", "..######..", "...####...",
    } },
    { id = "triangle", name = "三角形", mask = {
        "..........", "....##....", "...####...",
        "..######..", ".########.", "##########",
    } },
    { id = "cross", name = "十字", mask = {
        "....##....", "....##....", "##########",
        "##########", "....##....", "....##....",
    } },
    { id = "arrow", name = "箭头", mask = {
        "....##....", "....##....", "##########",
        ".########.", "..######..", "...####...",
    } },
    { id = "smiley", name = "笑脸", mask = {
        "..######..", ".########.", "##..##..##",
        "##..##..##", ".########.", "..######..",
    } },
    { id = "hourglass", name = "沙漏", mask = {
        "##########", "##########", "..######..",
        "...####...", "..######..", "##########",
    } },
    { id = "letter_a", name = "字母A", mask = {
        "...####...", "..######..", ".########.",
        "##########", "..##..##..", "..##..##..",
    } },
    { id = "letter_h", name = "字母H", mask = {
        "##......##", "##......##", "##########",
        "##########", "##......##", "##......##",
    } },
    { id = "letter_t", name = "字母T", mask = {
        "##########", "...####...", "...####...",
        "...####...", "...####...", "...####...",
    } },
    { id = "letter_u", name = "字母U", mask = {
        ".########.", ".##....##.", ".##....##.",
        ".##....##.", ".##....##.", "..######..",
    } },
    { id = "letter_x", name = "字母X", mask = {
        "###....###", ".###..###.", "..######..",
        "..######..", ".###..###.", "###....###",
    } },
    { id = "letter_e", name = "字母E", mask = {
        "##########", "##........", "##........",
        "######....", "##........", "##########",
    } },
    { id = "letter_b", name = "字母B", mask = {
        ".########.", ".##....##.", ".##....##.",
        ".########.", ".##....##.", ".########.",
    } },
    { id = "letter_c", name = "字母C", mask = {
        "..######..", ".########.", "##........",
        "##........", ".########.", "..######..",
    } },
    { id = "letter_o", name = "字母O", mask = {
        "..######..", ".########.", "##......##",
        "##......##", ".########.", "..######..",
    } },
    { id = "letter_s", name = "字母S", mask = {
        "..######..", ".##.......", "..######..",
        ".......##.", ".##....##.", "..######..",
    } },
    { id = "letter_v", name = "字母V", mask = {
        "##......##", "##......##", "##......##",
        ".##....##.", ".##....##.", "..######..",
    } },
    { id = "letter_y", name = "字母Y", mask = {
        "##......##", "##......##", ".##....##.",
        "..######..", "...####...", "...####...",
    } },
}

-- 道具砖数量：每关 6 块起步，关卡越高越多，封顶 10 块
local POWER_BRICK_MIN = 6
local POWER_BRICK_MAX = 10

-- 顶栏按钮：靠左排布，避开右上角系统状态栏(时钟/电量)的覆盖区域
-- 最左边是 AI 辅助开关：开启时按钮反白（黑底白字），
-- 墨水屏上明暗反转是最强的状态区分，比灰阶可靠。
local BTN_DEF = {
    { x = 220, w = 62, action = "ai" },
    { x = 286, w = 62, action = "pause" },
    { x = 352, w = 62, action = "restart" },
    { x = 418, w = 62, action = "exit" },
}

-- 玩家手动拖动挡板后，AI 让位多久（秒）再自动接管
local AI_MANUAL_HOLD = 1.2


local BreakoutDialog = InputContainer:extend{
    name = "breakout_dialog",
    dimen = Geom:new{ x = 0, y = 0, w = 600, h = 800 },
    modal = true,
    -- 必须关闭原生 double_tap：
    --   KOReader 在 double_tap 开启时，会把单次 tap 延迟 300ms 才下发，
    --   并把 300ms 内的两次 tap 合并成一个 double_tap 事件（两次 tap 全部丢失）。
    --   "点一下发球 / 点底部跳板"这类即时操作不能忍受 300ms 延迟，
    --   因此关掉原生 double_tap，让 tap 立即送达，双击暂停改为在 tap 序列上自行判定。
    disable_double_tap = true,
}

-- ======================= 初始化 =======================
function BreakoutDialog:init()
    self.show_parent = self

    -- 适配真实屏幕尺寸 (Kindle Basic 第 7 代 / KT2 = 600x800)
    self.W = Screen:getWidth()
    self.H = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }

    -- 场地
    self.FIELD_X = 10
    self.FIELD_Y = TOPBAR_H + 4
    self.FIELD_W = self.W - 20
    self.FIELD_H = self.H - self.FIELD_Y - BOTBAR_H - 4

    -- 砖阵网格
    self.GRID_W = COLS * BRICK_W + (COLS - 1) * BRICK_GAP
    self.GRID_X = self.FIELD_X + math.floor((self.FIELD_W - self.GRID_W) / 2)
    self.GRID_Y = self.FIELD_Y + 36
    self.GRID_H = ROWS * BRICK_H + (ROWS - 1) * BRICK_GAP

    -- 挡板与判死线
    -- 挡板比原来上移 2px：让挡板底边(704)离底栏(708)留出余量，
    -- 这样"运动脏区"即使外扩 14px 也仍能被夹在 707 以内，不会扫进底栏
    self.PADDLE_Y = self.FIELD_Y + self.FIELD_H - 42
    self.DEATH_Y = self.FIELD_Y + self.FIELD_H

    -- 字体缓存 (paintTo 每帧调用，避免重复取)
    self.font_title = Font:getFace("tfont", 20)
    self.font_btn = Font:getFace("cfont", 14)
    self.font_num = Font:getFace("cfont", 17)
    self.font_small = Font:getFace("cfont", 13)
    self.font_mini = Font:getFace("cfont", 11)

    -- 最高分持久化
    self.hiscore_file = DataStorage:getSettingsDir() .. "/breakout_hiscore.txt"
    self.hiscore = self:loadHiscore()

    self.bricks = {}
    for r = 1, ROWS do
        self.bricks[r] = {}
    end

    self.state = STATE_READY
    self.score = 0
    self.level = 1
    self.lives = MAX_LIVES
    self.combo = 0
    self.bricks_left = 0

    self.paddle_x = self.FIELD_X + math.floor(self.FIELD_W / 2)
    self.paddle_target_x = self.paddle_x
    self.pan_anchor = nil
    self.pan_start_x = nil
    self.pan_start_y = nil

    -- AI 辅助：开启后挡板自动跟住球的预测落点。
    -- ai_pause_until 是"玩家手动接管到什么时候"（fts 时间戳）：
    -- 玩家一拖动挡板，AI 就让位；玩家停手后 AI 再接回来。
    self.ai_mode = false
    self.ai_pause_until = 0
    self.ai_target_x = nil

    self.marker_x = nil

    -- 多球：balls 为球数组；caught_ball 为被吸盘吸附的那一颗
    self.balls = {}
    self.caught_ball = nil

    -- 激光：挡板自动向上发射的子弹
    self.bullets = {}
    self.laser_timer = 0

    -- 挡板宽度会被道具改变
    self.paddle_w = PADDLE_W

    -- 生效中的限时道具： id -> 到期 tick
    self.effects = {}

    -- 下落的道具徽章
    self.items = {}

    -- 下落道具的落点标记（横坐标列表）
    self.item_markers = {}

    -- 刚接住道具的提示（toast）
    self.toast = nil

    self.timer_action = nil
    self.is_closed = false
    self.tick_count = 0
    self.brick_timer = 1
    self.state_countdown = 0

    -- 脏区分桶：运动脏区 + 底栏 + 状态浮层 + 砖阵区，四者独立推送
    -- 分桶的原因：KOReader 的刷新队列会合并"相交或共享边界"的矩形，
    -- 分开的桶各推各的，就不会把一块小区域卷成整屏重刷。
    -- 底栏与浮层如果不显式标脏，增量刷新只会把"运动区域"推给面板，
    -- 面板上永远看不到分数/生命变化与"游戏结束"浮层。
    self._dr = {}
    self._bar_sig = nil      -- 底栏内容指纹
    self._painted_state = self.state -- 上一次绘制时的状态，用于检测状态切换

    self.last_tap_time = 0
    self.last_tap_x = 0
    self.last_tap_y = 0

    -- 手势区：整屏 tap / pan / pan_release
    self:registerTouchZones({
        {
            id = "breakout_tap",
            ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler = function(ges) return self:onTap(nil, ges) end,
        },
        {
            id = "breakout_pan",
            ges = "pan",
            rate = 30, -- e-ink 上限制手势频率，避免主线程被高频事件打满
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler = function(ges) return self:onPan(nil, ges) end,
        },
        {
            id = "breakout_pan_release",
            ges = "pan_release",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler = function(ges) return self:onPanRelease(nil, ges) end,
        },
        {
            -- 快速拖拽(<900ms)会被手势检测器判成 swipe 而不是 pan_release，
            -- 必须单独接住 swipe 来清除拖动锚点，否则锚点跨次残留会导致挡板跳位
            id = "breakout_swipe",
            ges = "swipe",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler = function(ges) return self:onPanRelease(nil, ges) end,
        },
    })

    self:startNewGame()
    -- 启动主循环定时器 (没有它球不会动)
    self:scheduleTick()
end

-- ======================= 存档 =======================
function BreakoutDialog:loadHiscore()
    local f = io.open(self.hiscore_file, "r")
    if f then
        local s = f:read("*number")
        f:close()
        if s then return s end
    end
    return 0
end

function BreakoutDialog:saveHiscore()
    if self.score > self.hiscore then
        self.hiscore = self.score
        local f = io.open(self.hiscore_file, "w")
        if f then
            f:write(tostring(self.hiscore))
            f:close()
        end
    end
end

-- ======================= 关卡 =======================
-- 随机抽一个形状。exclude 用来避开上一个形状 —— 保证相邻两关形状不同，
-- 否则"每关换个花样"的观感会被 1/20 的概率破坏掉。
function BreakoutDialog:pickShape(exclude)
    local s = nil
    for _ = 1, 24 do
        s = SHAPE_LIBRARY[math.random(#SHAPE_LIBRARY)]
        if not exclude or s.id ~= exclude.id then break end
    end
    return s
end

-- 按形状铺一关
-- 返回每行 10 字符的字符串数组，字符含义：
--   '.' = 空   '1' = 普通(1血)   '2' = 强化(2血)   '3' = 精英(3血)
--   '#' = 钢砖(不可破)   '*' = 道具砖(1血，击碎后掉落随机道具)
function BreakoutDialog:randomLevel(n)
    -- 本关用哪个形状：优先用预抽好的（过关浮层要提前告诉玩家下一关是什么形状）
    local shape = self.next_shape or self:pickShape()
    self.level_shape = shape

    local rows = {}
    local cells = {}
    for r = 1, ROWS do
        local line = shape.mask[r] or ""
        local row = {}
        for c = 1, COLS do
            if string.sub(line, c, c) == "#" then
                row[c] = "1"
                cells[#cells + 1] = { r = r, c = c }
            else
                row[c] = "."
            end
        end
        rows[r] = table.concat(row)
    end

    -- 把形状占用的格子洗一遍，后面按洗好的顺序"发牌"，
    -- 免得钢砖/道具砖全挤在形状的某一侧。
    for i = #cells, 2, -1 do
        local j = math.random(i)
        cells[i], cells[j] = cells[j], cells[i]
    end
    local idx = 0
    local function next_cell()
        idx = idx + 1
        if idx > #cells then return nil end
        return cells[idx]
    end
    local function put(cell, ch)
        local line = rows[cell.r]
        rows[cell.r] = string.sub(line, 1, cell.c - 1) .. ch .. string.sub(line, cell.c + 1)
    end

    -- 第一步：钢砖。第 4 关起掺几块不可破的砖。
    -- 钢砖**不计入过关计数**，所以掺多少都不会卡关。
    local steel = 0
    if n >= 4 then steel = math.min(math.floor((n - 2) / 2), 6) end
    for _ = 1, steel do
        local cell = next_cell()
        if not cell then break end
        put(cell, "#")
    end

    -- 第二步：道具砖，每关 6 块起步，关卡越高越多。
    -- 放在血量升级之前 —— 否则高关卡里普通砖都被升级成 2/3 血砖，
    -- 可放道具砖的位置不够，数量就会少放。
    local want = math.min(POWER_BRICK_MAX, POWER_BRICK_MIN + math.floor((n - 1) / 3))
    for _ = 1, want do
        local cell = next_cell()
        if not cell then break end
        put(cell, "*")
    end

    -- 第三步：剩余普通砖按关卡升级血量（道具砖不参与升级，保持 1 血一击即掉）
    local maxhp = math.min(3, 1 + math.floor((n - 1) / 4))
    if maxhp > 1 then
        for r = 1, ROWS do
            local row = {}
            for c = 1, COLS do
                local ch = string.sub(rows[r], c, c)
                if ch == "1" and math.random(1, 100) <= 28 * (maxhp - 1) then
                    ch = tostring(math.random(2, maxhp))
                end
                row[c] = ch
            end
            rows[r] = table.concat(row)
        end
    end

    -- 为下一关预抽形状：过关浮层要提前告诉玩家"下一关是什么形状"，
    -- 并且避开本关的形状，保证相邻两关不重样。
    self.next_shape = self:pickShape(shape)
    return rows
end

function BreakoutDialog:loadLevel(n)
    local pattern = self:randomLevel(n)

    self.bricks_left = 0
    for r = 1, ROWS do
        local line = pattern[r] or ""
        for c = 1, COLS do
            local ch = string.sub(line, c, c)
            local brick = nil
            if ch == "1" then
                brick = { hp = 1, base = 1 }
            elseif ch == "2" then
                brick = { hp = 2, base = 2 }
            elseif ch == "3" then
                brick = { hp = 3, base = 3 }
            elseif ch == "#" then
                brick = { hp = -1, base = -1 }
            elseif ch == "*" then
                brick = { hp = 1, base = 1, power = true }
            end
            self.bricks[r][c] = brick
            if brick and brick.hp > 0 then
                self.bricks_left = self.bricks_left + 1
            end
        end
    end
end

function BreakoutDialog:startNewGame(full)
    self.score = 0
    self.level = 1
    self.lives = MAX_LIVES
    self.combo = 0
    self.effects = {}
    self.items = {}
    self.toast = nil
    self.paddle_w = PADDLE_W
    self.bullets = {}
    self.laser_timer = 0
    -- 新的一局要重新抽形状：把预抽的清掉
    self.next_shape = nil
    self:loadLevel(1)
    self.state = STATE_READY
    self.state_before_pause = nil
    self.state_countdown = 0
    self.marker_x = nil
    -- 重开一局不改变 AI 开关（那是玩家的偏好），但让 AI 立刻重新接管
    self.ai_pause_until = 0
    self:resetBallToPaddle()
    self:refreshAll()
    -- 重新开局做一次全刷，清掉上一局残留在砖阵区的灰影
    -- (init() 阶段对话框尚未挂到 UI 栈，此时不能走全刷)
    if full then UIManager:setDirty(self, "full") end
end

function BreakoutDialog:nextLevel()
    self.level = self.level + 1
    self.combo = 0
    self.effects = {}
    self.items = {}
    self.toast = nil
    self.paddle_w = PADDLE_W
    self.bullets = {}
    self.laser_timer = 0
    self:loadLevel(self.level)
    self.state = STATE_READY
    self.marker_x = nil
    self:resetBallToPaddle()
    -- 关卡切换做一次全刷，兜底清空累积残影
    UIManager:setDirty(self, "full")
end

function BreakoutDialog:resetBallToPaddle()
    -- 每次重置只保留一颗待发球
    local r = self:currentBallR()
    local x, y = self.paddle_x, self.PADDLE_Y - r - 1
    self.balls = { { x = x, y = y, vx = 0, vy = 0, px = x, py = y, r = r } }
    self.caught_ball = nil
    -- 新球是凭空冒出来的，得显式标脏一次，否则它不在旧位置列表里、永远刷不出来
    self:markRect(x - r - 2, y - r - 2, x + r + 2, y + r + 2)
end

-- 当前生效的球半径。"细球"道具期间球变小，过期后恢复。
-- 半径存在球对象上(r 字段)，不用全局查表 —— 碰撞路径每帧要跑很多次。
function BreakoutDialog:currentBallR()
    if self.effects.narrow then return BALL_R_SMALL end
    return BALL_R
end

-- 基础球速（不含道具修正），底栏显示用
function BreakoutDialog:baseSpeed()
    return math.min(MAX_SPEED, BASE_SPEED + (self.level - 1) * SPEED_STEP)
end

-- 道具带来的速度系数
function BreakoutDialog:speedFactor()
    if self.effects.slow then return 0.7 end
    if self.effects.fast then return 1.35 end
    return 1
end

function BreakoutDialog:currentSpeed()
    return math.min(MAX_SPEED * 1.4, self:baseSpeed() * self:speedFactor())
end

-- 按当前速度系数重新缩放所有球的速率（减速/加速生效或到期时调用）
function BreakoutDialog:recomputeBallSpeeds()
    local target = self:currentSpeed()
    for _, b in ipairs(self.balls) do
        local sp = math.sqrt(b.vx * b.vx + b.vy * b.vy)
        if sp > 1 then
            local k = target / sp
            b.vx = b.vx * k
            b.vy = b.vy * k
        end
    end
end

function BreakoutDialog:launchBall()
    if self.state ~= STATE_READY then return end
    local b = self.balls[1]
    if not b then return end
    local r = b.r or BALL_R
    local speed = self:currentSpeed()
    local ang = -math.pi / 2 + (math.random() * 2 - 1) * math.rad(26)
    b.vx = math.cos(ang) * speed
    b.vy = math.sin(ang) * speed
    b.x = self.paddle_x
    b.y = self.PADDLE_Y - r - 1
    b.px, b.py = b.x, b.y
    self.state = STATE_PLAYING
end

-- ======================= 碰撞检测 =======================
-- rad = 碰撞半径，默认用当前球的半径("细球"道具会让它变小)
function BreakoutDialog:brickAt(x, y, rad)
    rad = rad or self:currentBallR()
    local r0 = math.floor((y - rad - self.GRID_Y) / (BRICK_H + BRICK_GAP)) + 1
    local r1 = math.floor((y + rad - self.GRID_Y) / (BRICK_H + BRICK_GAP)) + 1
    local c0 = math.floor((x - rad - self.GRID_X) / (BRICK_W + BRICK_GAP)) + 1
    local c1 = math.floor((x + rad - self.GRID_X) / (BRICK_W + BRICK_GAP)) + 1
    for r = r0, r1 do
        if r >= 1 and r <= ROWS then
            for c = c0, c1 do
                if c >= 1 and c <= COLS then
                    local br = self.bricks[r][c]
                    if br then
                        local bx = self.GRID_X + (c - 1) * (BRICK_W + BRICK_GAP)
                        local by = self.GRID_Y + (r - 1) * (BRICK_H + BRICK_GAP)
                        if x + rad > bx and x - rad < bx + BRICK_W
                            and y + rad > by and y - rad < by + BRICK_H then
                            return r, c, bx, by
                        end
                    end
                end
            end
        end
    end
    return nil
end

function BreakoutDialog:resolveWalls(b)
    local r = b.r or BALL_R
    local left = self.FIELD_X + r
    local right = self.FIELD_X + self.FIELD_W - r
    local top = self.FIELD_Y + r
    if b.x < left then
        b.x = left
        b.vx = math.abs(b.vx)
    elseif b.x > right then
        b.x = right
        b.vx = -math.abs(b.vx)
    end
    if b.y < top then
        b.y = top
        b.vy = math.abs(b.vy)
    end
    -- 判死用「球底触线」而不是「球顶越线」：
    -- 旧写法要球顶越过底线才判死，球心能跑到 711、球底 718，会压到底栏(708起)
    -- 画在状态栏上；而运动脏区还会外扩 14px，直接伸进底栏触发合并刷新。
    -- 改成球底触到底线就消失，球永远画不到 707 以下，脏区夹断也不会丢内容。
    if b.y + r > self.DEATH_Y then
        b.dead = true   -- 掉出底线，交给上层统一处理（多球时不是立刻扣命）
        return true
    end
    return false
end

function BreakoutDialog:resolvePaddle(b)
    if b.vy <= 0 then return false end
    local r = b.r or BALL_R
    local half = self.paddle_w / 2
    local dx = b.x - self.paddle_x
    if dx < -half - r or dx > half + r then return false end

    -- 护盾：挡板上方一层护壁，接住这一球后护盾本身消失
    if self.effects.shield then
        local sy = self.PADDLE_Y - SHIELD_GAP
        if b.y + r >= sy - 1 and b.y - r <= sy + 8 then
            self.effects.shield = nil
            b.y = sy - r - 0.5
            b.vy = -math.abs(b.vy)
            self.combo = 0
            return true
        end
    end

    if b.y + r < self.PADDLE_Y or b.y - r > self.PADDLE_Y + PADDLE_H then return false end

    -- 吸盘生效且尚未吸附球：把球粘在挡板上，等玩家点击释放
    if self.effects.catch and not self.caught_ball then
        b.caught = true
        self.caught_ball = b
        b.vx, b.vy = 0, 0
        b.x = self.paddle_x
        b.y = self.PADDLE_Y - r - 1
        b.px, b.py = b.x, b.y
        self.combo = 0
        return true
    end

    -- 击球点决定出射角：正中近垂直，边缘大角度
    local speed = math.sqrt(b.vx * b.vx + b.vy * b.vy)
    if speed < 1 then speed = self:currentSpeed() end
    local off = math.max(-1, math.min(1, dx / half))
    local ang = off * MAX_SPIN
    -- 混乱：出射角随机抖动。抖动量受限，保证 cos(ang)>0，球永远往上飞。
    if self.effects.chaos then
        ang = ang + (math.random() * 2 - 1) * CHAOS_JITTER
    end
    b.vx = math.sin(ang) * speed
    b.vy = -math.cos(ang) * speed
    -- 保证横向分量不为 0，杜绝垂直死循环
    if math.abs(b.vx) < speed * MIN_VX_RATIO then
        b.vx = (b.vx >= 0 and 1 or -1) * speed * MIN_VX_RATIO
    end
    b.y = self.PADDLE_Y - r - 0.5
    self.combo = 0 -- 连击在触板时清零
    return true
end

function BreakoutDialog:resolveBricks(b)
    local r = b.r or BALL_R
    local rr, c, bx, by = self:brickAt(b.x, b.y, r)
    if not rr then return false end

    local br = self.bricks[rr][c]
    local steel = br and br.hp < 0
    -- 穿透：球直接穿过砖块不反弹（钢砖仍然会挡，因为它压根打不碎）
    local pierce = self.effects.pierce ~= nil and not steel

    if not pierce then
        -- 最小穿透轴反射
        local dl = b.x - r - bx
        local dr = bx + BRICK_W - (b.x + r)
        local dt = b.y - r - by
        local db = by + BRICK_H - (b.y + r)
        local m = math.min(dl, dr, dt, db)
        if m == dl then
            b.x = bx - r - 0.5
            b.vx = -math.abs(b.vx)
        elseif m == dr then
            b.x = bx + BRICK_W + r + 0.5
            b.vx = math.abs(b.vx)
        elseif m == dt then
            b.y = by - r - 0.5
            b.vy = -math.abs(b.vy)
        else
            b.y = by + BRICK_H + r + 0.5
            b.vy = math.abs(b.vy)
        end
    end

    self:damageBrick(rr, c, bx, by)

    -- 爆裂：撞砖时把周围 3x3 的砖一起炸掉
    if self.effects.bomb then
        self:explodeBricks(rr, c)
    end

    return true
end

-- 爆裂：炸掉命中砖周围一圈(3x3)的砖
function BreakoutDialog:explodeBricks(r, c)
    if self.state ~= STATE_PLAYING then return end
    for dr = -1, 1 do
        for dc = -1, 1 do
            if dr ~= 0 or dc ~= 0 then
                -- 场上砖已被打空并结算过关，剩下的不用再炸
                if self.state == STATE_LEVELCLEAR then return end
                local rr, cc = r + dr, c + dc
                if rr >= 1 and rr <= ROWS and cc >= 1 and cc <= COLS then
                    local br = self.bricks[rr][cc]
                    if br and br.hp > 0 then
                        local bx = self.GRID_X + (cc - 1) * (BRICK_W + BRICK_GAP)
                        local by = self.GRID_Y + (rr - 1) * (BRICK_H + BRICK_GAP)
                        self:damageBrick(rr, cc, bx, by)
                    end
                end
            end
        end
    end
end

function BreakoutDialog:damageBrick(r, c, bx, by)
    local br = self.bricks[r][c]
    if not br then return end

    if br.hp < 0 then
        -- 钢砖：只反弹，不计分
        return
    end

    br.hp = br.hp - 1
    self.combo = self.combo + 1
    -- 砖块掉血/击碎：当场精确标脏把这一格擦干净。
    -- 以前这里只置 brick_force，等 0.5s 一次的"砖阵区维护刷新"才去擦，
    -- 结果是碎砖的残影要挂半秒，而且维护刷新还把整片砖阵(555x167)重刷一遍。
    self:markRect(bx - 2, by - 2, bx + BRICK_W + 2, by + BRICK_H + 2, "brick")

    if br.hp <= 0 then
        self.bricks[r][c] = nil
        self.bricks_left = self.bricks_left - 1
        local mult = 1 + math.min(self.combo - 1, 10) * 0.1
        local pts = br.power and 30 or (BRICK_SCORE[br.base] or 10)
        self.score = self.score + math.floor(pts * mult)
        -- 道具砖被击碎 -> 掉出一个随机道具
        if br.power then
            self:spawnItem(bx + BRICK_W / 2, by + BRICK_H / 2)
        end
        -- 过关结算。一关只能结算一次：
        --   爆裂一次炸掉 9 块砖时，第一块可能已经把场上砖清空并触发了过关，
        --   后面几块再结算一次就会重复加过关奖励；
        --   激光在待发球状态把砖打光时也必须能结算，否则场上没砖了却永远进不了下一关。
        if self.bricks_left <= 0
            and self.state ~= STATE_LEVELCLEAR and self.state ~= STATE_GAMEOVER then
            self:levelClear()
        end
    else
        self.score = self.score + 5
    end
end

function BreakoutDialog:loseLife()
    self.lives = self.lives - 1
    self.combo = 0
    self.marker_x = nil
    self.caught_ball = nil
    if self.lives <= 0 then
        self.state = STATE_GAMEOVER
        self:saveHiscore()
    else
        self.state = STATE_READY
        self:resetBallToPaddle()
    end
end

function BreakoutDialog:levelClear()
    -- 过关奖励：基础分 + 剩余生命加成
    self.score = self.score + 200 * self.level + 100 * self.lives
    self.state = STATE_LEVELCLEAR
    -- 墨水屏刷新本身要 ~1s，浮层停留时间太短玩家读不到，给足 2.5s
    self.state_countdown = 2.5
    self.marker_x = nil
    self.caught_ball = nil
    self:saveHiscore()
end

-- ======================= 掉落道具系统 =======================
function BreakoutDialog:spawnItem(x, y)
    if #self.items >= ITEM_MAX_COUNT then return end
    -- 加权抽取：约 2/3 出增益、1/3 出减益。
    -- 17 种等概率抽的话减益占 41%，手感太惩罚。
    local list = (math.random(100) <= 66) and POWERUPS_GOOD or POWERUPS_BAD
    local pu = list[math.random(#list)]
    self.items[#self.items + 1] = {
        id = pu.id, x = x, y = y, px = x, py = y, checked = false,
    }
end

function BreakoutDialog:applyPowerUp(id)
    local pu = POWERUP_BY_ID[id]
    if not pu then return end

    if id == "multi" then
        self:applyMulti()
    elseif id == "life" then
        self.lives = math.min(MAX_LIVES_CAP, self.lives + 1)
    elseif id == "gold" then
        self.score = self.score + 1000
    elseif id == "drop" then
        -- 掉命：直接扣一条命，但不打断当前球局
        self.lives = self.lives - 1
        self.combo = 0
        if self.lives <= 0 then
            self.lives = 0
            self.state = STATE_GAMEOVER
            self:saveHiscore()
        end
    elseif id == "slow" or id == "fast" then
        self.effects[id] = self.tick_count + pu.dur * 10
        self:recomputeBallSpeeds()
    elseif id == "narrow" then
        self.effects[id] = self.tick_count + pu.dur * 10
        for _, b in ipairs(self.balls) do
            local oldr = b.r or BALL_R
            b.r = BALL_R_SMALL
            -- 球变小：旧的大圆要擦掉，否则墨水屏上留下一个球形残影
            self:markRect(b.x - oldr - 2, b.y - oldr - 2, b.x + oldr + 2, b.y + oldr + 2)
        end
    else
        -- 其余全是纯计时型效果：加长/变短/吸盘/穿透/爆裂/激光/护盾/反转/隐形/混乱
        self.effects[id] = self.tick_count + pu.dur * 10
    end

    self.toast = { id = id, name = pu.name, expire = self.tick_count + 18 }
end

-- 多球：每颗飞行中的球分裂出 2 颗新球（左右各偏 20°）
function BreakoutDialog:applyMulti()
    local sources = {}
    for _, b in ipairs(self.balls) do
        if not b.caught then sources[#sources + 1] = b end
    end
    local speed = self:currentSpeed()
    local r = self:currentBallR()
    for _, b in ipairs(sources) do
        -- math.atan(y, x) 两参形式在 5.1 / 5.3 / LuaJIT 都可用
        local base = math.atan(b.vy, b.vx)
        for _, off in ipairs({ -20, 20 }) do
            if #self.balls >= MAX_BALLS then return end
            local a = base + math.rad(off)
            self.balls[#self.balls + 1] = {
                x = b.x, y = b.y, px = b.x, py = b.y,
                vx = math.cos(a) * speed, vy = math.sin(a) * speed,
                r = r,
            }
        end
    end
end

-- 释放被吸盘吸附的球
function BreakoutDialog:releaseCaught()
    local b = self.caught_ball
    if not b then return false end
    self.caught_ball = nil
    b.caught = false
    local r = b.r or BALL_R
    local speed = self:currentSpeed()
    local ang = -math.pi / 2 + (math.random() * 2 - 1) * math.rad(30)
    b.vx = math.cos(ang) * speed
    b.vy = math.sin(ang) * speed
    b.x = self.paddle_x
    b.y = self.PADDLE_Y - r - 1
    b.px, b.py = b.x, b.y
    return true
end

-- 道具下落 + 接取判定
function BreakoutDialog:updateItems()
    local alive = {}
    for _, it in ipairs(self.items) do
        it.px, it.py = it.x, it.y
        it.y = it.y + ITEM_FALL_SPEED * TICK

        local taken = false
        if not it.checked and it.y + ITEM_SIZE / 2 >= self.PADDLE_Y then
            it.checked = true -- 只在越过接球线时判定一次
            local half = self.paddle_w / 2
            if math.abs(it.x - self.paddle_x) <= half then
                self:applyPowerUp(it.id)
                taken = true
            end
        end

        -- 同球：道具也改成"底边触线即消失"（旧写法用顶边，底边会到 732 压进底栏）
        if not taken and it.y + ITEM_SIZE / 2 <= self.DEATH_Y then
            alive[#alive + 1] = it
        end
    end
    self.items = alive

    -- 道具直落，落地横坐标就是道具当前 x -> 画落点空心方框
    self.item_markers = {}
    local n = 0
    for _, it in ipairs(self.items) do
        if n < ITEM_MARK_MAX and not it.checked then
            n = n + 1
            self.item_markers[n] = it.x
        end
    end
end

-- 限时道具到期
function BreakoutDialog:updateEffects()
    for _, pu in ipairs(POWERUPS) do
        local expiry = self.effects[pu.id]
        if expiry and self.tick_count >= expiry then
            self.effects[pu.id] = nil
            if pu.id == "slow" or pu.id == "fast" then
                self:recomputeBallSpeeds()
            elseif pu.id == "narrow" then
                for _, b in ipairs(self.balls) do
                    local oldr = b.r or BALL_R
                    b.r = BALL_R
                    -- 球恢复：旧的小圆要擦掉再画大的
                    self:markRect(b.x - oldr - 2, b.y - oldr - 2, b.x + oldr + 2, b.y + oldr + 2)
                end
            end
        end
    end
    -- 挡板宽度随道具变化（加长优先于变短）
    local w = PADDLE_W
    if self.effects.extend then
        w = PADDLE_W_LONG
    elseif self.effects.shrink then
        w = PADDLE_W_SHORT
    end
    self.paddle_w = w

    -- 提示条过期
    if self.toast and self.tick_count >= self.toast.expire then
        self.toast = nil
    end
end

-- 激光：挡板自动向上打子弹，子弹撞砖就把砖打掉
function BreakoutDialog:updateBullets(dt)
    -- 过关 / 结束时不再开火：一边结算画面一边打砖既没意义又要额外刷屏
    local laser_on = self.effects.laser
        and self.state ~= STATE_GAMEOVER and self.state ~= STATE_LEVELCLEAR
    if not laser_on then
        -- 效果到期：场上残留的子弹要擦掉，否则会停在半空变成幽灵弹
        if #self.bullets > 0 then
            for _, bu in ipairs(self.bullets) do
                self:markRect(bu.x - 5, bu.y - 5, bu.x + 5, bu.y + 5)
            end
            self.bullets = {}
        end
        return
    end

    self.laser_timer = self.laser_timer - 1
    if self.laser_timer <= 0 then
        self.laser_timer = LASER_INTERVAL
        local bx = self.paddle_x
        local by = self.PADDLE_Y - 6
        self.bullets[#self.bullets + 1] = { x = bx, y = by, px = bx, py = by }
        -- 新子弹是凭空冒出来的，得显式标脏一次
        self:markRect(bx - 5, by - 5, bx + 5, by + 5)
    end

    local alive = {}
    for _, bu in ipairs(self.bullets) do
        local sx, sy = bu.x, bu.y
        local hit = false
        -- 子弹一 tick 要飞 42px，比砖块(24px)还高，直接一步跨过去会打空。
        -- 拆成 <= SUBSTEP 的子步逐段检测，和球用同一套路。
        local dist = LASER_SPEED * dt
        local steps = math.max(1, math.ceil(dist / SUBSTEP))
        local sdt = dt / steps
        for _ = 1, steps do
            bu.px, bu.py = bu.x, bu.y
            bu.y = bu.y - LASER_SPEED * sdt
            local r, c, bx, by = self:brickAt(bu.x, bu.y, LASER_BULLET_R)
            if r then
                self:damageBrick(r, c, bx, by)
                hit = true
                break
            end
        end
        -- 整条飞行路径都要标脏：只标首尾的话中间那段不会被刷掉，会留下断掉的弹道
        self:markRect(math.min(sx, bu.x) - 5, math.min(sy, bu.y) - 5,
                      math.max(sx, bu.x) + 5, math.max(sy, bu.y) + 5)
        if not hit and bu.y >= self.FIELD_Y then
            alive[#alive + 1] = bu
        end
    end
    self.bullets = alive
end

-- ======================= 物理推进 =======================
function BreakoutDialog:stepBall(b, dt)
    local speed = math.sqrt(b.vx * b.vx + b.vy * b.vy)
    if speed < 1 then return end

    -- 单 tick 位移拆成 <= SUBSTEP 的子步，逐子步碰撞，杜绝穿模
    local dist = speed * dt
    local steps = math.max(1, math.ceil(dist / SUBSTEP))
    local sdt = dt / steps
    for _ = 1, steps do
        b.px, b.py = b.x, b.y
        b.x = b.x + b.vx * sdt
        b.y = b.y + b.vy * sdt
        if self:resolveWalls(b) then return end
        if self:resolvePaddle(b) then return end
        if self:resolveBricks(b) then
            -- 穿透生效时不反弹，继续走下一个子步
            if not self.effects.pierce then return end
        end
    end
end

-- 推进所有球；只有全部球都掉出底线时才扣命
function BreakoutDialog:stepBalls(dt)
    local alive = {}
    for _, b in ipairs(self.balls) do
        if self.state ~= STATE_PLAYING then
            alive[#alive + 1] = b
        elseif b.caught then
            -- 吸附中的球跟随挡板
            b.px, b.py = b.x, b.y
            b.x = self.paddle_x
            b.y = self.PADDLE_Y - (b.r or BALL_R) - 1
            alive[#alive + 1] = b
        else
            self:stepBall(b, dt)
            if not b.dead then alive[#alive + 1] = b end
        end
    end
    self.balls = alive
    if #self.balls == 0 and self.state == STATE_PLAYING then
        self:loseLife()
    end
end

-- 预测球落到挡板高度时的横坐标 (供"落点标记"与 AI 辅助使用)
--
-- 这里曾经有一个让落点预测"几乎永远算不准"的坑，已修掉：
-- 步长单位。vx/vy 是 px/s，步长必须也是"秒"，不能拿像素当步长。
-- 原来写成 step=6 像素，等于球每步走 6 秒的距离，一步就越过整个场地，
-- 结果永远撞在左右边界上、立刻返回边界坐标 —— 屏幕上的落点十字
-- 基本停在场地边上，AI 也就无从跟起。
--
-- 现在 dt=0.05s（每步 7~10px，比砖高 24px 细），最多 600 步 = 30 秒路径。
function BreakoutDialog:predictLanding(src)
    local b = src or self.balls[1]
    if not b then return nil end
    local rad = b.r or BALL_R
    local x, y, vx, vy = b.x, b.y, b.vx, b.vy
    local dt = 0.05
    local bounces = 0
    for _ = 1, 600 do
        x = x + vx * dt
        y = y + vy * dt

        local left = self.FIELD_X + rad
        local right = self.FIELD_X + self.FIELD_W - rad
        local top = self.FIELD_Y + rad
        if x < left then
            x = left; vx = -vx
        elseif x > right then
            x = right; vx = -vx
        end
        if y < top then
            y = top; vy = -vy
        end

        if y >= self.GRID_Y - rad and y <= self.GRID_Y + self.GRID_H + rad then
            local r, c, bx, by = self:brickAt(x, y, rad)
            if r then
                bounces = bounces + 1
                if bounces > 30 then return nil end
                local dl = x - rad - bx
                local dr = bx + BRICK_W - (x + rad)
                local dt = y - rad - by
                local db = by + BRICK_H - (y + rad)
                local m = math.min(dl, dr, dt, db)
                if m == dl then
                    x = bx - rad - 1; vx = -math.abs(vx)
                elseif m == dr then
                    x = bx + BRICK_W + rad + 1; vx = math.abs(vx)
                elseif m == dt then
                    y = by - rad - 1; vy = -math.abs(vy)
                else
                    y = by + BRICK_H + rad + 1; vy = math.abs(vy)
                end
            end
        end

        if y >= self.PADDLE_Y - rad then
            return x
        end
    end
    return nil
end

-- ======================= 挡板与预测 =======================
function BreakoutDialog:clampPaddle(x)
    local half = self.paddle_w / 2
    local lo = self.FIELD_X + half
    local hi = self.FIELD_X + self.FIELD_W - half
    return math.max(lo, math.min(hi, x))
end

-- "反转"道具生效时，左右输入被镜像：往右拖，挡板往左走。
-- 映射只作用在输入上，挡板自身的坐标是连续的，所以道具到期时不会突然跳位。
function BreakoutDialog:mapControlX(x)
    if self.effects.flip then
        return self.FIELD_X + self.FIELD_W - x
    end
    return x
end

function BreakoutDialog:updatePaddle()
    local target = self:clampPaddle(self.paddle_target_x)
    local dx = target - self.paddle_x
    local max_move = 900 * TICK
    if dx > max_move then dx = max_move elseif dx < -max_move then dx = -max_move end
    self.paddle_x = self.paddle_x + dx * 0.7

    if self.state == STATE_READY then
        -- 待发球的球跟随挡板
        for _, b in ipairs(self.balls) do
            b.x = self.paddle_x
            b.y = self.PADDLE_Y - (b.r or BALL_R) - 1
            b.px, b.py = b.x, b.y
        end
    end
end

function BreakoutDialog:updatePrediction()
    self.marker_x = nil
    if self.state ~= STATE_PLAYING then return end
    -- 多球时只预测最迫近的一颗（y 最大），避免标记过多、残影过重
    local best, besty = nil, nil
    for _, b in ipairs(self.balls) do
        if not b.caught and (besty == nil or b.y > besty) then
            best, besty = b, b.y
        end
    end
    if not best then return end
    local px = self:predictLanding(best)
    if px then
        self.marker_x = self:clampPaddle(px)
    end
end

-- 球已经掉出砖阵区时的落点外推：路径只剩左右墙反射，可以精确解析求解。
-- 用"对折"法处理任意次墙面反射：把展开路径按场地宽度对折回区间内。
function BreakoutDialog:extrapolateLanding(b)
    local rad = b.r or BALL_R
    if not b or b.vy <= 0 then return nil end
    local t = (self.PADDLE_Y - rad - b.y) / b.vy
    if t < 0 then return nil end
    local left = self.FIELD_X + rad
    local right = self.FIELD_X + self.FIELD_W - rad
    local w = right - left
    if w <= 0 then return nil end
    local rel = (b.x + b.vx * t) - left
    rel = rel % (2 * w)
    if rel > w then rel = 2 * w - rel end
    return left + rel
end

-- AI 目标：挡板该去的横坐标（没有目标时返回 nil）
--
-- 落点来源分两种：
--  · 球还在砖阵区里 -> 用 updatePrediction 的 marker_x（含砖块反弹）。
--    但那是"砖块快照"预测：球飞行途中会打碎砖，路径随之改变，
--    所以预测值会漂，只能作大方向参考。
--  · 球已经掉出砖阵区 -> 路径只剩左右墙反射，用 extrapolateLanding 精确外推，
--    这时候算出来的落点才是准的。
function BreakoutDialog:aiTarget()
    if self.state ~= STATE_PLAYING then return nil end
    -- 球被吸盘吸在挡板上时，挡板本来就该待在原地
    if self.caught_ball then return nil end

    -- 最迫近的那颗球（y 最大）
    local best, besty = nil, nil
    for _, b in ipairs(self.balls) do
        if not b.caught and (besty == nil or b.y > besty) then
            best, besty = b, b.y
        end
    end
    if not best then return nil end

    local rad = best.r or BALL_R
    local target = nil
    if best.y > self.GRID_Y + self.GRID_H + rad then
        -- 已出砖阵区：精确外推
        target = self:extrapolateLanding(best)
    else
        -- 还在砖阵区：用快照预测
        target = self.marker_x
    end
    if not target then
        -- 兜底：预测失败时退化成"跟着球走"，
        -- 至少保证挡板在球的正下方，不会完全漏接。
        target = best.x
    end
    return self:clampPaddle(target)
end

-- 玩家优先：一旦手动拖动挡板，AI 在 ai_pause_until 之前完全不插手；
-- 玩家停手一会儿后 AI 再接回来。所以它是"辅助"，不会和玩家抢挡板。
--
-- 不自动发球：发球是玩家的动作，AI 只负责"接"。
function BreakoutDialog:updateAI()
    if not self.ai_mode then return end
    if Time.now() < (self.ai_pause_until or 0) then return end
    local t = self:aiTarget()
    -- 缓存本次用的目标：落点每 tick 都在变，缓存下来才能对得上
    -- "挡板当前是被 AI 摆到哪"这个问题（否则断言会差一个 tick 的量）。
    self.ai_target_x = t
    if t then self.paddle_target_x = t end
end

-- ======================= 主循环与刷新 =======================
-- 标脏：bucket 省略时归入"运动脏区"(单一包围盒)；
--        "bar" = 底栏，"overlay" = 状态浮层。
-- 三类区域独立推送，避免"运动包围盒"把底栏/浮层一起带到脏区里，
-- 也避免底栏变化时被迫把整个屏幕推给面板。
function BreakoutDialog:markRect(x1, y1, x2, y2, bucket)
    -- bucket 为 nil -> 运动脏区桶；其余桶名(barscore/barfx/overlay/brick)各自独立。
    -- 必须原样用桶名：底栏各格的矩形在 731 行往下，如果被并进运动脏区桶，
    -- 会被"运动脏区下边界夹到 707"的钳制直接丢弃(高度算成负数)，底栏就永远刷不出来。
    local key = bucket or "field"
    local d = self._dr[key]
    if not d then
        d = { x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
        self._dr[key] = d
        return
    end
    if x1 < d.x1 then d.x1 = x1 end
    if y1 < d.y1 then d.y1 = y1 end
    if x2 > d.x2 then d.x2 = x2 end
    if y2 > d.y2 then d.y2 = y2 end
end

-- 把一个脏矩形推送到面板
function BreakoutDialog:pushRect(d, pad)
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

-- 挡板的"外观签名"：挡板位置/宽度不变，但外观变了（隐形/激光/护盾）也必须重画，
-- 否则墨水屏上会留着上一种外观的残影。
function BreakoutDialog:paddleLook()
    local look = ""
    if self.effects.blind then look = look .. "B" end
    if self.effects.laser then look = look .. "L" end
    if self.effects.shield then look = look .. "S" end
    if look == "" then look = "N" end
    return look
end

-- 标脏整块挡板区域
function BreakoutDialog:markPaddleDirty(ox, ow)
    local ph = self.paddle_w / 2 + 3
    local pho = (ow or self.paddle_w) / 2 + 3
    self:markRect(ox - pho, self.PADDLE_Y - 3, ox + pho, self.PADDLE_Y + PADDLE_H + 3)
    self:markRect(self.paddle_x - ph, self.PADDLE_Y - 3, self.paddle_x + ph, self.PADDLE_Y + PADDLE_H + 3)
end

-- 标脏护盾线区域。护盾线挂在挡板上方 SHIELD_GAP 处，会跟着挡板走，
-- 所以挡板移动时也要把旧位置擦掉。
-- 单独拆出来是为了不把它并进挡板移动脏区 —— 没有护盾时白白多刷 23px 高的区域，
-- 墨水屏上这块是纯浪费。
function BreakoutDialog:markShieldDirty(ox, ow)
    local x1 = ox or self.paddle_x
    local w1 = ow or self.paddle_w
    local ph = self.paddle_w / 2 + 3
    local pho = w1 / 2 + 3
    local sy = self.PADDLE_Y - SHIELD_GAP
    self:markRect(x1 - pho, sy - 4, x1 + pho, sy + 4)
    self:markRect(self.paddle_x - ph, sy - 4, self.paddle_x + ph, sy + 4)
end

-- 底栏的 5 个数据格：分数/最高/生命/关卡/速度
-- 每格单独一个刷新桶：只刷真正变化的那一格。
-- 以前是整条底栏(580x92)一起刷，等于每打碎一块砖底栏就整块闪一下，
-- e-ink 上非常显眼（真机抓到过整条底栏空白半秒）。
local BAR_FIELDS = {
    { key = "score", cell = 1 },
    { key = "hi",    cell = 2 },
    { key = "lives", cell = 3 },
    { key = "level", cell = 4 },
    { key = "speed", cell = 5 },
}

-- 底栏逐字段指纹：只有变了的那一格才需要重绘
function BreakoutDialog:barFieldSignatures()
    local fx = {}
    -- 效果条只显示前 MAX_FX_SLOTS 个效果，签名也只算这几个，
    -- 否则显示不出来的效果照样会每秒改一次签名，白白触发整条效果条刷新。
    -- 倒计时用"最小剩余秒数"做指纹：所有效果每秒最多让签名变一次，
    -- 而不是每个效果各变一次（那样同屏 6 个效果就是每秒 6 次整条刷新）。
    local slot = 0
    local minleft = nil
    for _, pu in ipairs(POWERUPS) do
        local e = self.effects[pu.id]
        if e and slot < MAX_FX_SLOTS then
            slot = slot + 1
            fx[#fx + 1] = pu.id
            local left = math.max(0, math.ceil((e - self.tick_count) / 10))
            if minleft == nil or left < minleft then minleft = left end
        end
    end
    if self.toast then fx[#fx + 1] = "toast:" .. self.toast.id end
    if self.caught_ball then fx[#fx + 1] = "caught" end
    return {
        score = tostring(self.score),
        hi    = tostring(math.max(self.score, self.hiscore)),
        lives = tostring(self.lives),
        level = tostring(self.level),
        speed = tostring(math.floor(self:currentSpeed())),
        fx    = table.concat(fx, ",") .. "|" .. tostring(minleft or 0),
    }
end

--- 底栏某个数据格的刷新矩形（只含数值行，标签是静态的）
--- 相邻格之间刻意留 4px 间隙：KOReader 会把"共享边界"的矩形合并成一次刷新，
--- 贴着排就会被并成一大块，等于又回到整条刷。
function BreakoutDialog:barCellRect(idx)
    local by0 = self.H - BOTBAR_H
    local cell_w = math.floor((self.W - 20) / 5)
    local cx = 10 + (idx - 1) * cell_w
    return cx + 1, by0 + 23, cx + cell_w - 3, by0 + 43
end

--- 底栏效果条 / 提示行的刷新矩形
--- 上界要盖住 6 个道具槽(12 + 6*54 = 336)加提示文字，
--- 否则第 6 个槽以外的图标画出来了却刷不出来（会留在屏上不更新）。
function BreakoutDialog:barFxRect()
    local by0 = self.H - BOTBAR_H
    return 8, by0 + 45, 440, by0 + 75
end

function BreakoutDialog:refreshAll()
    self._dr = {}
    UIManager:setDirty(self, "ui", Geom:new{ x = 0, y = 0, w = self.W, h = self.H })
end

function BreakoutDialog:doRefresh()
    -- 1) 运动脏区：只把球/挡板/标记的变化推送到面板
    local d = self._dr.field
    if d then
        local pad = 14
        local x = math.max(0, math.floor(d.x1 - pad))
        local y = math.max(0, math.floor(d.y1 - pad))
        local w = math.min(self.W - x, math.ceil(d.x2 + pad - x))
        local h = math.min(self.H - y, math.ceil(d.y2 + pad - y))
        -- 关键：运动脏区绝不能伸进底栏。
        -- 底栏 y 从 H-BOTBAR_H(=708) 开始，而 KOReader 的 _refresh 会把"共享边界"
        -- 的两个矩形也合并成一次刷新(Geom:openIntersectWith 的判定)，于是
        -- 底栏会被卷进"运动区 + 底栏"的大局部刷新里 —— e-ink 的部分刷新波形
        -- 会把实心生命圆点刷成空心、把底栏文字吃掉，表现为底栏闪烁/残缺。
        -- 所以这里把运动脏区下边界严格夹在底栏上方 1px，让两块永不合并。
        local maxy = self.H - BOTBAR_H - 1
        if y + h > maxy then h = maxy - y end
        if w > 0 and h > 0 then
            UIManager:setDirty(self, "ui", Geom:new{ x = x, y = y, w = w, h = h })
        end
    end
    -- 运动脏区必须用完即清：不清的话它的矩形会随着球跑过的地方越滚越大，
    -- 最后变成"每次都刷新整屏"，墨水屏根本受不了。
    self._dr.field = nil

    -- 2) 底栏脏区：按字段分桶推送，只刷真正变化的那一小格
    -- pad 用 0：矩形边界就是刷新边界，贴着别的区域会被 KOReader 合并
    for _, f in ipairs(BAR_FIELDS) do
        local bk = "bar" .. f.key
        if self._dr[bk] then
            self:pushRect(self._dr[bk], 0)
            self._dr[bk] = nil
        end
    end
    if self._dr.barfx then
        self:pushRect(self._dr.barfx, 0)
        self._dr.barfx = nil
    end

    -- 3) 状态浮层脏区：暂停/过关/结束
    self:pushRect(self._dr.overlay, 2)
    self._dr.overlay = nil

    -- 4) 砖阵区脏区：单独一个桶推送。
    -- 必须和运动区分开推：KOReader 的刷新队列是逐条执行的，
    -- 两个不相交的矩形各刷各的；一旦并成一个大矩形就是把整屏重刷一遍。
    if self._dr.brick then
        self:pushRect(self._dr.brick, 1)
        self._dr.brick = nil
    end

    -- 5) 顶栏脏区：AI 开关切换时只刷按钮那一小块，不整屏重刷
    if self._dr.topbar then
        self:pushRect(self._dr.topbar, 1)
        self._dr.topbar = nil
    end

    -- 6) 砖阵区低频维护刷新：清理 e-ink 残影。
    -- 只在游戏中做，而且要很稀疏 —— 这一刷是 555x167 的大区域，
    -- 0.5s 一次的话既费电又刷得满屏闪。
    if self.state == STATE_PLAYING then
        self.brick_timer = self.brick_timer - 1
        if self.brick_timer <= 0 then
            self.brick_timer = BRICK_REFRESH_TICKS
            UIManager:setDirty(self, "ui", Geom:new{
                x = self.GRID_X - 4, y = self.GRID_Y - 4,
                w = self.GRID_W + 8, h = self.GRID_H + 8,
            })
        end
    end
end

function BreakoutDialog:tick()
    if self.is_closed then return end

    -- 记录本 tick 之前各运动物体的位置，用于计算脏区
    local oldballs = {}
    for _, b in ipairs(self.balls) do
        oldballs[#oldballs + 1] = { b = b, x = b.x, y = b.y }
    end
    local olditems = {}
    for _, it in ipairs(self.items) do
        olditems[#olditems + 1] = { it = it, x = it.x, y = it.y }
    end
    local opx = self.paddle_x
    local opw = self.paddle_w -- 旧挡板宽度：变长/变短到期后要清理旧宽度的残影
    local olook = self:paddleLook()  -- 旧外观：隐形/激光/护盾切换时要重画
    local omx = self.marker_x
    local omarkers = {}
    for _, m in ipairs(self.item_markers or {}) do omarkers[#omarkers + 1] = m end

    -- 暂停时全场冻结：挡板不缓动、球不动、标记不更新
    if self.state ~= STATE_PAUSED then
        self:updateEffects()
        -- AI 在 updatePaddle 之前设定目标：marker_x 是上一 tick 算好的落点，
        -- 提前一步用上，本 tick 就能开始往落点挪。
        self:updateAI()
        self:updatePaddle()
        self:updateItems()
        self:updateBullets(TICK)
    end

    if self.state == STATE_PLAYING then
        self:stepBalls(TICK)
        self:updatePrediction()
    elseif self.state == STATE_LEVELCLEAR then
        self.state_countdown = self.state_countdown - TICK
        if self.state_countdown <= 0 then
            self:nextLevel()
        end
    end

    -- 脏区：球 / 挡板 / 落点标记 / 下落道具 的旧位置与新位置
    -- 铁律：只有"真的动了"才标脏。
    -- 墨水屏上每 10Hz 推一次区域刷新，KOReader 会照单全收地刷面板，
    -- 轻则留下残影、重则被升级成全屏黑闪 —— 真机实测静止画面 10 连拍有 2 帧糊掉半屏。
    -- 所以静止时必须一个像素都不刷新。
    -- 球半径改用 b.r（"细球"道具会让它变小），所以这里没有统一的 r
    for _, o in ipairs(oldballs) do
        local b = o.b
        if b.x ~= o.x or b.y ~= o.y then
            local br = (b.r or BALL_R) + 2
            self:markRect(o.x - br, o.y - br, o.x + br, o.y + br)   -- 旧位置要擦
            self:markRect(b.x - br, b.y - br, b.x + br, b.y + br)   -- 新位置要画
        end
    end
    -- 挡板：位置、宽度或外观变了才标脏（缓动是浮点微移，dx=0 时完全不动）
    local look_changed = olook ~= self:paddleLook()
    if self.paddle_x ~= opx or self.paddle_w ~= opw or look_changed then
        self:markPaddleDirty(opx, opw)
    end
    -- 护盾线单独处理：只在护盾存在或刚刚消失时才占刷新预算
    if olook:find("S") or self.effects.shield then
        self:markShieldDirty(opx, opw)
    end
    -- 球的落点标记：位置变了才标脏
    if omx ~= self.marker_x then
        if omx then self:markRect(omx - 12, self.PADDLE_Y - 26, omx + 12, self.PADDLE_Y - 2) end
        if self.marker_x then self:markRect(self.marker_x - 12, self.PADDLE_Y - 26, self.marker_x + 12, self.PADDLE_Y - 2) end
    end

    -- 下落道具的脏区
    local ir = ITEM_SIZE / 2 + 2
    for _, o in ipairs(olditems) do
        local it = o.it
        if it.x ~= o.x or it.y ~= o.y then
            self:markRect(o.x - ir, o.y - ir, o.x + ir, o.y + ir)
            self:markRect(it.x - ir, it.y - ir, it.x + ir, it.y + ir)
        end
    end
    -- 激光子弹的脏区在 updateBullets 里整条路径一起标（子弹一 tick 飞 42px，
    -- 只标首尾会漏掉中间那段），这里不再重复比对。
    -- 道具落点标记（空心方框）：只有新增/消失才要重画，
    -- 位置不变的标记不需要标脏（道具是垂直直落的，x 不会变）。
    local old_marks = {}
    for _, m in ipairs(omarkers) do old_marks[m] = true end
    local new_marks = {}
    for _, m in ipairs(self.item_markers or {}) do new_marks[m] = true end
    for m in pairs(old_marks) do
        if not new_marks[m] then self:markRect(m - 12, self.PADDLE_Y - 26, m + 12, self.PADDLE_Y - 2) end
    end
    for m in pairs(new_marks) do
        if not old_marks[m] then self:markRect(m - 12, self.PADDLE_Y - 26, m + 12, self.PADDLE_Y - 2) end
    end

    -- 状态浮层：状态切换时必须显式标脏浮层区域，
    -- 否则增量刷新只推"运动区域"，面板上永远看不到"游戏结束/过关/暂停"浮层。
    if self.state ~= self._painted_state then
        local old_state = self._painted_state
        self._painted_state = self.state
        -- 只有"进出浮层状态"才需要重刷浮层区域(READY<->PLAYING 不画浮层)
        if (self.state == STATE_PAUSED or self.state == STATE_LEVELCLEAR
            or self.state == STATE_GAMEOVER)
            or (old_state == STATE_PAUSED or old_state == STATE_LEVELCLEAR
            or old_state == STATE_GAMEOVER) then
            local cx = math.floor((self.W - 260) / 2)
            self:markRect(cx - 8, 282, cx + 268, 418, "overlay")
        end
        -- 注意：状态切换**不要**再整条标脏底栏。
        -- 底栏内容(分数/最高/生命/关卡/速度/提示)全部由下面的逐字段比对覆盖，
        -- 状态切换本身并不改变底栏内容。以前这里整条刷，等于每次掉命都把
        -- 底栏拆成 6 个小格依次刷一遍，e-ink 上就是整条底栏闪一下。
    end

    -- 底栏：逐字段比对，只刷变化的那一格
    local bf = self:barFieldSignatures()
    if not self._bar_fields then self._bar_fields = bf end
    for _, f in ipairs(BAR_FIELDS) do
        if self._bar_fields[f.key] ~= bf[f.key] then
            local x1, y1, x2, y2 = self:barCellRect(f.cell)
            self:markRect(x1, y1, x2, y2, "bar" .. f.key)
        end
    end
    if self._bar_fields.fx ~= bf.fx then
        local x1, y1, x2, y2 = self:barFxRect()
        self:markRect(x1, y1, x2, y2, "barfx")
    end
    self._bar_fields = bf

    self.tick_count = self.tick_count + 1
    self:doRefresh()
    self:scheduleTick()
end

function BreakoutDialog:scheduleTick()
    if self.is_closed then return end
    self:stopTimer()
    -- 重要: UIManager:scheduleIn 没有返回值(设备端 uimanager.lua:335)，
    -- 必须自己保存 action 函数引用，stopTimer() 才能真正 unschedule 掉旧链，
    -- 否则每 tick 都会多叠一条主循环定时器 (空转耗电)。
    local tick_timer
    tick_timer = function()
        if self.is_closed then return end
        self:tick()
    end
    self.timer_action = tick_timer
    UIManager:scheduleIn(TICK, tick_timer)
end

function BreakoutDialog:stopTimer()
    if self.timer_action then
        UIManager:unschedule(self.timer_action)
        self.timer_action = nil
    end
end

-- ======================= 绘制 =======================
function BreakoutDialog:paintLine(bb, x1, y1, x2, y2, w, color)
    local dx, dy = x2 - x1, y2 - y1
    local steps = math.max(1, math.ceil(math.max(math.abs(dx), math.abs(dy))))
    for i = 0, steps do
        local t = i / steps
        bb:paintRect(math.floor(x1 + dx * t - w / 2), math.floor(y1 + dy * t - w / 2), w, w, color)
    end
end

function BreakoutDialog:drawButton(bb, bx, by, bw, bh, label, active)
    -- active = true 时反白（黑底白字）：墨水屏上明暗反转是最醒目的开关状态
    local bg = active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    local fg = active and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    bb:paintRoundedRect(bx, by, bw, bh, bg, 4)
    local tw = RenderText:sizeUtf8Text(0, nil, self.font_btn, label, false, true).x
    RenderText:renderUtf8Text(bb, bx + math.floor((bw - tw) / 2), by + 21, self.font_btn, label, false, true, fg)
end

function BreakoutDialog:drawOverlay(bb, cx, cy, w, h, title, sub)
    bb:paintRoundedRect(cx, cy, w, h, Blitbuffer.COLOR_BLACK, 8)
    bb:paintRoundedRect(cx + 2, cy + 2, w - 4, h - 4, Blitbuffer.COLOR_WHITE, 6)
    local tw = RenderText:sizeUtf8Text(0, nil, self.font_title, title, false, true).x
    RenderText:renderUtf8Text(bb, cx + math.floor((w - tw) / 2), cy + 38, self.font_title, title, false, true, Blitbuffer.COLOR_BLACK)
    if sub then
        local sw = RenderText:sizeUtf8Text(0, nil, self.font_small, sub, false, false).x
        RenderText:renderUtf8Text(bb, cx + math.floor((w - sw) / 2), cy + 66, self.font_small, sub, false, false, Blitbuffer.COLOR_GRAY_5)
    end
end

-- 道具图标：纯几何图形，靠"剪影"区分，不依赖颜色
--   加长 = 满宽横杠   变短 = 窄横杠   多球 = 三个点
--   减速 = 钟面       加速 = 双箭头   加命 = 十字   吸盘 = U 形碗
--   金币 = 菱形       穿透 = 砖上穿箭 爆裂 = 圆球加刺 激光 = 炮座光柱
--   护盾 = 盾形       细球 = 漏斗     反转 = 左右箭头 掉命 = 下箭头
--   隐形 = 点阵挡板   混乱 = 折线
-- 增益用纯黑底白图标，减益用浅灰底黑图标 —— 玩家一眼可分好坏
function BreakoutDialog:drawPowerIcon(bb, x, y, id, size)
    local pu = POWERUP_BY_ID[id]
    if not pu then return end
    local fg = pu.bad and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    local bg = pu.bad and Blitbuffer.COLOR_GRAY_B or Blitbuffer.COLOR_BLACK
    bb:paintRoundedRect(x, y, size, size, bg, 4)

    local cx = math.floor(x + size / 2)
    local cy = math.floor(y + size / 2)
    local s = size / 28 -- 图标按 28px 基准等比缩放

    if id == "extend" then
        -- 满宽横杠：挡板变长的直观表达
        bb:paintRect(cx - math.floor(10 * s), cy - math.floor(3 * s),
                     math.floor(20 * s), math.floor(6 * s), fg)
    elseif id == "shrink" then
        -- 窄横杠：挡板变短的直观表达
        bb:paintRect(cx - math.floor(4 * s), cy - math.floor(3 * s),
                     math.floor(8 * s), math.floor(6 * s), fg)
    elseif id == "multi" then
        bb:paintCircle(cx - math.floor(6 * s), cy + math.floor(3 * s), math.floor(3 * s), fg)
        bb:paintCircle(cx, cy - math.floor(4 * s), math.floor(3 * s), fg)
        bb:paintCircle(cx + math.floor(6 * s), cy + math.floor(3 * s), math.floor(3 * s), fg)
    elseif id == "slow" then
        -- 钟面
        bb:paintCircle(cx, cy, math.floor(9 * s), fg, 2)
        bb:paintRect(cx - 1, cy - math.floor(6 * s), 2, math.floor(7 * s), fg)
        bb:paintRect(cx - 1, cy - 1, math.floor(6 * s), 2, fg)
    elseif id == "fast" then
        -- 双右箭头
        for _, ox in ipairs({ -8, 1 }) do
            for i = 0, 7 do
                bb:paintRect(cx + math.floor((ox + i) * s), cy - math.floor((8 - i) * s), 2, 2, fg)
                bb:paintRect(cx + math.floor((ox + i) * s), cy + math.floor((6 - i) * s), 2, 2, fg)
            end
        end
    elseif id == "life" then
        -- 十字
        bb:paintRect(cx - 2, cy - math.floor(9 * s), 4, math.floor(18 * s), fg)
        bb:paintRect(cx - math.floor(9 * s), cy - 2, math.floor(18 * s), 4, fg)
    elseif id == "catch" then
        -- U 形碗
        bb:paintRect(cx - math.floor(9 * s), cy - math.floor(6 * s), 3, math.floor(12 * s), fg)
        bb:paintRect(cx + math.floor(6 * s), cy - math.floor(6 * s), 3, math.floor(12 * s), fg)
        bb:paintRect(cx - math.floor(9 * s), cy + math.floor(3 * s), math.floor(18 * s), 3, fg)
    elseif id == "gold" then
        -- 菱形硬币：实心菱形中间掏个方孔
        for i = -9, 9 do
            local rw = 18 - 2 * math.abs(i)
            if rw > 0 then
                bb:paintRect(cx - math.floor(rw / 2), cy + i, rw, 1, fg)
            end
        end
        bb:paintRect(cx - 4, cy - 4, 8, 8, bg)
    elseif id == "pierce" then
        -- 穿透：一根竖着的砖 + 一支从左穿到右的箭
        bb:paintRect(cx - math.floor(10 * s), cy - math.floor(10 * s),
                     math.floor(3 * s), math.floor(20 * s), fg)
        bb:paintRect(cx - math.floor(8 * s), cy - 1, math.floor(14 * s), 2, fg)
        for i = 0, 6 do
            bb:paintRect(cx + math.floor((5 + i) * s), cy - math.floor((6 - i) * s), 2, 2, fg)
            bb:paintRect(cx + math.floor((5 + i) * s), cy + math.floor((5 - i) * s), 2, 2, fg)
        end
    elseif id == "bomb" then
        -- 爆裂：圆球 + 四向八根放射刺
        bb:paintCircle(cx, cy, math.floor(6 * s), fg, 2)
        for _, o in ipairs({ { 0, -12 }, { 0, 12 }, { -12, 0 }, { 12, 0 },
                             { -9, -9 }, { 9, -9 }, { -9, 9 }, { 9, 9 } }) do
            bb:paintRect(cx + math.floor(o[1] * s) - 1, cy + math.floor(o[2] * s) - 1, 2, 2, fg)
        end
    elseif id == "laser" then
        -- 激光：底部炮座 + 向上的光柱 + 箭头
        bb:paintRect(cx - math.floor(10 * s), cy + math.floor(6 * s),
                     math.floor(20 * s), math.floor(3 * s), fg)
        bb:paintRect(cx - 1, cy - math.floor(7 * s), 3, math.floor(14 * s), fg)
        for i = 0, 4 do
            bb:paintRect(cx - math.floor(i * s) - 1, cy - math.floor((11 - i) * s), 2, 2, fg)
            bb:paintRect(cx + math.floor(i * s) - 1, cy - math.floor((11 - i) * s), 2, 2, fg)
        end
    elseif id == "shield" then
        -- 护盾：上宽下尖的盾形轮廓
        bb:paintRect(cx - math.floor(8 * s), cy - math.floor(9 * s), math.floor(16 * s), 2, fg)
        bb:paintRect(cx - math.floor(8 * s), cy - math.floor(9 * s), 2, math.floor(11 * s), fg)
        bb:paintRect(cx + math.floor(6 * s), cy - math.floor(9 * s), 2, math.floor(11 * s), fg)
        for i = 0, 4 do
            local yy = cy + math.floor((1 + i) * s)
            bb:paintRect(cx + math.floor((5 - i) * s) - 1, yy, 2, 2, fg)
            bb:paintRect(cx + math.floor((3 - i) * s) - 1, yy, 2, 2, fg)
        end
    elseif id == "narrow" then
        -- 细球：上宽下窄的漏斗
        bb:paintRect(cx - math.floor(10 * s), cy - math.floor(9 * s), math.floor(20 * s), 2, fg)
        for i = 0, 8 do
            local yy = cy - math.floor(6 * s) + i
            bb:paintRect(cx - math.floor((9 - i) * s), yy, 2, 2, fg)
            bb:paintRect(cx + math.floor((8 - i) * s), yy, 2, 2, fg)
        end
    elseif id == "flip" then
        -- 反转：左右背离的双箭头
        for i = 0, 5 do
            local sp = i
            bb:paintRect(cx - math.floor(11 * s) + i - 1, cy - sp - 1, 2, 2, fg)
            bb:paintRect(cx - math.floor(11 * s) + i - 1, cy + sp - 1, 2, 2, fg)
        end
        bb:paintRect(cx - math.floor(6 * s), cy - 1, math.floor(6 * s), 2, fg)
        bb:paintRect(cx, cy - 1, math.floor(6 * s), 2, fg)
        for i = 0, 5 do
            local sp = 5 - i
            bb:paintRect(cx + math.floor(5 * s) + i - 1, cy - sp - 1, 2, 2, fg)
            bb:paintRect(cx + math.floor(5 * s) + i - 1, cy + sp - 1, 2, 2, fg)
        end
    elseif id == "drop" then
        -- 掉命：向下的箭头
        bb:paintRect(cx - 1, cy - math.floor(10 * s), 3, math.floor(12 * s), fg)
        for i = 0, 5 do
            local sp = 5 - i
            bb:paintRect(cx - sp - 1, cy + math.floor(1 * s) + i, 2, 2, fg)
            bb:paintRect(cx + sp - 1, cy + math.floor(1 * s) + i, 2, 2, fg)
        end
    elseif id == "blind" then
        -- 隐形：点阵状的挡板（实体被抹掉只剩虚影）
        for i = 0, 3 do
            bb:paintRect(cx - math.floor(10 * s) + i * math.floor(6 * s),
                         cy - math.floor(2 * s), math.floor(3 * s), math.floor(4 * s), fg)
        end
    elseif id == "chaos" then
        -- 混乱：来回折线
        bb:paintRect(cx - math.floor(10 * s), cy - math.floor(8 * s), math.floor(9 * s), 2, fg)
        bb:paintRect(cx - math.floor(2 * s), cy - math.floor(8 * s), 2, math.floor(9 * s), fg)
        bb:paintRect(cx - math.floor(2 * s), cy - 1, math.floor(9 * s), 2, fg)
        bb:paintRect(cx + math.floor(6 * s), cy - 1, 2, math.floor(9 * s), fg)
        bb:paintRect(cx + math.floor(6 * s), cy + math.floor(6 * s), math.floor(6 * s), 2, fg)
    end
end

function BreakoutDialog:paintTo(bb, x, y)
    local W, H = self.W, self.H

    -- 底色
    bb:paintRect(0, 0, W, H, Blitbuffer.COLOR_WHITE)

    -- ---------- 顶栏 ----------
    bb:paintRect(0, 0, W, TOPBAR_H, Blitbuffer.COLOR_BLACK)
    RenderText:renderUtf8Text(bb, 12, 31, self.font_title, "砖石战场", false, true, Blitbuffer.COLOR_WHITE)
    self:drawButton(bb, BTN_DEF[1].x, 7, BTN_DEF[1].w, 30, "AI", self.ai_mode)
    self:drawButton(bb, BTN_DEF[2].x, 7, BTN_DEF[2].w, 30, self.state == STATE_PAUSED and "继续" or "暂停")
    self:drawButton(bb, BTN_DEF[3].x, 7, BTN_DEF[3].w, 30, "重开")
    self:drawButton(bb, BTN_DEF[4].x, 7, BTN_DEF[4].w, 30, "退出")

    -- ---------- 场地 ----------
    bb:paintRect(self.FIELD_X - 2, self.FIELD_Y - 2, self.FIELD_W + 4, self.FIELD_H + 4, Blitbuffer.COLOR_BLACK)
    bb:paintRect(self.FIELD_X, self.FIELD_Y, self.FIELD_W, self.FIELD_H, Blitbuffer.COLOR_WHITE)

    -- ---------- 砖阵 ----------
    for r = 1, ROWS do
        for c = 1, COLS do
            local br = self.bricks[r][c]
            if br then
                local bx = self.GRID_X + (c - 1) * (BRICK_W + BRICK_GAP)
                local by = self.GRID_Y + (r - 1) * (BRICK_H + BRICK_GAP)
                if br.hp < 0 then
                    -- 钢砖：浅灰底 + 黑描边 + 黑菱形点阵 (双重区分于可破砖)
                    bb:paintRoundedRect(bx, by, BRICK_W, BRICK_H, Blitbuffer.COLOR_GRAY_B, 3)
                    bb:paintRect(bx, by, BRICK_W, 2, Blitbuffer.COLOR_BLACK)
                    bb:paintRect(bx, by + BRICK_H - 2, BRICK_W, 2, Blitbuffer.COLOR_BLACK)
                    bb:paintRect(bx, by, 2, BRICK_H, Blitbuffer.COLOR_BLACK)
                    bb:paintRect(bx + BRICK_W - 2, by, 2, BRICK_H, Blitbuffer.COLOR_BLACK)
                    local ccx = math.floor(bx + BRICK_W / 2)
                    local ccy = math.floor(by + BRICK_H / 2)
                    for _, o in ipairs({ { 0, 0 }, { -9, -5 }, { 9, -5 }, { -9, 5 }, { 9, 5 } }) do
                        bb:paintRect(ccx + o[1] - 2, ccy + o[2] - 2, 4, 4, Blitbuffer.COLOR_BLACK)
                    end
                else
                    -- 可破砖：普通砖=深灰底(退居背景层)，2/3 血砖与道具砖=纯黑
                    -- 颜色按"砖的原始类型 base"取，不按当前血量 —— 受创过的砖不能变色，
                    -- 否则一次击打会整块换灰阶(墨水屏残影重)且与普通砖混淆
                    local plain = (not br.power) and br.base == 1
                    local fill = plain and Blitbuffer.COLOR_GRAY_3 or Blitbuffer.COLOR_BLACK
                    bb:paintRoundedRect(bx, by, BRICK_W, BRICK_H, fill, 3)
                    local ccx = math.floor(bx + BRICK_W / 2)
                    local ccy = math.floor(by + BRICK_H / 2)
                    if br.power then
                        -- 道具砖：白色菱形 pip（比血量方 pip 更大更尖，一眼可辨）
                        -- 宽度序列 2,4,6,8,6,4,2 -> 对称菱形
                        for i = 0, 6 do
                            local rw = 8 - 2 * math.abs(i - 3)
                            bb:paintRect(ccx - math.floor(rw / 2), ccy - 7 + i * 2, rw, 2, Blitbuffer.COLOR_WHITE)
                        end
                    elseif br.hp == 2 then
                        bb:paintRect(ccx - 4, ccy - 4, 8, 8, Blitbuffer.COLOR_WHITE)
                    elseif br.hp >= 3 then
                        bb:paintRect(ccx - 12, ccy - 4, 8, 8, Blitbuffer.COLOR_WHITE)
                        bb:paintRect(ccx + 4, ccy - 4, 8, 8, Blitbuffer.COLOR_WHITE)
                    end
                end
            end
        end
    end

    -- ---------- 待发球：发射方向短射线 ----------
    if self.state == STATE_READY then
        local b0 = self.balls[1]
        if b0 then
            local ang = -math.pi / 2 + math.rad(12)
            local dx, dy = math.cos(ang), math.sin(ang)
            for i = 1, 8 do
                local d = i * 9
                local px = math.floor(b0.x + dx * d)
                local py = math.floor(b0.y + dy * d)
                bb:paintRect(px - 2, py - 2, 4, 4, Blitbuffer.COLOR_GRAY_7)
            end
        end
    end

    -- ---------- 护盾（挡板上方一层护壁，接住一球后消失） ----------
    if self.effects.shield then
        local sy = self.PADDLE_Y - SHIELD_GAP
        local sw = self.paddle_w
        local sx = math.floor(self.paddle_x - sw / 2)
        -- 先铺白底，保证护盾从任何背景上都读得出来
        bb:paintRect(sx, sy - 3, sw, 7, Blitbuffer.COLOR_WHITE)
        local seg = 10
        local n = math.max(2, math.floor(sw / seg))
        for i = 0, n - 1 do
            bb:paintRect(sx + i * seg, sy - 1, math.max(3, seg - 5), 3, Blitbuffer.COLOR_BLACK)
        end
    end

    -- ---------- 挡板（宽度会被道具改变） ----------
    local pw = self.paddle_w
    local px = math.floor(self.paddle_x - pw / 2)
    if self.effects.blind then
        -- 隐形：实体不画，只留一圈浅灰虚线框，挡板位置还在但很难盯
        local seg = 10
        local n = math.max(2, math.floor(pw / seg))
        for i = 0, n - 1 do
            bb:paintRect(px + i * seg, self.PADDLE_Y, math.max(3, seg - 5), PADDLE_H,
                         Blitbuffer.COLOR_GRAY_7)
        end
        bb:paintRect(px, self.PADDLE_Y, pw, 1, Blitbuffer.COLOR_GRAY_8)
        bb:paintRect(px, self.PADDLE_Y + PADDLE_H - 1, pw, 1, Blitbuffer.COLOR_GRAY_8)
    else
        bb:paintRoundedRect(px, self.PADDLE_Y, pw, PADDLE_H, Blitbuffer.COLOR_BLACK, 4)
        bb:paintRect(px + 5, self.PADDLE_Y + 3, pw - 10, 2, Blitbuffer.COLOR_WHITE)
    end
    -- 激光：挡板两侧装炮管
    if self.effects.laser then
        for _, sgn in ipairs({ -1, 1 }) do
            local gx = math.floor(self.paddle_x + sgn * (pw / 2 - 7))
            bb:paintRect(gx - 2, self.PADDLE_Y - 9, 4, 11, Blitbuffer.COLOR_BLACK)
        end
    end

    -- ---------- 落点标记（球：实心十字 + 黑心） ----------
    if self.marker_x then
        local mx = math.floor(self.marker_x)
        local my = self.PADDLE_Y - 16
        bb:paintRect(mx - 10, my - 1, 21, 3, Blitbuffer.COLOR_GRAY_5)
        bb:paintRect(mx - 1, my - 10, 3, 21, Blitbuffer.COLOR_GRAY_5)
        bb:paintCircle(mx, my, 5, Blitbuffer.COLOR_BLACK)
    end

    -- ---------- 道具落点标记（空心方框，与球的十字区分） ----------
    for _, mx in ipairs(self.item_markers or {}) do
        local mx = math.floor(mx)
        local my = self.PADDLE_Y - 16
        bb:paintRect(mx - 9, my - 9, 19, 2, Blitbuffer.COLOR_GRAY_7)
        bb:paintRect(mx - 9, my + 7, 19, 2, Blitbuffer.COLOR_GRAY_7)
        bb:paintRect(mx - 9, my - 9, 2, 19, Blitbuffer.COLOR_GRAY_7)
        bb:paintRect(mx + 7, my - 9, 2, 19, Blitbuffer.COLOR_GRAY_7)
    end

    -- ---------- 下落的道具徽章 ----------
    for _, it in ipairs(self.items) do
        self:drawPowerIcon(bb, math.floor(it.x - ITEM_SIZE / 2),
                               math.floor(it.y - ITEM_SIZE / 2), it.id, ITEM_SIZE)
    end

    -- ---------- 球（可能有多颗） ----------
    if self.state ~= STATE_GAMEOVER then
        for _, b in ipairs(self.balls) do
            local br = b.r or BALL_R
            -- 白色描边：球是纯黑的，撞进纯黑砖/深灰砖里会看不清。
            -- 先画一圈白环再画黑球，白底上完全看不出来(白环融进背景)，
            -- 在任何深色砖上都能把球"抠"出来
            bb:paintCircle(math.floor(b.x), math.floor(b.y), br + 2, Blitbuffer.COLOR_WHITE)
            if b.px ~= b.x or b.py ~= b.y then
                -- 拖尾短线：让"跳格"看起来是连续运动
                self:paintLine(bb, b.px, b.py, b.x, b.y, 2, Blitbuffer.COLOR_BLACK)
            end
            bb:paintCircle(math.floor(b.x), math.floor(b.y), br, Blitbuffer.COLOR_BLACK)
            if self.effects.pierce then
                -- 穿透状态：球心点一个白点，一眼能看出"球会穿砖"
                bb:paintCircle(math.floor(b.x), math.floor(b.y),
                               math.max(2, br - 3), Blitbuffer.COLOR_WHITE)
            end
        end
    end

    -- ---------- 激光子弹 ----------
    for _, bu in ipairs(self.bullets) do
        local bx = math.floor(bu.x)
        local by = math.floor(bu.y)
        -- 同样先铺白边，深色砖上才看得见
        bb:paintRect(bx - 2, by - 7, 5, 15, Blitbuffer.COLOR_WHITE)
        bb:paintRect(bx - 1, by - 6, 3, 13, Blitbuffer.COLOR_BLACK)
    end

    -- ---------- 底栏 ----------
    local by0 = H - BOTBAR_H
    bb:paintRect(0, by0, W, BOTBAR_H, Blitbuffer.COLOR_WHITE)
    bb:paintRect(0, by0, W, 1, Blitbuffer.COLOR_BLACK)

    local cell_w = math.floor((W - 20) / 5)
    local cells = {
        { label = "分数", value = tostring(self.score) },
        { label = "最高", value = tostring(math.max(self.score, self.hiscore)) },
        { label = "生命", value = nil },
        { label = "关卡", value = tostring(self.level) },
        { label = "速度", value = tostring(math.floor(self:currentSpeed())) },
    }
    for i, cell in ipairs(cells) do
        local cx = 10 + (i - 1) * cell_w
        RenderText:renderUtf8Text(bb, cx + 2, by0 + 15, self.font_mini, cell.label, false, false, Blitbuffer.COLOR_GRAY_5)
        if cell.value then
            RenderText:renderUtf8Text(bb, cx + 2, by0 + 40, self.font_num, cell.value, false, true, Blitbuffer.COLOR_BLACK)
        else
            for k = 1, MAX_LIVES_CAP do
                local lx = cx + 8 + (k - 1) * 16
                if k <= self.lives then
                    bb:paintCircle(lx, by0 + 32, 6, Blitbuffer.COLOR_BLACK)
                else
                    bb:paintCircle(lx, by0 + 32, 6, Blitbuffer.COLOR_GRAY_7)
                end
            end
        end
    end

    -- ---------- 道具效果条 ----------
    -- 生效中的限时道具（图标 + 剩余秒数），刚接住的道具给一条短提示
    local ex, ey = 12, by0 + 48
    local slot = 0
    for _, pu in ipairs(POWERUPS) do
        local expiry = self.effects[pu.id]
        if expiry and slot < MAX_FX_SLOTS then
            slot = slot + 1
            self:drawPowerIcon(bb, ex, ey, pu.id, 24)
            local left = math.max(0, math.ceil((expiry - self.tick_count) / 10))
            RenderText:renderUtf8Text(bb, ex + 28, ey + 17, self.font_mini, tostring(left) .. "s",
                                      false, false, Blitbuffer.COLOR_GRAY_5)
            ex = ex + 54
        end
    end
    if self.toast then
        -- 提示行总是要显示：槽位满了也不能把"刚接到什么道具"这条信息吞掉
        self:drawPowerIcon(bb, ex, ey, self.toast.id, 24)
        RenderText:renderUtf8Text(bb, ex + 28, ey + 17, self.font_mini, self.toast.name,
                                  false, false, Blitbuffer.COLOR_BLACK)
    end
    if slot == 0 and not self.toast then
        local hint = "拖动移板 · 点砖阵发球 · 双击发球/暂停"
        if self.caught_ball then hint = "轻触屏幕释放被吸附的球" end
        RenderText:renderUtf8Text(bb, ex, ey + 17, self.font_small, hint, false, false, Blitbuffer.COLOR_GRAY_5)
    end

    -- ---------- 状态浮层 ----------
    local cx = math.floor((W - 260) / 2)
    if self.state == STATE_PAUSED then
        self:drawOverlay(bb, cx, 300, 260, 100, "已暂停", "轻触屏幕或双击继续")
    elseif self.state == STATE_GAMEOVER then
        self:drawOverlay(bb, cx, 290, 260, 120, "游戏结束", "得分 " .. self.score .. " · 轻触重开")
    elseif self.state == STATE_LEVELCLEAR then
        -- 提前告诉玩家下一关是什么形状（next_shape 是过关时就抽好的）
        local sub = "进入第 " .. (self.level + 1) .. " 关"
        if self.next_shape then
            sub = sub .. " · " .. self.next_shape.name
        end
        self:drawOverlay(bb, cx, 300, 260, 100, "过关！", sub)
    end
end

-- ======================= 手势与触控 =======================
function BreakoutDialog:onTap(arg, ges)
    ges = ges or arg
    if not ges or not ges.pos then return true end
    local x, y = ges.pos.x, ges.pos.y
    -- 计时用单调时钟的 fts 编码：fts 是线性定点值，差值可直接与 Time.s() 比较。
    -- 注意不能用 ges.time(事件时间戳) 与 Time.s() 混比，两者时钟源可能不同；
    -- 也不能用 os.clock()，设备上它走的是 CPU 时间，几乎不走。
    local now = Time.now()
    -- 抬手产生的 tap 同样意味着一次拖动结束，清掉锚点
    self:resetPanAnchor()

    -- 1) 顶栏按钮
    if y >= 2 and y <= TOPBAR_H then
        for _, b in ipairs(BTN_DEF) do
            if x >= b.x and x <= b.x + b.w then
                self:doButton(b.action)
                return true
            end
        end
        return true
    end

    -- 2) 底栏区域不做交互
    if y >= self.H - BOTBAR_H then return true end

    -- 3) 游戏结束：轻触重开
    if self.state == STATE_GAMEOVER then
        self:startNewGame(true)
        return true
    end

    -- 4) 暂停中：轻触继续 (恢复到暂停前的状态)
    if self.state == STATE_PAUSED then
        self:togglePause()
        return true
    end

    -- 5) 吸盘：轻触释放被吸附的球
    if self.caught_ball then
        self.last_tap_time = 0 -- 释放后不参与双击判定
        self:releaseCaught()
        self:refreshAll()
        return true
    end

    -- 6) 双击判定 (手动实现，60~380ms 内且距离 < 90px)
    --    两次 tap 的 fts 差值与 Time.s() 同量纲，可直接比较
    if self.last_tap_time and self.last_tap_time > 0 then
        local dt = now - self.last_tap_time
        if dt >= Time.s(0.06) and dt < Time.s(0.38) then
            local dist = math.sqrt((x - self.last_tap_x) ^ 2 + (y - self.last_tap_y) ^ 2)
            if dist < 90 then
                self.last_tap_time = 0
                -- 待发球时：双击 = 直接发射弹珠（不用瞄准砖阵下方那块区域）
                if self.state == STATE_READY then
                    self:launchBall()
                    self:refreshAll()
                else
                    self:togglePause()
                end
                return true
            end
        end
    end
    self.last_tap_time = now
    self.last_tap_x = x
    self.last_tap_y = y

    -- 7) 待发球：点砖阵区发球
    if self.state == STATE_READY then
        if y < self.GRID_Y + self.GRID_H then
            self.last_tap_time = 0 -- 发球后不参与双击判定
            self:launchBall()
            self:refreshAll()
            return true
        end
    end

    -- 7) 点底部区：挡板绝对跳转（"反转"道具生效时左右镜像）
    if y > self.GRID_Y + self.GRID_H then
        self.paddle_target_x = self:clampPaddle(self:mapControlX(x))
    end

    return true
end

function BreakoutDialog:resetPanAnchor()
    self.pan_anchor = nil
    self.pan_start_x = nil
    self.pan_start_y = nil
end

function BreakoutDialog:onPan(arg, ges)
    ges = ges or arg
    if not ges then return true end

    -- 新的一次拖动 (起点变化) -> 重置锚点，保证挡板不跳位
    local sp = ges.start_pos
    if sp and (self.pan_start_x ~= sp.x or self.pan_start_y ~= sp.y) then
        self.pan_start_x = sp.x
        self.pan_start_y = sp.y
        self.pan_anchor = nil
    end

    local rel = ges.relative or { x = 0, y = 0 }
    -- "反转"道具生效时，横向位移取反：手指往右拖，挡板往左走
    local move = self.effects.flip and (-rel.x) or rel.x
    if not self.pan_anchor then
        self.pan_anchor = self.paddle_x - move
    end
    self.paddle_target_x = self:clampPaddle(self.pan_anchor + move)
    -- 玩家一动手，AI 立刻让位；玩家停手 AI_MANUAL_HOLD 秒后自动接回来
    self.ai_pause_until = Time.now() + Time.s(AI_MANUAL_HOLD)
    -- 渲染交给主循环统一刷新，避免高频重绘打爆 e-ink
    return true
end

function BreakoutDialog:onPanRelease(arg, ges)
    -- pan_release 与 swipe 两条通路都要走到这里
    self:resetPanAnchor()
    return true
end

function BreakoutDialog:togglePause()
    if self.state == STATE_PLAYING or self.state == STATE_READY then
        -- 记住暂停前的状态 (READY 表示球还停在挡板上)
        self.state_before_pause = self.state
        self.state = STATE_PAUSED
        self:saveHiscore()
    elseif self.state == STATE_PAUSED then
        self.state = self.state_before_pause or STATE_PLAYING
        self.state_before_pause = nil
    end
    self:refreshAll()
end

function BreakoutDialog:doButton(action)
    if action == "pause" then
        if self.state == STATE_READY or self.state == STATE_PLAYING or self.state == STATE_PAUSED then
            self:togglePause()
        end
    elseif action == "restart" then
        self:startNewGame(true)
    elseif action == "exit" then
        self:onClose()
    elseif action == "ai" then
        -- AI 辅助开关：切过去时立刻让玩家接管一次（别在玩家正拖挡板时突然抢走）
        self.ai_mode = not self.ai_mode
        self.ai_pause_until = 0
        if self.ai_mode then
            self.ai_pause_until = Time.now() + Time.s(0.3)
        end
        -- 只刷顶栏那一小块，别整屏重刷
        self:markRect(BTN_DEF[1].x - 2, 2, BTN_DEF[4].x + BTN_DEF[4].w + 2, TOPBAR_H, "topbar")
    end
end

function BreakoutDialog:onClose()
    self.is_closed = true
    self:stopTimer()
    self:saveHiscore()
    UIManager:close(self)
end

return BreakoutDialog
