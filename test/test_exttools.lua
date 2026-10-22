-- test_exttools.lua
-- Tests for assistant_exttools.lua: SerpAPI, Tavily, SearXNG, Exa.ai, Parallel Search, and SearchToolBase.
local helper = require("test.helper")
local assert = helper.assert
local extools = helper.extools
local json = require("rapidjson")

local function test(name, fn)
    return { name = name, fn = fn }
end

local function withFetchJSON(response, callback)
    local original = helper.NetUtils.fetchJSON
    local calls = {}
    helper.NetUtils.fetchJSON = function(url, headers, trap_widget, timeout, maxtime, post_body)
        table.insert(calls, {
            url = url,
            headers = headers,
            trap_widget = trap_widget,
            timeout = timeout,
            maxtime = maxtime,
            post_body = post_body,
        })
        return response.parsed, response.err
    end
    local ok, first, second = pcall(callback, calls)
    helper.NetUtils.fetchJSON = original
    if not ok then error(first) end
    return first, second, calls
end

local tests = {

    -- =========================================================================
    -- SearchToolBase (none, builtin)
    -- =========================================================================

    test("SearchToolBase: SearchKeywords returns empty string", function()
        local ok, result = extools.none:SearchKeywords("test query")
        assert.equal(ok, true, "SearchKeywords should return ok=true")
        assert.equal(result, "", "SearchKeywords should return empty string")
    end),

    test("SearchToolBase: AccoutInfo returns the display name", function()
        local ok, result = extools.none:AccoutInfo()
        assert.equal(ok, true)
        assert.notNil(result)
    end),

    test("SearchToolBase: builtin instance exists", function()
        assert.isTrue(extools.builtin ~= nil)
        assert.equal(extools.builtin.name, "Model Built-In")
    end),

    -- =========================================================================
    -- SerpAPI: SearchKeywords
    -- =========================================================================

    test("SerpAPI: successful search with reconstructed_markdown", function()
        helper.mockFetchJSON({
            { parsed = {
                reconstructed_markdown = "AI summary text",
                references = {},
            }, err = nil },
        })
        local ok, result = extools.serpapi:SearchKeywords("test query")
        assert.isTrue(ok)
        assert.matches(result, "Google AI Summary")
        assert.matches(result, "AI summary text")
    end),

    test("SerpAPI: successful search with references", function()
        helper.mockFetchJSON({
            { parsed = {
                reconstructed_markdown = nil,
                references = {
                    { index = 1, title = "Source One", source = "Web" },
                    { index = 2, title = "Source Two", source = "Blog" },
                },
            }, err = nil },
        })
        local ok, result = extools.serpapi:SearchKeywords("test query")
        assert.isTrue(ok)
        assert.matches(result, "Verified Sources")
        assert.matches(result, "Source One")
        assert.matches(result, "Source Two")
    end),

    test("SerpAPI: no results returns error", function()
        helper.mockFetchJSON({
            { parsed = {}, err = nil },
        })
        local ok, err = extools.serpapi:SearchKeywords("test query")
        assert.isFalse(ok)
        assert.matches(err, "No relevant search")
    end),

    test("SerpAPI: network error", function()
        helper.mockFetchJSON({
            { parsed = nil, err = "NETWORK_ERROR" },
        })
        local ok, err = extools.serpapi:SearchKeywords("test query")
        assert.isFalse(ok)
        assert.equal(err, "NETWORK_ERROR")
    end),

    test("SerpAPI: cancelled by user", function()
        local CODE_CANCELLED = helper.NetUtils.HANDLERCODE.CODE_CANCELLED
        helper.mockFetchJSON({
            { parsed = nil, err = CODE_CANCELLED },
        })
        local ok, err = extools.serpapi:SearchKeywords("test query")
        assert.isFalse(ok)
        assert.equal(err, CODE_CANCELLED)
    end),

    -- =========================================================================
    -- Tavily: SearchKeywords
    -- =========================================================================

    test("Tavily: successful search with answer and results", function()
        helper.mockFetchJSON({
            { parsed = {
                answer = "Tavily summary text",
                results = {
                    { title = "Result 1", content = "Content 1" },
                    { title = "Result 2", content = "Content 2" },
                },
            }, err = nil },
        })
        local ok, result = extools.tavilyapi:SearchKeywords("test query")
        assert.isTrue(ok)
        assert.matches(result, "Summary")
        assert.matches(result, "Tavily summary text")
        assert.matches(result, "Source 1")
        assert.matches(result, "Result 1")
        assert.matches(result, "Source 2")
    end),

    test("Tavily: search without answer still succeeds", function()
        helper.mockFetchJSON({
            { parsed = {
                results = {
                    { title = "Only Result", content = "Content" },
                },
            }, err = nil },
        })
        local ok, result = extools.tavilyapi:SearchKeywords("test query")
        assert.isTrue(ok)
        assert.notMatches(result, "## Summary") -- AI-answer section should be absent
        assert.matches(result, "verified search results")
    end),

    test("Tavily: missing results field returns error", function()
        helper.mockFetchJSON({
            { parsed = {}, err = nil },
        })
        local ok, err = extools.tavilyapi:SearchKeywords("test query")
        assert.isFalse(ok)
        assert.equal(err, "fail to parse tavily return")
    end),

    test("Tavily: network error", function()
        helper.mockFetchJSON({
            { parsed = nil, err = "NETWORK_ERROR" },
        })
        local ok, err = extools.tavilyapi:SearchKeywords("test query")
        assert.isFalse(ok)
        assert.equal(err, "NETWORK_ERROR")
    end),

    test("Tavily: cancelled by user", function()
        local CODE_CANCELLED = helper.NetUtils.HANDLERCODE.CODE_CANCELLED
        helper.mockFetchJSON({
            { parsed = nil, err = CODE_CANCELLED },
        })
        local ok, err = extools.tavilyapi:SearchKeywords("test query")
        assert.isFalse(ok)
        assert.equal(err, CODE_CANCELLED)
    end),

    -- =========================================================================
    -- SearXNG: SearchKeywords
    -- =========================================================================

    test("SearXNG: successful search with results", function()
        helper.mockFetchJSON({
            { parsed = {
                results = {
                    { title = "Page 1", url = "https://example.com/1", content = "Content 1" },
                    { title = "Page 2", url = "https://example.com/2", content = "Content 2" },
                },
            }, err = nil },
        })
        local ok, result = extools.searxngapi:SearchKeywords("test query")
        assert.isTrue(ok)
        assert.matches(result, "Web Search Results")
        assert.matches(result, "Page 1")
        assert.matches(result, "https://example.com/1")
        assert.matches(result, "Page 2")
    end),

    test("SearXNG: missing results field returns error", function()
        helper.mockFetchJSON({
            { parsed = {}, err = nil },
        })
        local ok, err = extools.searxngapi:SearchKeywords("test query")
        assert.isFalse(ok)
        assert.equal(err, "fail to parse searxng return")
    end),

    test("SearXNG: network error", function()
        helper.mockFetchJSON({
            { parsed = nil, err = "NETWORK_ERROR" },
        })
        local ok, err = extools.searxngapi:SearchKeywords("test query")
        assert.isFalse(ok)
        assert.equal(err, "NETWORK_ERROR")
    end),

    -- =========================================================================
    -- Exa.ai: SearchKeywords
    -- =========================================================================

    test("Exa.ai: successful search with summary and highlights", function()
        helper.mockFetchJSON({
            { parsed = {
                results = {
                    {
                        title = "Doc 1",
                        summary = "Summary of doc 1",
                        highlights = { "highlight 1a", "highlight 1b" },
                    },
                },
            }, err = nil },
        })
        local ok, result = extools.exaapi:SearchKeywords("test query")
        assert.isTrue(ok)
        assert.matches(result, "Exa.ai Search Results")
        assert.matches(result, "Doc 1")
        assert.matches(result, "Summary of doc 1")
        assert.matches(result, "highlight 1a")
        assert.matches(result, "highlight 1b")
    end),

    test("Exa.ai: search with subpages", function()
        helper.mockFetchJSON({
            { parsed = {
                results = {
                    {
                        title = "Main Doc",
                        summary = "Main summary",
                        subpages = {
                            {
                                title = "Subpage 1",
                                summary = "Sub summary",
                                highlights = { "sub highlight" },
                            },
                        },
                    },
                },
            }, err = nil },
        })
        local ok, result = extools.exaapi:SearchKeywords("test query")
        assert.isTrue(ok)
        assert.matches(result, "Subpage 1")
        assert.matches(result, "Sub summary")
        assert.matches(result, "sub highlight")
    end),

    test("Exa.ai: missing results field returns error", function()
        helper.mockFetchJSON({
            { parsed = {}, err = nil },
        })
        local ok, err = extools.exaapi:SearchKeywords("test query")
        assert.isFalse(ok)
        assert.equal(err, "fail to parse exa.ai return")
    end),

    test("Exa.ai: network error", function()
        helper.mockFetchJSON({
            { parsed = nil, err = "NETWORK_ERROR" },
        })
        local ok, err = extools.exaapi:SearchKeywords("test query")
        assert.isFalse(ok)
        assert.equal(err, "NETWORK_ERROR")
    end),

    test("Exa.ai: cancelled by user", function()
        local CODE_CANCELLED = helper.NetUtils.HANDLERCODE.CODE_CANCELLED
        helper.mockFetchJSON({
            { parsed = nil, err = CODE_CANCELLED },
        })
        local ok, err = extools.exaapi:SearchKeywords("test query")
        assert.isFalse(ok)
        assert.equal(err, CODE_CANCELLED)
    end),

    -- =========================================================================
    -- Module return table shape
    -- =========================================================================

    test("module exports all tools", function()
        assert.notNil(extools.none)
        assert.notNil(extools.builtin)
        assert.notNil(extools.serpapi)
        assert.notNil(extools.tavilyapi)
        assert.notNil(extools.searxngapi)
        assert.notNil(extools.exaapi)
    end),

    test("all tools have expected properties", function()
        local tools = { "serpapi", "tavilyapi", "searxngapi", "exaapi" }
        for _, key in ipairs(tools) do
            local tool = extools[key]
            assert.notNil(tool, key .. " should exist")
            assert.notNil(tool.name, key .. " should have name")
            assert.isTrue(tool.is_external, key .. " should be external")
            assert.equal(tool.api_key, nil, key .. " should not retain an API key")
            assert.equal(tool.base_url, nil, key .. " should not retain a base URL")
        end
    end),

    test("search clients accept request-level configuration snapshots", function()
        local config = {
            serpapi = { api_key = "test-key", base_url = "https://serpapi.com" },
            tavilyapi = { api_key = "test-key", base_url = "https://api.tavily.com" },
            searxngapi = { base_url = "http://localhost:8888" },
            exaapi = { api_key = "test-key", base_url = "https://api.exa.ai" },
            parallelapi = { api_key = "test-key", mode = "fast" },
        }
        helper.mockFetchJSON({
            { parsed = { reconstructed_markdown = "result", references = {} } },
            { parsed = { answer = "answer", results = {} } },
            { parsed = { results = {} } },
            { parsed = { results = {} } },
            { parsed = { results = { { title = "Parallel result" } } } },
        })
        for _, key in ipairs({ "serpapi", "tavilyapi", "searxngapi", "exaapi", "parallelapi" }) do
            local ok, err = extools[key]:SearchKeywords("test query", nil, config[key])
            assert.isTrue(ok, key .. " should accept its request snapshot: " .. tostring(err))
        end
    end),

    test("Parallel Search sends a separate objective and request snapshot", function()
        local trap_widget = { id = "search-indicator" }
        local ok, result, calls = withFetchJSON({ parsed = { results = {
            { title = "Policy", url = "https://example.com/policy", excerpts = { "Relevant passage" } },
        } } }, function()
            return extools.parallelapi:SearchKeywords("solar storage policy", trap_widget, {
                api_key = "parallel-test-key",
                base_url = "https://parallel.example/",
                mode = "basic",
            }, "Find current residential solar storage policies")
        end)

        assert.isTrue(ok)
        assert.isTrue(result:find("https://example.com/policy", 1, true) ~= nil)
        assert.equal(#calls, 1)
        assert.equal(calls[1].url, "https://parallel.example/v1/search")
        assert.equal(calls[1].headers["x-api-key"], "parallel-test-key")
        assert.equal(calls[1].trap_widget, trap_widget)
        assert.equal(calls[1].timeout, 45)
        assert.equal(calls[1].maxtime, 120)
        local body = json.decode(calls[1].post_body)
        assert.equal(body.objective, "Find current residential solar storage policies")
        assert.equal(body.mode, "basic")
        assert.equal(body.search_queries[1], "solar storage policy")
        assert.equal(#body.search_queries, 1)
        assert.equal(body.max_chars_total, 6000)
    end),

    test("Parallel Search uses the official endpoint and fast mode by default", function()
        local ok, _, calls = withFetchJSON({ parsed = { results = {
            { title = "Result", url = "https://example.com" },
        } } }, function()
            return extools.parallelapi:SearchKeywords("battery recycling market", nil, { api_key = "parallel-test-key" })
        end)
        assert.isTrue(ok)
        assert.equal(calls[1].url, "https://api.parallel.ai/v1/search")
        local body = json.decode(calls[1].post_body)
        assert.equal(body.mode, "fast")
        assert.equal(body.objective, "battery recycling market")
    end),

    test("Parallel Search falls back to fast for an unsupported mode and blank objective", function()
        local ok, _, calls = withFetchJSON({ parsed = { results = {
            { title = "Result", url = "https://example.com" },
        } } }, function()
            return extools.parallelapi:SearchKeywords("grid storage", nil, {
                api_key = "key",
                mode = "unsupported",
            }, "  \t ")
        end)
        assert.isTrue(ok)
        local body = json.decode(calls[1].post_body)
        assert.equal(body.mode, "fast")
        assert.equal(body.objective, "grid storage")
    end),

    test("Parallel Search renders every result and excerpt in ranked order", function()
        local results = {
            { title = "First", url = "https://example.com/1", publish_date = "2026-01-01", excerpts = { "first excerpt one", "first excerpt two", "first excerpt three" } },
        }
        for i = 2, 6 do
            table.insert(results, { title = "Result " .. i, url = "https://example.com/" .. i, excerpts = { "excerpt " .. i } })
        end
        local ok, rendered = withFetchJSON({ parsed = { results = results } }, function()
            return extools.parallelapi:SearchKeywords("solar storage policy", nil, { api_key = "key" })
        end)
        assert.isTrue(ok)
        for i = 1, 6 do
            assert.isTrue(rendered:find("Source " .. i, 1, true) ~= nil)
            assert.isTrue(rendered:find("https://example.com/" .. i, 1, true) ~= nil)
        end
        for _, excerpt in ipairs({ "first excerpt one", "first excerpt two", "first excerpt three", "excerpt 6" }) do
            assert.isTrue(rendered:find(excerpt, 1, true) ~= nil)
        end
        assert.isTrue(rendered:find("Published: 2026-01-01", 1, true) ~= nil)
        local first = rendered:find("first excerpt one", 1, true)
        local second = rendered:find("first excerpt two", 1, true)
        local third = rendered:find("first excerpt three", 1, true)
        assert.isTrue(first < second and second < third)
    end),

    test("Parallel Search ignores null fields and rejects unrenderable results", function()
        local ok, rendered = withFetchJSON({ parsed = { results = {
            { title = json.null, url = json.null, publish_date = json.null, excerpts = { "usable excerpt", json.null, 42 } },
        } } }, function()
            return extools.parallelapi:SearchKeywords("public transport funding", nil, { api_key = "key" })
        end)
        assert.isTrue(ok)
        assert.isTrue(rendered:find("Untitled", 1, true) ~= nil)
        assert.isTrue(rendered:find("usable excerpt", 1, true) ~= nil)
        assert.isTrue(rendered:find("Published:", 1, true) == nil)

        local empty_ok, empty_err = withFetchJSON({ parsed = { results = {} } }, function()
            return extools.parallelapi:SearchKeywords("public transport funding", nil, { api_key = "key" })
        end)
        local malformed_ok, malformed_err = withFetchJSON({ parsed = { results = "not-an-array" } }, function()
            return extools.parallelapi:SearchKeywords("public transport funding", nil, { api_key = "key" })
        end)
        assert.isFalse(empty_ok)
        assert.equal(empty_err, "No Parallel Search results found.")
        assert.isFalse(malformed_ok)
        assert.equal(malformed_err, "No Parallel Search results found.")
    end),

    test("Parallel Search preserves network and cancellation errors", function()
        local _, network_err = withFetchJSON({ parsed = nil, err = "NETWORK_ERROR" }, function()
            return extools.parallelapi:SearchKeywords("public transport funding", nil, { api_key = "key" })
        end)
        local _, http_err = withFetchJSON({ parsed = nil, err = "HTTP Status 503: Parallel unavailable" }, function()
            return extools.parallelapi:SearchKeywords("public transport funding", nil, { api_key = "key" })
        end)
        local _, cancelled_err = withFetchJSON({ parsed = nil, err = helper.NetUtils.HANDLERCODE.CODE_CANCELLED }, function()
            return extools.parallelapi:SearchKeywords("public transport funding", nil, { api_key = "key" })
        end)
        assert.equal(network_err, "NETWORK_ERROR")
        assert.equal(http_err, "HTTP Status 503: Parallel unavailable")
        assert.equal(cancelled_err, helper.NetUtils.HANDLERCODE.CODE_CANCELLED)
    end),

    test("Parallel Search provider singleton does not store credentials", function()
        assert.notNil(extools.parallelapi)
        assert.equal(extools.parallelapi.api_key, nil)
        assert.equal(extools.parallelapi.base_url, nil)
        assert.equal(extools.parallelapi.mode, nil)
    end),
}

return helper.runTests("assistant_exttools.lua", tests)