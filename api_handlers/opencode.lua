local OpenAIHandler = require("api_handlers.openai")
local socket = require("socket")

local OpenCode = OpenAIHandler:new({ name = "opencode", can_fetch_models = true })
local GO_URL = "https://opencode.ai/inference/go/openai/v1"
local LEGACY_GO_URL = "https://opencode.ai/zen/go/v1"
local MODEL_URLS = {
    [GO_URL] = "https://opencode.ai/inference/go/v1/models",
    ["https://opencode.ai/inference/openai/v1"] = "https://opencode.ai/inference/v1/models",
}
local sessions = setmetatable({}, { __mode = "k" })
local session_count = 0

local function isGo(base_url)
    local base = base_url and base_url:gsub("/+$", "")
    return base == GO_URL or base == LEGACY_GO_URL
end

local function newSessionId()
    session_count = session_count + 1
    local now = socket.gettime and socket.gettime() or os.time()
    return string.format("assistant.koplugin-%x-%x", math.floor(now * 1000000), session_count)
end

function OpenCode:requestHeaders(message_history)
    local headers = OpenAIHandler.requestHeaders(self, message_history)
    if isGo(self.base_url) then
        headers["User-Agent"] = "assistant.koplugin/1.0"
        local session = type(message_history) == "table" and sessions[message_history] or nil
        if not session then
            session = newSessionId()
            if type(message_history) == "table" then sessions[message_history] = session end
        end
        headers["x-opencode-session"] = session
    end
    return headers
end

function OpenCode:getModelsUrl()
    local base = self.base_url and self.base_url:gsub("/+$", "")
    return self.models_url or MODEL_URLS[base] or OpenAIHandler.getModelsUrl(self)
end

-- /models has no protocol or pricing fields. Only suggest likely Chat Completions
-- models in the picker; manually entered IDs still go directly to the API.
-- Free models are omitted from suggestions; availability depends on the service.
local function isChatModel(id, go)
    if type(id) ~= "string" then return false end
    if id:match("%-free$") then return false end
    if not go then
        return id:match("^glm%-5") or id:match("^kimi%-k")
            or id:match("^deepseek%-v4") or id:match("^minimax%-m")
            or id:match("^qwen3%.8%-max$") or id:match("^mistral%-large%-4$")
    end
    return id:match("^glm%-") or id:match("^kimi%-") or id:match("^deepseek%-")
        or id:match("^longcat%-") or id:match("^mimo%-v2%.[0-9]")
        or id:match("^hy[34]") or id:match("^minimax%-m3%.1%-flash$")
        or id:match("^step%-5%-preview$")
end

function OpenCode:FetchModels()
    local models, err = OpenAIHandler.FetchModels(self)
    if not models then return nil, err end
    local filtered = {}
    local go = isGo(self.base_url)
    for i, model in ipairs(models) do
        if type(model) == "table" and isChatModel(model.id, go) then
            filtered[#filtered + 1] = model
        end
    end
    return filtered, nil
end

return OpenCode
