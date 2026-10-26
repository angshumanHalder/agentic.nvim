if not vim.env.AGENTIC_BENCH_CHILD then
    local script = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
    local channel = vim.fn.jobstart(
        { vim.v.progpath, "--headless", "--embed", "-u", "NONE", "-i", "NONE" },
        {
            rpc = true,
            env = { AGENTIC_BENCH_CHILD = "1" },
        }
    )
    assert(channel > 0, "Could not start benchmark Neovim")
    vim.rpcrequest(channel, "nvim_ui_attach", 120, 40, { rgb = true })
    local ok, err = pcall(
        vim.rpcrequest,
        channel,
        "nvim_exec_lua",
        "dofile(...)",
        { script }
    )
    vim.fn.jobstop(channel)
    assert(ok, err)
    vim.cmd("qa!")
    return
end
-- Run: timeout 120 nvim --headless -u NONE -i NONE -l scripts/benchmark.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.cmd("syntax enable")
local Writer = require("agentic.ui.message_writer")
local Payloads = require("agentic.acp.acp_payloads")
local Config = require("agentic.config")
Config.auto_scroll = { threshold = 10 }
local results = { nvim = vim.version(), workloads = {} }
local body =
    '# Heading\n\n- list **bold** and *italic* `inline`\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n```lua\nprint("hello")\n```\n'
local function timed(fn)
    collectgarbage("collect")
    local start = vim.uv.hrtime()
    fn()
    return (vim.uv.hrtime() - start) / 1e6
end
for _, count in ipairs({ 100, 100, 500, 1000 }) do
    local samples = {}
    for run = 1, 5 do
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(0, buf)
        vim.bo[buf].syntax = "AgenticChat"
        vim.bo[buf].modifiable = false
        vim.wo[0][0].wrap = true
        local writer = Writer:new(buf)
        writer:set_provider_name("mock")
        local messages = {}
        for i = 1, count do
            if i % 10 == 0 then
                messages[i] = {
                    type = "tool_call",
                    tool_call_id = "tool-" .. i,
                    kind = "read",
                    argument = "README.md",
                    status = "completed",
                    body = { "file contents" },
                }
            else
                messages[i] = {
                    type = i % 2 == 0 and "agent" or "user",
                    text = body,
                    provider_name = "mock",
                }
            end
        end
        local copied, writes, marks = 0, 0, 0
        local get_lines = vim.api.nvim_buf_get_lines
        local set_lines = vim.api.nvim_buf_set_lines
        local set_mark = vim.api.nvim_buf_set_extmark
        vim.api.nvim_buf_get_lines = function(...)
            local lines = get_lines(...)
            copied = copied + #lines
            return lines
        end
        vim.api.nvim_buf_set_lines = function(...)
            writes = writes + 1
            return set_lines(...)
        end
        vim.api.nvim_buf_set_extmark = function(...)
            marks = marks + 1
            return set_mark(...)
        end
        local load_ms = timed(function()
            writer:replay_history_messages(messages)
            vim.cmd("redraw")
        end)
        vim.api.nvim_buf_get_lines = get_lines
        vim.api.nvim_buf_set_lines = set_lines
        vim.api.nvim_buf_set_extmark = set_mark
        local scroll_ms = timed(function()
            vim.cmd("normal! gg")
            for _ = 1, 100 do
                vim.cmd("normal! " .. string.char(6))
                vim.cmd("redraw")
            end
        end)
        vim.cmd("normal! G0zb")
        local stream_ms = timed(function()
            for token = 1, 1000 do
                writer:write_message_chunk(
                    Payloads.generate_agent_message(" token")
                )
                if token % 16 == 0 then
                    vim.cmd("redraw")
                end
            end
        end)
        local other = vim.api.nvim_create_buf(false, true)
        local switch_ms = timed(function()
            for _ = 1, 100 do
                vim.api.nvim_win_set_buf(0, other)
                vim.api.nvim_win_set_buf(0, buf)
                vim.cmd("redraw")
            end
        end)
        assert(
            vim.api.nvim_buf_line_count(buf) > count,
            "History was not rendered"
        )
        assert(not vim.bo[buf].modifiable, "Output became editable")
        collectgarbage("collect")
        samples[run] = {
            load_ms = load_ms,
            scroll_100_ms = scroll_ms,
            stream_1000_ms = stream_ms,
            switch_100_ms = switch_ms,
            copied_lines = copied,
            line_writes = writes,
            extmark_writes = marks,
            lua_kib = collectgarbage("count"),
            rss_bytes = vim.uv.resident_set_memory(),
            buffer_bytes = vim.api.nvim_buf_get_offset(
                buf,
                vim.api.nvim_buf_line_count(buf)
            ),
        }
        writer:destroy()
        vim.api.nvim_buf_delete(buf, { force = true })
        vim.api.nvim_buf_delete(other, { force = true })
    end
    results.workloads[tostring(count)] = samples
end
local ChatWidget = require("agentic.ui.chat_widget")
local Registry = require("agentic.session_registry")
results.session_switch = {}
for _, count in ipairs({ 100, 500, 1000 }) do
    local samples = {}
    for run = 1, 5 do
        local first = ChatWidget:new(function()
            return true
        end)
        local second = ChatWidget:new(function()
            return true
        end)
        local writer = Writer:new(first.buf_nrs.chat)
        local messages = {}
        for i = 1, count do
            messages[i] = {
                type = i % 2 == 0 and "agent" or "user",
                text = body,
                provider_name = "mock",
            }
        end
        writer:replay_history_messages(messages)
        Registry.sessions[1] = { session_key = 1, widget = first }
        Registry.sessions[2] = { session_key = 2, widget = second }
        Registry.show_session(1, { focus_prompt = false })
        samples[run] = timed(function()
            for _ = 1, 10 do
                Registry.show_session(2, { focus_prompt = false })
                Registry.show_session(1, { focus_prompt = false })
                vim.cmd("redraw")
            end
        end)
        assert(
            first:get_visible_tab_id() ~= nil,
            "Target session was not shown"
        )
        assert(
            second:get_visible_tab_id() == nil,
            "Outgoing session stayed visible"
        )
        writer:destroy()
        Registry.sessions = {}
        Registry._most_recent = nil
        Registry._previous_most_recent = nil
        first:destroy()
        second:destroy()
    end
    results.session_switch[tostring(count)] = samples
end
local wrapped_widget = ChatWidget:new(function()
    return true
end)
local wrapped_buf = wrapped_widget.buf_nrs.chat
require("agentic.utils.buf_helpers").with_modifiable(wrapped_buf, function()
    local lines = {}
    for i = 1, 1000 do
        lines[i] = string.rep("wrapped paragraph text ", 150) .. i
    end
    vim.api.nvim_buf_set_lines(wrapped_buf, 0, -1, false, lines)
end)
wrapped_widget:show({ focus_prompt = false })
local wrapped_win = wrapped_widget.win_nrs.chat
vim.api.nvim_set_current_win(wrapped_win)
vim.cmd("normal! gg0")
vim.api.nvim_feedkeys("j", "xt", false)
results.wrapped_navigation = {
    width = vim.api.nvim_win_get_width(wrapped_win),
    smoothscroll = vim.wo[wrapped_win].smoothscroll,
    first_j_cursor = vim.api.nvim_win_get_cursor(wrapped_win),
    samples = {},
}
for run = 1, 5 do
    vim.cmd("normal! gg0")
    local worst_ms = 0
    local elapsed = timed(function()
        for _ = 1, 100 do
            local step = vim.uv.hrtime()
            vim.api.nvim_feedkeys("j", "xt", false)
            vim.cmd("redraw")
            worst_ms = math.max(worst_ms, (vim.uv.hrtime() - step) / 1e6)
        end
    end)
    results.wrapped_navigation.samples[run] =
        { total_ms = elapsed, worst_ms = worst_ms }
end
assert(
    vim.bo[wrapped_buf].modifiable == false,
    "Scrolling made output editable"
)
wrapped_widget:destroy()
local ACPClient = require("agentic.acp.acp_client")
local agent = setmetatable({
    agent_capabilities = {
        loadSession = true,
        sessionCapabilities = { list = {} },
    },
}, { __index = ACPClient })
local pages, discovered = 0, 0
function agent:when_ready(callback)
    callback()
end
function agent:_send_request(method, params, callback)
    assert(method == "session/list", "Unexpected ACP request")
    local page = tonumber(params.cursor) or 1
    pages = pages + 1
    assert(pages <= 10, "Pagination did not terminate")
    local sessions = {}
    for i = 1, 100 do
        sessions[i] = { sessionId = page .. "-" .. i, cwd = vim.fn.getcwd() }
    end
    callback({
        sessions = sessions,
        nextCursor = page < 10 and tostring(page + 1) or nil,
    })
end
require("agentic.acp.agent_instance").get_instance = function()
    return agent
end
require("agentic.session_registry").current = function()
    return nil
end
vim.schedule = function(callback)
    callback()
end
vim.ui.select = function(items, _, callback)
    local last = items[#items]
    if last and last.cursor then
        callback(last)
    else
        discovered = #items
    end
end
results.pagination = {
    elapsed_ms = timed(function()
        require("agentic.session_restore").show_picker()
    end),
}
results.pagination.pages = pages
results.pagination.sessions = discovered
assert(discovered == pages * 100, "Picker lost sessions")
local output = vim.env.AGENTIC_BENCH_OUTPUT
    or "/private/tmp/agentic-benchmark.json"
vim.fn.writefile({ vim.json.encode(results) }, output)
print(output)
