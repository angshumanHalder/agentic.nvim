local BufHelpers = require("agentic.utils.buf_helpers")

local ChatTable = {}

--- @param bufnr integer
--- @return integer|nil winid
function ChatTable.open(bufnr)
    local cursor = vim.api.nvim_win_get_cursor(0)
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "markdown")
    if not ok or not parser then
        return nil
    end
    parser:parse({ cursor[1] - 1, cursor[1] })
    local node = vim.treesitter.get_node({
        bufnr = bufnr,
        pos = { cursor[1] - 1, cursor[2] },
        ignore_injections = true,
    })
    while node and node:type() ~= "pipe_table" do
        node = node:parent()
    end
    if not node then
        return nil
    end

    local rows = {}
    local widths = {}
    for child in node:iter_children() do
        if
            child:type() == "pipe_table_header"
            or child:type() == "pipe_table_row"
        then
            local cells = {}
            for cell in child:iter_children() do
                if cell:type() == "pipe_table_cell" then
                    local value = vim.treesitter
                        .get_node_text(cell, bufnr)
                        :gsub("%[([^%]]+)%]%b()", "%1")
                        :gsub("`", "")
                        :gsub("^%s+", "")
                        :gsub("%s+$", "")
                    cells[#cells + 1] = value
                    widths[#cells] =
                        math.max(widths[#cells] or 0, vim.fn.strwidth(value))
                end
            end
            rows[#rows + 1] = cells
        end
    end
    if #rows == 0 then
        return nil
    end

    local lines = {}
    for _, cells in ipairs(rows) do
        local parts = {}
        for i, value in ipairs(cells) do
            parts[i] = value
                .. string.rep(" ", widths[i] - vim.fn.strwidth(value))
        end
        lines[#lines + 1] = "| " .. table.concat(parts, " | ") .. " |"
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = "AgenticTable"
    local width =
        math.min(vim.fn.strwidth(lines[1]), math.max(1, vim.o.columns - 4))
    local height = math.min(#lines, math.max(1, vim.o.lines - 4))
    local winid = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        style = "minimal",
        border = "rounded",
        width = width,
        height = height,
        row = math.floor((vim.o.lines - height - 2) / 2),
        col = math.floor((vim.o.columns - width - 2) / 2),
    })
    vim.wo[winid][0].wrap = false
    for _, key in ipairs({ "q", "<Esc>" }) do
        BufHelpers.keymap_set(buf, "n", key, function()
            if BufHelpers.is_win_usable(winid) then
                vim.api.nvim_win_close(winid, true)
            end
        end, { desc = "Agentic: Close table" })
    end
    return winid
end

return ChatTable
