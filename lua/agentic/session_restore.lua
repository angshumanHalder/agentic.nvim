local Logger = require("agentic.utils.logger")
local Config = require("agentic.config")
local AgentInstance = require("agentic.acp.agent_instance")
local SessionRegistry = require("agentic.session_registry")

--- @class agentic.SessionRestoreContext
--- @field agent agentic.acp.ACPClient
--- @field provider_name agentic.UserConfig.ProviderName
--- @field source? agentic.SessionManager

--- @class agentic.SessionRestore
local SessionRestore = {}

--- @return agentic.SessionRestoreContext|nil context
local function resolve_context()
    local source = SessionRegistry.current()
    if source then
        return {
            agent = source.agent,
            provider_name = source.provider_name,
            source = source,
        }
    end

    local agent = AgentInstance.get_instance(Config.provider)
    if not agent then
        return nil
    end

    return {
        agent = agent,
        provider_name = Config.provider,
    }
end

--- @param operation string
--- @return fun(err: agentic.acp.ACPError) callback
local function notify_readiness_failure(operation)
    return function(err)
        Logger.notify(
            "Failed to "
                .. operation
                .. ": "
                .. (err.message or "provider unavailable"),
            vim.log.levels.WARN
        )
    end
end

--- @param item { display: string, session_id?: string }
--- @param supports_chunks boolean|nil
--- @return string label
local function format_picker_item(item, supports_chunks)
    if not item.session_id then
        return item.display
    end
    return supports_chunks and item.display
        or item.display .. " " .. item.session_id
end

--- @param context agentic.SessionRestoreContext
--- @param session_id string
--- @param title string|nil
--- @param timestamp string|integer|nil
local function restore(context, session_id, title, timestamp)
    --- @type agentic.SessionStartSpec
    local start_spec = {
        kind = "load",
        session_id = session_id,
        title = title,
        timestamp = timestamp,
    }

    -- Only a fresh target issues `session/load`; an existing manager can be
    -- shown without the provider advertising load support.
    local existing =
        SessionRegistry.find_by_acp_session_id(session_id, context.agent)
    if not existing then
        local capabilities = context.agent.agent_capabilities
        if not capabilities or not capabilities.loadSession then
            Logger.notify(
                "Agent does not support loading sessions",
                vim.log.levels.WARN
            )
            return
        end
    end

    SessionRegistry.choose_session_lifecycle(
        context.source,
        "Restore session:",
        function(destroy_source)
            --- @type agentic.SessionReplacementOpts
            local opts = { agent = context.agent }
            if context.source and not destroy_source then
                opts.retain_source = true
            end

            SessionRegistry.replace(
                context.source,
                context.provider_name,
                start_spec,
                opts
            )
        end
    )
end

function SessionRestore.show_picker()
    local context = resolve_context()
    if not context then
        return
    end

    local cwd = vim.fn.getcwd()
    local items, seen, cursors = {}, {}, {}
    local fetch_page
    local function show_page(cursor)
        local choices = vim.list_extend({}, items)
        if cursor then
            choices[#choices + 1] =
                { display = "Load more sessions…", cursor = cursor }
        end
        if #choices == 0 then
            Logger.notify("No saved sessions found", vim.log.levels.INFO)
            return
        end
        vim.schedule(function()
            vim.ui.select(choices, {
                prompt = "Select session to restore:",
                format_item = format_picker_item,
            }, function(choice)
                if not choice then
                    return
                end
                if choice.cursor then
                    fetch_page(choice.cursor)
                else
                    restore(
                        context,
                        choice.session_id,
                        choice.title,
                        choice.updated_at
                    )
                end
            end)
        end)
    end
    fetch_page = function(cursor)
        context.agent:list_sessions(cwd, function(result, err)
            if err or not result then
                Logger.notify(
                    "Failed to list sessions: "
                        .. (err and err.message or "unknown error"),
                    vim.log.levels.WARN
                )
                if #items > 0 then
                    show_page(cursor)
                end
                return
            end

            if cursor then
                cursors[cursor] = true
            end
            for _, session in ipairs(result.sessions) do
                if not seen[session.sessionId] then
                    seen[session.sessionId] = true
                    local date = session.updatedAt
                            and session.updatedAt:sub(1, 16):gsub("T", " ")
                        or "unknown date"
                    local title = (session.title or "(no title)")
                        :gsub("\r\n", " ")
                        :gsub("[\r\n]", " ")
                        :sub(1, 80)
                    items[#items + 1] = {
                        display = string.format(
                            "%s - %s - %s",
                            date,
                            session.sessionId:sub(1, 8),
                            title
                        ),
                        session_id = session.sessionId,
                        title = session.title,
                        updated_at = session.updatedAt,
                    }
                end
            end

            local next_cursor = result.nextCursor
            if next_cursor and cursors[next_cursor] then
                Logger.notify(
                    "Agent repeated a session pagination cursor",
                    vim.log.levels.WARN
                )
                next_cursor = nil
            end
            show_page(next_cursor)
        end, cursor)
    end
    context.agent:when_ready(function()
        fetch_page(nil)
    end, notify_readiness_failure("list sessions"))
end

--- @param session_id string
function SessionRestore.restore_by_id(session_id)
    local context = resolve_context()
    if not context then
        return
    end

    context.agent:when_ready(function()
        restore(context, session_id, nil, nil)
    end, notify_readiness_failure("restore session"))
end

return SessionRestore
