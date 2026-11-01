--[[--
中国象棋 (Xiangqi) 插件入口
照抄《数独 (Sudoku)》的结构：注册到 KOReader 的工具菜单，
点击后打开 xiangqidialog（全屏对话框）。
菜单项 key 用 xiangqi_game（全局唯一，避免和别的游戏插件互相覆盖）。
--]]--

local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local reader_order = require("ui/elements/reader_menu_order")
local filemanager_order = require("ui/elements/filemanager_menu_order")

-- 插入到工具栏菜单首位
table.insert(reader_order.tools, 1, "xiangqi_game")
table.insert(filemanager_order.tools, 1, "xiangqi_game")

local XiangqiPlugin = WidgetContainer:extend{
    name = "xiangqi",
    is_doc_only = false,
}

function XiangqiPlugin:init()
    self.ui.menu:registerToMainMenu(self)
end

function XiangqiPlugin:addToMainMenu(menu_items)
    menu_items.xiangqi_game = {
        text = "中国象棋 (Xiangqi)",
        sorting_hint = "tools",
        callback = function()
            package.loaded["xiangqidialog"] = nil
            local XiangqiDialog = require("xiangqidialog")
            local dlg = XiangqiDialog:new()
            UIManager:show(dlg)
        end,
    }
end

return XiangqiPlugin
