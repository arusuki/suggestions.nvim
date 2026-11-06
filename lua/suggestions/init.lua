local M = {}
local api = vim.api
local backend = require("suggestions.backend")
local ui = require("suggestions.ui")
local completion = require("suggestions.completion")
local ns = api.nvim_create_namespace("suggestions.cmdline")
local state = { enabled = false, levels = {}, mappings = {}, serial = 0, block = {} }
local queue_render, refresh

local function active()
  local level, model = 0, nil
  for key, value in pairs(state.levels) do
    if key > level then
      level, model = key, value
    end
  end
  return model
end

local function reset_items(model)
  if model.cancel then
    model.cancel()
    model.cancel = nil
  end
  model.items, model.selected, model.ghost, model.suggestion = {}, 0, nil, nil
  model.loading, model.error = false, nil
  model.want_select = nil
end

local function suggest(model)
  model.ghost, model.suggestion = nil, nil
  if model.firstc ~= ":" or model.pos ~= #model.text or model.text == "" then
    return
  end
  local function use(candidate)
    if candidate and candidate.text:sub(1, #model.text) == model.text and #candidate.text > #model.text then
      model.ghost = candidate.text:sub(#model.text + 1)
      model.suggestion = candidate
      return true
    end
  end
  -- An explicit selection owns the preview, even when it rewrites the input.
  if model.selected > 0 then
    use(model.items[model.selected])
    return
  end
  local prefix = model.shell or ""
  local text = model.text:sub(#prefix + 1)
  if text == "" then
    return
  end
  local history
  if model.shell then
    history = backend.history(text, 1)[1]
  else
    history = completion.ex_history(text)
  end
  if history and use({ text = prefix .. history, cursor = #prefix + #history }) then
    return
  end
  for _, item in ipairs(model.items) do
    if use(item) then
      return
    end
  end
end

local function render()
  state.render_queued = false
  if not state.enabled then
    return
  end
  local model = active()
  if not model then
    ui.close()
    vim.cmd.redraw()
    return
  end
  refresh(model)
  model.block = state.block
  ui.render(model, state.config.ui)
  -- Scheduled UI updates do not automatically redraw while native cmdline
  -- input is blocking. Flush the drawer now, including async zsh results.
  ui.flush()
end

queue_render = function()
  if state.render_queued then
    return
  end
  state.render_queued = true
  vim.schedule(function()
    local ok, err = pcall(render)
    if not ok then
      M.disable()
      vim.notify("suggestions.nvim: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

local function complete(model, serial)
  if not state.enabled or active() ~= model or model.serial ~= serial then
    return
  end
  if (model.firstc ~= ":" and model.firstc ~= "/" and model.firstc ~= "?") or model.text == "" then
    return
  end
  if model.loading then
    return
  end
  if model.shell and model.pos >= #model.shell then
    model.loading = true
    local prefix, text, pos = model.shell, model.text:sub(#model.shell + 1), model.pos - #model.shell
    backend.request(text, pos, model.cwd, function(items, err)
      if not state.enabled or active() ~= model or model.serial ~= serial then
        return
      end
      model.loading, model.error = false, err
      model.items = {}
      for _, item in ipairs(items or {}) do
        item.label = item.text
        item.text, item.cursor = prefix .. item.text, #prefix + item.cursor
        model.items[#model.items + 1] = item
      end
      if model.want_select and #model.items > 0 then
        model.selected = model.want_select > 0 and 1 or #model.items
      end
      model.want_select = nil
      suggest(model)
      queue_render()
    end)
  elseif not model.shell then
    model.loading = true
    model.cancel = completion.request(model, state.config, function(items, err)
      if not state.enabled or active() ~= model or model.serial ~= serial then
        return
      end
      model.loading, model.error = false, err
      model.items = items or {}
      if model.want_select and #model.items > 0 then
        model.selected = model.want_select > 0 and 1 or #model.items
      end
      model.want_select = nil
      suggest(model)
      queue_render()
    end)
  end
end

refresh = function(model)
  local identity = model.firstc .. "\0" .. model.text .. "\0" .. model.pos
  if model.identity == identity then
    return
  end
  model.identity = identity
  state.serial = state.serial + 1
  model.serial = state.serial
  reset_items(model)
  model.shell = model.firstc == ":" and completion.shell_prefix(model.text) or nil
  if model.navigation and model.text ~= model.navigation.expected then
    model.navigation = nil
  end
  suggest(model)
  local serial = model.serial
  if state.config.completion.auto then
    vim.defer_fn(function()
      complete(model, serial)
    end, state.config.completion.debounce_ms)
  end
end

local function flatten(chunks)
  local parts = {}
  for _, chunk in ipairs(chunks) do
    parts[#parts + 1] = chunk[2]
  end
  return table.concat(parts)
end

local function on_ui(event, ...)
  if not state.enabled then
    return
  end
  local args = { ... }
  if event == "cmdline_show" then
    local chunks, pos, firstc, prompt, indent, level = unpack(args)
    local previous = active()
    if previous and previous ~= state.levels[level] then
      reset_items(previous)
      previous.identity = nil
    end
    local model = state.levels[level]
      or {
        items = {},
        selected = 0,
        cwd = state.cwd or vim.fn.getcwd(),
        buf = state.buf or api.nvim_get_current_buf(),
      }
    model.text, model.pos, model.firstc, model.prompt = flatten(chunks), pos, firstc, prompt
    model.indent, model.special = indent, nil
    state.levels[level] = model
  elseif event == "cmdline_pos" then
    local model = state.levels[args[2]]
    if model then
      model.pos = args[1]
    end
  elseif event == "cmdline_special_char" then
    local model = state.levels[args[3]]
    if model then
      model.special = args[1]
    end
  elseif event == "cmdline_hide" then
    if state.levels[args[1]] then
      reset_items(state.levels[args[1]])
    end
    state.levels[args[1]] = nil
  elseif event == "cmdline_block_show" then
    state.block = {}
    for _, chunks in ipairs(args[1]) do
      state.block[#state.block + 1] = flatten(chunks)
    end
  elseif event == "cmdline_block_append" then
    state.block[#state.block + 1] = flatten(args[1])
  elseif event == "cmdline_block_hide" then
    state.block = {}
  else
    return false
  end
  queue_render()
  return true
end

local function keycodes(keys)
  return api.nvim_replace_termcodes(keys, true, false, true)
end

local function apply(model, item)
  model.navigation = nil
  reset_items(model)
  model.identity = nil
  vim.fn.setcmdline(item.text, item.cursor + 1)
end

local function cycle(model, direction)
  if #model.items == 0 then
    model.want_select = direction
    complete(model, model.serial)
    return
  end
  if model.selected == 0 then
    model.selected = direction > 0 and 1 or #model.items
  else
    model.selected = (model.selected - 1 + direction) % #model.items + 1
  end
  suggest(model)
  queue_render()
end

local function history(model, direction)
  if not model.shell then
    return false
  end
  if not model.navigation then
    local prefix = model.text:sub(#model.shell + 1)
    model.navigation = { draft = model.text, matches = backend.history(prefix), index = 0 }
  end
  local nav = model.navigation
  if #nav.matches == 0 then
    return false
  end
  nav.index = math.max(0, math.min(#nav.matches, nav.index + direction))
  nav.expected = nav.index == 0 and nav.draft or model.shell .. nav.matches[nav.index]
  vim.fn.setcmdline(nav.expected)
  return true
end

function M._key(action)
  local fallback = state.config.keys[action]
  -- A mapped <Esc> executes an Ex command (Vim compatibility); <C-c> is
  -- the unambiguous cancel operation, including in nested/search prompts.
  if action == "close" then
    return keycodes("<C-c>")
  end
  local model = active()
  local cmdtype = vim.fn.getcmdtype()
  if not model or (cmdtype ~= ":" and cmdtype ~= "/" and cmdtype ~= "?") then
    return keycodes(fallback)
  end
  if cmdtype ~= ":" and (not state.config.fuzzy.enabled or not state.config.fuzzy.search) then
    return keycodes(fallback)
  end
  -- Mappings may run before the next UI redraw has delivered cmdline_show.
  model.text, model.pos = vim.fn.getcmdline(), vim.fn.getcmdpos() - 1
  refresh(model)
  if action == "next" or action == "previous" then
    cycle(model, action == "next" and 1 or -1)
    return ""
  elseif action == "confirm" then
    local item = model.items[model.selected]
    if item then
      apply(model, item)
      return ""
    end
  elseif action == "accept" or action == "accept_word" or action == "line_end" then
    local item = model.items[model.selected] or model.suggestion
    if item and (model.selected > 0 or model.pos == #model.text) then
      if action == "accept_word" and model.ghost then
        local word = model.ghost:match("^%s*[^%s/]+/?%s*") or model.ghost
        apply(model, { text = model.text .. word, cursor = #model.text + #word })
      else
        apply(model, item)
      end
      return ""
    end
    if action == "accept_word" then
      return keycodes("<S-Right>")
    end
    if action == "line_end" then
      return keycodes("<End>")
    end
  elseif action == "history_previous" or action == "history_next" then
    local previous = action == "history_previous"
    if model.selected > 0 then
      cycle(model, previous and -1 or 1)
      return ""
    end
    if history(model, previous and 1 or -1) then
      return ""
    end
  elseif action == "line_start" then
    return keycodes("<Home>")
  elseif action == "word_left" then
    return keycodes("<S-Left>")
  elseif action == "kill_end" then
    apply(model, { text = model.text:sub(1, model.pos), cursor = model.pos })
    return ""
  end
  return keycodes(fallback)
end

function M.disable()
  state.enabled = false
  state.serial = state.serial + 1
  for _, model in pairs(state.levels) do
    reset_items(model)
  end
  state.levels, state.block = {}, {}
  pcall(vim.ui_detach, ns)
  pcall(api.nvim_del_augroup_by_name, "Suggestions")
  for _, map in ipairs(state.mappings) do
    local current = vim.fn.maparg(map.lhs, "c", false, true)
    if current.desc == map.desc then
      vim.keymap.del("c", map.lhs)
      if next(map.previous) then
        vim.fn.mapset("c", false, map.previous)
      end
    end
  end
  state.mappings = {}
  backend.stop()
  ui.destroy()
end

function M.enable()
  if state.enabled then
    return
  end
  if not state.config then
    return M.setup()
  end
  assert(vim.fn.has("nvim-0.11") == 1, "suggestions.nvim requires Neovim 0.11+")
  state.enabled = true
  ui.highlights(state.config.highlights)
  backend.setup(state.config.zsh)
  local ok, err = pcall(vim.ui_attach, ns, { ext_cmdline = true }, on_ui)
  if not ok then
    state.enabled = false
    error(err)
  end
  for action, lhs in pairs(state.config.keys) do
    if lhs and lhs ~= "" then
      local desc = "suggestions.nvim: " .. action
      state.mappings[#state.mappings + 1] = { lhs = lhs, desc = desc, previous = vim.fn.maparg(lhs, "c", false, true) }
      vim.keymap.set("c", lhs, function()
        return M._key(action)
      end, { expr = true, silent = true, desc = desc, replace_keycodes = false })
    end
  end
  local group = api.nvim_create_augroup("Suggestions", { clear = true })
  api.nvim_create_autocmd("CmdlineEnter", {
    group = group,
    callback = function()
      state.cwd = vim.fn.getcwd()
      state.buf = api.nvim_get_current_buf()
    end,
  })
  api.nvim_create_autocmd("CmdlineLeave", {
    group = group,
    callback = function()
      if vim.fn.getcmdtype() == ":" and not vim.v.event.abort then
        local text = vim.fn.getcmdline()
        local prefix = completion.shell_prefix(text)
        if prefix then
          backend.remember(text:sub(#prefix + 1))
        end
      end
    end,
  })
  api.nvim_create_autocmd("VimResized", { group = group, callback = queue_render })
  api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      ui.highlights(state.config.highlights)
      queue_render()
    end,
  })
  api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      backend.stop()
      for _, model in pairs(state.levels) do
        reset_items(model)
      end
    end,
  })
end

function M.setup(opts)
  if state.enabled then
    M.disable()
  end
  state.config = require("suggestions.config").resolve(opts)
  if state.config.enabled then
    M.enable()
  end
end

function M.reload()
  if not state.enabled then
    return false
  end
  -- Invalidate callbacks and debounced requests before stopping the worker.
  for _, model in pairs(state.levels) do
    state.serial = state.serial + 1
    model.serial = state.serial
    model.identity, model.navigation = nil, nil
    reset_items(model)
  end
  local ok, err = backend.reload()
  if not ok then
    vim.notify("suggestions.nvim: " .. err, vim.log.levels.WARN)
  end
  queue_render()
  return ok, err
end

function M.toggle()
  if state.enabled then
    M.disable()
  else
    M.enable()
  end
end

function M.inspect()
  local current = vim.deepcopy(active())
  if current then
    current.cancel = nil
  end
  return {
    enabled = state.enabled,
    current = current,
    ui = ui.inspect(),
    backend = backend.status(),
    shell = state.config and state.config.zsh.shell or "zsh",
    fuzzy = state.config and vim.deepcopy(state.config.fuzzy) or require("suggestions.config").defaults.fuzzy,
  }
end

return M
