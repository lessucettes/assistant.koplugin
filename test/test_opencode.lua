local helper = require("test.helper")
local assert = helper.assert
local OpenAI = require("api_handlers.openai")
local OpenCode = require("api_handlers.opencode")
local NetUtils = helper.NetUtils

local function test(name, fn) return { name = name, fn = fn } end
local function handler(base_url, model)
    return OpenCode:new({ base_url = base_url, model = model or "glm-5.3-flash", api_key = "test-key" })
end
local ZEN = "https://opencode.ai/zen/v1"
local GO = "https://opencode.ai/zen/go/v1"
local function withFetchJSON(fn)
    local original = NetUtils.fetchJSON
    local ok, err = pcall(fn)
    NetUtils.fetchJSON = original
    if not ok then error(err) end
end

local function modelIds(models)
    local ids = {}
    for i, model in ipairs(models) do ids[i] = model.id end
    return table.concat(ids, ",")
end

return helper.runTests("opencode", {
    test("Current Go endpoint keeps session headers and uses the shared model catalog", function()
        local base = "https://opencode.ai/inference/go/openai/v1"
        local h = handler(base .. "/")
        local history = {}
        local headers = h:requestHeaders(history)
        assert.equal(headers["User-Agent"], "assistant.koplugin/1.0")
        assert.notNil(headers["x-opencode-session"])
        assert.equal(headers["x-opencode-session"], h:requestHeaders(history)["x-opencode-session"])
        assert.equal(h:getModelsUrl(), "https://opencode.ai/inference/go/v1/models")
        h.models_url = "https://proxy.example/catalog"
        assert.equal(h:getModelsUrl(), h.models_url)
        withFetchJSON(function()
            h.models_url = nil
            NetUtils.fetchJSON = function(url, request_headers)
                assert.equal(url, "https://opencode.ai/inference/go/v1/models")
                assert.notNil(request_headers["x-opencode-session"])
                return { data = {
                    { id = "mimo-v2.6-pro" }, { id = "minimax-m3" },
                    { id = "minimax-m3.1-flash" }, { id = "step-5-preview" },
                    { id = "claude-haiku-5-5" }, { id = "gpt-6-luna" },
                } }
            end
            assert.equal(modelIds(h:FetchModels()), "mimo-v2.6-pro,minimax-m3.1-flash,step-5-preview")
        end)
    end),
    test("Current Zen endpoint browses the shared catalog without Go headers", function()
        local h = handler("https://opencode.ai/inference/openai/v1")
        assert.equal(h:getModelsUrl(), "https://opencode.ai/inference/v1/models")
        assert.equal(h:requestHeaders({})["x-opencode-session"], nil)
        assert.equal(handler("https://proxy.example/v1"):getModelsUrl(), "https://proxy.example/v1/models")
        assert.equal(handler(GO .. ".example"):requestHeaders({})["x-opencode-session"], nil)
    end),
    test("Go keeps one session across transactional history views", function()
        local h = handler(GO)
        local canonical = { { role = "user", content = "current policy" } }
        local sessions = {}
        h.parseToolCalls = function() return "ok" end
        h.makeRequest = function(self, url, headers)
            sessions[#sessions + 1] = headers["x-opencode-session"]
            return true, 200, "{}"
        end
        for round = 1, 2 do
            local view = { canonical[1], { role = "tool", content = "round " .. round } }
            assert.equal(h:query(view, {
                use_stream_mode = false,
                conversation_history = canonical,
            }), "ok")
        end
        assert.notNil(sessions[1])
        assert.equal(sessions[1], sessions[2])
    end),
    test("OpenCode applies the shared Chat Completions reasoning overlay", function()
        local h = handler(GO)
        h:SyncOptions({
            provider_name = "opencode_go",
            handler_name = "opencode",
            provider_setting = { api_key = "test-key", base_url = GO, model = "glm-5.3-flash" },
            settings = { readSetting = function() return nil end },
        }, { reasoning_effort = "low" })
        assert.equal(h.additional_parameters.reasoning_effort, "low")
        local body
        h.testRequest = function(self, url, headers, payload) body = payload; return true end
        assert.isTrue(h:Test())
        assert.equal(body.reasoning_effort, "low")
    end),
    test("Go uses the Chat Completions URL, honest agent and stable conversation session", function()
        local h = handler(GO)
        local first_message = { role = "user", content = "hello" }
        local history = { first_message }
        local other = { first_message }
        local calls = {}
        h.parseToolCalls = function() return "ok" end
        h.makeRequest = function(_, url, headers, body)
            calls[#calls + 1] = { url = url, headers = headers, body = body }
            return true, 200, "{}"
        end
        h.backgroundRequest = function(_, url, headers, body)
            calls[#calls + 1] = { url = url, headers = headers, body = body }
            return function() end
        end
        assert.equal(h:query(history, { use_stream_mode = false }), "ok")
        -- Mutating the history in place must not change the session.
        table.remove(history, 1)
        table.insert(history, { role = "user", content = "follow-up" })
        assert.equal(type(h:query(history, { use_stream_mode = true })), "function")
        h:query(other, { use_stream_mode = false })
        assert.equal(calls[1].url, GO .. "/chat/completions")
        assert.equal(calls[2].url, GO .. "/chat/completions")
        assert.equal(calls[1].headers.Authorization, "Bearer test-key")
        assert.equal(calls[1].headers["User-Agent"], "assistant.koplugin/1.0")
        assert.matches(calls[1].headers["x-opencode-session"], "^assistant%.koplugin%-")
        assert.equal(calls[1].headers["x-opencode-session"], calls[2].headers["x-opencode-session"])
        assert.isTrue(calls[1].headers["x-opencode-session"] ~= calls[3].headers["x-opencode-session"])
        assert.equal(calls[2].headers.Accept, "text/event-stream")
    end),

    test("Zen and ordinary OpenAI retain their original headers", function()
        local z = handler(ZEN, "glm-5.3-flash"):requestHeaders({})
        local o = OpenAI:new({ api_key = "test-key" }):requestHeaders({})
        assert.equal(z["Content-Type"], "application/json")
        assert.equal(z.Authorization, "Bearer test-key")
        assert.equal(z["User-Agent"], nil)
        assert.equal(z["x-opencode-session"], nil)
        assert.equal(o["Content-Type"], "application/json")
        assert.equal(o.Authorization, "Bearer test-key")
        assert.equal(o["User-Agent"], nil)
        assert.equal(o["x-opencode-session"], nil)
    end),

    test("Zen and ordinary OpenAI keep standard headers on request surfaces", function()
        local cases = {
            { handler = handler(ZEN, "glm-5.3-flash"), base_url = ZEN },
            { handler = OpenAI:new({ base_url = "https://api.openai.com/v1", model = "gpt-4o", api_key = "test-key" }),
              base_url = "https://api.openai.com/v1" },
        }
        local function assertStandardHeaders(headers)
            assert.equal(headers["Content-Type"], "application/json")
            assert.equal(headers.Authorization, "Bearer test-key")
            assert.equal(headers["User-Agent"], nil)
            assert.equal(headers["x-opencode-session"], nil)
        end
        withFetchJSON(function()
            NetUtils.fetchJSON = function(_, headers)
                assertStandardHeaders(headers)
                return { data = {} }
            end
            for _, case in ipairs(cases) do
                local h = case.handler
                h:FetchModels()

                local test_headers
                h.testRequest = function(_, url, headers)
                    assert.equal(url, case.base_url .. "/chat/completions")
                    test_headers = headers
                    return "ok"
                end
                assert.equal(h:Test(), "ok")
                assertStandardHeaders(test_headers)

                local query_headers
                h.makeRequest = function(_, url, headers)
                    assert.equal(url, case.base_url .. "/chat/completions")
                    query_headers = headers
                    return true, 200, "{}"
                end
                h.parseToolCalls = function() return "ok" end
                assert.equal(h:query({ { role = "user", content = "hi" } }, { use_stream_mode = false }), "ok")
                assertStandardHeaders(query_headers)
            end
        end)
    end),

    test("Go sends headers for connection tests and model browsing too", function()
        local h = handler(GO)
        local captured
        h.testRequest = function(_, url, headers, body)
            captured = { url = url, headers = headers, body = body }
            return true
        end
        assert.isTrue(h:Test())
        assert.equal(captured.url, GO .. "/chat/completions")
        assert.equal(captured.headers["User-Agent"], "assistant.koplugin/1.0")
        assert.notNil(captured.headers["x-opencode-session"])
        local test_session = captured.headers["x-opencode-session"]
        withFetchJSON(function()
            NetUtils.fetchJSON = function(url, headers)
                captured = { url = url, headers = headers }
                return { data = { { id = "glm-5.3-flash" } } }
            end
            local models = h:FetchModels()
            assert.equal(models[1].id, "glm-5.3-flash")
            assert.equal(captured.url, GO .. "/models")
            assert.equal(captured.headers["User-Agent"], "assistant.koplugin/1.0")
            assert.notNil(captured.headers["x-opencode-session"])
            assert.isTrue(test_session ~= captured.headers["x-opencode-session"],
                "standalone requests without history should receive fresh sessions")
        end)
    end),

    test("Browse Models suggests paid Zen Chat models and Go Chat families", function()
        withFetchJSON(function()
            NetUtils.fetchJSON = function(url)
                if url == ZEN .. "/models" then
                    return { data = {
                        { id = "glm-5.3-flash" }, { id = "glm-5.3" },
                        { id = "kimi-k3" }, { id = "minimax-m3" },
                        { id = "deepseek-v4.1-flash" }, { id = "qwen3.8-max" }, { id = "mistral-large-4" },
                        { id = "gpt-6-luna" }, { id = "claude-opus-5" },
                        { id = "qwen3.8-flash" }, { id = "muse-spark-1.3" },
                        { id = "big-pickle" }, { id = "space-bunny-free" },
                        { id = "mimo-v2.6-flash-free" }, { id = "deepseek-v4-flash-free" },
                        { id = "ling-3.0-flash-fin-free" }, { id = "nemotron-3-ultra-free" },
                        { id = "jev-1.13-free" }, { id = "muse-spark-1.3-contributor-free" },
                    } }
                end
                return { data = {
                    { id = "glm-5.3-flash" }, { id = "kimi-k3" },
                    { id = "deepseek-v4-pro" }, { id = "longcat-2.0" },
                    { id = "mimo-v2.6-pro" }, { id = "hy3" },
                    { id = "hy4-preview" }, { id = "space-bunny-free" },
                    { id = "gpt-6-luna" }, { id = "grok-4.7" },
                    { id = "muse-spark-1.3-contributor" }, { id = "qwen3.8-max" },
                    { id = "minimax-m3" }, { id = "jev-1.13" },
                    { id = "mimo-v2-pro" }, { id = "mimo-v2-omni" },
                } }
            end
            local zen = handler(ZEN):FetchModels()
            assert.equal(modelIds(zen), "deepseek-v4.1-flash,glm-5.3,glm-5.3-flash,kimi-k3,minimax-m3,mistral-large-4,qwen3.8-max")
            local go = handler(GO):FetchModels()
            assert.equal(modelIds(go), "deepseek-v4-pro,glm-5.3-flash,hy3,hy4-preview,kimi-k3,longcat-2.0,mimo-v2.6-pro")
        end)
    end),

    test("Browse Models preserves model-fetch errors", function()
        withFetchJSON(function()
            NetUtils.fetchJSON = function() return nil, "catalog unavailable" end
            local models, err = handler(ZEN):FetchModels()
            assert.equal(models, nil)
            assert.equal(err, "catalog unavailable")
        end)
    end),

    test("Manual model IDs reach the API even when absent from Browse Models", function()
        local h = handler(GO, "new-manual-model")
        local sent
        h.makeRequest = function(_, url, headers, body)
            sent = { url = url, body = body, headers = headers }
            return false, 404, '{"error":{"message":"unknown model"}}'
        end
        local answer, err = h:query({ { role = "user", content = "hi" } }, { use_stream_mode = false })
        assert.equal(answer, nil)
        assert.matches(err, "unknown model")
        assert.equal(sent.url, GO .. "/chat/completions")
        assert.matches(sent.body, "new%-manual%-model")
        assert.notNil(sent.headers["x-opencode-session"])
    end),
})
