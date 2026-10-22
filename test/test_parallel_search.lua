local helper = require("test.helper")
local assert = helper.assert
local ToolExecutor = require("assistant_tool_executor")
local json = require("rapidjson")
local ExtTools = helper.extools
local OpenAIHandler = require("api_handlers.openai")
local AnthropicHandler = require("api_handlers.anthropic")
local GeminiHandler = require("api_handlers.gemini")
local ResponsesHandler = require("api_handlers.responses")

local function test(name, fn)
    return { name = name, fn = fn }
end

local function mockAssistant(providers)
    return {
        config = {
            getProvider = function(_, key)
                return providers[key]
            end,
        },
    }
end

local function withSearchMethod(key, replacement, callback)
    local original = ExtTools[key].SearchKeywords
    ExtTools[key].SearchKeywords = replacement
    local ok, first, second = pcall(callback)
    ExtTools[key].SearchKeywords = original
    if not ok then error(first) end
    return first, second
end

local function captureHandlerBody(handler_module, fields, mode)
    local handler = handler_module:new(fields)
    local request_body
    handler.backgroundRequest = function(_, _, _, body)
        request_body = json.decode(body)
        return function() end
    end
    handler:query({ { role = "user", content = "Current energy policy" } }, {
        use_stream_mode = true,
        use_websearch = mode,
    })
    return request_body
end

local function getToolParameters(format, tool)
    if format == "anthropic" then return tool.input_schema end
    if format == "gemini" then return tool.function_declarations[1].parameters end
    if format == "responses" then return tool.parameters end
    return tool["function"].parameters
end

local tests = {
    test("Parallel Search is the final selectable external search mode", function()
        assert.equal(ToolExecutor.SEARCH_API_NAMES[#ToolExecutor.SEARCH_API_NAMES], "parallelapi")
    end),

    test("Querier captures one search snapshot for both tool-call paths", function()
        local project_root = debug.getinfo(1).source:match("@(.*/)test/")
        local file = io.open(project_root .. "assistant_querier.lua", "r")
        assert.notNil(file, "assistant_querier.lua must be readable")
        local source = file:read("*a")
        file:close()

        local snapshot = "local search_config = ToolExecutor.getSearchConfig(self.assistant)"
        local closure = "local function executeSearch("
        local snapshot_pos = source:find(snapshot, 1, true)
        local closure_pos = source:find(closure, 1, true)
        assert.notNil(snapshot_pos, "query must capture the search config")
        assert.notNil(closure_pos, "shared search executor must exist")
        assert.isTrue(snapshot_pos < closure_pos, "snapshot must be captured before the tool-round closure")

        local _, snapshot_count = source:gsub("ToolExecutor%.getSearchConfig%(self%.assistant%)", "")
        local _, call_count = source:gsub("= executeSearch%(", "")
        assert.equal(snapshot_count, 1, "one snapshot must be reused for the query")
        assert.equal(call_count, 2, "stream and non-stream loops must share the closure")
        assert.matches(source, "tool_rounds%+i, search_config, objective%)",
            "the frozen snapshot and objective must reach the external executor")
    end),

    test("search snapshots copy configured Parallel settings and honor credential requirements", function()
        local assistant = mockAssistant({
            parallelapi = {
                api_key = "parallel-test",
                base_url = "https://proxy.example///",
                mode = "basic",
            },
            searxngapi = { base_url = "https://search.example///" },
        })
        local snapshot = ToolExecutor.getSearchConfig(assistant)
        assert.equal(snapshot.parallelapi.api_key, "parallel-test")
        assert.equal(snapshot.parallelapi.base_url, "https://proxy.example")
        assert.equal(snapshot.parallelapi.mode, "basic")
        assert.equal(snapshot.searxngapi.base_url, "https://search.example")

        local invalid = ToolExecutor.getSearchConfig(mockAssistant({
            parallelapi = { api_key = "", base_url = "https://proxy.example" },
        }))
        assert.equal(invalid.parallelapi, nil)
    end),

    test("search snapshots are isolated from later provider mutations", function()
        local provider = { api_key = "first-key", base_url = "https://one.example/", mode = "fast" }
        local first = ToolExecutor.getSearchConfig(mockAssistant({ parallelapi = provider }))
        local second = ToolExecutor.getSearchConfig(mockAssistant({
            parallelapi = { api_key = "second-key", mode = "basic" },
        }))
        provider.api_key = "changed-key"
        provider.base_url = "https://changed.example"
        provider.mode = "advanced"

        assert.equal(first.parallelapi.api_key, "first-key")
        assert.equal(first.parallelapi.base_url, "https://one.example")
        assert.equal(first.parallelapi.mode, "fast")
        assert.equal(second.parallelapi.api_key, "second-key")
        assert.equal(second.parallelapi.mode, "basic")
    end),

    test("external search instances do not retain request credentials or mode", function()
        assert.equal(ExtTools.parallelapi.api_key, nil)
        assert.equal(ExtTools.parallelapi.base_url, nil)
        assert.equal(ExtTools.parallelapi.mode, nil)
    end),

    test("only Parallel schemas request an objective in all handler formats", function()
        local cases = {
            {
                format = "openai",
                handler = OpenAIHandler,
                fields = { base_url = "https://example.com/v1", model = "gpt-test", api_key = "key" },
            },
            {
                format = "anthropic",
                handler = AnthropicHandler,
                fields = { base_url = "https://example.com/v1", model = "claude-test", api_key = "key" },
            },
            {
                format = "gemini",
                handler = GeminiHandler,
                fields = { base_url = "https://example.com/v1beta/models", model = "gemini-test", api_key = "key" },
            },
            {
                format = "responses",
                handler = ResponsesHandler,
                fields = { base_url = "https://example.com/v1", responses_url = "https://example.com/v1/responses", model = "gpt-test", api_key = "key" },
            },
        }
        for _, case in ipairs(cases) do
            local body = captureHandlerBody(case.handler, case.fields, "parallelapi")
            local parameters = getToolParameters(case.format, body.tools[1])
            assert.equal(parameters.properties.keywords.type, "string", case.format)
            assert.equal(parameters.properties.objective.type, "string", case.format)
            assert.equal(parameters.required[1], "keywords", case.format)
            assert.equal(parameters.required[2], "objective", case.format)
        end

        local generic = captureHandlerBody(OpenAIHandler, {
            base_url = "https://example.com/v1", model = "gpt-test", api_key = "key",
        }, "exaapi")
        local generic_parameters = getToolParameters("openai", generic.tools[1])
        assert.equal(generic_parameters.properties.objective, nil)
        assert.equal(#generic_parameters.required, 1)
    end),

    test("extractKeywords returns objectives from JSON, Gemini, and Anthropic calls", function()
        local cases = {
            {
                call = { id = "openai-id", arguments = json.encode({ keywords = "solar storage policy", objective = "Find the latest policy" }) },
                id = "openai-id",
                objective = "Find the latest policy",
            },
            {
                call = { tool_call_id = "gemini-id", args = { keywords = "battery recycling", objective = "Compare current programs" } },
                id = "gemini-id",
                objective = "Compare current programs",
            },
            {
                call = { id = "anthropic-id", input = { keywords = "grid storage", objective = "Find recent deployments" } },
                id = "anthropic-id",
                objective = "Find recent deployments",
            },
        }
        for _, case in ipairs(cases) do
            local id, keywords, err, objective = ToolExecutor.extractKeywords(case.call)
            assert.equal(id, case.id)
            assert.notNil(keywords)
            assert.equal(err, nil)
            assert.equal(objective, case.objective)
        end
    end),

    test("extractKeywords ignores invalid objectives and rejects non-string keywords", function()
        local _, _, _, missing = ToolExecutor.extractKeywords({
            id = "missing-objective", arguments = '{"keywords":"clean energy incentives"}',
        })
        local _, _, _, numeric = ToolExecutor.extractKeywords({
            id = "numeric-objective", arguments = json.encode({ keywords = "clean energy incentives", objective = 42 }),
        })
        local _, _, _, null_objective = ToolExecutor.extractKeywords({
            tool_call_id = "null-objective", args = { keywords = "clean energy incentives", objective = json.null },
        })
        assert.equal(missing, nil)
        assert.equal(numeric, nil)
        assert.equal(null_objective, nil)

        local ok, id, keywords, err = pcall(ToolExecutor.extractKeywords, {
            tool_call_id = "invalid-keywords", args = { keywords = 42 },
        })
        assert.isTrue(ok)
        assert.equal(id, nil)
        assert.equal(keywords, nil)
        assert.notNil(err)
    end),

    test("stream reconstruction preserves objectives for Anthropic and Gemini", function()
        local anthropic_ok, anthropic = ToolExecutor.buildRawAssistantForToolCall({
            { id = "anthropic-stream", input = { keywords = "solar storage", objective = "Find recent deployments" } },
        }, "anthropic")
        assert.isTrue(anthropic_ok)
        assert.equal(anthropic[1].input.keywords, "solar storage")
        assert.equal(anthropic[1].input.objective, "Find recent deployments")

        local gemini_args = { keywords = "battery policy", objective = "Compare the latest rules" }
        local gemini_ok, gemini = ToolExecutor.buildRawAssistantForToolCall({
            { tool_call_id = "gemini-stream", args = gemini_args },
        }, "gemini")
        assert.isTrue(gemini_ok)
        assert.equal(gemini.parts[1].functionCall.args, gemini_args)
        assert.equal(gemini.parts[1].functionCall.args.objective, "Compare the latest rules")
    end),

    test("external execution uses frozen Parallel config and preserves URLs", function()
        local record = { api_key = "snapshot-key", mode = "fast" }
        local passed_record, passed_objective
        local ok, result = withSearchMethod("parallelapi", function(_, keywords, _, config, objective)
            assert.equal(keywords, "solar storage policy")
            passed_record = config
            passed_objective = objective
            return true, "URL: https://parallel.example/source\n"
        end, function()
            return ToolExecutor.executeWebSearch("solar storage policy", "parallelapi", {
                resetTrapWidget = function() return nil end,
            }, 1, { parallelapi = record }, "Find current residential policies")
        end)
        assert.isTrue(ok)
        assert.equal(passed_record, record)
        assert.equal(passed_objective, "Find current residential policies")
        assert.isTrue(result:find("https://parallel.example/source", 1, true) ~= nil)

        local legacy_result = withSearchMethod("tavilyapi", function()
            return true, "URL: https://legacy.example/source\n"
        end, function()
            local legacy_ok, text = ToolExecutor.executeWebSearch("legacy query", "tavilyapi", {
                resetTrapWidget = function() return nil end,
            }, 1, { tavilyapi = { api_key = "key" } })
            assert.isTrue(legacy_ok)
            return text
        end)
        assert.isTrue(legacy_result:find("https://legacy.example/source", 1, true) == nil)
    end),

    test("external execution rejects invalid snapshots and accepts SearXNG URL", function()
        local provider_calls = 0
        withSearchMethod("parallelapi", function()
            provider_calls = provider_calls + 1
            return true, "unexpected"
        end, function()
            local handler = { resetTrapWidget = function() return nil end }
            local cases = {
                false,
                { parallelapi = { api_key = "" } },
                { parallelapi = { base_url = "https://proxy.example" } },
            }
            for _, snapshot in ipairs(cases) do
                local ok, err = ToolExecutor.executeWebSearch("valid query", "parallelapi", handler, 1, snapshot)
                assert.isFalse(ok)
                assert.equal(err, "Web search provider is not configured.")
            end
        end)
        assert.equal(provider_calls, 0)

        local searx_record = { base_url = "https://searx.example" }
        local searx_config
        local searx_ok = withSearchMethod("searxngapi", function(_, _, _, config)
            searx_config = config
            return true, "SearXNG result"
        end, function()
            return ToolExecutor.executeWebSearch("valid query", "searxngapi", {
                resetTrapWidget = function() return nil end,
            }, 1, { searxngapi = searx_record })
        end)
        assert.isTrue(searx_ok)
        assert.equal(searx_config, searx_record)

        local builtin_ok = ToolExecutor.executeWebSearch("valid query", "builtin", {
            resetTrapWidget = function() return nil end,
        }, 1, nil)
        assert.isTrue(builtin_ok)
    end),
}

return helper.runTests("Parallel Search tool flow", tests)
