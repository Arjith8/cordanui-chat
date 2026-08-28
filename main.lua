plugin = {}

-- state (Lua upvalues = view model, persists across frames)
local history = {}
local draft = ""
local sending = false

-- ---------------------------------------------------------------------------
-- helpers: config
-- ---------------------------------------------------------------------------
local function cfg(key, def)
  local v = nil
  if cord and cord.config and cord.config.get then
    local ok, val = pcall(cord.config.get, key)
    if ok then v = val end
    if v == nil and def ~= nil then
      local ok2, val2 = pcall(cord.config.get, key, def)
      if ok2 and val2 ~= nil then v = val2 end
    end
  end
  if (v == nil or v == "") and cordanui and cordanui.config then
    v = cordanui.config[key]
  end
  if v == nil or v == "" then return def end
  return v
end

local function api_key()
  local k = cfg("api_key", nil)
  if k and k ~= "" then return k end
  if cordanui and cordanui.config and cordanui.config.api_key and cordanui.config.api_key ~= "" then
    return cordanui.config.api_key
  end
  -- env fallback
  local env = nil
  if os and os.getenv then
    env = os.getenv("OPENCODE_API_KEY")
    if (not env or env == "") then env = os.getenv("OPENAI_API_KEY") end
    local api_key_env = cfg("api_key_env", nil)
    if (not env or env == "") and api_key_env and api_key_env ~= "" then
      env = os.getenv(api_key_env)
    end
  end
  return env
end

-- ---------------------------------------------------------------------------
-- persistence
-- ---------------------------------------------------------------------------
local function load_history()
  local raw = nil
  if cord and cord.config and cord.config.get then
    local ok, val = pcall(cord.config.get, "chat.history")
    if ok then raw = val end
  end
  if (not raw or raw == "") and cordanui and cordanui.config then
    raw = cordanui.config["chat.history"]
  end
  if raw and raw ~= "" and cordanui and cordanui.json and cordanui.json.decode then
    local ok, v = pcall(cordanui.json.decode, raw)
    if ok and type(v) == "table" then
      history = v
    end
  end
end

local function save_history()
  if not (cordanui and cordanui.json and cordanui.json.encode) then return end
  local max_bytes = 32 * 1024
  local ok, json = pcall(cordanui.json.encode, history)
  if not ok then return end
  while #json > max_bytes and #history > 1 do
    table.remove(history, 1)
    local ok2, j2 = pcall(cordanui.json.encode, history)
    if not ok2 then break end
    json = j2
  end
  if cord and cord.config and cord.config.set then
    pcall(cord.config.set, "chat.history", json)
  end
end

-- ---------------------------------------------------------------------------
-- LLM
-- ---------------------------------------------------------------------------
local function build_messages()
  local system_prompt = cfg("system_prompt", "You are a helpful assistant for goal tracking.")
  local msgs = {}
  msgs[#msgs + 1] = { role = "system", content = system_prompt }
  for _, m in ipairs(history) do
    msgs[#msgs + 1] = { role = m.role, content = m.content }
  end
  return msgs
end

local function do_llm_request()
  local key = api_key()
  if not key or key == "" then
    local msg = "missing api_key: run Configure on cordanui-chat or set OPENCODE_API_KEY"
    if cord and cord.ui and cord.ui.notify then
      pcall(cord.ui.notify, { message = msg, level = "error" })
    end
    if cordanui and cordanui.log then pcall(cordanui.log.error, msg) end
    sending = false
    return
  end

  local base = cfg("base_url", "https://opencode.ai/zen/v1")
  -- trim trailing slash
  if base:sub(-1) == "/" then base = base:sub(1, -2) end
  local model = cfg("default_model", "grok-code")
  local messages = build_messages()

  -- check if backend service is running — optional delegation
  local via_service = false
  if cord and cord.services and cord.services.is_running then
    local ok, running = pcall(cord.services.is_running, "cordanui-agents")
    if ok and running then
      via_service = true
    end
  end

  if via_service then
    -- Attempt service delegation; if anything fails fall back to direct.
    local ok, res = pcall(cord.services.request, "cordanui-agents", {
      method = "POST",
      path = "/chat",
      body = { model = model, messages = messages },
    })
    if ok and res and res.status == 200 and res.body then
      local pok, parsed = pcall(cordanui.json.decode, res.body)
      if pok and parsed then
        local content = nil
        if parsed.content then content = parsed.content
        elseif parsed.choices and parsed.choices[1] and parsed.choices[1].message then
          content = parsed.choices[1].message.content
        elseif parsed.output_text then content = parsed.output_text
        end
        if content then
          history[#history + 1] = { role = "assistant", content = content, at = os.date("!%Y-%m-%dT%H:%M:%SZ") }
          save_history()
          sending = false
          return
        end
      end
    end
    -- fall through to direct on any service error
    if cordanui and cordanui.log then pcall(cordanui.log.info, "cordanui-chat: service delegation failed, falling back to direct HTTP") end
  end

  -- direct HTTP
  if not (cordanui and cordanui.http and cordanui.http.request) then
    local msg = "http not available in this host"
    if cord and cord.ui and cord.ui.notify then pcall(cord.ui.notify, { message = msg, level = "error" }) end
    sending = false
    return
  end

  local body_ok, body = pcall(cordanui.json.encode, { model = model, messages = messages, temperature = 0.7 })
  if not body_ok then
    if cord and cord.ui and cord.ui.notify then pcall(cord.ui.notify, { message = "failed to encode request", level = "error" }) end
    sending = false
    return
  end

  local url = base .. "/chat/completions"
  local ok, res = pcall(cordanui.http.request, {
    url = url,
    method = "POST",
    headers = {
      ["content-type"] = "application/json",
      ["authorization"] = "Bearer " .. key,
    },
    body = body,
  })

  if not ok then
    local msg = "chat request failed: " .. tostring(res)
    if cord and cord.ui and cord.ui.notify then pcall(cord.ui.notify, { message = msg, level = "error" }) end
    if cordanui and cordanui.log then pcall(cordanui.log.error, msg) end
    sending = false
    return
  end

  if not res or res.status ~= 200 then
    local status = res and res.status or "unknown"
    local snippet = ""
    if res and res.body then snippet = res.body:sub(1, 200) end
    local msg = "chat failed HTTP " .. tostring(status) .. ": " .. snippet
    if cord and cord.ui and cord.ui.notify then pcall(cord.ui.notify, { message = msg, level = "error" }) end
    if cordanui and cordanui.log then pcall(cordanui.log.error, msg) end
    sending = false
    return
  end

  local pok, parsed = pcall(cordanui.json.decode, res.body)
  if not pok or not parsed then
    local msg = "chat: invalid JSON response"
    if cord and cord.ui and cord.ui.notify then pcall(cord.ui.notify, { message = msg, level = "error" }) end
    sending = false
    return
  end

  local content = nil
  if parsed.choices and parsed.choices[1] and parsed.choices[1].message and parsed.choices[1].message.content ~= nil then
    content = parsed.choices[1].message.content
  elseif parsed.content then
    -- generic fallback
    if type(parsed.content) == "string" then content = parsed.content
    elseif type(parsed.content) == "table" and parsed.content[1] and parsed.content[1].text then content = parsed.content[1].text
    end
  end

  if content == nil then
    local msg = "chat: missing content in response"
    if cord and cord.ui and cord.ui.notify then pcall(cord.ui.notify, { message = msg, level = "error" }) end
    sending = false
    return
  end

  history[#history + 1] = { role = "assistant", content = content, at = os.date("!%Y-%m-%dT%H:%M:%SZ") }
  save_history()
  sending = false
end

-- ---------------------------------------------------------------------------
-- panel
-- ---------------------------------------------------------------------------
local function draw()
  local items = {}
  for _, m in ipairs(history) do
    items[#items + 1] = m.role .. ": " .. m.content
  end
  local draft_line
  if sending then
    draft_line = { content = "...thinking...", fg = "tertiary" }
  else
    draft_line = { content = "> " .. draft, fg = "secondary" }
  end
  return {
    { content = "Chat (" .. #history .. " msgs) — Enter send, Esc close, /clear wipe", fg = "primary", bold = true },
    { items = items, highlight = #items > 0 and #items or nil },
    draft_line,
  }
end

local function on_key(key)
  if key == "esc" then
    if cord and cord.ui and cord.ui.close_panel then pcall(cord.ui.close_panel) end
    return true
  end

  if key == "enter" then
    if sending then return true end
    if draft == "" then return true end

    -- handle slash commands
    if draft:sub(1, 1) == "/" then
      if draft == "/clear" then
        history = {}
        save_history()
        if cord and cord.ui and cord.ui.notify then pcall(cord.ui.notify, "history cleared") end
        draft = ""
        return true
      else
        if cord and cord.ui and cord.ui.notify then
          pcall(cord.ui.notify, { message = "unknown command: " .. draft, level = "warn" })
        end
        draft = ""
        return true
      end
    end

    -- push user message
    local at = os.date("!%Y-%m-%dT%H:%M:%SZ")
    history[#history + 1] = { role = "user", content = draft, at = at }
    draft = ""
    sending = true
    save_history()
    -- trigger LLM (awaitable)
    do_llm_request()
    return true
  end

  if key == "backspace" then
    if #draft > 0 then draft = draft:sub(1, -2) end
    return true
  end

  -- single printable char (including space)
  if #key == 1 then
    draft = draft .. key
    return true
  end

  if key == "space" then
    draft = draft .. " "
    return true
  end

  return false
end

local function openChat()
  load_history()
  if cord and cord.ui and cord.ui.show_panel then
    cord.ui.show_panel{
      title = "Chat — cordanui-chat",
      draw = draw,
      on_key = on_key,
    }
  else
    if cordanui and cordanui.log then pcall(cordanui.log.warn, "cordanui-chat: cord.ui.show_panel not available (headless)") end
  end
  return "chat opened"
end

local function clearChat()
  history = {}
  save_history()
  if cord and cord.ui and cord.ui.notify then pcall(cord.ui.notify, "history cleared") end
  -- if panel is open, it will redraw on next frame; ensure draft cleared
  draft = ""
  sending = false
  return "history cleared"
end

plugin.commands = {
  ["cordanui-chat.open"] = { run = openChat, desc = "Open chat" },
  ["cordanui-chat.clear"] = { run = clearChat, desc = "Clear history" },
}

return plugin
