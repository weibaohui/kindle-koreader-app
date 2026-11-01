--[[--
国际象棋 (Chess) 插件入口

只做两件事：
  1. 把菜单项注册到主菜单（key 必须全局唯一，这里用 chess_game）
  2. 被点击时打开 chessdialog

玩法逻辑全部在 chessdialog.lua 里，这里不碰。
--]]

local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local reader_order = require("ui/elements/reader_menu_order")
local filemanager_order = require("ui/elements/filemanager_menu_order")

-- 插入到工具栏菜单首位 (与《数独》《方块战争》《砖石战场》并列)
table.insert(reader_order.tools, 1, "chess_game")
table.insert(filemanager_order.tools, 1, "chess_game")

local ChessPlugin = WidgetContainer:extend{
    name = "chess",
    is_doc_only = false,
}

function ChessPlugin:init()
    self.ui.menu:registerToMainMenu(self)
end

function ChessPlugin:addToMainMenu(menu_items)
    menu_items.chess_game = {
        text = "国际象棋 (Chess)",
        sorting_hint = "tools",
        callback = function()
            package.loaded["chessdialog"] = nil
            local ChessDialog = require("chessdialog")
            local dlg = ChessDialog:new()
            UIManager:show(dlg)
        end,
    }
end

return ChessPlugin
