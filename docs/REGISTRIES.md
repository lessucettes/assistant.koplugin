# Registries & Config

Two registries own everything configured from the UI. Both store JSON in `LuaSettings` and are merged with file-based config into the effective `CONFIGURATION`.

## Hard rules

- Do all UI provider/search CRUD through `Registry`/`SearchRegistry`. **Never** call `settings:saveSetting("ui_providers"/"ui_search_tools", ...)` directly.
- Read/write `CONFIGURATION` only via `assistant.config` (`getFeature`/`getProvider`/`getProviderSettings`/`getFeatures`/`isProviderEnabled`/`getActiveProviderId`/`setProvider`/`deleteProvider`/`setSearchTool`/`deleteSearchTool`/`buildEffectiveConfig`). Never read `CONFIGURATION.features`/`provider_settings` directly, and never write `CONFIGURATION.provider_settings[key]` by hand.
- File providers/tools live in `configuration.lua` (gitignored, holds secrets) — never read/modify it; update `configuration.sample.lua` only.
- Normalize credentials here: `Registry.validate` / `SearchRegistry.validate` trim `display_name`/`model`/`base_url`/`api_key` and reject **internal** whitespace. Shared normalization lives in `assistant_doc_utils.validate_credential_field` (trim + required/scheme/whitespace checks) and `assistant_doc_utils.trimDialogFields`; both registries route their credential checks through it. Do not scatter trims through handlers or header construction.

## Provider Registry (`assistant_provider_registry.lua`, `Registry`)

- Storage: `ui_providers` JSON. `Registry.load` reads it; `Registry.merge(file_config, ui_data)` combines file + UI providers into `CONFIGURATION.provider_settings`. File providers get `source="file"`, `immutable=true`; UI providers get `source="ui"`, `custom:N` (auto-incrementing). `main.lua` init builds the effective config.
- Config keys: file `{handler}_{description}`; UI `custom:N`. `display_name` drives the Settings radio and main-menu label (not the config key).
- `Registry.validate(record)` checks `display_name`, `handler` (must match an `api_handlers/` file), `model` (blank → `"auto"`), `base_url` (`http(s)://`, no whitespace), `api_key` (no whitespace).
- `Registry.installProvider(assistant, …)` — add + save + update in-memory config + load into the querier. `Registry.updateProvider` validates a candidate before mutating, so a rejected edit leaves the stored record untouched.
- `Registry.delete(data, id)` / `Registry.is_deletable(provider)` — only `source=="ui"` providers are editable/deletable.
- Gemini `base_url` must keep the `/models` segment (`FetchModels` GETs base_url; `query` POSTs `{base_url}/{model}:generateContent`). OpenAI-compatible Gemini endpoints use the `openai` handler.
- `Registry.showParametersDialog` is the reference hand-built dialog (no input field) — see `docs/UI_DIALOGS.md`.

## Search Registry (`assistant_search_registry.lua`, `SearchRegistry`)

- Storage: `ui_search_tools` JSON. Uses **fixed tool keys** (`serpapi`, `tavilyapi`, `exaapi`, `searxngapi`, `parallelapi`) rather than `custom:N`; `SEARCH_TOOLS` defines each key and its required credential. Engines: SerpAPI, Tavily, SearXNG, Exa, Parallel Search. UI tools are added via Settings → WebSearch API.
- `load`/`save`/`merge`/`validate`/`upsert`/`installSearchTool`/`delete`/`is_deletable` mirror the provider registry's `source`/`immutable` pattern (file tools `source="file"`, immutable; only UI tools are deletable). `merge` keys by tool key.
- `upsert` validates and then stores from the normalized record; `installSearchTool` reuses that record.
- `SearchRegistry.is_configured(record, key)` is the shared availability predicate for menu checkboxes, Web Search selection, and request snapshots. It checks the required field from `SEARCH_TOOLS`: API-key backends need a nonblank key, while SearXNG needs a nonblank base URL.
- `ToolExecutor.getSearchConfig` copies configured credentials, an optional trimmed base URL, and an optional mode once per query. Every tool round uses the same snapshot; external execution rejects a missing or invalid snapshot without re-reading mutable assistant config.
- Parallel Search uses `/v1/search`, sends `objective` separately from its keyword query, defaults to `fast`, and preserves ranked URLs and excerpts. A file-config `mode` and optional `base_url` are copied into the snapshot; a UI record replaces the whole file record and inherits neither field because the current dialog edits only the API key.

## Credential input

Both the provider and search dialogs read fields through `DocUtils.trimDialogFields`; `Registry.validate`/`SearchRegistry.validate` are the authoritative normalization gate (the Web Search dialog relies on `SearchRegistry.validate` via `installSearchTool` instead of duplicating required-field checks). This stops a pasted key/URL carrying a trailing `\n`/space from producing a malformed auth header (HTTP 401) or URL.
