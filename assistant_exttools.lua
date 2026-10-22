local koutil = require("util")
local _ = require("assistant_gettext")
local T = require("ffi/util").template
local strbuf = require("string.buffer")
local json = require("rapidjson")
local ASUtils = require("assistant_utils")
local NetUtils = require("assistant_net_utils")
local json_default = ASUtils.json_default

-- ---------------------------------------------------------------------------
-- Search API helpers
-- ---------------------------------------------------------------------------

local SearchToolBase = {
    name = "",
    is_external = false,
}
function SearchToolBase:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end
function SearchToolBase:SearchKeywords(keywords, trap_widget, config)
    return true, ""
end
function SearchToolBase:AccoutInfo()
    return true, T("%1", self.name)
end


local serpapi = SearchToolBase:new({
    name = "SerpAPI",
    is_external = true,
})
function serpapi:SearchKeywords(keywords, trap_widget, config)
    config = config or {}
    local search_url = (config.base_url or "https://serpapi.com") .. "/search"
    local key       = config.api_key
    local q         = koutil.urlEncode(keywords)
    local url       = T("%1?engine=google_ai_mode&api_key=%2&q=%3", search_url, key, q)

    local parsed, err = NetUtils.fetchJSON(url, nil, trap_widget, 45, 120)
    if not parsed then
        if err == NetUtils.HANDLERCODE.CODE_CANCELLED then
            return false, NetUtils.HANDLERCODE.CODE_CANCELLED
        end
        return false, err
    end

    if not parsed.reconstructed_markdown and not parsed.references then
        return false, "No relevant search or AI summary results found."
    end

    local segments = strbuf.new()
    if json_default(parsed.reconstructed_markdown) then
        segments:put("## Google AI Summary:\n")
        segments:put(parsed.reconstructed_markdown)
        segments:put("\n")
    end
    if parsed.references and #parsed.references > 0 then
        segments:put( "## Verified Sources (References):")
        for _, ref in ipairs(parsed.references) do
            local idx         = json_default(ref.index, 0)
            local title       = json_default(ref.title, "Untitled Source")
            local source_name = json_default(ref.source, "Web")
            segments:putf("[%d] %s (%s)", idx, title, source_name)
        end
    end
    segments:put("\n")
    return true, segments:get()
end
function serpapi:AccoutInfo(config)
    config = config or {}
    local acc_url  = (config.base_url or "https://serpapi.com") .. "/account"
    local key      = config.api_key
    local url      = T("%1?api_key=%2", acc_url, key)
    local parsed, err = NetUtils.fetchJSON(url, nil, "loading...", 30, 60)
    if not parsed then
        if err == NetUtils.HANDLERCODE.CODE_CANCELLED then
            return false, NetUtils.HANDLERCODE.CODE_CANCELLED
        end
        return false, err
    end
    local ret = T("SerpAPI\n\n%1/%2\nUsed: %3\nLeft: %4",
        json_default(parsed.plan_name, ""),
        json_default(parsed.account_email, ""),
        json_default(parsed.this_month_usage, ""),
        json_default(parsed.plan_searches_left), "")
    return true, ret
end

local tavily = SearchToolBase:new({
    name = "Tavily",
    is_external = true,
})
function tavily:SearchKeywords(keywords, trap_widget, config)
    config = config or {}
    local search_url = (config.base_url or "https://api.tavily.com") .. "/search"
    local requestBodyTable = {
        api_key              = config.api_key,
        auto_parameters      = true,
        max_results          = 3,
        search_depth         = "basic",
        include_answer       = true,
        include_raw_content  = false,
        query                = keywords,
    }
    local requestBody = json.encode(requestBodyTable)

    local parsed, err = NetUtils.fetchJSON(search_url, nil, trap_widget, 45, 120, requestBody)
    if not parsed then
        if err == NetUtils.HANDLERCODE.CODE_CANCELLED then
            return false, NetUtils.HANDLERCODE.CODE_CANCELLED
        end
        return false, err
    end
    if not parsed.results then
        return false, "fail to parse tavily return"
    end

    local segments = strbuf.new()
    if json_default(parsed.answer) then
        segments:put("## Summary\n")
        segments:put(parsed.answer)
        segments:put("\n")
    end
    segments:put("Here are the verified search results:\n")
    for i, item in ipairs(parsed.results) do
        segments:put("---")
        segments:putf("### Source %d: %s", i, json_default(item.title, "Untitled"))
        -- segments:put( string.format("* URL: %s", json_default(item.url, "N/A")))
        segments:put("* Summary: ")
        segments:put(json_default(item.content, ""))
        segments:put("\n")
    end
    segments:put("\n")
    return true, segments:get()
end

function tavily:AccoutInfo(config)
    config = config or {}
    local acc_url  = (config.base_url or "https://api.tavily.com") .. "/usage"
    local reqHeaders = { ["Authorization"]="Bearer " .. config.api_key }
    local parsed, err = NetUtils.fetchJSON(acc_url, reqHeaders, "loading...", 30, 60)
    if not parsed then
        if err == NetUtils.HANDLERCODE.CODE_CANCELLED then
            return false, NetUtils.HANDLERCODE.CODE_CANCELLED
        end
        return false, err
    end
    local ret = T("Tavily API\n\nPlan: %1\nUsed: %2\nLimits: %3",
        json_default(parsed.account.current_plan, ""),
        json_default(parsed.account.plan_usage, ""),
        json_default(parsed.account.plan_limit), "")
    return true, ret
end

local searxng = SearchToolBase:new({
    name = "SearXNG",
    is_external = true,
})
function searxng:SearchKeywords(keywords, trap_widget, config)
    config = config or {}
    local search_url = (config.base_url or "http://localhost") .. "/search"
    local q        = koutil.urlEncode(keywords)
    local url      = T("%1?q=%2&format=json", search_url, q)

    local parsed, err = NetUtils.fetchJSON(url, nil, trap_widget, 45, 120)
    if not parsed then
        if err == NetUtils.HANDLERCODE.CODE_CANCELLED then
            return false, NetUtils.HANDLERCODE.CODE_CANCELLED
        end
        return false, err
    end
    if not parsed.results then
        return false, "fail to parse searxng return"
    end

    local segments = strbuf.new()
    segments:put("## Web Search Results:\n")
    for i, item in ipairs(parsed.results) do
        segments:put("---")
        segments:putf("### Source %d: %s", i, json_default(item.title, "Untitled"))
        segments:put("* URL: ")
        segments:put(json_default(item.url, "N/A"))
        segments:put("\n")
        segments:put("* Summary: ")
        segments:put(json_default(item.content, ""))
        segments:put("\n")
    end
    segments:put("\n")
    return true, segments:get()
end


local exaai = SearchToolBase:new({
    name = "Exa.ai",
    is_external = true,
})
function exaai:SearchKeywords(keywords, trap_widget, config)
    config = config or {}
    local search_url = (config.base_url or "https://api.exa.ai") .. "/search"
    local requestBodyTable = {
        query      = keywords,
        type       = "auto",
        numResults = 5,
        contents   = {
            highlights = true,
            summary    = true,
        },
    }
    local requestBody = json.encode(requestBodyTable)
    local reqHeaders = { ["x-api-key"] = config.api_key }

    local parsed, err = NetUtils.fetchJSON(search_url, reqHeaders, trap_widget, 45, 120, requestBody)
    if not parsed then
        if err == NetUtils.HANDLERCODE.CODE_CANCELLED then
            return false, NetUtils.HANDLERCODE.CODE_CANCELLED
        end
        return false, err
    end
    if not parsed.results then
        return false, "fail to parse exa.ai return"
    end

    local segments = strbuf.new()
    segments:put("## Exa.ai Search Results:\n\n")
    for i, item in ipairs(parsed.results) do
        segments:put("---")
        segments:putf("### Source %d: %s", i, json_default(item.title, "Untitled"))
        -- segments:put("* URL: ")
        -- segments:put(json_default(item.url, "N/A"))
        segments:put("\n")
        if item.summary then
            segments:put("* Summary: ")
            segments:put(item.summary)
            segments:put("\n")
        end
        if item.highlights and #item.highlights > 0 then
            segments:put("* Key Excerpts:\n")
            for _, hl in ipairs(item.highlights) do
                segments:putf("  - %s", hl)
            end
        end
        if item.subpages and #item.subpages > 0 then
            segments:put("* Subpages:\n")
            for j, sub in ipairs(item.subpages) do
                segments:putf("    %d. **%s**", j, json_default(sub.title, "Untitled"))
                segments:put("\n")
                if sub.summary then
                    segments:putf("       Summary: %s\n", sub.summary)
                end
                if sub.highlights and #sub.highlights > 0 then
                    segments:put("       Excerpts:\n")
                    for _, hl in ipairs(sub.highlights) do
                        segments:putf("         - %s\n", hl)
                    end
                end
            end
        end
        segments:put("\n")
    end
    segments:put("\n")
    return true, segments:get()
end

local parallel = SearchToolBase:new({
    name = "Parallel Search",
    is_external = true,
})

--- Search with Parallel's request-level credentials and optional research objective.
---@param self table Parallel Search provider instance
---@param keywords string Search query keywords
---@param trap_widget table|nil Cancellation widget
---@param config table|nil Request-level provider configuration
---@param objective string|nil Self-contained research goal
---@return boolean ok
---@return string|nil result or error
function parallel:SearchKeywords(keywords, trap_widget, config, objective)
    if type(keywords) ~= "string" or keywords == "" then
        return false, "Search keywords are empty."
    end
    config = config or {}
    local mode = config.mode
    if mode ~= "turbo" and mode ~= "fast" and mode ~= "basic" and mode ~= "advanced" then
        mode = "fast"
    end
    local request_body = json.encode({
        objective = type(objective) == "string" and objective:find("%S") and objective or keywords,
        search_queries = { keywords },
        mode = mode,
        max_chars_total = 6000,
    })
    local base_url = (config.base_url or "https://api.parallel.ai"):gsub("/+$", "")
    local parsed, err = NetUtils.fetchJSON(base_url .. "/v1/search",
        { ["x-api-key"] = config.api_key }, trap_widget, 45, 120, request_body)
    if not parsed then return false, err end
    if type(parsed.results) ~= "table" or #parsed.results == 0 then
        return false, "No Parallel Search results found."
    end

    local segments = strbuf.new()
    segments:put("## Parallel Search Results:\n")
    local result_count = 0
    for i, item in ipairs(parsed.results) do
        if type(item) == "table" then
            local title = type(item.title) == "string" and item.title or nil
            local url = type(item.url) == "string" and item.url or nil
            local publish_date = type(item.publish_date) == "string" and item.publish_date or nil
            local excerpts = {}
            if type(item.excerpts) == "table" then
                for _, excerpt in ipairs(item.excerpts) do
                    if type(excerpt) == "string" and excerpt:find("%S") then
                        table.insert(excerpts, excerpt)
                    end
                end
            end

            local has_content =
                (title and title:find("%S")) or
                (url and url:find("%S")) or
                (publish_date and publish_date:find("%S")) or
                #excerpts > 0
            if has_content then
                result_count = result_count + 1
                segments:putf("### Source %d: %s\n", i,
                    title and title:find("%S") and title or "Untitled")
                if url and url:find("%S") then
                    segments:putf("URL: %s\n", url)
                end
                if publish_date and publish_date:find("%S") then
                    segments:putf("Published: %s\n", publish_date)
                end
                for _, excerpt in ipairs(excerpts) do
                    segments:putf("- %s\n", excerpt)
                end
                segments:put("\n")
            end
        end
    end
    if result_count == 0 then
        return false, "No Parallel Search results found."
    end
    return true, segments:get()
end

return {
    none = SearchToolBase:new{name = _("None")},
    builtin = SearchToolBase:new{name = _("Model Built-In")},
    serpapi   = serpapi,
    tavilyapi = tavily,
    searxngapi = searxng,
    exaapi    = exaai,
    parallelapi = parallel,
}