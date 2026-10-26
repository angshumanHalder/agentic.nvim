if not vim.env.AGENTIC_FOCUS_CHILD then
    local script = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
    local channel = vim.fn.jobstart(
        { vim.v.progpath, "--headless", "--embed", "-u", "NONE", "-i", "NONE" },
        {
            rpc = true,
            env = {
                AGENTIC_FOCUS_CHILD = "1",
                AGENTIC_RENDER = vim.env.AGENTIC_RENDER,
            },
        }
    )
    assert(channel > 0, "Could not start benchmark Neovim")
    vim.rpcrequest(channel, "nvim_ui_attach", 192, 54, { rgb = true })
    local ok, result = pcall(
        vim.rpcrequest,
        channel,
        "nvim_exec_lua",
        "return dofile(...)",
        { script }
    )
    vim.fn.jobstop(channel)
    assert(ok, result)
    print(vim.json.encode(result))
    vim.cmd("qa!")
    return
end

vim.treesitter.language.register("markdown", "AgenticChat")
local render = vim.env.AGENTIC_RENDER == "1"
if render then
    vim.g.render_markdown_config = {
        file_types = { "AgenticChat" },
        overrides = {
            filetype = {
                AgenticChat = {
                    render_modes = true,
                    anti_conceal = { enabled = false },
                    heading = { enabled = false },
                    code = { enabled = false },
                    bullet = { enabled = false },
                    pipe_table = { enabled = true, cell = "padded" },
                },
            },
        },
    }
    vim.cmd.packadd("render-markdown.nvim")
end

local file = vim.api.nvim_get_current_win()
vim.opt.splitright = true
vim.cmd("vsplit")
local chat = vim.api.nvim_get_current_win()
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(chat, buf)
vim.bo[buf].filetype = "AgenticChat"
vim.wo[chat][0].wrap = true
vim.wo[chat][0].linebreak = true
vim.api.nvim_win_set_width(chat, 76)
local lines = {}
for i = 1, 19730 do
    if i % 29 == 0 then
        lines[i] = "```lua"
    elseif i % 29 == 1 then
        lines[i] = "print('response')"
    elseif i % 29 == 2 then
        lines[i] = "```"
    else
        lines[i] =
            "A restored conversation paragraph with a few Markdown tokens."
    end
end
lines[7424] = "| Command | Current issue | Required arity |"
lines[7425] = "|---|---|---|"
lines[7426] =
    "| [`TYPE`](</example/long/path/to/commands.rs:42>) | Extra arguments are ignored | Exactly 1 |"
lines[7427] =
    "| [`BLPOP`](</example/long/path/to/commands.rs:75>) | Missing timeout in the implementation | 2 or more |"
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
vim.treesitter.start(buf, "markdown")
vim.api.nvim_win_set_cursor(chat, { 7424, 0 })
vim.api.nvim_set_current_win(file)
vim.cmd("redraw")
local parses = {}
if render then
    local updater = require("render-markdown.core.ui").updater
    local original = updater.parse
    updater.parse = function(self, callback)
        local start = vim.uv.hrtime()
        local result = original(self, callback)
        parses[#parses + 1] = (vim.uv.hrtime() - start) / 1e6
        return result
    end
end
local start = vim.uv.hrtime()
vim.api.nvim_feedkeys(
    vim.api.nvim_replace_termcodes("<C-w>l", true, false, true),
    "xt",
    false
)
vim.cmd("redraw")
local focus_ms = (vim.uv.hrtime() - start) / 1e6
vim.wait(350)
assert(vim.api.nvim_get_current_win() == chat, "Focus did not reach chat")
if render then
    assert(#parses > 0, "Renderer did not parse during the benchmark")
end
return {
    nvim = vim.version(),
    lines = #lines,
    bytes = vim.api.nvim_buf_get_offset(buf, #lines),
    renderer = render,
    focus_ms = focus_ms,
    render_parse_ms = parses,
}
