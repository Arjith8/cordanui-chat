plugin = {}

-- auto-start agents backend on install/open (callback via top-level load)
-- This runs when TUI loads the plugin (activate) and again on each `open`.
-- Host has no explicit on_install hook - top-level is the closest (AGENTS.md:10.2).
pcall(function()
  if cord and cord.services and cord.services.is_running and cord.services.start then
    local ok, running = pcall(cord.services.is_running, "cordanui-agents")
    if ok and not running then
      local ok2, err = pcall(cord.services.start, "cordanui-agents")
      if not ok2 and cord and cord.ui and cord.ui.notify then
        pcall(cord.ui.notify, { message = "failed to auto-start cordanui-agents: " .. tostring(err), level = "error" })
      elseif ok2 and cordanui and cordanui.log then
        pcall(cordanui.log.info, "cordanui-chat: auto-started cordanui-agents")
      end
    end
  end
end)

-- state (Lua upvalues = view model, persists across frames)
local history = {}
local draft = ""
local sending = false
local pending_llm = false
local selected_model = nil
local cached_models = nil
local cached_at = 0
local spinner_tick = 0
local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

-- suggestion dropdown state (not popups, inline lists)
local suggest_idx = 1
local suggest_type = nil -- "slash" | "mention" | nil
local slash_cmds = { "/clear", "/model", "/help" }

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
-- @ mentions: @1-6 / @<sno>-<sno> (sno = serial, 1-based visible order; uuid fallback) -> assign to agent via cord.goals
-- ---------------------------------------------------------------------------
local function handle_mentions(text)
  if not (cord and cord.goals and cord.goals.assign) then return {} end
  local assigned = {}
  -- Numeric sno range @1-6 (preferred over uuid)
  for s, e in text:gmatch("@(%d+)%-(%d+)") do
    local ok, ids = pcall(cord.goals.assign_range, s, e, { model = selected_model })
    if ok and ids and #ids > 0 then
      for _, id in ipairs(ids) do table.insert(assigned, id) end
      pcall(cord.ui.notify, { message = "assigned @" .. s .. "-" .. e .. " (" .. #ids .. " tasks) to agent", level = "info" })
    elseif not ok then
      pcall(cord.ui.notify, { message = "assign @" .. s .. "-" .. e .. " failed: " .. tostring(ids), level = "error" })
    end
  end
  -- Single @sno or @<id> (not part of range) — sno (serial, 1-based) preferred, uuid fallback
  local text_no_ranges = text:gsub("@%d+%-%d+", "")
  for id in text_no_ranges:gmatch("@([%w%.%-_]+)") do
    local ok_sno, ids_sno = pcall(cord.goals.assign_range, id, id, { model = selected_model })
    if ok_sno and ids_sno and #ids_sno > 0 then
      for _, nid in ipairs(ids_sno) do table.insert(assigned, nid) end
      pcall(cord.ui.notify, { message = "assigned @" .. id .. " (sno) to agent", level = "info" })
    else
      local ok, _ = pcall(cord.goals.assign, id, { model = selected_model })
      if ok then
        table.insert(assigned, id)
        pcall(cord.ui.notify, { message = "assigned @" .. id .. " to agent", level = "info" })
      else
        pcall(cord.ui.notify, { message = "assign @" .. id .. " failed: not found", level = "warn" })
      end
    end
  end
  return assigned
end

-- ---------------------------------------------------------------------------
-- suggestion dropdowns (inline, not popups) for / cmds and @ mentions
-- ---------------------------------------------------------------------------
local function slashCandidates()
  if draft:sub(1, 1) ~= "/" then return nil end
  local prefix = draft:lower()
  local out = {}
  for _, c in ipairs(slash_cmds) do
    if c:sub(1, #prefix) == prefix then table.insert(out, c) end
  end
  -- also "/" alone shows all
  if #out == 0 then return nil end
  return out
end

local function mentionCandidates()
  if draft:sub(1, 1) == "/" then return nil end
  local at_pos = draft:match(".*()@")
  if not at_pos then return nil end
  local token = draft:sub(at_pos + 1)
  if token:find("%s") then return nil end
  -- token may be "1", "1-6", "abc", ""; empty means show all
  local ok, goals = pcall(function()
    if not (cord and cord.goals and cord.goals.list) then return {} end
    local ok2, list = pcall(cord.goals.list)
    if ok2 and type(list) == "table" then return list else return {} end
  end)
  if not ok or type(goals) ~= "table" or #goals == 0 then return nil end
  local filter = token:match("^([^%-]+)") or token
  filter = filter:lower()
  local out = {}
  for _, g in ipairs(goals) do
    local sno = tostring(g.index or "")
    local id = g.id or ""
    local title = g.title or ""
    local status = g.status or ""
    local match = false
    if filter == "" then match = true
    elseif sno:lower():find(filter, 1, true) or id:lower():find(filter, 1, true) or title:lower():find(filter, 1, true) then match = true end
    if match then
      table.insert(out, { display = sno .. ": " .. title .. " [" .. status .. "]", insert = "@" .. sno .. " ", sno = sno, id = id })
      if #out >= 8 then break end
    end
  end
  if #out == 0 then return nil end
  return out
end

-- ---------------------------------------------------------------------------
-- models: via backend GET /models, cached 5m
-- per CHAT-AGENTS-BACKEND-SPEC.md §2.2
-- ---------------------------------------------------------------------------
local function getModels()
  local now = os.time()
  -- always verify backend still running, even on cache hit — otherwise deleting
  -- cordanui-agents would stay hidden behind a 5m cache and user sees no error
  local backend_ok, backend_running = false, false
  if cord and cord.services and cord.services.is_running then
    local ok, r = pcall(cord.services.is_running, "cordanui-agents")
    backend_ok, backend_running = ok, r
    if not (ok and r) then
      -- invalidate stale cache and fall through to error path below
      if cached_models and #cached_models > 0 then
        cached_models = nil
        cached_at = 0
      end
    elseif cached_models and (now - cached_at) < 300 and type(cached_models) == "table" and #cached_models > 0 then
      if cordanui and cordanui.log then pcall(cordanui.log.info, "cordanui-chat getModels: cache hit " .. #cached_models .. " models, backend still active") end
      return cached_models
    end
  else
    -- no services API at all — invalidate cache
    if cached_models and #cached_models > 0 then
      cached_models = nil
      cached_at = 0
    end
  end

  -- backend is the only source of models — no direct fallback
  if cord and cord.services and cord.services.is_running then
    local ok_running, running = backend_ok, backend_running
    -- if we already probed above, reuse; otherwise probe now (covers first call where cache was empty)
    if backend_ok == false and backend_running == false then
      local ok2, r2 = pcall(cord.services.is_running, "cordanui-agents")
      ok_running, running = ok2, r2
    end
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
          if cord and cord.ui and cord.ui.notify then pcall(cord.ui.notify, { message = "agent backend active: " .. #list .. " model(s) available", level = "info" }) end
          return list
        elseif ok2 and type(list) == "table" then
          if cordanui and cordanui.log then pcall(cordanui.log.info, "cordanui-chat getModels: backend returned empty list") end
          if cord and cord.ui and cord.ui.notify then pcall(cord.ui.notify, { message = "agent backend returned no models — install/activate a provider plugin", level = "warn" }) end
          cached_models = {}
          cached_at = now
          return cached_models
        end
      end
      if cordanui and cordanui.log then pcall(cordanui.log.info, "cordanui-chat: /models via service failed") end
      if cord and cord.ui and cord.ui.notify then pcall(cord.ui.notify, { message = "agent backend error: GET /models failed", level = "error" }) end
      cached_models = {}
      cached_at = now
      return cached_models
    else
      local msg = "agent backend not active: cordanui-agents is not running — start it via `cordanui service start cordanui-agents` or TUI with --with-agents"
      if cordanui and cordanui.log then pcall(cordanui.log.warn, "cordanui-chat getModels: " .. msg) end
      if cord and cord.ui and cord.ui.notify then pcall(cord.ui.notify, { message = msg, level = "error" }) end
      cached_models = {}
      cached_at = now
      return cached_models
    end
  else
    local msg = "agent backend not active: cord.services unavailable — host does not support services"
    if cordanui and cordanui.log then pcall(cordanui.log.warn, "cordanui-chat getModels: " .. msg) end
    if cord and cord.ui and cord.ui.notify then pcall(cord.ui.notify, { message = msg, level = "error" }) end
    cached_models = {}
    cached_at = now
    return cached_models
  end
end

-- ---------------------------------------------------------------------------
-- LLM: backend POST /chat only (no direct fallback)
-- per CHAT-AGENTS-BACKEND-SPEC.md §2.3 — backend is the only transport
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
-- background thread/process so UI stays responsive (loader animates)
local pending_file = nil
local pending_start = 0

local function check_backend_running()
  if not (cord and cord.services and cord.services.is_running) then
    return false, "agent backend not active: cord.services unavailable"
  end
  local ok_running, running = pcall(cord.services.is_running, "cordanui-agents")
  if not (ok_running and running) then
    return false, "agent backend not active: cordanui-agents is not running — start it via `cordanui service start cordanui-agents` or TUI with --with-agents"
  end
  return true, nil
end

local function spawn_via_backend_async(model, messages)
  local ok, running = check_backend_running()
  if not ok then
    return false, running
  end
  -- use curl in background so panel stays responsive
  local body_ok, body = pcall(cordanui.json.encode, { model = model, messages = messages, temperature = 0.7 })
  if not body_ok or not body then
    return false, "failed to encode request"
  end
  -- check curl exists
  if os.execute("command -v curl > /dev/null 2>&1") ~= 0 then
    return false, "curl not found - please install curl"
  end
  -- temp file for response
  local tmp = os.tmpname()
  pending_file = tmp
  pending_start = os.time()
  -- escape single quotes for shell
  local esc_body = body:gsub("'", "'\\''")
  -- curl to backend's /chat (addr http://127.0.0.1:8081 per cordanui-agents manifest)
  -- --max-time 120 matches host timeout, -s silent, -o file, & background
  -- on curl failure, write error JSON so poll doesn't wait 130s
  local url = "http://127.0.0.1:8081/chat"
  local cmd = string.format("curl -s -X POST '%s' -H 'Content-Type: application/json' -d '%s' -o '%s' --max-time 120 || echo '{\"error\":\"curl failed: backend not reachable\"}' > '%s' &", url, esc_body, tmp, tmp)
  local exec_ok = os.execute(cmd)
  if cordanui and cordanui.log then
    pcall(cordanui.log.info, "cordanui-chat spawn curl: " .. cmd .. " ok=" .. tostring(exec_ok))
  end
  return true, nil
end

local function poll_pending_async()
  if not pending_file or not sending then return end
  local f = io.open(pending_file, "r")
  if not f then
    -- file not yet created (curl hasn't started) — check timeout
    if os.time() - pending_start > 130 then
      history[#history + 1] = { role = "assistant", content = "⚠ timeout waiting for backend", at = os.date("!%Y-%m-%dT%H:%M:%SZ") }
      save_history()
      sending = false
      pending_file = nil
      pcall(cord.ui.notify, { message = "chat timeout", level = "error" })
    end
    return
  end
  local content = f:read("*a")
  f:close()
  -- curl creates file immediately empty, then fills when done.
  -- If file is empty, still waiting.
  if not content or content == "" then
    if os.time() - pending_start > 130 then
      history[#history + 1] = { role = "assistant", content = "⚠ timeout waiting for backend", at = os.date("!%Y-%m-%dT%H:%M:%SZ") }
      save_history()
      sending = false
      os.remove(pending_file)
      pending_file = nil
      pcall(cord.ui.notify, { message = "chat timeout", level = "error" })
    end
    return
  end
  -- got response
  os.remove(pending_file)
  pending_file = nil
  local ok2, parsed = pcall(cordanui.json.decode, content)
  if not ok2 or not parsed then
    local msg = "invalid JSON from backend"
    history[#history + 1] = { role = "assistant", content = "⚠ " .. msg, at = os.date("!%Y-%m-%dT%H:%M:%SZ") }
    save_history()
    sending = false
    pcall(cord.ui.notify, { message = msg, level = "error" })
    return
  end
  if parsed.error then
    local detail = parsed.detail and (": " .. parsed.detail) or ""
    local msg = parsed.error .. detail
    history[#history + 1] = { role = "assistant", content = "⚠ " .. msg, at = os.date("!%Y-%m-%dT%H:%M:%SZ") }
    save_history()
    sending = false
    pcall(cord.ui.notify, { message = msg, level = "error" })
    if msg and msg:find("unknown model") then cached_models = nil end
    return
  end
  local out = parsed.content or ""
  history[#history + 1] = { role = "assistant", content = out, at = os.date("!%Y-%m-%dT%H:%M:%SZ") }
  save_history()
  sending = false
end

local function do_llm_request()
  local model = selected_model or cfg("default_model", "grok-code") or "grok-code"
  local messages = build_messages()
  local ok, err = spawn_via_backend_async(model, messages)
  if not ok then
    local msg = err or "agent backend not active"
    history[#history + 1] = { role = "assistant", content = "⚠ " .. msg, at = os.date("!%Y-%m-%dT%H:%M:%SZ") }
    save_history()
    if cord and cord.ui and cord.ui.notify then pcall(cord.ui.notify, { message = msg, level = "error" }) end
    if cordanui and cordanui.log then pcall(cordanui.log.error, "cordanui-chat viaBackend: " .. msg) end
    sending = false
    pending_file = nil
    if msg and msg:find("unknown model") then cached_models = nil end
    return
  end
  -- keep sending true; poll will clear it when file arrives
end

-- ---------------------------------------------------------------------------
-- panel
-- ---------------------------------------------------------------------------
local function draw()
  -- if a send was queued in on_key, kick off the LLM now that one frame of
  -- spinner has already been drawn - this makes the loader visible
  if pending_llm and sending then
    pending_llm = false
    -- run in pcall so errors still clear sending; this now spawns curl in background (&)
    pcall(do_llm_request)
  end
  -- poll background curl result - non-blocking, keeps spinner animating
  if pending_file and sending then
    pcall(poll_pending_async)
  end
  if sending then spinner_tick = spinner_tick + 1 end
  local items = {}
  for _, m in ipairs(history) do
    items[#items + 1] = m.role .. ": " .. m.content
  end
  local model_label = selected_model or cfg("default_model", "grok-code")
  local header
  if sending then
    local frame = SPINNER[(spinner_tick % #SPINNER) + 1]
    header = frame .. " Chat (" .. #history .. " msgs) [" .. model_label .. "] — thinking... (q to cancel)"
  else
    header = "Chat (" .. #history .. " msgs) [" .. model_label .. "] — Enter send, q close (when empty), / for cmds, @ for sno"
  end
  local draft_line
  if sending then
    local frame = SPINNER[(spinner_tick % #SPINNER) + 1]
    local dots = string.rep(".", (spinner_tick % 3) + 1)
    draft_line = { content = frame .. " thinking" .. dots .. " (" .. model_label .. ")", fg = "tertiary", bold = true }
  else
    draft_line = { content = "> " .. draft .. "▏", fg = "secondary" }
  end
  -- inline dropdowns (not popups)
  local slash = slashCandidates()
  local mention = slash and nil or mentionCandidates()
  local widgets = {
    { content = header, fg = "primary", bold = true },
    { items = items, highlight = #items > 0 and #items or nil },
  }
  if slash then
    suggest_type = "slash"
    if suggest_idx > #slash then suggest_idx = #slash end
    if suggest_idx < 1 then suggest_idx = 1 end
    local disp = {}
    for _, c in ipairs(slash) do disp[#disp + 1] = c .. " — slash cmd" end
    table.insert(widgets, { content = " / commands (↑↓ navigate, Tab complete, Enter run):", fg = "tertiary" })
    table.insert(widgets, { items = disp, highlight = suggest_idx })
  elseif mention then
    suggest_type = "mention"
    if suggest_idx > #mention then suggest_idx = #mention end
    if suggest_idx < 1 then suggest_idx = 1 end
    local disp = {}
    for _, m in ipairs(mention) do disp[#disp + 1] = m.display end
    table.insert(widgets, { content = " @ sno (↑↓ navigate, Tab complete):", fg = "tertiary" })
    table.insert(widgets, { items = disp, highlight = suggest_idx })
  else
    suggest_type = nil
    suggest_idx = 1
  end
  table.insert(widgets, draft_line)
  if not slash and not mention and draft ~= "" and draft:sub(1, 1) ~= "/" and not draft:find("@") then
    table.insert(widgets, { content = " tip: type / for cmds or @<sno> to assign", fg = "tertiary" })
  end
  return widgets
end

local chat_buffer_id = nil

local function on_key(key)
  if key == "esc" then
    -- Esc now does nothing (was closing buffer and hanging) - use q to close
    return true
  end
  if key == "q" and draft == "" then
    sending = false
    pending_llm = false
    pending_file = nil
    return false
  end

  -- inline dropdown navigation (not popups) for / and @
  do
    local slash = slashCandidates()
    local mention = slash and nil or mentionCandidates()
    local has = (slash and #slash > 0) or (mention and #mention > 0)
    if has then
      if key == "up" then
        suggest_idx = math.max(1, suggest_idx - 1)
        return true
      elseif key == "down" then
        local max = slash and #slash or #mention
        suggest_idx = math.min(max, suggest_idx + 1)
        return true
      elseif key == "tab" or key == "shift+tab" then
        if slash then
          draft = slash[suggest_idx] or draft
          return true
        elseif mention then
          local sel = mention[suggest_idx]
          if sel and sel.insert then
            local at_pos = draft:match(".*()@")
            if at_pos then draft = draft:sub(1, at_pos) .. sel.insert
            else draft = draft .. sel.insert end
          end
          return true
        end
      end
    end
  end

  if key == "enter" then
    if sending then return true end
    if draft == "" then return true end

    -- if slash dropdown visible, Enter completes partial prefix to highlighted suggestion
    -- slash commands
    if draft:sub(1, 1) == "/" then
      do
        local sc = slashCandidates()
        if sc and #sc > 0 then
          local exact = false
          for _, c in ipairs(sc) do if c == draft then exact = true break end end
          if not exact then draft = sc[suggest_idx] or sc[1] end
        end
      end
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
        -- Panel on_key is sync (no Tokio reactor) — cord.ui.pick is async and
        -- would panic "no reactor running" if called here. Use first model
        -- directly; full picker is available via <leader>; cordanui-chat.model
        local first = models[1]
        if first and first.id then
          save_model(first.id)
          if cord and cord.ui and cord.ui.notify then pcall(cord.ui.notify, "model: " .. first.id .. " (use <leader>; cordanui-chat.model for picker)") end
        else
          if cord and cord.ui and cord.ui.notify then pcall(cord.ui.notify, { message = "pick not available in panel — use <leader>; cordanui-chat.model", level = "warn" }) end
        end
        return true
      elseif draft == "/help" then
        if cord and cord.ui and cord.ui.notify then pcall(cord.ui.notify, "/clear wipe history · /model pick model (↑↓ Tab complete) · @<sno> assign sno range, Tab completes") end
        draft = ""
        return true
      else
        if cord and cord.ui and cord.ui.notify then
          pcall(cord.ui.notify, { message = "unknown command: " .. draft .. " (try /help)", level = "warn" })
        end
        draft = ""
        return true
      end
    end

    -- @ mentions -> assign tasks to agent (e.g. @1-6, @<id>-<id>, @<id>)
    pcall(handle_mentions, draft)

    -- push user message - defer LLM to next draw so spinner is visible
    local at = os.date("!%Y-%m-%dT%H:%M:%SZ")
    history[#history + 1] = { role = "user", content = draft, at = at }
    draft = ""
    sending = true
    pending_llm = true
    save_history()
    return true
  end

  if key == "backspace" then
    if #draft > 0 then draft = draft:sub(1, -2) end
    suggest_idx = 1
    return true
  end

  if #key == 1 then
    draft = draft .. key
    suggest_idx = 1
    return true
  end

  if key == "space" then
    draft = draft .. " "
    suggest_idx = 1
    return true
  end

  return false
end

local function openChat()
  load_history()
  load_model()
  -- auto-start on open if not running (covers case where plugin was installed before agents backend existed)
  pcall(function()
    if cord and cord.services and cord.services.is_running and cord.services.start then
      local ok, running = pcall(cord.services.is_running, "cordanui-agents")
      if ok and not running then
        local ok2, err = pcall(cord.services.start, "cordanui-agents")
        if not ok2 and cord and cord.ui and cord.ui.notify then
          pcall(cord.ui.notify, { message = "failed to auto-start cordanui-agents: " .. tostring(err), level = "error" })
        end
      end
    end
  end)
  -- explicit backend check — status is returned as command result so it isn't
  -- clobbered by the host's `poll_command_results` overwriting a separate `notify`.
  local backend_status = "unknown"
  pcall(function()
    if not (cord.services and cord.services.is_running) then
      local msg = "agent backend not active: cord.services unavailable"
      backend_status = "backend unavailable"
      if cordanui and cordanui.log then pcall(cordanui.log.warn, "cordanui-chat open: " .. msg) end
      return
    end
    local ok, running = pcall(cord.services.is_running, "cordanui-agents")
    if ok and running then
      backend_status = "backend active"
      if cordanui and cordanui.log then pcall(cordanui.log.info, "cordanui-chat open: backend active") end
    else
      local detail = (not ok) and (" (" .. tostring(running) .. ")") or ""
      local msg = "agent backend not active: cordanui-agents is not running" .. detail
      backend_status = "backend not running"
      if cordanui and cordanui.log then pcall(cordanui.log.warn, "cordanui-chat open: " .. msg) end
    end
  end)
  -- pre-warm models cache (best effort) — result folded into final return
  local prewarm_ok, prewarm_models = pcall(getModels)
  local is_provider_list = prewarm_ok and prewarm_models and #prewarm_models > 0 and not (#prewarm_models == 1 and prewarm_models[1].id == "cordanui-agents")
  if is_provider_list then
    backend_status = backend_status .. " — " .. #prewarm_models .. " model(s)"
  elseif prewarm_ok and prewarm_models and (#prewarm_models == 0 or (#prewarm_models == 1 and prewarm_models[1].id == "cordanui-agents")) and backend_status:find("active") then
    backend_status = backend_status .. " — no providers (install provider plugin + set api_key)"
    if cord and cord.ui and cord.ui.notify then
      pcall(cord.ui.notify, { message = "hey you haven't set anything up pls do that first — no provider configured — install/activate a provider plugin (e.g. opencode-zen-provider) and set its api_key in plugin settings", level = "warn" })
    end
  elseif backend_status:find("not running") or backend_status:find("unavailable") then
    backend_status = backend_status .. " — no models (backend down)"
  end
  -- Prefer buffer (sheet-tab, Claude Code/Codex style) — host built this after
  -- the original chat spec (which used popup panel). Fallback to panel for
  -- older hosts / headless tests.
  local opened_via = nil
  if cord and cord.buffers and cord.buffers.create and cord.buffers.select then
    local ok, id = pcall(cord.buffers.create, { name = "Chat", draw = draw, on_key = on_key })
    if ok and id then
      chat_buffer_id = id
      pcall(cord.buffers.select, id)
      opened_via = "buffer"
    else
      if cordanui and cordanui.log then pcall(cordanui.log.warn, "cordanui-chat: cord.buffers.create failed: " .. tostring(id)) end
    end
  end
  if not opened_via and cord and cord.ui and cord.ui.show_panel then
    cord.ui.show_panel{
      title = "Chat — cordanui-chat",
      draw = draw,
      on_key = on_key,
    }
    opened_via = "panel"
  end
  if not opened_via then
    if cordanui and cordanui.log then pcall(cordanui.log.warn, "cordanui-chat: no UI surface available (headless)") end
  end
  return "chat opened — " .. backend_status .. (opened_via and (" (" .. opened_via .. ")") or "")
end

local function clearChat()
  history = {}
  save_history()
  if cord and cord.ui and cord.ui.notify then pcall(cord.ui.notify, "history cleared") end
  draft = ""
  sending = false
  pending_llm = false
  if pending_file then pcall(os.remove, pending_file) pending_file = nil end
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

local function assignCommand()
  if not (cord and cord.goals and cord.goals.assign_range) then
    if cord and cord.ui and cord.ui.notify then pcall(cord.ui.notify, { message = "cord.goals not available — update host to get @1-6 assign", level = "error" }) end
    return "cord.goals not available"
  end
  -- prompt for range: supports @1-6 / @<sno>-<sno> (sno = serial, visible order; uuid dotted fallback; bare 1-6 also ok)
  local range = nil
  if cord and cord.ui and cord.ui.input then
    local ok, val = pcall(cord.ui.input, { title = "Assign to agent", placeholder = "@1-6 or @<sno>-<sno> (sno=serial; uuid fallback)", prefill = "@" })
    if not ok then return "assign cancelled: " .. tostring(val) end
    range = val
  else
    return "assign requires cord.ui.input (headless: use @1-6 inside chat message)"
  end
  if not range or range:match("^%s*$") then return "cancelled" end
  range = range:gsub("^%s+", ""):gsub("%s+$", "")
  -- normalize bare 1-6 -> @1-6 so handle_mentions finds it
  if not range:find("@") then
    if range:match("^%d+%s*%-%s*%d+$") or range:match("^%d+$") or range:match("^[%w%.%-_]+%s*%-%s*[%w%.%-_]+$") or range:match("^[%w%.%-_]+$") then
      range = "@" .. range:gsub("%s+", "")
    end
  end
  local assigned = handle_mentions(range)
  if assigned and #assigned > 0 then
    return "assigned " .. #assigned .. " task(s) " .. range .. " to agent [" .. (selected_model or cfg("default_model", "grok-code") or "grok-code") .. "]"
  else
    return "no tasks matched " .. range
  end
end

plugin.commands = {
  ["cordanui-chat.open"] = { run = openChat, desc = "Open chat (buffer tab)" },
  ["cordanui-chat.clear"] = { run = clearChat, desc = "Clear history" },
  ["cordanui-chat.model"] = { run = pickModel, desc = "Pick model (from cordanui-agents /models)" },
  ["cordanui-chat.assign"] = { run = assignCommand, desc = "Assign @1-6 / @<sno>-<sno> range to agent (sno=serial)" },
}

return plugin
