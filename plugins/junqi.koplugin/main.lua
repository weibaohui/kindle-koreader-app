--[[--
军棋 (Junqi) 插件的菜单注册入口。

只负责把「军棋」挂到阅读器/文件管理器的工具菜单上（菜单 key: junqi_game，全局唯一），
真正的棋盘逻辑、绘制与交互都在 junqidialog.lua 里。
--]]--

local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local reader_order = require("ui/elements/reader_menu_order")
local filemanager_order = require("ui/elements/filemanager_menu_order")

-- 插入到工具栏菜单首位
table.insert(reader_order.tools, 1, "junqi_game")
table.insert(filemanager_order.tools, 1, "junqi_game")

local JunqiPlugin = WidgetContainer:extend{
    name = "junqi",
    is_doc_only = false,
}

function JunqiPlugin:init()
    self.ui.menu:registerToMainMenu(self)
end

function JunqiPlugin:addToMainMenu(menu_items)
    menu_items.junqi_game = {
        text = "军棋 (Junqi)",
        sorting_hint = "tools",
        callback = function()
            package.loaded["junqidialog"] = nil
            local JunqiDialog = require("junqidialog")
            local dlg = JunqiDialog:new()
            UIManager:show(dlg)
        end,
    }
end

return JunqiPlugin
