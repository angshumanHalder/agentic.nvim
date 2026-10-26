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
        "keeps chat highlighting responsive when a filetype hook starts Treesitter",
        function()
            child.lua([[
            vim.cmd('syntax enable')
            vim.treesitter.language.register('markdown', 'AgenticChat')
            vim.api.nvim_create_autocmd('FileType', {
                pattern = 'AgenticChat',
                callback = function(args)
                    vim.treesitter.start(args.buf, 'markdown')
                    started = vim.treesitter.highlighter.active[args.buf] ~= nil
                end,
            })
            widget = require('agentic.ui.chat_widget'):new(function() return true end)
        ]])
            assert.is_true(child.lua_get("started"))
            assert.is_false(
                child.lua_get(
                    "vim.treesitter.highlighter.active[widget.buf_nrs.chat] ~= nil"
                )
            )
            assert.equal(
                "AgenticChat",
                child.lua_get("vim.bo[widget.buf_nrs.chat].syntax")
            )
        end
    )

    it(
        "does not pull a reader out of a wrapped response during streaming",
        function()
            child.lua([[
            widget = require('agentic.ui.chat_widget'):new(function() return true end)
            widget:show({ focus_prompt = false })
            vim.api.nvim_set_current_win(widget.win_nrs.chat)
            writer = require('agentic.ui.message_writer'):new(widget.buf_nrs.chat)
            writer:write_message_chunk({ sessionUpdate = 'agent_message_chunk', content = {
                type = 'text', text = string.rep('wrapped response ', 500),
            } })
            local row = vim.api.nvim_buf_line_count(widget.buf_nrs.chat)
            vim.api.nvim_win_set_cursor(widget.win_nrs.chat, { row, 500 })
            writer:write_message_chunk({ sessionUpdate = 'agent_message_chunk', content = {
                type = 'text', text = 'tail',
            } })
        ]])
            assert.equal(
                500,
                child.lua_get(
                    "vim.api.nvim_win_get_cursor(widget.win_nrs.chat)[2]"
                )
            )
        end
    )

    it("allows screen-line keys to be remapped", function()
        child.lua([[
            require('agentic').setup({ keymaps = { chat = { next_line = 'J', prev_line = 'K' } } })
            widget = require('agentic.ui.chat_widget'):new(function() return true end)
            require('agentic.utils.buf_helpers').with_modifiable(widget.buf_nrs.chat, function(buf)
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, { string.rep('wrapped text ', 100), 'next' })
            end)
            widget:show({ focus_prompt = false })
            vim.api.nvim_set_current_win(widget.win_nrs.chat)
            vim.cmd('normal! gg0')
        ]])
        assert.is_true(
            child.lua_get(
                'vim.fn.maparg("J", "n", false, true).callback ~= nil'
            )
        )
        child.type_keys("J")
        assert.equal(1, child.lua_get('vim.fn.line(".")'))
        assert.is_true(child.lua_get('vim.fn.col(".") > 1'))
        child.type_keys("K")
        assert.equal(1, child.lua_get('vim.fn.col(".")'))
    end)

    it("moves j/k by display lines while keeping counted motions", function()
        child.lua([[
            widget = require('agentic.ui.chat_widget'):new(function() return true end)
            require('agentic.utils.buf_helpers').with_modifiable(widget.buf_nrs.chat, function(buf)
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
                    string.rep('wrapped paragraph ', 100), 'second', 'third', 'fourth',
                })
            end)
            widget:show({ focus_prompt = false })
            vim.api.nvim_set_current_win(widget.win_nrs.chat)
            vim.cmd('normal! gg0')
        ]])
        child.type_keys("j")
        assert.equal(1, child.lua_get('vim.fn.line(".")'))
        assert.is_true(child.lua_get('vim.fn.col(".") > 1'))
        child.type_keys("k")
        assert.equal(1, child.lua_get('vim.fn.col(".")'))
        child.type_keys("3j")
        assert.equal(4, child.lua_get('vim.fn.line(".")'))
    end)

    it("scrolls within a wrapped paragraph instead of skipping it", function()
        child.lua([[
            widget = require('agentic.ui.chat_widget'):new(function() return true end)
            local buf = widget.buf_nrs.chat
            require('agentic.utils.buf_helpers').with_modifiable(buf, function()
                local lines = { string.rep('wrapped paragraph ', 500) }
                for i = 1, 100 do lines[#lines + 1] = 'following ' .. i end
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
            end)
            widget:show({ focus_prompt = false })
            vim.api.nvim_set_current_win(widget.win_nrs.chat)
            vim.cmd('normal! gg')
            vim.cmd('normal! ' .. string.char(5))
            view = vim.fn.winsaveview()
        ]])
        assert.equal(1, child.lua_get("view.topline"))
        assert.is_true(child.lua_get("view.skipcol > 0"))
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
