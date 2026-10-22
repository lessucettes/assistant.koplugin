# AGENTS.md

Guidance for AI agents working in `assistant.koplugin` (KOReader AI assistant plugin). **Keep this file short** — deep guidance lives in `docs/` and is loaded on demand. Read the relevant doc before editing:

| Before you touch… | Read |
|---|---|
| tests, stubs, headless behavior, test runner | `docs/TESTING.md` |
| modules, request flow, handlers, config | `docs/ARCHITECTURE.md` |
| provider/search registry, UI settings CRUD | `docs/REGISTRIES.md` |
| dialogs, widgets, layout | `docs/UI_DIALOGS.md` |

## Environment

- Debian/Ubuntu. Install KOReader from the official `.deb`; the runtime lands at `/usr/lib/koreader/`.
- There is no project package manifest or dependency-install step; the runtime and Lua libraries come from KOReader.
- The plugin targets the latest KOReader stable only, currently `2026.07.1`. If the local install differs, fix the environment first — never adapt code to old or hypothetical upstream behavior.
- Read `/usr/lib/koreader/` (`frontend/`, `plugins/`, the bundled `luajit`) for upstream APIs and reference implementations — **never modify anything there**.
- `configuration.lua` is gitignored and holds real secrets: **never read or modify it**. Update `configuration.sample.lua` instead.

## Build / Test / Lint

- No build or configured lint step; Lua files run directly.
- Syntax: `/usr/lib/koreader/luajit -e "assert(loadfile('main.lua'))"`; `luac -p file.lua` checks standard Lua syntax only. **Never** `luajit -bl` (stripped build lacks `jit.*`).
- Tests: `./test/run.sh` (all) or `./test/run.sh exttools` (module-name substring filter). UI: `./test/runui.sh model_picker` (options: `-w=1072 -h=1448 -d=300` or `-s=kobo-clara`). Translation: `cd l10n && make check` (only when explicitly requested). Full detail: `docs/TESTING.md`.
- Run `./test/run.sh` before committing — CI ships without running tests.

## Architecture (map)

- `main.lua` — plugin init, dispatcher actions/gestures, menu registration; `assistant_hooks.lua` owns KOReader monkey patches.
- `assistant_querier.lua` — query engine: handler loading, stream/SSE, web-search tool loop (max 3 rounds).
- `api_handlers/` — wire-format handlers and provider aliases; `base.lua` = `BaseHandler`; `openai`/`opencode`/`anthropic`/`gemini`/`responses` are UI-selectable, alias wrappers and deltas are not.
- `assistant_tool_executor.lua` — normalizes tool calls across OpenAI-compatible, Anthropic, Gemini, and Responses formats; `assistant_exttools.lua` — search API clients.
- `assistant_provider_registry.lua` (`Registry`) / `assistant_search_registry.lua` (`SearchRegistry`) — UI provider/search CRUD + JSON settings.
- `assistant_config.lua` — owns the effective `CONFIGURATION`.
- Shared utils: `assistant_text_utils.lua` (text/render), `assistant_net_utils.lua` (HTTP/fetch), `assistant_doc_utils.lua` (book/page extraction, online guard, field trim); `assistant_utils.lua` is the slim core (`PLUGIN_DIR`, attrs, JSON default).
- UI: `assistant_dialog.lua`, `assistant_viewer.lua`, `assistant_featuredialog.lua`, `assistant_dictdialog.lua`, `assistant_provider_dialog.lua`, `assistant_settings_menu.lua`, `assistant_model_picker.lua`, `assistant_quicknote.lua`, `assistant_mdparser.lua`.
- `assistant_term_xray.lua` — sentence splitting + term-anchor (keyword-in-context) extraction.
Full flow, handlers, config, key files: `docs/ARCHITECTURE.md`.

## Core Principles

- **Dependencies first**: lean on what is already in the project or upstream before writing your own implementation or adding packages. Check docs and type definitions first; do not assume a library lacks a capability.
- **Mature patterns first**: before designing a solution, study how mature products solve the same problem - especially KOReader's existing plugins and widgets - and adopt their proven patterns instead of inventing from scratch.

## Refactoring and Compatibility

- The plugin ships and updates atomically: never preserve backward compatibility for internal interfaces.
- Target latest KOReader only: never code against old or hypothetical upstream APIs, and never add version fallbacks.
- Internal modules may be freely refactored, renamed, or deleted. Do not add compatibility shims, fallbacks, or migration layers for internal-only code; update every call site in one go.
- Comments describe what the code is now, never its change history (no "moved from X", "formerly", "no shim left").

## Invariants (never break)

1. **Config**: read/write `CONFIGURATION` only via `assistant.config` getters/mutators; UI provider/search CRUD only via `Registry`/`SearchRegistry`. Never touch `settings:saveSetting("ui_providers"/"ui_search_tools", ...)`.
2. **JSON**: `rapidjson` only (never `dkjson`/`cjson`); `null` is `rapidjson.null` — compare `== nil or == rapidjson.null`, fall back via `assistant_utils.json_default`.
3. **Nested reads**: use `assistant.config:get*` or `koutil.tableGetValue(t, ...)` (also for API responses, incl. numeric keys). Never `t and t.foo and t.foo.bar` — it crashes on malformed shapes. `koutil.tableMerge(t1,t2)` mutates `t1` and returns nil.
4. **gettext**: wrap every user-facing string in `_()`; msgids must be US-ASCII — replace Unicode punctuation with ASCII (`-` not `—`, `...` not `…`) and inject all non-ASCII glyphs (emoji, arrows, symbols) **outside** `_()` via `T()` placeholders or concatenation. Msgids carry only human-readable words plus the custom `<b>` tag (parsed by `bold_format`, not real HTML) — never real HTML/markup; build real markup with `T()` placeholders or concatenation outside `_()` (e.g. `T(_("<b>Header:</b> %1"), val)` vs `T('<div>%1</div>', _("Text"))`). Plurals via `N_()`; keep strings contiguous inside `T(_("..."))`. Guarded by `test/test_gettext_ascii_msgids.lua`.
5. **Never use `_` as a discarded loop variable** (`for _, x in ...`): it shadows the gettext function and crashes `_()` calls in the loop body. Guarded by `test/test_gettext_loop_shadow.lua`.
6. **Dialogs**: cancellation/close on the **left**, action buttons (Save/OK) on the **right**. Title Case labels; short words (`to`, `for`, `as`, `and`, `in`) lowercase.
7. **Notifications**: `Notification:notify(msg, Notification.SOURCE_ALWAYS_SHOW)` only for transient success; errors/failures/ack → `UIManager:show(InfoMessage:new{...})`.
8. **Credentials**: UI-entered `api_key`/`base_url` are trimmed and internal whitespace rejected in `Registry.validate`/`SearchRegistry.validate`. Normalize there — not per handler, not at header build.
9. **Module structure**: `require` the owning module directly (one hop); split by domain and keep module responsibilities explicit.
10. **Style**: Lua 5.1 / LuaJIT 2.1; use `string.buffer` for hot loops. 4 spaces, never tabs (vendored `lib/` keeps upstream formatting); `snake_case` modules, `PascalCase` classes, `camelCase` methods, `UPPER_CASE` consts. Errors usually return `nil, err`; HTTP helpers use their documented status/code tuples.
11. **Directions/formatting**: `T = require("ffi/util").template`; bold via `assistant_text_utils.bold_format(T(_("<b>Header:</b> %1"), val))`; message metadata via `assistant_utils.set_attr`/`get_attr`.
12. **Scope**: exclude `l10n/` from code searches/reads (40+ languages, no code insight). Polish non-native English wording into idiomatic English without changing intent.
13. **Widgets**: reuse existing scaffolding (`ChatGPTViewer`, `assistant_dialog.lua`); read `docs/UI_DIALOGS.md` before hand-building dialogs. KOReader widget internals only as a last resort.
14. **Upstream helpers**: when a helper exists in `/usr/lib/koreader/` (`frontend/`, `ffi/util`, plugins), reuse it; drop the replaced local helper outright.
15. **EmmyLua annotations**: new functions with more than 3 params must document every param/return in `---` EmmyLua style (`@param name type desc`, `@return type desc`), as in `assistant_net_utils.fetchJSON`.

## Git / Versioning

- `main`; Conventional Commits (`fix:`, `refactor:`, `add:`, `feat:`). Commit directly when asked, with a concise message.
- `_meta.lua` holds `X.Y-dev`. Release: tag `vX.Y` on the matching commit; CI rewrites the packaged `_meta.lua` from the tag (repo stays `X.Y-dev`), then bump the repo to `X.(Y+1)-dev` and commit.
- CI (`.github/workflows/release.yml`) builds the zip using `.releaseignore`, creates a normal GitHub release (`prerelease: false`), and runs **no tests**. `.releaseignore` already excludes `*.md`, `test/`, `docs/`, `.github/`, `l10n` sources (the OTA updater reads the same file).

## Translation

- Translation scripts are developer-run: **never** run `make template/update/translate/ai-translate`. Only `make check` when explicitly requested. `make stats` is read-only (per-language DONE%/FUZZY/UNTRANSLATED table) — after changing many user-facing strings, run it and report the pending load (languages affected, remaining entries) to the developer.
- Domain `assistant` (`assistant.pot`/`.po`/`.mo`); MO files are committed. See `l10n/Makefile`.
