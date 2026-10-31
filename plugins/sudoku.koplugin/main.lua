local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local reader_order = require("ui/elements/reader_menu_order")
local filemanager_order = require("ui/elements/filemanager_menu_order")

-- 插入到工具栏菜单首位 (与《方块战争》《砖石战场》并列，无需翻页或点更多工具)
table.insert(reader_order.tools, 1, "sudoku_game")
table.insert(filemanager_order.tools, 1, "sudoku_game")

local SudokuPlugin = WidgetContainer:extend{
    name = "sudoku",
    is_doc_only = false,
}

function SudokuPlugin:init()
    self.ui.menu:registerToMainMenu(self)
end

function SudokuPlugin:addToMainMenu(menu_items)
    menu_items.sudoku_game = {
        text = "数独 (Sudoku)",
        sorting_hint = "tools",
        callback = function()
            package.loaded["sudokudialog"] = nil
            local SudokuDialog = require("sudokudialog")
            local dlg = SudokuDialog:new()
            UIManager:show(dlg)
        end,
    }
end

return SudokuPlugin
