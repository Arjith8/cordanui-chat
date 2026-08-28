# cordanui-chat

Chat panel for [cordanui](https://github.com/anomalyco/cordanui) — Lua plugin, no backend required.

## Install

In cordanui: `<leader>+p` → `i` → paste this repo URL → Enter.

Or clone directly:

```bash
git clone <this-repo> ~/.local/share/cordanui/plugins/cordanui-chat
```

Restart TUI. The plugin is `runtime = "lua"` — no build step.

## Configure

Plugin manager → select `cordanui-chat` → `c` (Configure), or set env:

```bash
export OPENCODE_API_KEY=sk-...
```

Fields:

- `api_key` (secret, required) — Zen / OpenAI-compatible key
- `base_url` (default `https://opencode.ai/zen/v1`)
- `default_model` (select: `grok-code`, `gpt-5`, `claude-sonnet-4-5`, `gemini-3-pro`)
- `system_prompt`

Values sync via Turso `settings` table (`cordanui-chat.*`).

## Use

- `<leader>;` → `cordanui-chat.open` → panel opens (`chat opened` on status line)
- Type, `Enter` sends, `Esc` closes
- `Backspace` deletes, `/clear` wipes history (also `cordanui-chat.clear` command)
- History persists via `cord.config` (`chat.history` JSON, <32KB, oldest truncated) and survives restarts / syncs
- `<leader>h` → `cordanui-chat` tab shows help

## LLM

Direct `POST {base_url}/chat/completions` via `cordanui.http.request` with `Authorization: Bearer <key>`. If `cordanui-agents` service is running (`cord.services.is_running`), the plugin attempts `POST /chat` via `cord.services.request` first and falls back to direct HTTP — both paths work.

Missing key → `cord.ui.notify` error, no crash.

## Layout

```
cordanui-chat/
├── cordanui.toml  # runtime=lua, [[field]] + [[help]]
├── main.lua       # plugin.commands, panel, persistence
└── README.md
```
