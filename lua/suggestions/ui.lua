local M = {}
local api = vim.api
local ns = api.nvim_create_namespace("suggestions.render")
local state = {}

local function blend(a, b, ratio)
  local out = 0
  for _, shift in ipairs({ 16, 8, 0 }) do
    local x, y = math.floor(a / 2 ^ shift) % 256, math.floor(b / 2 ^ shift) % 256
    out = out + math.floor(x * (1 - ratio) + y * ratio) * 2 ^ shift
  end
  return out
end

function M.highlights(config)
  local function hl(name)
    return api.nvim_get_hl(0, { name = name, link = false })
  end
  local normal, comment, accent = hl("Normal"), hl("Comment"), hl("Function")
  local dark = vim.o.background == "dark"
  local bg = normal.bg or (dark and 0x14161b or 0xf4f4f4)
  local fg = normal.fg or (dark and 0xe0e2ea or 0x24262d)
  local surface = normal.bg and blend(bg, fg, 0.035) or nil
  local groups = {
    Normal = { fg = fg, bg = surface },
    Muted = { fg = comment.fg or blend(bg, fg, 0.5), bg = surface },
    Ghost = { fg = comment.fg or blend(bg, fg, 0.48), bg = surface, italic = true },
    Border = { fg = blend(bg, fg, 0.2), bg = surface },
    Accent = { fg = accent.fg or 0x89b4fa, bg = surface, bold = true },
    Selection = { fg = fg, bg = blend(bg, accent.fg or fg, 0.16), bold = true },
  }
  for name, value in pairs(groups) do
    value.default = true
    api.nvim_set_hl(0, "Suggestions" .. name, value)
  end
  local configured = {}
  for key, name in pairs({ match = "Match", selected_match = "SelectedMatch" }) do
    local override = config and config[key] or {}
    configured[key] = next(override) ~= nil
    local value = vim.tbl_extend("force", { fg = accent.fg or 0x89b4fa, bold = true }, override)
    -- Explicit setup options survive ColorScheme. With no options, allow the
    -- usual nvim_set_hl overrides; reset colors previously managed by setup.
    value.default = not configured[key] and not (state.configured_highlights or {})[key]
    api.nvim_set_hl(0, "Suggestions" .. name, value)
  end
  state.configured_highlights = configured
end

local function width(text)
  return vim.fn.strdisplaywidth(text)
end
local function clean(text)
  return (text:gsub("[%z\1-\31\127]", " "))
end

local function take(text, columns)
  if width(text) <= columns then
    return text
  end
  local result = ""
  for char in text:gmatch("[\1-\127\194-\244][\128-\191]*") do
    if width(result .. char) > columns then
      break
    end
    result = result .. char
  end
  return result
end

local function truncate(text, columns)
  if columns <= 0 then
    return "", 0
  end
  text = clean(text)
  if width(text) <= columns then
    return text, #text
  end
  local visible = take(text, columns - 1)
  return visible .. "…", #visible
end

local function mark(row, start, finish, group, extra)
  if finish <= start then
    return
  end
  local opts = vim.tbl_extend("force", { end_col = finish, hl_group = group }, extra or {})
  api.nvim_buf_set_extmark(state.buf, ns, row, start, opts)
end

function M.close()
  if state.win and api.nvim_win_is_valid(state.win) then
    api.nvim_win_close(state.win, true)
  end
  state.win = nil
  if state.saved_height ~= nil then
    -- Respect option changes made by the user while the drawer was open.
    if vim.o.cmdheight == state.height then
      vim.o.cmdheight = state.saved_height
    end
    state.saved_height = nil
  end
end

function M.destroy()
  M.close()
  if state.buf and api.nvim_buf_is_valid(state.buf) then
    api.nvim_buf_delete(state.buf, { force = true })
  end
  state.buf = nil
end

function M.render(model, config)
  local columns = vim.o.columns
  local maximum = math.max(3, math.min(config.max_height, math.floor(vim.o.lines * config.max_ratio), vim.o.lines - 3))
  local slots = math.max(0, maximum - 3)
  local total = #model.items
  local count = math.min(total, slots)
  local context = model.block or {}
  if #context > 0 then
    count = math.min(#context, slots)
  end
  local height = math.min(maximum, math.max(config.min_height, count + 3))
  if state.saved_height == nil then
    state.saved_height = vim.o.cmdheight
  end
  -- Reserve real command-line space, so the drawer grows out of the editor
  -- instead of floating over its last few lines or its statusline.
  if vim.o.cmdheight ~= height then
    vim.o.cmdheight = height
  end
  state.height = height
  if not state.buf or not api.nvim_buf_is_valid(state.buf) then
    state.buf = api.nvim_create_buf(false, true)
    vim.bo[state.buf].bufhidden = "hide"
    vim.bo[state.buf].filetype = "suggestions"
    vim.bo[state.buf].undolevels = -1
  end
  local window = {
    relative = "editor",
    row = vim.o.lines - height,
    col = 0,
    width = columns,
    height = height,
    style = "minimal",
    border = "none",
    focusable = false,
    zindex = 200,
    noautocmd = true,
  }
  if not state.win or not api.nvim_win_is_valid(state.win) then
    state.win = api.nvim_open_win(state.buf, false, window)
    for key, value in pairs({
      wrap = false,
      cursorline = false,
      winblend = 0,
      winhighlight = "Normal:SuggestionsNormal,NormalNC:SuggestionsNormal,EndOfBuffer:SuggestionsNormal",
      scrolloff = 0,
      sidescrolloff = 0,
    }) do
      vim.wo[state.win][key] = value
    end
  else
    window.noautocmd = nil
    api.nvim_win_set_config(state.win, window)
  end
  local pad = string.rep(" ", math.min(config.padding, math.floor(columns / 8)))
  local label = model.shell and "zsh"
    or ({ [":"] = "command", ["/"] = "search", ["?"] = "search", ["="] = "expression" })[model.firstc]
    or "input"
  local left = " " .. label
  if model.shell then
    left = left .. " · " .. vim.fn.fnamemodify(model.cwd, ":~")
  end
  local hint = model.error
      and (model.shell and "zsh unavailable" or model.input and "completion unavailable" or "fzf unavailable")
    or model.loading and "completing…"
    or total > 0 and (tostring(total) .. (total == 1 and " match" or " matches") .. "  ·  tab select  ·  → accept")
    or "esc close"
  local right = " " .. hint .. " "
  left = truncate(left, math.max(8, columns - width(right) - 4)) .. " "
  if width(left .. right) > columns - 2 then
    right = " "
  end
  local separator = width(config.separator) == 1 and config.separator or "─"
  local header = separator .. left .. string.rep(separator, math.max(0, columns - width(left .. right) - 1)) .. right
  local lines = { (truncate(header, columns)) }
  local first = math.max(1, math.min(model.selected - count + 1, total - count + 1))
  local rows = {}
  for i = 1, count do
    if #context > 0 then
      lines[#lines + 1] = pad .. truncate(context[math.max(1, #context - count + i)], columns - #pad)
    else
      local index = first + i - 1
      local item = model.items[index]
      local selected = index == model.selected
      local lead = pad .. (selected and "› " or "  ")
      local badge = "  " .. (item.source or "") .. pad
      local text, visible = truncate(item.label or item.text, math.max(1, columns - width(lead .. badge) - 1))
      local gap = string.rep(" ", math.max(1, columns - width(lead .. text .. badge)))
      lines[#lines + 1] = lead .. text .. gap .. badge
      rows[#rows + 1] = {
        row = #lines - 1,
        selected = selected,
        badge = #(lead .. text .. gap),
        matches = item.matches,
        offset = #lead,
        visible = visible,
      }
    end
  end
  while #lines < height - 1 do
    lines[#lines + 1] = ""
  end
  local prefix = pad .. (model.prompt ~= "" and clean(model.prompt) or model.firstc) .. " "
  prefix = truncate(prefix, math.max(2, math.floor(columns / 3)))
  local text, pos = clean(model.text), model.pos
  local available = math.max(1, columns - width(prefix) - 1)
  local offset = 0
  while width(text:sub(offset + 1, pos)) >= available do
    local char = text:sub(offset + 1):match("^[\1-\127\194-\244][\128-\191]*")
    if not char then
      break
    end
    offset = offset + #char
  end
  local visible = take(text:sub(offset + 1), available)
  local ghost = model.ghost and take(clean(model.ghost), math.max(0, available - width(visible))) or ""
  local prompt_row = #lines
  lines[#lines + 1] = prefix .. visible .. ghost .. " "
  vim.bo[state.buf].modifiable = true
  api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  mark(0, 0, #lines[1], "SuggestionsBorder")
  mark(0, #separator, math.min(#lines[1], #separator + #left), "SuggestionsMuted")
  mark(0, math.max(0, #lines[1] - #right), #lines[1], "SuggestionsMuted")
  for _, row in ipairs(rows) do
    if row.selected then
      mark(row.row, 0, #lines[row.row + 1], "SuggestionsSelection", { hl_eol = true, priority = 100 })
    else
      mark(row.row, row.badge, #lines[row.row + 1], "SuggestionsMuted")
    end
    for _, span in ipairs(row.matches or {}) do
      local last = math.min(span[2], row.visible)
      if span[1] < last then
        mark(
          row.row,
          row.offset + span[1],
          row.offset + last,
          row.selected and "SuggestionsSelectedMatch" or "SuggestionsMatch",
          { priority = 150, hl_mode = "combine" }
        )
      end
    end
  end
  mark(prompt_row, 0, #prefix, "SuggestionsAccent")
  mark(prompt_row, #prefix + #visible, #prefix + #visible + #ghost, "SuggestionsGhost")
  local cursor = #prefix + math.max(0, pos - offset)
  api.nvim_win_set_cursor(state.win, { prompt_row + 1, cursor })
  api.nvim_win_call(state.win, function()
    vim.fn.winrestview({ topline = 1, leftcol = 0, lnum = prompt_row + 1, col = cursor })
  end)
  if model.special then
    api.nvim_buf_set_extmark(state.buf, ns, prompt_row, cursor, {
      virt_text = { { model.special, "SuggestionsAccent" } },
      virt_text_pos = "overlay",
      priority = 300,
    })
  end
  vim.bo[state.buf].modifiable = false
end

function M.flush()
  vim.cmd.redraw()
  if state.win and api.nvim_win_is_valid(state.win) then
    -- Place the actual terminal/GUI cursor without changing the active window.
    api.nvim__redraw({ win = state.win, cursor = true, flush = true })
  end
end

function M.inspect()
  return { win = state.win, buf = state.buf, height = state.height }
end
return M
