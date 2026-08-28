plugin = {}

-- state (Lua upvalues = view model, persists across frames)
local history = {}
local draft = ""
local sending = false
local selected_model = nil
local cached_models = nil
local cached_at = 0

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

-- ---------------------------------------------------------------------------
-- persistence: history + selected model
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

local function load_model()
  local m = cfg("chat.model", nil) or cfg("default_model", "grok-code")
  selected_model = m
end

local function save_model(m)
  selected_model = m
  if cord and cord.config and cord.config.set then
    pcall(cord.config.set, "chat.model", m)
  end
end

-- ---------------------------------------------------------------------------
-- models: via backend GET /models, cached 5m
-- per CHAT-AGENTS-BACKEND-SPEC.md §2.2
-- ---------------------------------------------------------------------------
local function getModels()
  local now = os.time()
  if cached_models and (now - cached_at) < 300 and type(cached_models) == "table" and #cached_models > 0 then
    return cached_models
  end

  -- prefer backend when available
  if cord and cord.services and cord.services.is_running then
    local ok_running, running = pcall(cord.services.is_running, "cordanui-agents")
    if cordanui and cordanui.log then pcall(cordanui.log.info, "cordanui-chat getModels: is_running=" .. tostring(running) .. " ok=" .. tostring(ok_running)) end
    if ok_running and running then
      local ok, res = pcall(cord.services.request, "cordanui-agents", { method = "GET", path = "/models" })
      if cordanui and cordanui.log then
        pcall(cordanui.log.info, "cordanui-chat getModels: request ok=" .. tostring(ok) .. " status=" .. tostring(res and res.status) .. " body=" .. tostring(res and res.body and res.body:sub(1,200) or "nil"))
      end
      if ok and res and res.status == 200 and res.body then
        local ok2, list = pcall(cordanui.json.decode, res.body)
        if ok2 and type(list) == "table" and #list > 0 then
          cached_models = list -- [{id, provider, display}]
          cached_at = now
          if cordanui and cordanui.log then pcall(cordanui.log.info, "cordanui-chat getModels: backend returned " .. #list .. " models") end
          return list
        elseif ok2 and type(list) == "table" then
          if cordanui and cordanui.log then pcall(cordanui.log.info, "cordanui-chat getModels: backend returned empty list, using fallback") end
        end
      end
      if cordanui and cordanui.log then pcall(cordanui.log.info, "cordanui-chat: /models via service failed, fallback") end
    end
  else
    if cordanui and cordanui.log then pcall(cordanui.log.info, "cordanui-chat getModels: services not available, using fallback") end
  end

  -- fallback: always at least one entry so picker is never empty
  local def = cfg("default_model", "grok-code")
  if not def or def == "" then def = "grok-code" end
  -- also include secondary option from manifest so user always has a choice even offline
  local fallback = {
    { id = def, provider = "direct", display = def .. " (direct)" },
  }
  -- add the other manifest option if different, so /model always shows choices
  local other = (def == "grok-code") and "gemini-3-pro" or "grok-code"
  fallback[#fallback + 1] = { id = other, provider = "direct", display = other .. " (direct)" }
  cached_models = fallback
  cached_at = now
  if cordanui and cordanui.log then pcall(cordanui.log.info, "cordanui-chat getModels: fallback " .. #fallback .. " models") end
  return fallback
end

-- ---------------------------------------------------------------------------
-- LLM: backend POST /chat + direct fallback
-- per CHAT-AGENTS-BACKEND-SPEC.md §2.3
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

-- chat → backend: backend injects api_key from settings, chat only sends model+messages
local function viaBackend(model, messages)
  if not (cord and cord.services and cord.services.is_running) then return nil end
  local ok_running, running = pcall(cord.services.is_running, "cordanui-agents")
  if not (ok_running and running) then return nil end

  local ok, res = pcall(cord.services.request, "cordanui-agents", {
    method = "POST",
    path = "/chat",
    headers = { ["content-type"] = "application/json" },
    body = { model = model, messages = messages, temperature = 0.7 },
  })
  if not ok or not res then return nil, "backend request failed: " .. tostring(res) end
  if res.status ~= 200 then return nil, "backend HTTP " .. tostring(res.status) end
  local ok2, parsed = pcall(cordanui.json.decode, res.body)
  if not ok2 then return nil, "invalid JSON from backend" end
  if parsed.error then
    local detail = parsed.detail and (": " .. parsed.detail) or ""
    return nil, parsed.error .. detail
  end
  return parsed.content, parsed.usage
end

-- fallback direct HTTP (only when backend absent). Keeps chat usable serverless.
-- Uses env OPENCODE_API_KEY if present; no provider discovery here.
local function do_direct_http(model, messages)
  if not (cordanui and cordanui.http and cordanui.http.request) then
    return nil, "http not available in this host"
  end
  -- direct fallback still needs a key, but chat does not declare [[field]] api_key anymore;
  -- rely on env (backend would have handled settings provider.*). This is best-effort.
  local key = nil
  if os and os.getenv then
    key = os.getenv("OPENCODE_API_KEY") or os.getenv("OPENAI_API_KEY") or ""
  end
  if not key or key == "" then
    -- also try cordanui.config if user still has legacy key
    if cordanui and cordanui.config and cordanui.config.api_key and cordanui.config.api_key ~= "" then
      key = cordanui.config.api_key
    end
  end
  if not key or key == "" then
    return nil, "missing api_key: backend not running and OPENCODE_API_KEY not set"
  end
  local base = cfg("base_url", "https://opencode.ai/zen/v1")
  if base:sub(-1) == "/" then base = base:sub(1, -2) end
  local body_ok, body = pcall(cordanui.json.encode, { model = model, messages = messages, temperature = 0.7 })
  if not body_ok then return nil, "failed to encode request" end
  local url = base .. "/chat/completions"
  local ok, res = pcall(cordanui.http.request, {
    url = url,
    method = "POST",
    headers = { ["content-type"] = "application/json", ["authorization"] = "Bearer " .. key },
    body = body,
  })
  if not ok then return nil, "chat request failed: " .. tostring(res) end
  if not res or res.status ~= 200 then
    local snippet = res and res.body and res.body:sub(1, 200) or ""
    return nil, "chat failed HTTP " .. tostring(res and res.status or "unknown") .. ": " .. snippet
  end
  local pok, parsed = pcall(cordanui.json.decode, res.body)
  if not pok or not parsed then return nil, "invalid JSON response" end
  local content = nil
  if parsed.choices and parsed.choices[1] and parsed.choices[1].message and parsed.choices[1].message.content ~= nil then
    content = parsed.choices[1].message.content
  elseif parsed.content and type(parsed.content) == "string" then
    content = parsed.content
  end
  if content == nil then return nil, "missing content in response" end
  return content, parsed.usage
end

local function do_llm_request()
  local model = selected_model or cfg("default_model", "grok-code") or "grok-code"
  local messages = build_messages()

  local content, usage_or_err = viaBackend(model, messages)
  if not content then
    local err = usage_or_err
    -- if backend gave an error (e.g. missing api_key: configure provider-zen), surface it and don't silently fallback
    -- but if backend was simply not running (viaBackend returned nil with no error), try direct
    local backend_running = false
    if cord and cord.services and cord.services.is_running then
      local ok, r = pcall(cord.services.is_running, "cordanui-agents")
      backend_running = ok and r
    end
    if backend_running then
      -- backend was running but returned error → show it
      local msg = err or "backend error"
      if cord and cord.ui and cord.ui.notify then pcall(cord.ui.notify, { message = msg, level = "error" }) end
      if cordanui and cordanui.log then pcall(cordanui.log.error, "cordanui-chat viaBackend: " .. msg) end
      sending = false
      -- invalidate models cache on unknown model
      if msg and msg:find("unknown model") then cached_models = nil end
      return
    end
    -- backend not running → fallback direct
    if cordanui and cordanui.log then pcall(cordanui.log.info, "cordanui-chat: backend not running, trying direct HTTP") end
    content, usage_or_err = do_direct_http(model, messages)
    if not content then
      local msg = usage_or_err or "direct request failed"
      if cord and cord.ui and cord.ui.notify then pcall(cord.ui.notify, { message = msg, level = "error" }) end
      if cordanui and cordanui.log then pcall(cordanui.log.error, msg) end
      sending = false
      return
    end
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
  local model_label = selected_model or cfg("default_model", "grok-code")
  local header = "Chat (" .. #history .. " msgs) [" .. model_label .. "] — Enter send, Esc close, /clear wipe, /model pick"
  local draft_line
  if sending then
    draft_line = { content = "...thinking...", fg = "tertiary" }
  else
    draft_line = { content = "> " .. draft, fg = "secondary" }
  end
  return {
    { content = header, fg = "primary", bold = true },
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

    -- slash commands
    if draft:sub(1, 1) == "/" then
      if draft == "/clear" then
        history = {}
        save_history()
        if cord and cord.ui and cord.ui.notify then pcall(cord.ui.notify, "history cleared") end
        draft = ""
        return true
      elseif draft == "/model" then
        draft = ""
        local models = getModels()
        if not models or #models == 0 then
          if cord and cord.ui and cord.ui.notify then pcall(cord.ui.notify, { message = "no models available", level = "warn" }) end
          if cordanui and cordanui.log then pcall(cordanui.log.warn, "cordanui-chat /model: getModels returned empty") end
          return true
        end
        local items = {}
        for _, m in ipairs(models) do items[#items + 1] = m.display or m.id or tostring(m) end
        if #items == 0 then
          if cord and cord.ui and cord.ui.notify then pcall(cord.ui.notify, { message = "no models available", level = "warn" }) end
          return true
        end
        if cord and cord.ui and cord.ui.pick then
          local ok, idx = pcall(cord.ui.pick, { title = "Model", items = items })
          if not ok then
            if cord and cord.ui and cord.ui.notify then pcall(cord.ui.notify, { message = "pick failed: " .. tostring(idx), level = "error" }) end
          elseif idx and models[idx] then
            save_model(models[idx].id)
            if cord and cord.ui and cord.ui.notify then pcall(cord.ui.notify, "model: " .. models[idx].id) end
          end
        else
          if cord and cord.ui and cord.ui.notify then pcall(cord.ui.notify, { message = "pick not available (headless). models: " .. table.concat(items, ", "), level = "warn" }) end
        end
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
    do_llm_request()
    return true
  end

  if key == "backspace" then
    if #draft > 0 then draft = draft:sub(1, -2) end
    return true
  end

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
  load_model()
  -- pre-warm models cache (non-blocking best effort)
  pcall(getModels)
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
  draft = ""
  sending = false
  return "history cleared"
end

local function pickModel()
  local models = getModels()
  if not models or #models == 0 then return "no models available" end
  local items = {}
  for _, m in ipairs(models) do items[#items + 1] = m.display or m.id or tostring(m) end
  if #items == 0 then return "no models available" end
  if not (cord and cord.ui and cord.ui.pick) then
    return "pick not available (headless). models: " .. table.concat(items, ", ")
  end
  local ok, idx = pcall(cord.ui.pick, { title = "Model", items = items })
  if not ok then return "pick failed: " .. tostring(idx) end
  if not idx then return "cancelled" end
  local m = models[idx]
  if m and m.id then
    save_model(m.id)
    return "model: " .. m.id
  end
  return "cancelled"
end

plugin.commands = {
  ["cordanui-chat.open"] = { run = openChat, desc = "Open chat" },
  ["cordanui-chat.clear"] = { run = clearChat, desc = "Clear history" },
  ["cordanui-chat.model"] = { run = pickModel, desc = "Pick model (from cordanui-agents /models)" },
}

return plugin
