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

    local rendered = {}
    local wrapped = false
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
        wrapped = wrapped or height > 1

        local lines = {}
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
        rendered[#rendered + 1] = lines
    end

    -- Wrapped cells hide row boundaries; separate body rows when any wraps.
    local separator = {}
    for index, width in ipairs(widths) do
        separator[index] = string.rep("-", width)
    end
    local lines = {}
    for index, row_lines in ipairs(rendered) do
        if wrapped and index > 3 then
            lines[#lines + 1] = "| " .. table.concat(separator, " | ") .. " |"
        end
        vim.list_extend(lines, row_lines)
    end
    return lines
end

--- @param line string|nil
--- @return boolean
local function is_row(line)
    return line ~= nil and line:find("|", 1, true) ~= nil
end

--- @param line string|nil
--- @return boolean
local function is_delimiter(line)
    return line ~= nil
        and is_row(line)
        and line:find("-", 1, true) ~= nil
        and line:match("^[%s|:%-]+$") ~= nil
end

--- @param line string
--- @return string[] cells
local function split_cells(line)
    local cells = {}
    local body = line:gsub("\\|", "\0"):gsub("^%s*|", ""):gsub("|%s*$", "")
    for cell in (body .. "|"):gmatch("([^|]*)|") do
        -- Link destinations would dominate narrow columns; keep the label.
        local text = cell:gsub("%z", "\\|"):gsub("%[([^%]]+)%]%b()", "%1")
        cells[#cells + 1] = vim.trim(text)
    end
    return cells
end

--- @param lines string[] header, delimiter, then body rows
--- @param width integer
--- @return string[] lines
local function render_table(lines, width)
    local align = {}
    for index, cell in ipairs(split_cells(lines[2])) do
        local left = cell:sub(1, 1) == ":"
        local right = cell:sub(-1) == ":"
        align[index] = left and right and "center"
            or (right and "right" or "left")
    end
    local rows = {}
    for index, line in ipairs(lines) do
        rows[index] = {
            cells = split_cells(line),
            delimiter = index == 2,
            align = align,
        }
    end
    return layout_rows(rows, width)
end

--- Aligns GFM pipe tables outside code fences, wrapping cells to `width`.
--- Unless `final`, a table or a possible header at the end of `lines` may
--- still grow, so processing stops before it.
--- @param lines string[]
--- @param width integer
--- @param in_fence boolean
--- @param final boolean
--- @return string[] rendered Replacement for the first `consumed` lines
--- @return integer consumed
--- @return boolean in_fence Fence state after the consumed lines
function ChatTable.render(lines, width, in_fence, final)
    local rendered = {}
    local index = 1
    while index <= #lines do
        local line = lines[index]
        local is_fence = line:match("^%s*```") or line:match("^%s*~~~")
        local may_start = not in_fence and not is_fence and is_row(line)
        if may_start and lines[index + 1] == nil and not final then
            break
        elseif may_start and is_delimiter(lines[index + 1]) then
            local stop = index + 2
            while is_row(lines[stop]) do
                stop = stop + 1
            end
            if lines[stop] == nil and not final then
                break
            end
            vim.list_extend(
                rendered,
                render_table(vim.list_slice(lines, index, stop - 1), width)
            )
            index = stop
        else
            if is_fence then
                -- ponytail: any fence toggles; nested fences of mixed length are rare in chat
                in_fence = not in_fence
            end
            rendered[#rendered + 1] = line
            index = index + 1
        end
    end
    return rendered, index - 1, in_fence
end

return ChatTable
