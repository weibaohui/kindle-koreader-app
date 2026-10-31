--[[--
数独插件的无头逻辑测试台 (headless harness)

把 KOReader 的依赖全部 mock 掉，只跑纯游戏逻辑：
出题（唯一解保证）/ 填数 / 笔记 / 撤销 / 冲突判定 / 完成判定 / 存档 / 脏区。

用法: lua tools/sim_sudoku.lua [插件路径]
--]]

-- 固定随机种子：出题用 math.random，不固定种子结果不可复现
math.randomseed(20261031)

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
local SAVE_DIR = "/tmp/sudoku_sim"
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
local SRC = arg[1] or "plugins/sudoku.koplugin/sudokudialog.lua"
local SudokuDialog = assert(loadfile(SRC))()

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

local function boxOf(r, c) return math.floor((r - 1) / 3) * 3 + math.floor((c - 1) / 3) + 1 end

--- 盘面是否合法（同一行/列/宫里没有重复数字）
local function gridValid(g)
    for r = 1, 9 do
        local seen = {}
        for c = 1, 9 do
            local v = g[(r - 1) * 9 + c]
            if v ~= 0 then
                if seen[v] then return false end
                seen[v] = true
            end
        end
    end
    for c = 1, 9 do
        local seen = {}
        for r = 1, 9 do
            local v = g[(r - 1) * 9 + c]
            if v ~= 0 then
                if seen[v] then return false end
                seen[v] = true
            end
        end
    end
    for b = 1, 9 do
        local seen = {}
        local br = math.floor((b - 1) / 3)
        local bc = (b - 1) % 3
        for dr = 1, 3 do
            for dc = 1, 3 do
                local v = g[(br * 3 + dr - 1) * 9 + (bc * 3 + dc - 1) + 1]
                if v ~= 0 then
                    if seen[v] then return false end
                    seen[v] = true
                end
            end
        end
    end
    return true
end

--- 造一份干净棋盘：先删存档，避免上一个用例的盘面污染下一个用例
local function freshDialog(diff)
    os.remove(SAVE_DIR .. "/sudoku_save.txt")
    local d = SudokuDialog:new()
    if diff then d:newGame(diff) end
    return d
end

local function countGivens(g)
    local n = 0
    for i = 1, 81 do
        if g[i] ~= 0 then n = n + 1 end
    end
    return n
end

-- ======================= 场景 1: 出题 =======================
section("场景 1: 出题（唯一解）")
local DIFFS = { { name = "简单", givens = 42 }, { name = "普通", givens = 32 }, { name = "困难", givens = 25 } }

for _, d in ipairs(DIFFS) do
    local ok_unique, ok_valid, ok_count = true, true, true
    local min_g = 99
    for _ = 1, 8 do
        local g = SudokuDialog.generatePuzzle(d.givens)
        if SudokuDialog.countSolutions(g, 2) ~= 1 then ok_unique = false end
        if not gridValid(g) then ok_valid = false end
        local n = countGivens(g)
        if n < d.givens then ok_count = false end
        if n < min_g then min_g = n end
    end
    check(d.name .. "题目解唯一", ok_unique)
    check(d.name .. "题面合法", ok_valid)
    check(d.name .. "给定数不少于目标", ok_count, "最少 " .. min_g)
end

-- ======================= 场景 2: 生成耗时 =======================
section("场景 2: 生成耗时")
local t0 = os.clock()
for _ = 1, 5 do SudokuDialog.generatePuzzle(25) end
local cost = (os.clock() - t0) / 5
check("困难局平均生成耗时 < 0.5s", cost < 0.5, string.format("%.3f s", cost))
print(string.format("     困难难度平均 %.3f s/局", cost))

-- ======================= 场景 3: 填数与擦除 =======================
section("场景 3: 填数与擦除")
local d = freshDialog()
-- 找一个空格（必须是这个盘自己的空格）
local function firstEmpty(dlg)
    for i = 1, 81 do
        if dlg.given[i] == 0 then return i end
    end
    return nil
end
local empty = firstEmpty(d)
d.sel = empty
d:placeNumber(7)
check("填入数字生效", d.val[empty] == 7, "val=" .. tostring(d.val[empty]))
d:placeNumber(7)
check("再点同一数字即擦除", d.val[empty] == 0, "val=" .. tostring(d.val[empty]))

-- 题目给定的格子不能改
local given_idx = nil
for i = 1, 81 do
    if d.given[i] ~= 0 then given_idx = i break end
end
d.sel = given_idx
local before = d.val[given_idx]
d:placeNumber(1)
check("题目给定的格子不可改", d.val[given_idx] == before, "val=" .. tostring(d.val[given_idx]))

-- ======================= 场景 4: 笔记 =======================
section("场景 4: 笔记")
d.sel = empty
d.notes_mode = true
d:toggleNote(3)
check("笔记写入", (d.notes[empty] or 0) == 4, "notes=" .. tostring(d.notes[empty]))
d:toggleNote(3)
check("再点取消笔记", (d.notes[empty] or 0) == 0, "notes=" .. tostring(d.notes[empty]))

-- ======================= 场景 5: 撤销 =======================
section("场景 5: 撤销")
d.sel = empty
d:placeNumber(5)
check("撤销前有值", d.val[empty] == 5)
d:undo()
check("撤销后回到空", d.val[empty] == 0, "val=" .. tostring(d.val[empty]))

-- ======================= 场景 6: 冲突判定 =======================
section("场景 6: 冲突判定")
local c1, c2 = nil, nil
for i = 1, 81 do
    local r = math.floor((i - 1) / 9) + 1
    local c = (i - 1) % 9 + 1
    if r == 1 and c == 1 and not c1 then c1 = i end
    if r == 1 and c == 2 and not c2 then c2 = i end
end
local cc = freshDialog()
cc.sel = c1
cc:placeNumber(4)
cc.sel = c2
cc:placeNumber(4)
check("同行重复数字被判冲突", cc.conflict[c1] == true and cc.conflict[c2] == true)

-- ======================= 场景 7: 完成判定 =======================
section("场景 7: 完成判定")
local wc = freshDialog()
-- 用该盘自己的完整解覆盖（模拟玩家全部填对）
for i = 1, 81 do
    if wc.given[i] == 0 then
        wc.val[i] = wc.solution[i]
    end
end
wc:computeConflicts()
local won = wc:checkWin()
check("填满且无冲突即判完成", won == true and wc.won == true)

-- ======================= 场景 8: 存档往返 =======================
section("场景 8: 存档往返")
local sd = freshDialog()
sd.sel = firstEmpty(sd)
sd:placeNumber(3)
sd.notes_mode = true
sd:toggleNote(8)
local saved_given = table.concat(sd.given, ",")
local saved_val = table.concat(sd.val, ",")
local saved_notes = table.concat(sd.notes, ",")
sd:saveGame()
local ld = SudokuDialog:new()
check("读档还原给定数", table.concat(ld.given, ",") == saved_given)
check("读档还原盘面", table.concat(ld.val, ",") == saved_val)
check("读档还原笔记", table.concat(ld.notes, ",") == saved_notes)
check("读档还原用时", ld.elapsed == sd.elapsed)

-- ======================= 场景 8b: 提示 =======================
section("场景 8b: 提示")
local hd = freshDialog()
local hcell = firstEmpty(hd)
hd.sel = hcell
hd:giveHint()
check("提示填入正确答案", hd.val[hcell] == hd.solution[hcell],
    "填了 " .. tostring(hd.val[hcell]) .. " 正确答案 " .. tostring(hd.solution[hcell]))
check("提示次数被记录", (hd.hints or 0) == 1, "hints=" .. tostring(hd.hints))

-- ======================= 场景 9: 刷新脏区 =======================
section("场景 9: 刷新脏区")
local rd = freshDialog()
dirty_regions = {}
rd.sel = firstEmpty(rd)
rd:placeNumber(6)
rd:doRefresh()
local grid_areas = 0
for _, r in ipairs(dirty_regions) do
    if r.y and r.y >= 50 and r.y <= 525 then
        grid_areas = grid_areas + 1
    end
end
check("填一个数只刷那一格附近", grid_areas >= 1 and grid_areas <= 3,
    "刷了 " .. grid_areas .. " 个棋盘区")
local max_area = 0
for _, r in ipairs(dirty_regions) do
    if r.w and r.h then max_area = math.max(max_area, r.w * r.h) end
end
check("没有整屏级刷新", max_area < 600 * 800, "最大区域 " .. tostring(max_area))

-- 静止时（没有操作）不应该产生任何刷新
dirty_regions = {}
rd:doRefresh()
check("无操作时不刷新", #dirty_regions == 0, "推了 " .. #dirty_regions .. " 个")

-- ======================= 结果 =======================
print(string.format("\n========== 结果: %d 通过, %d 失败 ==========", pass, fail))
os.exit(fail == 0 and 0 or 1)
