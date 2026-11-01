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
local ops = {}          -- 记录绘图指令，用于渲染层的越界/元素检查
local Blitbuffer = {
    COLOR_BLACK = 0x00, COLOR_WHITE = 0xFF,
    COLOR_GRAY_1 = 0x11, COLOR_GRAY_2 = 0x22, COLOR_GRAY_3 = 0x33,
    COLOR_GRAY_4 = 0x44, COLOR_GRAY_5 = 0x55, COLOR_GRAY_6 = 0x66,
    COLOR_GRAY_7 = 0x77, COLOR_GRAY_8 = 0x88, COLOR_GRAY_9 = 0x99,
    COLOR_GRAY_B = 0xBB, COLOR_LIGHT_GRAY = 0xCC, COLOR_GRAY_E = 0xEE,
}
-- 注意：插件里是 bb:paintRect(...) 冒号调用，第一个参数是 self
Blitbuffer.paintRect = function(_, x, y, w, h, color)
    drawn = drawn + 1
    ops[#ops + 1] = { op = "rect", x = x, y = y, w = w, h = h, c = color }
end
Blitbuffer.paintCircle = function(_, x, y, r, color, border)
    drawn = drawn + 1
    ops[#ops + 1] = { op = "circle", x = x, y = y, r = r, c = color, b = border }
end
Blitbuffer.paintRoundedRect = function(_, x, y, w, h, color, radius)
    drawn = drawn + 1
    ops[#ops + 1] = { op = "rr", x = x, y = y, w = w, h = h, c = color, r = radius }
end

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

-- 在当前关卡里找一块可破的砖，返回 r, c, bx, by（砖格左上角坐标）
-- 砖阵形状是随机的，测试不能再假定固定坐标上有砖
local function firstBrick(d)
    for r = 1, 6 do
        for c = 1, 10 do
            local b = d.bricks[r][c]
            if b and b.hp > 0 then
                return r, c, d.GRID_X + (c - 1) * 55, d.GRID_Y + (r - 1) * 27
            end
        end
    end
    return nil
end

-- 插件源码文本：道具表、关卡形状库都要从源码里解析，
-- 这样断言跟实现同源，不会两边各写一份对不上。
local text = (function()
    local f = assert(io.open(SRC, "r"))
    local t = f:read("*a")
    f:close()
    return t
end)()

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
do
local dlg = BreakoutDialog:new()
check("初始状态 READY", dlg.state == 0, "state=" .. tostring(dlg.state))
check("初始 1 颗球", #dlg.balls == 1, "#balls=" .. #dlg.balls)
check("初始挡板宽 96", dlg.paddle_w == 96, "w=" .. tostring(dlg.paddle_w))
-- 第 1 关的砖阵是随机形状，砖数取决于形状本身（28~52 之间）
check("第 1 关砖数在形状范围内", dlg.bricks_left >= 24 and dlg.bricks_left <= 52,
    "left=" .. tostring(dlg.bricks_left))

dlg:launchBall()
check("发球后进入 PLAYING", dlg.state == 1, "state=" .. tostring(dlg.state))

-- 让挡板自动跟随落点标记，连续跑 3000 帧
local ticks = 0
local serves = 0
local max_score = 0
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
    if dlg.score > max_score then max_score = dlg.score end
end
check("连续跑 3000 帧无异常", true)
-- 看"最高分"而不是"最终分"：游戏结束时 startNewGame 会把分数清零，
-- 最后一局万一一砖都没打着，最终分就是 0 —— 那是这个自动玩家水平不够
-- （改动前后实测发球次数完全一样，都是 27 次），不是游戏本身的问题。
check("分数有增长", max_score > 0, "最高分=" .. tostring(max_score))
print(string.format("     跑了 %d 帧, 发球 %d 次, 分数=%d, 关卡=%d, 生命=%d, 球数=%d",
    ticks, serves, dlg.score, dlg.level, dlg.lives, #dlg.balls))

end
-- ======================= 场景 2: 多球 =======================
section("场景 2: 多球分裂")
do
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

end
-- ======================= 场景 3: 球全部掉光才扣命 =======================
section("场景 3: 扣命判定")
do
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

end
-- ======================= 场景 4: 道具掉落与接取 =======================
section("场景 4: 道具系统")
do
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

end
-- ======================= 场景 5: 道具落点标记 =======================
section("场景 5: 道具落点标记")
do
local m = BreakoutDialog:new()
m:launchBall()
m:spawnItem(300, 150)
m:updateItems()
check("道具落点标记已生成", #m.item_markers == 1, "#markers=" .. #m.item_markers)
check("标记 x 与道具一致", m.item_markers[1] == m.items[1].x)

end
-- ======================= 场景 6: 吸盘吸附时球跟随挡板 =======================
section("场景 6: 吸附球跟随挡板")
do
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

end
-- ======================= 场景 7: 长时间压力测试 =======================
section("场景 7: 压力测试 (随机道具 + 多球, 20000 帧)")
do
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

end
-- ======================= 场景 8: 关卡推进到程序化关 =======================
section("场景 8: 关卡推进")
do
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

end
-- ======================= 场景 9: 增量刷新脏区 =======================
-- 真机教训: 增量刷新只推"运动脏区"时, 底栏(分数/生命/效果条)与
-- "游戏结束"浮层永远不会上屏 —— 必须显式把它们标脏。
section("场景 9: 增量刷新脏区")
do
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

end
-- ======================= 场景 10: 关卡形状库 =======================
-- 砖阵不再是固定的几排长方形，而是从形状库里随机挑一个形状铺出来。
section("场景 10: 关卡形状库")
do

-- 形状库直接从插件源码里解析，保证断言跟实现同源
-- 注意 id 里有下划线(letter_a)，正则要用 [%w_] 而不是 %w
local shape_blocks = {}
for id, nm, body in text:gmatch('{ id = "([%w_]+)", name = "([^"]+)", mask = {(.-)} }') do
    local mask = {}
    for s in body:gmatch('"([.#]+)"') do mask[#mask + 1] = s end
    if #mask == 6 then
        shape_blocks[#shape_blocks + 1] = { id = id, name = nm, mask = mask }
    end
end
check("形状库有 20 个形状", #shape_blocks == 20, "实际 " .. #shape_blocks)

-- 每个形状的掩码必须是 10x6
local badmask = {}
local counts = {}
for _, sh in ipairs(shape_blocks) do
    local n = 0
    for r = 1, 6 do
        local line = sh.mask[r] or ""
        if #line ~= 10 then badmask[#badmask + 1] = sh.id .. "/r" .. r end
        for c = 1, #line do
            if string.sub(line, c, c) == "#" then n = n + 1 end
        end
    end
    counts[sh.id] = n
    if n < 24 or n > 52 then badmask[#badmask + 1] ..= "" end
end
check("每个形状掩码都是 10x6", #badmask == 0, table.concat(badmask, ","))

-- 形状的砖数必须在合理区间（太少的形状一关秒过，太多的关卡太长）
local badcount = {}
for id, n in pairs(counts) do
    if n < 24 or n > 52 then badcount[#badcount + 1] = id .. "=" .. n end
end
check("每个形状砖数在 24~52 之间", #badcount == 0, table.concat(badcount, ","))

-- 剪影类形状必须左右对称（菱形/圆形/十字/笑脸等）。
-- 字母天然可以不对称（E/C/S 的开口方向本来就不对称），所以按类别排除；
-- 但那些本身对称的字母（A/H/T/U/X/O/V/Y）必须保持对称。
local SYMMETRIC_LETTERS = {
    letter_a = true, letter_h = true, letter_t = true, letter_u = true,
    letter_x = true, letter_o = true, letter_v = true, letter_y = true,
}
local asym = {}
for _, sh in ipairs(shape_blocks) do
    local is_letter = string.sub(sh.id, 1, 6) == "letter"
    if not (is_letter and not SYMMETRIC_LETTERS[sh.id]) then
        for _, row in ipairs(sh.mask) do
            if row ~= string.reverse(row) then
                asym[#asym + 1] = sh.id
                break
            end
        end
    end
end
check("剪影形状都左右对称", #asym == 0, table.concat(asym, ","))

-- 菱形必须上下左右都对称（用户明确要求"菱形对称"）
local dia
for _, sh in ipairs(shape_blocks) do
    if sh.id == "diamond" then dia = sh end
end
check("菱形存在", dia ~= nil)
if dia then
    local hs = true
    for _, row in ipairs(dia.mask) do
        if row ~= string.reverse(row) then hs = false end
    end
    local vs = true
    for i = 1, 3 do
        if dia.mask[i] ~= dia.mask[7 - i] then vs = false end
    end
    check("菱形左右对称", hs)
    check("菱形上下对称", vs)
end

-- 掩码的占用格集合
local function shape_sig(mask)
    local t = {}
    for r = 1, 6 do
        for c = 1, 10 do
            local ch = string.sub(mask[r] or "", c, c)
            t[#t + 1] = (ch == "#") and "1" or "0"
        end
    end
    return table.concat(t)
end
local shape_sigs = {}
for _, sh in ipairs(shape_blocks) do shape_sigs[shape_sig(sh.mask)] = sh.id end

-- 当前关卡实际占用的格子
local function level_sig(d)
    local t = {}
    for r = 1, 6 do
        for c = 1, 10 do
            t[#t + 1] = d.bricks[r][c] and "1" or "0"
        end
    end
    return table.concat(t)
end

-- (1) 每一关的砖阵都必须**正好等于**形状库里某个形状
-- next_shape = nil 是为了强制现抽一个形状（否则会用到预抽给下一关的那个）
local mismatch = {}
for lv = 1, 12 do
    local d = BreakoutDialog:new()
    d.next_shape = nil
    d.level = lv
    d:loadLevel(lv)
    if not shape_sigs[level_sig(d)] then
        mismatch[#mismatch + 1] = "第" .. lv .. "关"
    end
end
check("每关砖阵都正好等于某个形状", #mismatch == 0, table.concat(mismatch, ","))

-- (2) 相邻两关形状必须不同 —— 在同一个对话框上逐关推进才准
local same = 0
local prev = nil
local dw = BreakoutDialog:new()
for lv = 1, 30 do
    dw.level = lv
    dw:loadLevel(lv)
    local id = shape_sigs[level_sig(dw)]
    if id == prev then same = same + 1 end
    prev = id
end
check("相邻两关形状不重复", same == 0, "重复 " .. same .. " 次")

-- (3) 形状要真的随机：多跑多关，形状库里大部分形状都该出现过
local seen = {}
for lv = 1, 400 do
    local d = BreakoutDialog:new()
    d.next_shape = nil
    d.level = lv
    d:loadLevel(lv)
    seen[shape_sigs[level_sig(d)]] = true
end
local nseen = 0
for _ in pairs(seen) do nseen = nseen + 1 end
check("随机覆盖到大部分形状 (>=16/20)", nseen >= 16, "覆盖 " .. nseen .. "/20")

-- (4) 道具砖数量：每关 6 块起步，随关卡递增，封顶 10
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
local power_bad = {}
for lv = 1, 15 do
    local want = math.min(10, 6 + math.floor((lv - 1) / 3))
    local d = BreakoutDialog:new()
    d.next_shape = nil
    d.level = lv
    d:loadLevel(lv)
    local got = countPower(d)
    if got ~= want then power_bad[#power_bad + 1] = string.format("第%d关 %d≠%d", lv, got, want) end
end
check("道具砖数量符合 6→10 递增规则", #power_bad == 0, table.concat(power_bad, " "))

-- (5) 钢砖：第 4 关起才有，且不可破、也不计入过关计数
local steel_lv3 = 0
for _ = 1, 20 do
    local d = BreakoutDialog:new()
    d.level = 3
    d:loadLevel(3)
    for r = 1, 6 do
        for c = 1, 10 do
            local b = d.bricks[r][c]
            if b and b.hp < 0 then steel_lv3 = steel_lv3 + 1 end
        end
    end
end
check("第 3 关没有钢砖", steel_lv3 == 0, "出现 " .. steel_lv3 .. " 块")

local d5 = BreakoutDialog:new()
d5.level = 6
d5:loadLevel(6)
local steel5, breakable5 = 0, 0
for r = 1, 6 do
    for c = 1, 10 do
        local b = d5.bricks[r][c]
        if b then
            if b.hp < 0 then steel5 = steel5 + 1 else breakable5 = breakable5 + 1 end
        end
    end
end
check("第 6 关有钢砖", steel5 > 0, "钢砖 " .. steel5 .. " 块")
check("钢砖不计入过关计数", d5.bricks_left == breakable5,
    "left=" .. d5.bricks_left .. " 可破=" .. breakable5)

-- (6) 形状名要能显示在过关浮层上
local d7 = BreakoutDialog:new()
d7:launchBall()
d7:loadLevel(3)
check("关卡记下了形状名", d7.level_shape ~= nil and d7.level_shape.name ~= nil,
    tostring(d7.level_shape and d7.level_shape.name))

end
-- ======================= 场景 10b: 同屏掉落上限 =======================
section("场景 10b: 同屏掉落上限")
do
-- 同屏掉落上限与落点标记上限要跟得上道具砖数量：
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

end
-- ======================= 场景 11: 底栏与运动脏区分离 (底栏闪烁修复) =======================
-- 真机教训: KOReader 的 _refresh 会把"共享边界"的两个矩形也合并成一次刷新，
-- 运动脏区一旦伸进底栏(y>=708)，底栏就被卷进"运动区+底栏"的大局部刷新，
-- e-ink 部分刷新波形会把实心生命圆点刷成空心、吃掉底栏文字 —— 表现为底栏闪烁/残缺。
-- 修复三条:
--   ① 运动脏区下边界夹到 707;
--   ② 底栏 pushRect 用 pad=0，严格从 708 起，两块永不合并;
--   ③ 球/道具改成"底边触线即消失"，永远画不到 707 以下，夹断也不丢内容。
section("场景 11: 底栏与运动脏区分离")
do
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

end
-- ======================= 场景 12: 静止时零刷新 =======================
-- 真机教训: 插件以前每 tick 都把"挡板区"标脏推送，静止画面也在 10Hz 刷面板，
-- KOReader 照单全收地刷 —— 真机 10 连拍有 2 帧糊掉半屏/底栏残缺，
-- 墨水屏也白受刷新预算。铁律: 真的动了才标脏，静止时一个像素都不刷。
section("场景 12: 静止时零刷新")
do
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
-- 砖阵形状是随机的，得先找一块真实存在的砖来打
local bd = BreakoutDialog:new()
local br, bc, bbx, bby = firstBrick(bd)
check("当前关卡能找到可破的砖", br ~= nil)
if br then
    bd:damageBrick(br, bc, bbx, bby)
    check("击碎砖块当场标脏砖阵区", bd._dr.brick ~= nil,
        "brick 桶为空")
    if bd._dr.brick then
        local bx = bd._dr.brick.x1
        local bw = bd._dr.brick.x2 - bd._dr.brick.x1
        check("砖阵脏区只覆盖那一格", bw < 120, "宽 " .. tostring(bw) .. " (起点 " .. tostring(bx) .. ")")
    end
end

end
-- ======================= 场景 13: 道具谱系 (17 种) =======================
-- 参考 Arkanoid / DX-Ball 的道具谱系扩充：10 种增益 + 7 种减益。
-- 道具表直接从插件源码里解析，断言跟实现同源，不会两边各写一份对不上。
section("场景 13: 道具谱系")
do
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

end
-- ======================= 场景 14: 新道具效果 =======================
section("场景 14: 新道具效果")
do
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
-- 砖阵形状是随机的，得先找一块真实存在的砖来瞄
local n9 = fresh()
n9:applyPowerUp("laser")
n9.laser_timer = 99          -- 掐掉本次的自动发射，只测手动放的那颗子弹
local _, _, tbx, tby = firstBrick(n9)
n9.bullets = { { x = tbx + 26, y = tby + 26, px = tbx + 26, py = tby + 26 } }
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

end
-- ======================= 场景 15: 新机制的物理正确性 =======================
section("场景 15: 新机制的物理正确性")
do

-- 穿透：球穿砖不反弹，砖照常掉血
-- 球从砖下方顶上来（真实可达的姿态），不能把球塞进砖内部
local p1 = BreakoutDialog:new()
p1.state = 1
p1:applyPowerUp("pierce")
local pb = p1.balls[1]
pb.r = 7
local _, _, pbx, pby = firstBrick(p1)
pb.x = pbx + 26
pb.y = pby + 30
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
local sr, sc, sbx, sby = firstBrick(p2)
p2.bricks[sr][sc] = { hp = -1, base = -1 }   -- 换成钢砖
local p2b = p2.balls[1]
p2b.r = 7
p2b.x = sbx + 26
p2b.y = sby + 30
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

end
-- ======================= 场景 16: 新道具压力测试 =======================
section("场景 16: 新道具压力测试 (30000 帧)")
do
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

end
-- ======================= 场景 17: 渲染层冒烟测试 =======================
-- 墨水屏插件最怕两件事：画到屏幕外（内容看不见）、元素没画出来（效果等于没做）。
-- 这里直接调 paintTo，检查绘图指令的边界与关键元素是否到位。
section("场景 17: 渲染层冒烟测试")
do

local function render(d)
    ops = {}
    d:paintTo(Blitbuffer, 0, 0)
    return ops
end

-- (1) 各种道具组合下都不能有图形画到屏幕外
local combos = {
    {}, { "extend" }, { "multi" }, { "slow" }, { "life" }, { "catch" }, { "gold" },
    { "pierce" }, { "bomb" }, { "laser" }, { "shield" },
    { "shrink" }, { "fast" }, { "narrow" }, { "flip" }, { "drop" }, { "blind" }, { "chaos" },
    { "laser", "shield", "blind", "pierce", "narrow", "extend" },   -- 叠满
}
local oob = nil
local checked = 0
for _, combo in ipairs(combos) do
    local d = BreakoutDialog:new()
    d:launchBall()
    for _, id in ipairs(combo) do d:applyPowerUp(id) end
    d:updateEffects()
    -- 造出各类运动物体，保证渲染路径被完整走一遍
    d.bullets = { { x = d.paddle_x, y = d.PADDLE_Y - 40, px = d.paddle_x, py = d.PADDLE_Y - 40 } }
    d.items = { { id = "laser", x = 300, y = 200, px = 300, py = 200, checked = false } }
    local o = render(d)
    checked = checked + 1
    for _, op in ipairs(o) do
        local x1, y1, x2, y2
        if op.op == "circle" then
            x1, y1, x2, y2 = op.x - op.r, op.y - op.r, op.x + op.r, op.y + op.r
        else
            x1, y1, x2, y2 = op.x, op.y, op.x + op.w, op.y + op.h
        end
        if x1 < -1 or y1 < -1 or x2 > 601 or y2 > 801 then
            oob = string.format("组合 [%s]: %s 越界 (%.0f,%.0f)-(%.0f,%.0f)",
                table.concat(combo, "+"), op.op, x1, y1, x2, y2)
            break
        end
    end
    if oob then break end
end
check(string.format("各种道具组合(%d 种)下都不画到屏幕外", checked), oob == nil, tostring(oob))

-- (2) 护盾：挡板上方要有一条白底护壁
local sh = BreakoutDialog:new()
sh:launchBall()
sh:applyPowerUp("shield")
sh:updateEffects()
local sh_ops = render(sh)
local has_shield = false
for _, op in ipairs(sh_ops) do
    if op.op == "rect" and op.c == 0xFF and op.w == sh.paddle_w
        and math.abs(op.y - (sh.PADDLE_Y - 22 - 3)) <= 1 then
        has_shield = true
    end
end
check("护盾: 挡板上方画出护壁", has_shield)

-- (3) 激光：挡板两侧要画出炮管
local la = BreakoutDialog:new()
la:launchBall()
la:applyPowerUp("laser")
la:updateEffects()
local la_ops = render(la)
local gun = 0
for _, op in ipairs(la_ops) do
    if op.op == "rect" and op.c == 0x00 and op.w == 4 and op.h == 11
        and math.abs(op.y - (la.PADDLE_Y - 9)) <= 1 then
        gun = gun + 1
    end
end
check("激光: 挡板两侧画出炮管", gun == 2, "炮管 " .. gun .. " 个")

-- (4) 隐形：挡板实体不该再被画成实心黑块
local bl = BreakoutDialog:new()
bl:launchBall()
bl:applyPowerUp("blind")
bl:updateEffects()
local bl_ops = render(bl)
local solid_paddle = false
for _, op in ipairs(bl_ops) do
    if op.op == "rr" and op.c == 0x00 and op.w == bl.paddle_w and op.h == 12
        and math.abs(op.y - bl.PADDLE_Y) <= 1 then
        solid_paddle = true
    end
end
check("隐形: 挡板实体不再画实心黑块", not solid_paddle)

-- 正常状态下挡板必须是实心黑块（对照，防止上面的判断写得太宽）
local nm = BreakoutDialog:new()
nm:launchBall()
local nm_ops = render(nm)
local normal_paddle = false
for _, op in ipairs(nm_ops) do
    if op.op == "rr" and op.c == 0x00 and op.w == nm.paddle_w and op.h == 12
        and math.abs(op.y - nm.PADDLE_Y) <= 1 then
        normal_paddle = true
    end
end
check("对照: 正常挡板是实心黑块", normal_paddle)

-- (5) 穿透：球心要有一个白色小点
local pi = BreakoutDialog:new()
pi:launchBall()
pi:applyPowerUp("pierce")
pi:updateEffects()
local pi_ops = render(pi)
local pb = pi.balls[1]
local dot = false
for _, op in ipairs(pi_ops) do
    if op.op == "circle" and op.c == 0xFF and op.r == 4
        and math.abs(op.x - pb.x) <= 2 and math.abs(op.y - pb.y) <= 2 then
        dot = true
    end
end
check("穿透: 球心画出白色小点", dot)

-- (6) 细球：球画出来的半径要变小
local nr = BreakoutDialog:new()
nr:launchBall()
nr:applyPowerUp("narrow")
nr:updateEffects()
local nr_ops = render(nr)
local small_ball = false
for _, op in ipairs(nr_ops) do
    if op.op == "circle" and op.c == 0x00 and op.r == 4 then small_ball = true end
end
check("细球: 球按小半径画出来", small_ball)

-- (7) 效果条最多 6 个槽 + 1 个提示，横向不能超出底栏
local fx = BreakoutDialog:new()
fx:launchBall()
for _, id in ipairs({ "extend", "slow", "catch", "pierce", "bomb", "laser", "flip", "blind" }) do
    fx:applyPowerUp(id)
end
fx:updateEffects()
local fx_ops = render(fx)
local fx_right = 0
for _, op in ipairs(fx_ops) do
    if op.op == "rr" and op.r == 4 and op.w == 24 and op.h == 24 and op.y == fx.H - 92 + 48 then
        fx_right = math.max(fx_right, op.x + op.w)
    end
end
check("效果条不超出底栏右边界", fx_right <= fx.W, "最右 " .. tostring(fx_right))

end
-- ======================= 场景 18: 护盾脏区不白占刷新预算 =======================
-- 护盾线挂在挡板上方 22px 处。如果把它无条件并进"挡板移动"的脏区，
-- 没有护盾时也要多刷 23px 高的区域 —— 墨水屏上这块是纯浪费。
section("场景 18: 护盾脏区预算")
do

local sg = BreakoutDialog:new()
sg:launchBall()
sg.state = 1                 -- PLAYING，让挡板跟手移动
sg:tick()                    -- 预热：底栏首帧推一次，之后进入稳态

-- 直接数 markShieldDirty 的调用次数，避开"落点十字"脏区的干扰
-- （十字画在 PADDLE_Y-16，±10 -> 636..656，本来就盖住护盾带）
local called = 0
local orig_shield_dirty = sg.markShieldDirty
sg.markShieldDirty = function(self, ox, ow)
    called = called + 1
    return orig_shield_dirty(self, ox, ow)
end

sg.paddle_target_x = sg.paddle_x + 60
sg:tick()
check("无护盾时不标护盾脏区", called == 0, "调用 " .. called .. " 次")

sg:applyPowerUp("shield")
sg:updateEffects()
called = 0
sg.paddle_target_x = sg.paddle_x + 60
sg:tick()
check("有护盾时标护盾脏区", called == 1, "调用 " .. called .. " 次")

-- 护盾到期后同样不再标脏区
sg.tick_count = sg.effects.shield + 1
sg:updateEffects()
called = 0
sg.paddle_target_x = sg.paddle_x + 60
sg:tick()
check("护盾到期后不再标护盾脏区", called == 0, "调用 " .. called .. " 次")

end
-- ======================= 场景 19: AI 辅助 =======================
-- AI = 挡板自动跟住最迫近那颗球的预测落点（marker_x 就是那个落点，
-- 也正是屏幕上画的十字预测标记，两边永远一致）。
-- 玩家手动拖动时 AI 让位，停手后自动接回来 —— 它是"辅助"，不抢挡板。
section("场景 19: AI 辅助")
do

-- 19.1 默认关闭
local g0 = BreakoutDialog:new()
check("AI 默认关闭", g0.ai_mode == false, "ai_mode=" .. tostring(g0.ai_mode))
check("顶栏注册了 AI 按钮", text:find('action = "ai"') ~= nil)

-- 19.2 按钮可切换
g0:doButton("ai")
check("doButton 切到 AI 开", g0.ai_mode == true, "ai_mode=" .. tostring(g0.ai_mode))
g0:doButton("ai")
check("doButton 切回 AI 关", g0.ai_mode == false, "ai_mode=" .. tostring(g0.ai_mode))

-- 19.3 AI 关着时挡板纹丝不动
local g1 = BreakoutDialog:new()
g1:launchBall()
local x_before = g1.paddle_x
for _ = 1, 200 do g1:tick() end
check("AI 关闭时挡板不动", math.abs(g1.paddle_x - x_before) < 0.01,
    "dx=" .. tostring(g1.paddle_x - x_before))

-- 19.4 AI 开着时挡板自己动，且朝落点靠
local g2 = BreakoutDialog:new()
g2.ai_mode = true
g2:launchBall()
for _ = 1, 10 do g2:tick() end
check("AI 开启后有落点标记", g2.marker_x ~= nil)
local moved = false
for _ = 1, 200 do
    local before = g2.paddle_x
    g2:tick()
    if math.abs(g2.paddle_x - before) > 0.01 then moved = true end
end
check("AI 开启后挡板自动移动", moved)
-- AI 的目标由 aiTarget() 给出（出砖阵区走精确外推，在砖阵区走快照预测），
-- 所以断言对着 aiTarget()，不要绑死到 marker_x。
local gap = math.abs(g2.paddle_x - (g2:aiTarget() or g2.paddle_x))
check("AI 挡板跟着落点走", gap < 60, "离落点 " .. string.format("%.1f", gap) .. "px")

-- 19.5 玩家手动拖动时 AI 让位
local g3 = BreakoutDialog:new()
g3.ai_mode = true
g3:launchBall()
for _ = 1, 10 do g3:tick() end
g3:onPan(nil, { relative = { x = 0, y = 0 }, start_pos = { x = 300, y = 400 } })
g3.paddle_target_x = 120
g3:tick()
check("玩家拖动时 AI 不抢挡板", g3.paddle_target_x == 120,
    "target=" .. tostring(g3.paddle_target_x))

-- 19.6 让位期过后 AI 重新接管
g3.ai_pause_until = 0
for _ = 1, 5 do g3:tick() end
check("让位期过后 AI 重新接管",
    g3.ai_target_x ~= nil and math.abs(g3.paddle_target_x - g3.ai_target_x) < 0.01,
    "target=" .. tostring(g3.paddle_target_x) .. " aiTarget=" .. tostring(g3.ai_target_x))

-- 19.7 AI 挂机时不会把球漏掉（最强的一条：整局不扣命）
-- 压力测试：AI 全程接管挡板，玩家只负责发球。
-- 必须像场景 1 那样"待发球就发球"，否则球漏一次后就静止不动，
-- AI 根本不会被持续压测（踩过一次：漏球统计只有 1，看起来像"只漏一颗"）。
local g4 = BreakoutDialog:new()
g4.ai_mode = true
local _serves, _lost, _nilm = 0, 0, 0
local _prev_lives = 3
for _ = 1, 3000 do
    if g4.state == 0 then
        g4:launchBall()
        _serves = _serves + 1
    end
    g4:tick()
    if g4.marker_x == nil then _nilm = _nilm + 1 end
    if g4.lives < _prev_lives then
        _lost = _lost + 1
        _prev_lives = g4.lives
    end
end
print(string.format("   [诊断] 发球 %d 次, 漏球 %d 次, marker_x 为 nil 的帧数 = %d / 3000",
    _serves, _lost, _nilm))
-- 注意：不能只看 lives —— 漏球后如果捡到"加命"道具会把命补回来，
-- 漏球次数会被掩盖。这里直接数漏球次数。
check("AI 模式 3000 帧零漏球", _lost == 0,
    "漏球=" .. tostring(_lost) .. " lives=" .. tostring(g4.lives)
    .. " score=" .. tostring(g4.score) .. " 发球=" .. tostring(_serves))
check("AI 模式能持续得分", g4.score > 0, "score=" .. tostring(g4.score))

-- 19.8 AI 挂着不影响发球（辅助只管接，不管开球）
local g5 = BreakoutDialog:new()
g5.ai_mode = true
check("AI 开启时仍是待发球状态", g5.state == 0, "state=" .. tostring(g5.state))
g5:launchBall()
check("AI 开启仍可正常发球", g5.state == 1, "state=" .. tostring(g5.state))

end

-- ======================= 场景 20: AI 顺路接道具 =======================
-- AI 的落点策略：球优先，有余地就捎上正在下落的道具。
--
-- 两种接取区间宽度不同，这是"顺路"能成立的前提：
--   球  : |ballX - paddle_x| <= half + r  （球有半径，边缘能蹭到）-> 宽 110px
--   道具: |itemX - paddle_x| <= half        （道具要整个落在挡板上）-> 宽  96px
-- 球的区间更宽 -> 两区间常相交。
--
-- 三档，按"到线时刻"排先后（两个到线时刻不一样，挡板只能先停一处、再挪一处）：
--   1) 白捡：球落点本来就在道具的接取区间里 -> 目标一点不动，顺手就接住。
--   2) 顺路：道具和球差不多同时到线 -> 目标取交集中心，一个位置覆盖两个。
--   3) 绕路：道具明显先到线 -> 先停在道具正上方（稳定目标），接完再赶回球落点。
--
-- 两条底线：
--   · 球永远优先 —— 时间不够就老老实实回去接球。
--   · 减益不追 —— 尤其"掉命"道具直接扣一条命，AI 不去碰减益。
section("场景 20: AI 顺路接道具")
do

local RAD = 7 -- BALL_R

-- 20.1 顺路：两区间相交 + 两者差不多同时到线 -> 目标取交集中心
-- 用例要避开"白捡"：道具区间不能包含球落点 300，否则命中的是白捡档。
-- 球在 y=400 下落 -> tBall=2.55s；道具 eta 要落在 [2.20, 2.55] -> eta=2.4s（y=528）
-- 道具在 380 -> 道具区间 [332,428]，球区间 [245,355]，交集 [332,355] -> 中心 343.5
local g1 = BreakoutDialog:new()
g1.paddle_x = 300
g1.items = { { id = "extend", x = 380, y = 528, px = 380, py = 528, checked = false } }
local b1 = { x = 300, y = 400, vx = 0, vy = 100, r = RAD }
local t1 = g1:aiItemTarget(300, b1)
check("顺路：目标同时落在球和道具两个接取区间里",
    t1 >= 245 and t1 <= 355 and t1 >= 332 and t1 <= 428, "target=" .. tostring(t1))
check("顺路：目标 = 交集中心", math.abs(t1 - 343.5) < 0.01, "target=" .. tostring(t1))

-- 20.2 白捡：球落点本来就在道具区间里 -> 目标不挪（不是交集中心）
local g2 = BreakoutDialog:new()
g2.paddle_x = 300
g2.items = { { id = "extend", x = 270, y = 528, px = 270, py = 528, checked = false } }
local t2 = g2:aiItemTarget(300, b1)
-- 道具区间 [222,318] 含 300 -> 白捡，保持 300（交集中心会是 281.5）
check("白捡：球落点已在道具区间内，目标不挪", math.abs(t2 - 300) < 0.01,
    "target=" .. tostring(t2))

-- 20.3 球优先：道具马上就要过线、赶不过去 -> 目标仍是球落点
local g3 = BreakoutDialog:new()
g3.paddle_x = 300
g3.items = { { id = "extend", x = 480, y = 645, px = 480, py = 645, checked = false } }
local b3 = { x = 300, y = 600, vx = 0, vy = 100, r = RAD }
local t3 = g3:aiItemTarget(300, b3)
check("球优先：来不及接的道具不改变目标", math.abs(t3 - 300) < 0.01,
    "target=" .. tostring(t3))

-- 20.4 绕路：接完道具还能赶回来接球 -> 先去接道具
local g4 = BreakoutDialog:new()
g4.paddle_x = 300
g4.items = { { id = "extend", x = 480, y = 598, px = 480, py = 598, checked = false } }
local b4 = { x = 300, y = 300, vx = 0, vy = 100, r = RAD }
local t4 = g4:aiItemTarget(300, b4)
check("绕路：时间确实来得及就先去接道具", math.abs(t4 - 480) < 0.01,
    "target=" .. tostring(t4))

-- 20.5 球优先：球快到了就不为道具绕路
local g5 = BreakoutDialog:new()
g5.paddle_x = 300
g5.items = { { id = "extend", x = 480, y = 598, px = 480, py = 598, checked = false } }
local b5 = { x = 300, y = 500, vx = 0, vy = 100, r = RAD }
local t5 = g5:aiItemTarget(300, b5)
check("球优先：球快到了就不为道具绕路", math.abs(t5 - 300) < 0.01,
    "target=" .. tostring(t5))

-- 20.6 减益不追："掉命"道具直接扣一条命，AI 绕过去不接
local g6 = BreakoutDialog:new()
g6.paddle_x = 300
g6.items = { { id = "drop", x = 480, y = 598, px = 480, py = 598, checked = false } }
local t6 = g6:aiItemTarget(300, b4)
check("减益道具不追（掉命更不能碰）", math.abs(t6 - 300) < 0.01, "target=" .. tostring(t6))

-- 20.7 球还在砖阵区（落点不可靠）时不绕路
local g7 = BreakoutDialog:new()
g7.paddle_x = 300
g7.items = { { id = "extend", x = 480, y = 598, px = 480, py = 598, checked = false } }
local b7 = { x = 300, y = 200, vx = 0, vy = 100, r = RAD }
local t7 = g7:aiItemTarget(300, b7)
check("落点不可靠时不绕路（宁可接球也不冒险）", math.abs(t7 - 300) < 0.01,
    "target=" .. tostring(t7))

-- 20.8 已经判定过的道具（越过接球线）不再参与决策
local g8 = BreakoutDialog:new()
g8.paddle_x = 300
g8.items = { { id = "extend", x = 380, y = 528, px = 380, py = 528, checked = true } }
local t8 = g8:aiItemTarget(300, b1)
check("已判定的道具不再参与决策", math.abs(t8 - 300) < 0.01, "target=" .. tostring(t8))

-- 20.9 端到端：道具正好在球落点上（白捡）-> 球和道具都接到
local g9 = BreakoutDialog:new()
g9.ai_mode = true
g9.state = 1 -- PLAYING
g9.balls = { { x = 300, y = 300, px = 300, py = 300, vx = 0, vy = 120, r = RAD } }
g9.items = { { id = "extend", x = 300, y = 573, px = 300, py = 573, checked = false } }
for _ = 1, 40 do g9:tick() end
check("端到端：AI 接住了下落的道具", g9.effects.extend ~= nil,
    "effects.extend=" .. tostring(g9.effects.extend))
check("端到端：接道具的同时没漏球", g9.lives == 3 and #g9.balls == 1,
    "lives=" .. tostring(g9.lives) .. " balls=" .. tostring(#g9.balls))

-- 20.10 端到端：道具在球落点旁边 -> AI 绕路去接，而且球也接住了
local g10 = BreakoutDialog:new()
g10.ai_mode = true
g10.state = 1
g10.balls = { { x = 320, y = 300, px = 320, py = 300, vx = 0, vy = 120, r = RAD } }
g10.items = { { id = "extend", x = 220, y = 598, px = 220, py = 598, checked = false } }
for _ = 1, 45 do g10:tick() end
check("端到端：绕路接道具也接住了", g10.effects.extend ~= nil,
    "effects.extend=" .. tostring(g10.effects.extend))
check("端到端：绕路接道具没有牺牲接球",
    g10.lives == 3 and #g10.balls == 1 and g10.balls[1].vy < 0,
    "lives=" .. tostring(g10.lives) .. " balls=" .. tostring(#g10.balls)
    .. " vy=" .. tostring(g10.balls[1] and g10.balls[1].vy))

-- 20.11 同一条球轨迹的 A/B：唯一变量是"要不要道具逻辑"
--
-- 两条关键的方法论：
--  · 球被挡板弹开的角度取决于挡板位置，改一下挡板就会让整局轨迹分叉，
--    所以不能用"两次不同的随机对局"来比。必须固定随机种子、只切道具逻辑，
--    这样两边的球轨迹完全一致，差异只来自道具决策。
--  · 扣命的判据是"所有球都掉光"（多球模式下掉一颗不算扣命），
--    "掉命"道具直接扣一条命，也要和真漏球分开算。
local function runAB(seed, frames, with_item)
    math.randomseed(seed)
    local g = BreakoutDialog:new()
    g.ai_mode = true
    if not with_item then
        g.aiItemTarget = function(self, ballX, ball) return ballX end
    end
    local pickups, drop_pu, lives_lost = 0, 0, 0
    local prev_lives = g.lives
    local orig = g.applyPowerUp
    g.applyPowerUp = function(self, id)
        pickups = pickups + 1
        if id == "drop" then drop_pu = drop_pu + 1 end
        return orig(self, id)
    end
    for _ = 1, frames do
        if g.state == 0 then g:launchBall() end
        g:tick()
        if g.lives < prev_lives then
            lives_lost = lives_lost + (prev_lives - g.lives)
            prev_lives = g.lives
        end
    end
    return pickups, lives_lost - drop_pu, drop_pu
end
local p_on, l_on, d_on = 0, 0, 0
local p_off, l_off, d_off = 0, 0, 0
for s = 1, 8 do
    local a, b, c = runAB(20261031 + s * 7, 4000, true)
    p_on = p_on + a; l_on = l_on + b; d_on = d_on + c
    local a2, b2, c2 = runAB(20261031 + s * 7, 4000, false)
    p_off = p_off + a2; l_off = l_off + b2; d_off = d_off + c2
end
print(string.format("   [诊断] 8 局同轨迹 A/B：接住道具 有=%d 无=%d；真扣命 有=%d 无=%d；掉命道具 有=%d 无=%d",
    p_on, p_off, l_on, l_off, d_on, d_off))
check("道具增强：同一批对局里接到的道具明显更多", p_on > p_off * 1.2,
    "有=" .. tostring(p_on) .. " 无=" .. tostring(p_off))
check("道具增强：没有因为追道具而多扣命", l_on <= l_off,
    "有=" .. tostring(l_on) .. " 无=" .. tostring(l_off))

end

-- ======================= 结果 =======================
print(string.format("\n========== 结果: %d 通过, %d 失败 ==========", pass, fail))
os.exit(fail == 0 and 0 or 1)
