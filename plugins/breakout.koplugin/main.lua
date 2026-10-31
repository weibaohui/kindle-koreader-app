local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local reader_order = require("ui/elements/reader_menu_order")
local filemanager_order = require("ui/elements/filemanager_menu_order")

-- 插入到工具栏菜单首位 (与《方块战争》并列，无需翻页或点更多工具)
table.insert(reader_order.tools, 1, "breakout_game")
table.insert(filemanager_order.tools, 1, "breakout_game")

local BreakoutPlugin = WidgetContainer:extend{
    name = "breakout",
    is_doc_only = false,
}

function BreakoutPlugin:init()
    self.ui.menu:registerToMainMenu(self)
end

function BreakoutPlugin:addToMainMenu(menu_items)
    menu_items.breakout_game = {
        text = "砖石战场 (打砖块)",
        sorting_hint = "tools",
        callback = function()
            package.loaded["breakoutdialog"] = nil
            local BreakoutDialog = require("breakoutdialog")
            local dlg = BreakoutDialog:new()
            UIManager:show(dlg)
        end,
    }
end

return BreakoutPlugin
