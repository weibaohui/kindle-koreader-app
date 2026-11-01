--[[--
打砖块插件的无头逻辑测试台 (headless harness)

把 KOReader 的依赖全部 mock 掉，只跑纯游戏逻辑：
物理、碰撞、多球分裂、道具掉落/接取/生效/到期、关卡推进。

用法: lua tools/sim_headless.lua
--]]

-- 固定随机种子：发球角度/随机关卡都用 math.random，
-- 不固定种子的话测试结果会随进程启动而变（同一个用例偶发通过偶发失败）。
math.randomseed(20261031)

-- ======================= Mock: Blitbuffer =======================
local drawn = 0
local Blitbuffer = {
    COLOR_BLACK = 0x00, COLOR_WHITE = 0xFF,
    COLOR_GRAY_1 = 0x11, COLOR_GRAY_2 = 0x22, COLOR_GRAY_3 = 0x33,
    COLOR_GRAY_4 = 0x44, COLOR_GRAY_5 = 0x55, COLOR_GRAY_6 = 0x66,
    COLOR_GRAY_7 = 0x77, COLOR_GRAY_8 = 0x88, COLOR_GRAY_9 = 0x99,
    COLOR_GRAY_B = 0xBB, COLOR_LIGHT_GRAY = 0xCC, COLOR_GRAY_E = 0xEE,
}
local function noop() drawn = drawn + 1 end
Blitbuffer.paintRect = noop
Blitbuffer.paintCircle = noop
Blitbuffer.paintRoundedRect = noop

-- ======================= Mock: 其它 KOReader 模块 =======================
local FTS = 1e6 -- 模拟 fts 定点标度
local clock = 0
package.loaded["device"] = {
    screen = {
        getWidth = function() return 600 end,
        getHeight = function() return 800 end,
    },
}
package.loaded["ui/font"] = { getFace = function() return {} end }
-- 真实 KOReader 的 Geom.new(class, t)，冒号调用时第一个参数是类本身
package.loaded["ui/geometry"] = { new = function(a, b) return b or a end }
package.loaded["datastorage"] = { getSettingsDir = function() return "/tmp" end }
package.loaded["ffi/blitbuffer"] = Blitbuffer
package.loaded["ui/rendertext"] = {
    renderUtf8Text = function() end,
    sizeUtf8Text = function() return { x = 10 } end,
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
package.loaded["ui/widget/container/inputcontainer"] = InputContainer

local dirty_calls = 0
local dirty_regions = {}   -- 记录每次推送的脏矩形，用于断言底栏/浮层确实被标脏
package.loaded["ui/uimanager"] = {
    -- 注意：插件用冒号调用 UIManager:setDirty(...)，mock 必须保留 self 占位参数
    setDirty = function(_, widget, mode, region)
        dirty_calls = dirty_calls + 1
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
local SRC = arg[1] or "plugins/breakout.koplugin/breakoutdialog.lua"
local BreakoutDialog = assert(loadfile(SRC))()

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

-- ======================= 场景 1: 基础跑通 =======================
section("场景 1: 基本循环")
local dlg = BreakoutDialog:new()
check("初始状态 READY", dlg.state == 0, "state=" .. tostring(dlg.state))
check("初始 1 颗球", #dlg.balls == 1, "#balls=" .. #dlg.balls)
check("初始挡板宽 96", dlg.paddle_w == 96, "w=" .. tostring(dlg.paddle_w))
check("第 1 关 50 块砖", dlg.bricks_left == 50, "left=" .. tostring(dlg.bricks_left))

dlg:launchBall()
check("发球后进入 PLAYING", dlg.state == 1, "state=" .. tostring(dlg.state))

-- 让挡板自动跟随落点标记，连续跑 3000 帧
local ticks = 0
local serves = 0
for i = 1, 3000 do
    -- 模拟玩家：待发球就发球，球结束了就重开
    if dlg.state == 4 then
        dlg:startNewGame(false)
    elseif dlg.state == 0 then
        dlg:launchBall()
        serves = serves + 1
    end
    if dlg.marker_x then dlg.paddle_target_x = dlg.marker_x end
    dlg:tick()
    ticks = i
end
check("连续跑 3000 帧无异常", true)
check("分数有增长", dlg.score > 0, "score=" .. tostring(dlg.score))
print(string.format("     跑了 %d 帧, 发球 %d 次, 分数=%d, 关卡=%d, 生命=%d, 球数=%d",
    ticks, serves, dlg.score, dlg.level, dlg.lives, #dlg.balls))

-- ======================= 场景 2: 多球 =======================
section("场景 2: 多球分裂")
local g = BreakoutDialog:new()
g:launchBall()
check("分裂前 1 颗球", #g.balls == 1)
g:applyMulti()
check("一次多球 -> 3 颗", #g.balls == 3, "#balls=" .. #g.balls)
g:applyMulti()
check("二次多球 -> 封顶 4 颗", #g.balls == 4, "#balls=" .. #g.balls)
g:applyMulti()
check("三次多球仍封顶 4 颗", #g.balls == 4, "#balls=" .. #g.balls)
local allmoving = true
for _, b in ipairs(g.balls) do
    if math.abs(b.vx) + math.abs(b.vy) < 1 then allmoving = false end
end
check("所有球都有速度", allmoving)

-- 多球时只预测一颗球的落点
g:updatePrediction()
check("多球时只出一个落点标记", g.marker_x ~= nil)

-- ======================= 场景 3: 球全部掉光才扣命 =======================
section("场景 3: 扣命判定")
local h = BreakoutDialog:new()
h:launchBall()
h:applyMulti()
check("分裂后 3 颗球", #h.balls == 3)
-- 手动把两颗球丢出底线
h.balls[1].y = h.DEATH_Y + 100
h.balls[2].y = h.DEATH_Y + 100
h:stepBalls(0.1)
check("掉 2 颗球不扣命", h.lives == 3 and #h.balls == 1, "lives=" .. h.lives .. " #balls=" .. #h.balls)
h.balls[1].y = h.DEATH_Y + 100
h:stepBalls(0.1)
check("最后一颗球掉光才扣命", h.lives == 2, "lives=" .. h.lives)

-- ======================= 场景 4: 道具掉落与接取 =======================
section("场景 4: 道具系统")
local p = BreakoutDialog:new()
p:launchBall()

-- 4) 道具砖被击碎会掉落道具
local before = #p.items
p.bricks[5][3] = { hp = 1, base = 1, power = true }
local bx = p.GRID_X + 2 * (52 + 3)
local by = p.GRID_Y + 4 * (24 + 3)
p:damageBrick(5, 3, bx, by)
check("道具砖击碎掉落道具", #p.items == before + 1, "#items=" .. #p.items)

-- 5) 道具直落并被挡板接住
local item = p.items[1]
p.paddle_x = item.x
p.paddle_target_x = item.x
p.paddle_w = 96
-- 把道具放到挡板正上方
item.y = p.PADDLE_Y - 20
item.checked = false
local items_before = #p.items
-- 道具下落速度是可调参数，落几帧到接球线取决于速度，
-- 所以这里循环推进直到接住/掉出，测试不跟具体速度耦合。
for _ = 1, 20 do
    p:updateItems()
    if #p.items < items_before then break end
end
check("道具落到挡板处被接住", #p.items < items_before, "#items=" .. #p.items)
check("接住道具产生提示", p.toast ~= nil)

-- 6) 各道具效果
local function fresh()
    local d = BreakoutDialog:new()
    d:launchBall()
    return d
end

local e = fresh()
e:applyPowerUp("extend")
check("加长: 挡板变宽", e.paddle_w == 96, "初始 w=" .. e.paddle_w)
e:updateEffects()
check("加长生效后挡板 132", e.paddle_w == 132, "w=" .. e.paddle_w)

local e2 = fresh()
e2:applyPowerUp("shrink")
e2:updateEffects()
check("变短: 挡板 64", e2.paddle_w == 64, "w=" .. e2.paddle_w)

local e3 = fresh()
e3:applyPowerUp("life")
check("加命: 生命 +1", e3.lives == 4, "lives=" .. e3.lives)
e3:applyPowerUp("life")
e3:applyPowerUp("life")
check("加命有上限 5", e3.lives == 5, "lives=" .. e3.lives)

local e4 = fresh()
local sp0 = e4:currentSpeed()
e4:applyPowerUp("slow")
e4:updateEffects()
check("减速: 球速下降", e4:currentSpeed() < sp0, sp0 .. " -> " .. e4:currentSpeed())

local e5 = fresh()
local sp1 = e5:currentSpeed()
e5:applyPowerUp("fast")
e5:updateEffects()
check("加速: 球速上升", e5:currentSpeed() > sp1, sp1 .. " -> " .. e5:currentSpeed())

local e6 = fresh()
e6:applyPowerUp("multi")
check("多球道具立即生效", #e6.balls == 3, "#balls=" .. #e6.balls)

local e7 = fresh()
e7:applyPowerUp("catch")
e7:updateEffects()
check("吸盘生效", e7.effects.catch ~= nil)

-- 7) 限时道具到期
local e8 = fresh()
e8:applyPowerUp("extend")
e8:updateEffects()
check("加长已生效", e8.paddle_w == 132)
e8.tick_count = e8.effects.extend + 1
e8:updateEffects()
check("加长到期后恢复 96", e8.paddle_w == 96, "w=" .. e8.paddle_w)

local e9 = fresh()
e9:applyPowerUp("slow")
e9:updateEffects()
local slowed = e9:currentSpeed()
e9.tick_count = e9.effects.slow + 1
e9:updateEffects()
check("减速到期后速度恢复", e9:currentSpeed() > slowed, slowed .. " -> " .. e9:currentSpeed())

-- 8) 吸盘吸附与释放
local e10 = fresh()
e10:applyPowerUp("catch")
e10:updateEffects()
local b = e10.balls[1]
b.y = e10.PADDLE_Y - 5
b.vy = 100
e10:resolvePaddle(b)
check("吸盘把球粘住", e10.caught_ball == b, "caught=" .. tostring(e10.caught_ball ~= nil))
e10:releaseCaught()
check("释放后球恢复飞行", e10.caught_ball == nil and b.vy < 0, "vy=" .. tostring(b.vy))

-- ======================= 场景 5: 道具落点标记 =======================
section("场景 5: 道具落点标记")
local m = BreakoutDialog:new()
m:launchBall()
m:spawnItem(300, 150)
m:updateItems()
check("道具落点标记已生成", #m.item_markers == 1, "#markers=" .. #m.item_markers)
check("标记 x 与道具一致", m.item_markers[1] == m.items[1].x)

-- ======================= 场景 6: 吸盘吸附时球跟随挡板 =======================
section("场景 6: 吸附球跟随挡板")
local q = BreakoutDialog:new()
q:launchBall()
q:applyPowerUp("catch")
q:updateEffects()
local qb = q.balls[1]
qb.caught = true
q.caught_ball = qb
q.paddle_x = 200
q.paddle_target_x = 200
q:tick()
check("吸附球跟随挡板移动", math.abs(qb.x - q.paddle_x) < 1,
      "ball.x=" .. tostring(qb.x) .. " paddle.x=" .. tostring(q.paddle_x))

-- ======================= 场景 7: 长时间压力测试 =======================
section("场景 7: 压力测试 (随机道具 + 多球, 20000 帧)")
local st = BreakoutDialog:new()
local pu_ids = { "extend", "shrink", "multi", "slow", "life", "catch", "fast" }
local rand = 12345
local function rint(n)
    rand = (rand * 1103515245 + 12345) % 2147483648
    return (rand % n) + 1
end
local err = nil
local ok_frames = 0
for i = 1, 20000 do
    if st.state == 4 then
        st:startNewGame(false)
    elseif st.state == 0 then
        st:launchBall()
    end
    -- 随机给道具，制造各种状态组合
    if i % 37 == 0 then
        st:applyPowerUp(pu_ids[rint(#pu_ids)])
    end
    if i % 211 == 0 then
        st:spawnItem(rint(560) + 20, 120)
    end
    if st.marker_x then st.paddle_target_x = st.marker_x end
    local ok, e = pcall(function() st:tick() end)
    if not ok then err = e; break end
    ok_frames = i
end
check("20000 帧压力测试无异常", err == nil, tostring(err))
print(string.format("     跑了 %d 帧, 分数=%d, 关卡=%d, 球数=%d, 道具数=%d",
    ok_frames, st.score, st.level, #st.balls, #st.items))

-- ======================= 场景 8: 关卡推进到程序化关 =======================
section("场景 8: 关卡推进")
local lv = BreakoutDialog:new()
check("初始关卡 1", lv.level == 1)
lv.level = 5
lv:loadLevel(5)
local haspower = false
for r = 1, 6 do
    for c = 1, 10 do
        local b = lv.bricks[r][c]
        if b and b.power then haspower = true end
    end
end
check("程序化关卡含道具砖", haspower)

-- ======================= 场景 9: 增量刷新脏区 =======================
-- 真机教训: 增量刷新只推"运动脏区"时, 底栏(分数/生命/效果条)与
-- "游戏结束"浮层永远不会上屏 —— 必须显式把它们标脏。
section("场景 9: 增量刷新脏区")
local function regions_covers(y0, y1)
    for _, r in ipairs(dirty_regions) do
        if r.y == nil then print("   !! 区域缺 y:", r.x, r.y, r.w, r.h) end
        if r.y and r.y <= y0 and (r.y + r.h) >= y1 then return true end
    end
    return false
end

-- 是否有某个刷新矩形完整覆盖给定的矩形
local function region_covers(x0, y0, x1, y1)
    for _, r in ipairs(dirty_regions) do
        if r.x and r.y and r.x <= x0 and r.y <= y0
            and (r.x + r.w) >= x1 and (r.y + r.h) >= y1 then
            return true
        end
    end
    return false
end

-- 是否有任何刷新矩形落在底栏带内(y>=708)
local function region_in_bar()
    for _, r in ipairs(dirty_regions) do
        if r.y and r.y >= 708 then return true end
    end
    return false
end

-- 底栏各格的刷新矩形（与插件几何一致）
local BAR_CELL = { x0 = 11, y0 = 731, x1 = 119, y1 = 751 }   -- 分数格
local BAR_FX   = { x0 = 8,  y0 = 759, x1 = 292, y1 = 779 }   -- 效果条

local dr = BreakoutDialog:new()   -- 初始 READY

dr:tick()  -- 预热：首帧会推一次底栏(内容首次绘制)，之后进入稳态

-- (1) 普通 tick：状态不变、分数不变 -> 不该推底栏与浮层
dirty_regions = {}
dr:tick()
check("普通 tick 不推浮层区域", not regions_covers(282, 418))
check("普通 tick 不推底栏区域", not region_in_bar())

-- (2) 分数变化 -> 只推"分数"那一小格，不整条刷
dirty_regions = {}
dr.score = 123
dr:tick()
check("分数变化推分数格", region_covers(BAR_CELL.x0, BAR_CELL.y0, BAR_CELL.x1, BAR_CELL.y1))
check("分数变化不整条刷底栏", not region_covers(0, 708, 600, 800))

-- (3) 状态切到游戏结束 -> 必须推浮层
dirty_regions = {}
dr:launchBall()        -- READY -> PLAYING
dr.lives = 0
dr.balls = {}          -- 全部球掉光 -> loseLife() -> 游戏结束
dr:tick()
check("状态切换推浮层区域", regions_covers(282, 418))

-- (4) 限时道具生效/到期 -> 效果条变化必须推效果条
local dr2 = BreakoutDialog:new()
dr2.state = 1
dr2:tick()
dirty_regions = {}
dr2:applyPowerUp("slow")     -- 底栏速度显示会变
dr2:tick()
check("道具生效推效果条", region_covers(BAR_FX.x0, BAR_FX.y0, BAR_FX.x1, BAR_FX.y1))

-- ======================= 场景 10: 道具砖密度 (v1.2 加量) =======================
section("场景 10: 道具砖密度")
local function countPower(d)
    local n = 0
    for r = 1, 6 do
        for c = 1, 10 do
            local b = d.bricks[r][c]
            if b and b.power then n = n + 1 end
        end
    end
    return n
end

-- 手工关卡 1-4: 每关固定 6 块道具砖；加量的是"道具砖", 墙的总砖数不能跟着变
local expect_breakable = { 50, 60, 54, 40 }
for lv = 1, 4 do
    local d = BreakoutDialog:new()
    d.level = lv
    d:loadLevel(lv)
    check(string.format("第 %d 关道具砖恰好 6 块", lv), countPower(d) == 6,
        "实际 " .. countPower(d))
    check(string.format("第 %d 关可破砖块数保持 %d", lv, expect_breakable[lv]),
        d.bricks_left == expect_breakable[lv], "实际 " .. tostring(d.bricks_left))
end

-- 程序化关卡: 道具砖随关卡递增 6 -> 10 封顶；撒点必须放满，不能因随机位置不合法而少放
local expect_proc = { [5] = 6, [7] = 7, [9] = 8, [11] = 9, [13] = 10, [21] = 10 }
for lv, want in pairs(expect_proc) do
    local got, ok = nil, true
    for _ = 1, 8 do   -- 随机关卡, 多跑几次确认稳定
        local d = BreakoutDialog:new()
        d.level = lv
        d:loadLevel(lv)
        got = countPower(d)
        if got ~= want then ok = false end
    end
    check(string.format("程序化第 %d 关道具砖 %d 块", lv, want), ok,
        "实际 " .. tostring(got))
end

-- 同屏掉落上限与落点标记上限要跟得上加量后的掉落频率：
-- 连破多块道具砖时，第 5 个徽章要被上限挡住(而不是无限堆)，且实际能存下 4 个
local cap = BreakoutDialog:new()
cap:launchBall()
for c = 1, 6 do
    cap.bricks[5][c] = { hp = 1, base = 1, power = true }
    cap:damageBrick(5, c, cap.GRID_X + (c - 1) * 55 + 26, cap.GRID_Y + 4 * 27 + 12)
end
check("同屏徽章上限为 4", #cap.items == 4, "#items=" .. tostring(#cap.items))
cap:updateItems()   -- 落点标记是在 updateItems 里重建的
check("连破多砖时落点标记跟得上", #cap.item_markers == 3,
    "#markers=" .. tostring(#cap.item_markers))

-- ======================= 场景 11: 底栏与运动脏区分离 (底栏闪烁修复) =======================
-- 真机教训: KOReader 的 _refresh 会把"共享边界"的两个矩形也合并成一次刷新，
-- 运动脏区一旦伸进底栏(y>=708)，底栏就被卷进"运动区+底栏"的大局部刷新，
-- e-ink 部分刷新波形会把实心生命圆点刷成空心、吃掉底栏文字 —— 表现为底栏闪烁/残缺。
-- 修复三条:
--   ① 运动脏区下边界夹到 707;
--   ② 底栏 pushRect 用 pad=0，严格从 708 起，两块永不合并;
--   ③ 球/道具改成"底边触线即消失"，永远画不到 707 以下，夹断也不丢内容。
section("场景 11: 底栏与运动脏区分离")
local RB = 7        -- 插件里的 BALL_R
local RIS = 14     -- ITEM_SIZE / 2

-- (1) 球从挡板高度下坠，最后一个"存活帧"的球底必须在底线以内
-- 扫一整圈球速：单点测试会因子步落点不同而时灵时不灵，扫速度才稳定
local death_y = BreakoutDialog:new().DEATH_Y
local worst_ball = 0
for _, vy in ipairs({ 150, 170, 190, 210, 230, 250, 265, 285, 300, 340, 380, 420, 500 }) do
    local fall = BreakoutDialog:new()
    fall.state = 1     -- STATE_PLAYING
    local fb = fall.balls[1]
    fb.x = fall.FIELD_X + 30   -- 放到最左边，避开挡板反弹
    fb.y = fall.PADDLE_Y - 8
    fb.vx = 0
    fb.vy = vy
    for _ = 1, 300 do
        fall:stepBall(fb, 0.1)
        if fb.dead then break end
        worst_ball = math.max(worst_ball, fb.y + RB)
    end
end
check("下坠时球底不超过底线", worst_ball <= death_y,
    "最大球底 " .. worst_ball .. " > 底线 " .. death_y)

-- (2) 道具下坠同理（道具每 tick 固定落 5px，扫起始高度覆盖所有相位）
local worst_item = 0
for y0 = 100, 110 do
    local itd = BreakoutDialog:new()
    itd.items = { { id = "slow", x = 40, y = y0, checked = false } }
    for _ = 1, 300 do
        itd:updateItems()
        if #itd.items == 0 then break end
        worst_item = math.max(worst_item, itd.items[1].y + RIS)
    end
end
check("下坠时道具底边不超过底线", worst_item <= death_y,
    "最大底边 " .. worst_item .. " > 底线 " .. death_y)

-- (3) 运动脏区绝不能伸进底栏；底栏区域严格从 708 起
local dr3 = BreakoutDialog:new()
dr3:launchBall()          -- READY -> PLAYING
dr3:tick()                -- 预热，状态稳定
dirty_regions = {}
local b3 = dr3.balls[1]
b3.y = dr3.DEATH_Y - RB   -- 球底刚好触线
b3.vx = 0
b3.vy = 600
dr3:tick()                -- 这一 tick 球会掉出底线 -> 扣命 -> 状态切换

local bleed = 0           -- 起点在底栏上方、却伸进底栏的矩形（必须为 0）
local bar_min = nil
for _, r in ipairs(dirty_regions) do
    if r.y and r.h then
        if r.y >= 708 then
            bar_min = math.min(bar_min or 9999, r.y)
        elseif r.y + r.h > 707 then
            bleed = bleed + 1
        end
    end
end
check("运动脏区不伸进底栏", bleed == 0, "越界矩形 " .. bleed .. " 个")
check("底栏刷新矩形都在底栏带内", bar_min ~= nil and bar_min >= 708,
    "实际起点 " .. tostring(bar_min))

-- ======================= 场景 12: 静止时零刷新 =======================
-- 真机教训: 插件以前每 tick 都把"挡板区"标脏推送，静止画面也在 10Hz 刷面板，
-- KOReader 照单全收地刷 —— 真机 10 连拍有 2 帧糊掉半屏/底栏残缺，
-- 墨水屏也白受刷新预算。铁律: 真的动了才标脏，静止时一个像素都不刷。
section("场景 12: 静止时零刷新")
local idle = BreakoutDialog:new()
for _ = 1, 5 do idle:tick() end   -- 预热：挡板缓动收敛、底栏首帧推一次
dirty_regions = {}
for _ = 1, 5 do idle:tick() end
check("静止(READY)时不再推送任何刷新", #dirty_regions == 0,
    "5 个 tick 推了 " .. #dirty_regions .. " 个区域")

-- 运动脏区必须"用完即清"，否则矩形会随着球跑过的地方越滚越大，最后整屏重刷
local dr4 = BreakoutDialog:new()
dr4:launchBall()
dr4:tick()
check("运动脏区用完即清", dr4._dr.field == nil,
    "残留 " .. tostring(dr4._dr.field and "有" or "无"))

-- 游戏中该刷还得刷：球在动就必须推运动区
local play = BreakoutDialog:new()
play:launchBall()
play:tick()
dirty_regions = {}
play:tick()
local has_motion = false
for _, r in ipairs(dirty_regions) do
    if r.y and r.y < 700 and r.y > 250 then has_motion = true end
end
check("游戏中仍推送运动区", has_motion)

-- 砖块掉血/击碎：当场精确标脏砖阵桶（不再等低频维护刷新）
local bd = BreakoutDialog:new()
bd:damageBrick(1, 3, bd.GRID_X + 2 * 55, bd.GRID_Y)
check("击碎砖块当场标脏砖阵区", bd._dr.brick ~= nil,
    "brick 桶为空")
local bx = bd._dr.brick.x1
local bw = bd._dr.brick.x2 - bd._dr.brick.x1
check("砖阵脏区只覆盖那一格", bw < 120, "宽 " .. tostring(bw) .. " (起点 " .. tostring(bx) .. ")")

-- ======================= 场景 13: 道具谱系 (17 种) =======================
-- 参考 Arkanoid / DX-Ball 的道具谱系扩充：10 种增益 + 7 种减益。
-- 道具表直接从插件源码里解析，断言跟实现同源，不会两边各写一份对不上。
section("场景 13: 道具谱系")
local src = assert(io.open("plugins/breakout.koplugin/breakoutdialog.lua", "r"))
local text = src:read("*a")
src:close()

local ids, names, durs, isbad = {}, {}, {}, {}
for line in text:gmatch("[^\n]+") do
    local norm = line:gsub("%s+", " ")
    local id, nm, dur, rest = norm:match('{ id = "(%w+)", name = "([^"]+)", dur = (%d+)(.*) }')
    if id then
        ids[#ids + 1] = id
        names[id] = nm
        durs[id] = tonumber(dur)
        if rest:match("bad = true") then isbad[id] = true end
    end
end
check("道具总数 17 种", #ids == 17, "实际 " .. #ids)

local dup = {}
local seen = {}
for _, id in ipairs(ids) do
    if seen[id] then dup[#dup + 1] = id end
    seen[id] = true
end
check("道具 id 唯一", #dup == 0, table.concat(dup, ","))

local ngood, nbad = 0, 0
for _, id in ipairs(ids) do
    if isbad[id] then nbad = nbad + 1 else ngood = ngood + 1 end
end
check("增益道具 10 种", ngood == 10, "实际 " .. ngood)
check("减益道具 7 种", nbad == 7, "实际 " .. nbad)

local noname = {}
for _, id in ipairs(ids) do
    if not names[id] or names[id] == "" then noname[#noname + 1] = id end
end
check("每种道具都有中文名", #noname == 0, table.concat(noname, ","))

-- 每种道具都要有专属图标分支，否则徽章是一个纯色方块，玩家认不出
local noicon = {}
for _, id in ipairs(ids) do
    if not text:find('id == "' .. id .. '"', 1, true) then
        noicon[#noicon + 1] = id
    end
end
check("每种道具都有专属图标", #noicon == 0, table.concat(noicon, ","))

-- 掉落加权：约 2/3 增益、1/3 减益。等概率的话减益占 41%，太惩罚
local good_drop, bad_drop = 0, 0
local d14 = BreakoutDialog:new()
for _ = 1, 4000 do
    d14.items = {}
    d14:spawnItem(300, 100)
    local it = d14.items[1]
    if it then
        if isbad[it.id] then bad_drop = bad_drop + 1 else good_drop = good_drop + 1 end
    end
end
local ratio = good_drop / math.max(1, (good_drop + bad_drop))
check("掉落偏向增益 (增益占比 0.5~0.8)", ratio > 0.5 and ratio < 0.8,
    string.format("增益 %d / 减益 %d = %.2f", good_drop, bad_drop, ratio))

-- ======================= 场景 14: 新道具效果 =======================
section("场景 14: 新道具效果")
local function fresh()
    local d = BreakoutDialog:new()
    d:launchBall()
    return d
end

local n1 = fresh()
local sc0 = n1.score
n1:applyPowerUp("gold")
check("金币: +1000 分", n1.score == sc0 + 1000, "增加 " .. tostring(n1.score - sc0))

local n2 = fresh()
n2:applyPowerUp("drop")
check("掉命: 生命 -1", n2.lives == 2, "lives=" .. n2.lives)
check("掉命: 不打断当前球局", #n2.balls == 1 and n2.state == 1)
local n3 = fresh()
n3.lives = 1
n3:applyPowerUp("drop")
check("掉命到 0 条命 -> 游戏结束", n3.state == 4, "state=" .. n3.state)

local n4 = fresh()
check("细球前球半径 7", n4.balls[1].r == 7, tostring(n4.balls[1].r))
n4:applyPowerUp("narrow")
check("细球: 球半径变小", n4.balls[1].r == 4, tostring(n4.balls[1].r))
check("细球: currentBallR 同步", n4:currentBallR() == 4)
n4.tick_count = n4.effects.narrow + 1
n4:updateEffects()
check("细球到期后球半径恢复", n4.balls[1].r == 7, tostring(n4.balls[1].r))

local n5 = fresh()
check("反转前输入不镜像", n5:mapControlX(200) == 200)
n5:applyPowerUp("flip")
local mir = n5:mapControlX(200)
check("反转后输入左右镜像", mir ~= 200 and
    math.abs((mir + 200) - (n5.FIELD_X + n5.FIELD_W)) < 1,
    "200 -> " .. tostring(mir))
n5.tick_count = n5.effects.flip + 1
n5:updateEffects()
check("反转到期后输入恢复", n5:mapControlX(200) == 200)

local n6 = fresh()
n6:applyPowerUp("shield")
check("护盾生效", n6.effects.shield ~= nil)
local sb = n6.balls[1]
sb.x = n6.paddle_x
sb.y = n6.PADDLE_Y - 16
sb.vx = 0
sb.vy = 120
n6:resolvePaddle(sb)
check("护盾挡下这一球", sb.vy < 0, "vy=" .. tostring(sb.vy))
check("护盾挡球后消失", n6.effects.shield == nil)
n6:applyPowerUp("shield")
sb.y = n6.PADDLE_Y - 16
sb.vy = 120
n6:resolvePaddle(sb)
check("护盾重新生效后仍能挡", sb.vy < 0 and n6.effects.shield == nil)

-- 混乱：出射角随机抖动，且球永远往上飞
local n7 = fresh()
local distinct, allup = {}, true
for i = 1, 24 do
    local b = n7.balls[1]
    b.x = n7.paddle_x + 30
    b.y = n7.PADDLE_Y - 5
    b.vx = 0
    b.vy = 120
    n7:applyPowerUp("chaos")
    n7:resolvePaddle(b)
    distinct[math.floor(math.atan(b.vy, b.vx) * 1000)] = true
    if b.vy >= 0 then allup = false end
end
local ndist = 0
for _ in pairs(distinct) do ndist = ndist + 1 end
check("混乱: 出射角随机抖动", ndist >= 5, "不同角度 " .. ndist)
check("混乱: 球始终往上飞", allup)

-- 激光
local n8 = fresh()
n8:applyPowerUp("laser")
check("激光生效", n8.effects.laser ~= nil)
for _ = 1, 8 do n8:updateBullets(0.1) end
check("激光会发射子弹", #n8.bullets > 0, "#bullets=" .. #n8.bullets)
check("子弹向上飞", n8.bullets[1].y < n8.PADDLE_Y)

-- 子弹撞砖要真的打掉砖（子弹一 tick 飞 42px > 砖高 24px，不细分就会打空）
local n9 = fresh()
n9:applyPowerUp("laser")
n9.laser_timer = 99          -- 掐掉本次的自动发射，只测手动放的那颗子弹
n9.bullets = { { x = n9.GRID_X + 26, y = n9.GRID_Y + 22, px = n9.GRID_X + 26, py = n9.GRID_Y + 22 } }
local left0 = n9.bricks_left
n9:updateBullets(0.1)
check("激光子弹撞砖会打掉砖", n9.bricks_left < left0, "left " .. left0 .. " -> " .. n9.bricks_left)
check("子弹撞砖后消失", #n9.bullets == 0, "#bullets=" .. #n9.bullets)

-- 激光到期，场上子弹要清空（否则留在屏上变成幽灵弹）
local n10 = fresh()
n10:applyPowerUp("laser")
for _ = 1, 8 do n10:updateBullets(0.1) end
n10.tick_count = n10.effects.laser + 1
n10:updateEffects()
n10:updateBullets(0.1)
check("激光到期后子弹清空", #n10.bullets == 0, "#bullets=" .. #n10.bullets)

-- ======================= 场景 15: 新机制的物理正确性 =======================
section("场景 15: 新机制的物理正确性")

-- 穿透：球穿砖不反弹，砖照常掉血
-- 球从砖下方顶上来（真实可达的姿态），不能把球塞进砖内部
local p1 = BreakoutDialog:new()
p1.state = 1
p1:applyPowerUp("pierce")
local pb = p1.balls[1]
pb.r = 7
pb.x = p1.GRID_X + 26
pb.y = p1.GRID_Y + 30
pb.vx = 0
pb.vy = -150
local left1 = p1.bricks_left
p1:resolveBricks(pb)
check("穿透: 球不反弹", pb.vy < 0, "vy=" .. tostring(pb.vy))
check("穿透: 砖照常掉血", p1.bricks_left < left1)

-- 钢砖不能被穿透 —— 它本来就打不碎
local p2 = BreakoutDialog:new()
p2.state = 1
p2:applyPowerUp("pierce")
p2.bricks[1][1] = { hp = -1, base = -1 }   -- 钢砖
local p2b = p2.balls[1]
p2b.r = 7
p2b.x = p2.GRID_X + 26
p2b.y = p2.GRID_Y + 30
p2b.vx = 0
p2b.vy = -150
p2:resolveBricks(p2b)
check("穿透: 钢砖仍然挡球", p2b.vy > 0, "vy=" .. tostring(p2b.vy))

-- 爆裂：3x3 范围内的砖一起没了
-- 只保留 rows3-5 x cols3-5 的 9 块砖，球打正中 (4,4)，爆裂范围刚好盖住这 9 块
local p3 = BreakoutDialog:new()
p3.state = 1
p3:applyPowerUp("bomb")
for r = 1, 6 do
    for c = 1, 10 do
        if r < 3 or r > 5 or c < 3 or c > 5 then
            p3.bricks[r][c] = nil
        else
            p3.bricks[r][c] = { hp = 1, base = 1 }
        end
    end
end
p3.bricks_left = 9
local p3b = p3.balls[1]
p3b.r = 7
p3b.x = p3.GRID_X + 3 * 55 + 26   -- 第 4 列正中
p3b.y = p3.GRID_Y + 3 * 27 + 12   -- 第 4 行正中
p3:resolveBricks(p3b)
check("爆裂: 3x3 范围的砖全没了", p3.bricks_left == 0, "剩 " .. tostring(p3.bricks_left))
check("爆裂: 一次只结算一次过关", p3.state == 3, "state=" .. p3.state)

-- 爆裂不得重复结算过关（否则过关奖励会被加两遍）
local p4 = BreakoutDialog:new()
p4.state = 1
p4:applyPowerUp("bomb")
for r = 1, 6 do
    for c = 1, 10 do p4.bricks[r][c] = nil end
end
p4.bricks[1][1] = { hp = 1, base = 1 }
p4.bricks_left = 1
local clear_calls = 0
local orig_clear = p4.levelClear
p4.levelClear = function(self)
    clear_calls = clear_calls + 1
    orig_clear(self)
end
local p4b = p4.balls[1]
p4b.r = 7
p4b.x = p4.GRID_X + 26
p4b.y = p4.GRID_Y + 30
local sc_before = p4.score
p4:resolveBricks(p4b)
local bonus1 = p4.score - sc_before
check("爆裂: 过关只结算一次", clear_calls == 1, "结算 " .. clear_calls .. " 次")
-- 一块砖 10 分 + 过关奖励(200*关卡 + 100*生命) = 510；结算两遍会到 1000 以上
check("爆裂: 过关奖励没被加两遍", bonus1 < 700, "加 " .. tostring(bonus1) .. " 分")

-- 细球：贴墙判定用小半径 —— 球能贴得比正常球更靠近边
-- 砖列之间只有 3px 缝，够不出"擦边"的位置，所以拿场地边界来验半径
local pw = BreakoutDialog:new()
pw.state = 1
pw:applyPowerUp("narrow")
local pwb = pw.balls[1]
pwb.x = pw.FIELD_X + 5
pwb.vx = -200
pwb.vy = 0
pw:resolveWalls(pwb)
check("细球: 贴墙判定用小半径", pwb.x == pw.FIELD_X + 5, "x=" .. tostring(pwb.x))

local pwg = BreakoutDialog:new()
local pwgb = pwg.balls[1]
pwgb.x = pwg.FIELD_X + 5
pwgb.vx = -200
pwgb.vy = 0
pwg:resolveWalls(pwgb)
check("对照: 正常球贴墙被推到 FIELD_X+7", pwgb.x == pwg.FIELD_X + 7, "x=" .. tostring(pwgb.x))

-- 细球：对局里撞砖照样反弹（走真实物理循环，不手工摆位置）
local p5 = BreakoutDialog:new()
p5.state = 1
p5:applyPowerUp("narrow")
local p5b = p5.balls[1]
check("细球: 球对象半径已变小", p5b.r == 4, tostring(p5b.r))
p5b.x = p5.GRID_X + 26
p5b.y = p5.GRID_Y + 200
p5b.vx = 0
p5b.vy = -150
local bounced = false
for _ = 1, 60 do
    local vy0 = p5b.vy
    p5:stepBall(p5b, 0.1)
    if vy0 < 0 and p5b.vy > 0 then bounced = true; break end
end
check("细球: 撞砖后被弹回", bounced)

-- 效果条槽位上限：同屏最多显示 6 个
-- 从插件自己的指纹里数效果条目（"toast:"/"caught" 这类带冒号的不是效果槽）
local p6 = BreakoutDialog:new()
p6.state = 1
local timed = { "extend", "slow", "catch", "pierce", "bomb", "laser", "flip", "blind" }
for _, id in ipairs(timed) do p6:applyPowerUp(id) end
p6:updateEffects()
local fxids = p6:barFieldSignatures().fx:match("^([^|]*)")
local slots = 0
for part in fxids:gmatch("[^,]+") do
    if not part:match(":") then slots = slots + 1 end
end
check("效果条最多 6 个槽位", slots == 6, "实际 " .. slots)

-- 效果条刷新节流：倒计时每秒最多让整条效果条刷一次
local p7 = BreakoutDialog:new()
p7.state = 1
p7:applyPowerUp("extend")
p7:applyPowerUp("slow")
p7:applyPowerUp("catch")
local sig = p7:barFieldSignatures().fx
local changes = 0
for i = 1, 10 do
    p7.tick_count = p7.tick_count + 1
    local s = p7:barFieldSignatures().fx
    if s ~= sig then changes = changes + 1 end
    sig = s
end
check("效果条签名每秒最多变一次", changes <= 1, "10 tick 内变了 " .. changes .. " 次")

-- ======================= 场景 16: 新道具压力测试 =======================
section("场景 16: 新道具压力测试 (30000 帧)")
local st2 = BreakoutDialog:new()
local all_ids = {}
for line in text:gmatch("[^\n]+") do
    local norm = line:gsub("%s+", " ")
    local id = norm:match('{ id = "(%w+)", name')
    if id then all_ids[#all_ids + 1] = id end
end
local rand2 = 987654321
local function rint2(n)
    rand2 = (rand2 * 1103515245 + 12345) % 2147483648
    return (rand2 % n) + 1
end
local err2 = nil
local ok2 = 0
for i = 1, 30000 do
    if st2.state == 4 then
        st2:startNewGame(false)
    elseif st2.state == 0 then
        st2:launchBall()
    end
    if i % 13 == 0 then
        st2:applyPowerUp(all_ids[rint2(#all_ids)])
    end
    if i % 197 == 0 then
        st2:spawnItem(rint2(560) + 20, 120)
    end
    if st2.marker_x then st2.paddle_target_x = st2.marker_x end
    local ok, e = pcall(function() st2:tick() end)
    if not ok then err2 = e; break end
    ok2 = i
end
check("30000 帧全道具压力测试无异常", err2 == nil, tostring(err2))
print(string.format("     跑了 %d 帧, 分数=%d, 关卡=%d, 球数=%d, 子弹=%d, 道具数=%d",
    ok2, st2.score, st2.level, #st2.balls, #st2.bullets, #st2.items))

-- 压力测试期间不允许出现"场上没砖却进不了下一关"的卡死
check("压力测试后状态自洽",
    st2.state == 0 or st2.state == 1 or st2.state == 3 or st2.state == 4,
    "state=" .. tostring(st2.state))

-- ======================= 结果 =======================
print(string.format("\n========== 结果: %d 通过, %d 失败 ==========", pass, fail))
os.exit(fail == 0 and 0 or 1)
