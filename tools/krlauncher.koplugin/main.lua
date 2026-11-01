--[[--
krlauncher: 真机验证用的临时启动器（仅开发/验证期使用，验证完必须撤掉）

为什么需要它：
  这台 Kindle（KT2 / zforce2）上，KOReader 的插件目录扫描发生在启动时，
  新装的插件必须重启 KOReader 才会出现在「工具」菜单里；
  而菜单里的入口坐标会随菜单项数量变化，不好写死。
  所以用一个临时插件，按命令直接打开指定游戏的对话框窗口。

命令协议：把命令写进 /tmp/kr_cmd（每行一条），插件 1 秒内执行：
    open <key>     打开对应游戏窗口
                   key ∈ sudoku / chess / xiangqi / go / junqi / breakout / tetris
    close          关闭当前最上层的游戏窗口
    status         在日志里记录当前窗口栈

执行记录写入 /tmp/kr_launcher.log。

安装：把本目录复制到 /mnt/us/koreader/plugins/krlauncher.koplugin/ 后重启 KOReader。
撤除：mv /mnt/us/koreader/plugins/krlauncher.koplugin /mnt/us/koreader/plugins.disabled/
--]]

local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local CMD_FILE = "/tmp/kr_cmd"
local LOG_FILE = "/tmp/kr_launcher.log"

-- 游戏 key → { 插件目录, 对话框模块, 窗口 name }
local GAMES = {
    sudoku   = { dir = "sudoku.koplugin",   mod = "sudokudialog",   win = "sudoku_dialog"   },
    chess    = { dir = "chess.koplugin",    mod = "chessdialog",    win = "chess_dialog"    },
    xiangqi  = { dir = "xiangqi.koplugin",  mod = "xiangqidialog",  win = "xiangqi_dialog"  },
    go       = { dir = "go.koplugin",       mod = "godialog",       win = "go_dialog"       },
    junqi    = { dir = "junqi.koplugin",    mod = "junqidialog",    win = "junqi_dialog"    },
    breakout = { dir = "breakout.koplugin", mod = "breakoutdialog", win = "breakout_dialog" },
    tetris   = { dir = "tetris.koplugin",   mod = "tetrisdialog",   win = "tetris_dialog"   },
}

local function log(msg)
    local f = io.open(LOG_FILE, "a")
    if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. tostring(msg) .. "\n")
        f:close()
    end
end

-- 把所有插件目录加进 package.path，保证 require 能找到对话框模块
local function setup_path()
    for _, g in pairs(GAMES) do
        local p = "/mnt/us/koreader/plugins/" .. g.dir .. "/?.lua"
        if not package.path:find(p, 1, true) then
            package.path = package.path .. ";" .. p
        end
    end
end

-- 找到已打开的窗口（UIManager 的窗口栈字段是私有 _window_stack）
local function find_window(win_name)
    local stack = UIManager._window_stack or {}
    for _, w in ipairs(stack) do
        local widget = w.widget or w
        if widget.name == win_name then return widget end
    end
    return nil
end

local function open_game(key)
    local g = GAMES[key]
    if not g then
        log("ERR unknown game: " .. tostring(key))
        return
    end
    if find_window(g.win) then
        log(key .. " already open")
        return
    end
    setup_path()
    package.loaded[g.mod] = nil
    local ok, dlg = pcall(function()
        return require(g.mod):new()
    end)
    if not ok or not dlg then
        log("ERR open " .. key .. ": " .. tostring(dlg))
        return
    end
    UIManager:show(dlg)
    log("opened " .. key)
end

local function close_game()
    local stack = UIManager._window_stack or {}
    local closed = 0
    for i = #stack, 1, -1 do
        local widget = stack[i].widget or stack[i]
        local nm = widget.name or ""
        for _, g in pairs(GAMES) do
            if nm == g.win then
                UIManager:close(widget)
                closed = closed + 1
                break
            end
        end
    end
    log("closed " .. closed .. " window(s)")
end

local function status()
    local stack = UIManager._window_stack or {}
    local names = {}
    for _, w in ipairs(stack) do
        local widget = w.widget or w
        names[#names + 1] = tostring(widget.name)
    end
    log("stack: " .. table.concat(names, " | "))
end

local function handle(line)
    local t = {}
    -- LuaJIT 5.1: string.gmatch 返回迭代函数，不能塞进 ipairs
    for w in line:gmatch("%S+") do t[#t + 1] = w end
    local cmd = (t[1] or ""):lower()
    local ok, err = pcall(function()
        if cmd == "open" and t[2] then
            open_game(t[2]:lower())
        elseif cmd == "close" then
            close_game()
        elseif cmd == "status" then
            status()
        else
            log("unknown cmd: " .. line)
        end
    end)
    -- 任何异常都不允许把 KOReader 带崩
    if not ok then log("cmd error: " .. tostring(err)) end
end

local function poll()
    local f = io.open(CMD_FILE, "r")
    if not f then return end
    local content = f:read("*a")
    f:close()
    os.remove(CMD_FILE)
    pcall(function()
        for line in content:gmatch("[^\r\n]+") do
            if line:match("%S") then handle(line) end
        end
    end)
end

local Launcher = WidgetContainer:extend{
    name = "krlauncher",
    is_doc_only = false,
}

function Launcher:init()
    setup_path()
    log("launcher init")
    local function again()
        poll()
        UIManager:scheduleIn(1, again)
    end
    UIManager:scheduleIn(1, again)
end

return Launcher
