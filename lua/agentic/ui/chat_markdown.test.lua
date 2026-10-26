local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

describe("Chat Markdown", function()
    local child = Child.new()
    before_each(function()
        child.setup()
    end)
    after_each(function()
        child.stop()
    end)

    it(
        "highlights Markdown without changing text or output editability",
        function()
            child.lua([[
            vim.cmd('syntax enable')
            widget = require('agentic.ui.chat_widget'):new(function() return true end)
            local buf = widget.buf_nrs.chat
            vim.api.nvim_win_set_buf(0, buf)
            require('agentic.utils.buf_helpers').with_modifiable(buf, function()
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
                    '# Heading', '', '- item', '', '**bold** and `code`', '',
                    '| A | B |', '| --- | --- |', '', '```lua', 'print(1)', '```',
                    '*italic* _under_ __strong__', '1. ordered', '~~~', 'code', '~~~',
                })
            end)
            groups = {}
            for _, pos in ipairs({ {1, 3}, {3, 1}, {5, 3}, {5, 15}, {7, 1}, {11, 1}, {13, 3}, {13, 11}, {13, 21}, {14, 1}, {16, 1} }) do
                groups[#groups + 1] = vim.fn.synIDattr(vim.fn.synID(pos[1], pos[2], 1), 'name')
            end
        ]])
            assert.equal({
                "markdownH1",
                "markdownListMarker",
                "markdownBold",
                "markdownCode",
                "markdownLinkDelimiter",
                "markdownCodeBlock",
                "markdownItalic",
                "markdownItalic",
                "markdownBold",
                "markdownOrderedListMarker",
                "markdownCodeBlock",
            }, child.lua_get("groups"))
            assert.is_false(
                child.lua_get("vim.bo[widget.buf_nrs.chat].modifiable")
            )
            assert.is_true(
                child.lua_get("vim.bo[widget.buf_nrs.input].modifiable")
            )
            assert.equal(
                "**bold** and `code`",
                child.lua_get(
                    "vim.api.nvim_buf_get_lines(widget.buf_nrs.chat, 4, 5, false)[1]"
                )
            )
        end
    )
end)
