local BufHelpers = require("agentic.utils.buf_helpers")

local ChatTable = {}

--- @param text string
--- @param width integer
--- @return string[]
local function wrap_cell(text, width)
    local result = {}
    local line = ""
    for word in text:gmatch("%S+") do
        local candidate = line == "" and word or line .. " " .. word
        if line ~= "" and vim.fn.strdisplaywidth(candidate) > width then
            result[#result + 1] = line
            line = ""
        end
        if vim.fn.strdisplaywidth(word) <= width then
            line = line == "" and word or line .. " " .. word
        else
            for _, char in ipairs(vim.fn.split(word, "\\zs")) do
                if
                    line ~= ""
                    and vim.fn.strdisplaywidth(line .. char) > width
                then
                    result[#result + 1] = line
                    line = ""
                end
                line = line .. char
            end
        end
    end
    result[#result + 1] = line
    return result
end

--- @param rows { cells: string[], delimiter?: boolean, align?: string[] }[]
--- @param max_width integer
--- @return string[] lines
local function layout_rows(rows, max_width)
    local widths = {}
    for _, row in ipairs(rows) do
        for index, value in ipairs(row.cells) do
            widths[index] = math.max(
                widths[index] or 3,
                row.delimiter
                        and 3 + (value:sub(1, 1) == ":" and 1 or 0) + (value:sub(
                            -1
                        ) == ":" and 1 or 0)
                    or vim.fn.strdisplaywidth(value)
            )
        end
    end

    local overhead = 3 * #widths + 1
    local content_width = math.max(#widths, max_width - overhead)
    local total_width = overhead
    for _, width in ipairs(widths) do
        total_width = total_width + width
    end
    while total_width > overhead + content_width do
        local largest
        for index, width in ipairs(widths) do
            if width > 1 and (not largest or width > widths[largest]) then
                largest = index
            end
        end
        if not largest then
            break
        end
        widths[largest] = widths[largest] - 1
        total_width = total_width - 1
    end

    local lines = {}
    for _, row in ipairs(rows) do
        local cells = {}
        local height = 1
        for index, width in ipairs(widths) do
            local value = row.cells[index] or ""
            if row.delimiter then
                local left = value:sub(1, 1) == ":"
                local right = value:sub(-1) == ":"
                local dashes = string.rep(
                    "-",
                    math.max(1, width - (left and 1 or 0) - (right and 1 or 0))
                )
                cells[index] =
                    { (left and ":" or "") .. dashes .. (right and ":" or "") }
            else
                cells[index] = wrap_cell(value, width)
                height = math.max(height, #cells[index])
            end
        end

        for line_index = 1, height do
            local parts = {}
            for index, width in ipairs(widths) do
                local value = cells[index][line_index] or ""
                local padding =
                    math.max(0, width - vim.fn.strdisplaywidth(value))
                local align = row.align and row.align[index] or "left"
                local before = align == "right" and padding
                    or (align == "center" and math.floor(padding / 2) or 0)
                parts[index] = string.rep(" ", before)
                    .. value
                    .. string.rep(" ", padding - before)
            end
            lines[#lines + 1] = "| " .. table.concat(parts, " | ") .. " |"
        end
    end
    return lines
end

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
    for child in node:iter_children() do
        if
            child:type() == "pipe_table_header"
            or child:type() == "pipe_table_row"
            or child:type() == "pipe_table_delimiter_row"
        then
            local row = {
                cells = {},
                delimiter = child:type() == "pipe_table_delimiter_row",
                align = {},
            }
            for cell in child:iter_children() do
                if
                    cell:type() == "pipe_table_cell"
                    or cell:type() == "pipe_table_delimiter_cell"
                then
                    local value = vim.treesitter
                        .get_node_text(cell, bufnr)
                        :gsub("%[([^%]]+)%]%b()", "%1")
                        :gsub("`", "")
                        :gsub("^%s+", "")
                        :gsub("%s+$", "")
                    row.cells[#row.cells + 1] = value
                    if row.delimiter then
                        local left = value:sub(1, 1) == ":"
                        local right = value:sub(-1) == ":"
                        row.align[#row.align + 1] = left and right and "center"
                            or (right and "right" or "left")
                    end
                end
            end
            rows[#rows + 1] = row
        end
    end
    if #rows == 0 then
        return nil
    end
    local alignment = {}
    for _, row in ipairs(rows) do
        if row.delimiter then
            alignment = row.align
            break
        end
    end
    for _, row in ipairs(rows) do
        if not row.delimiter then
            row.align = alignment
        end
    end

    local lines = layout_rows(rows, math.max(1, vim.o.columns - 4))

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = "AgenticTable"
    local width = math.min(
        vim.fn.strdisplaywidth(lines[1]),
        math.max(1, vim.o.columns - 4)
    )
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
