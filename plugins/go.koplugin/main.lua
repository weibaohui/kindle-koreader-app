--[[--
围棋 (Go) 插件入口：只负责在工具菜单里注册一个菜单项。

菜单项 key 用 `go_game`（全局唯一，和数独的 sudoku_game 不冲突）。
游戏本体在 godialog.lua 里，这里不写任何游戏逻辑。
--]]--

local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local reader_order = require("ui/elements/reader_menu_order")
local filemanager_order = require("ui/elements/filemanager_menu_order")

-- 插入到工具栏菜单首位（与《数独》《砖石战场》并列，不用翻页）
table.insert(reader_order.tools, 1, "go_game")
table.insert(filemanager_order.tools, 1, "go_game")

local GoPlugin = WidgetContainer:extend{
    name = "go",
    is_doc_only = false,
}

function GoPlugin:init()
    self.ui.menu:registerToMainMenu(self)
end

function GoPlugin:addToMainMenu(menu_items)
    menu_items.go_game = {
        text = "围棋 (Go)",
        sorting_hint = "tools",
        callback = function()
            package.loaded["godialog"] = nil
            local GoDialog = require("godialog")
            local dlg = GoDialog:new()
            UIManager:show(dlg)
        end,
    }
end

return GoPlugin
