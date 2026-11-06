local M = {}

-- Only recognize Ex shell forms. An exclamation in :s or :echo is ordinary
-- command text, while a range/filter or :read ! must keep its Ex prefix.
function M.shell_prefix(line)
  local range = "^%s*[%d%%.$,'<>;+%-]*%s*"
  local prefix = line:match(range .. "!")
  if prefix then
    return prefix
  end
  for _, command in ipairs({ "r", "re", "rea", "read", "w", "wr", "wri", "writ", "write" }) do
    prefix = line:match(range .. command .. "%s+!")
    if prefix then
      return prefix
    end
  end
end

function M.ex_history(prefix)
  if prefix == "" then
    return nil
  end
  -- Read native history directly: this includes ShaDa and the current session,
  -- and respects histdel() and 'history' without a second cache.
  for index = 1, vim.o.history do
    local entry = vim.fn.histget(":", -index)
    if entry == "" then
      break
    end
    if #entry > #prefix and entry:sub(1, #prefix) == prefix and not entry:find("[\r\n]") then
      return entry
    end
  end
end

local function ex_context(line, pos)
  local kind = vim.fn.getcmdcompltype()
  -- Lua user-command callbacks can have an empty completion type even though
  -- getcompletion() supplies matches. Let the native lookup decide.
  local pattern = vim.fn.getcmdcomplpat()
  local before, after = line:sub(1, pos), line:sub(pos + 1)
  -- getcmdcomplpat() includes the text to the right of the cursor. Only the
  -- part before it is the query; keep the right-hand text verbatim on insert.
  if after ~= "" and pattern:sub(-#after) == after then
    pattern = pattern:sub(1, #pattern - #after)
  end
  -- Use Neovim's own context parser (spaces in paths, :set, user commands,
  -- Lua expressions, etc.), never guess a replacement range from whitespace.
  if before:sub(#before - #pattern + 1) ~= pattern then
    return nil
  end
  local prefix = before:sub(1, #before - #pattern)
  return { kind = kind, query = pattern, prefix = prefix, before = before, after = after }
end

local function ex_items(context, matches, limit)
  local kind, prefix, after = context.kind, context.prefix, context.after
  local items = {}
  for _, match in ipairs(matches) do
    local word = match
    if
      context.escape ~= false
      and (kind == "file" or kind == "dir" or kind == "file_in_path" or kind == "dir_in_path" or kind == "buffer")
    then
      word = vim.fn.fnameescape(word)
    end
    items[#items + 1] = {
      text = prefix .. word .. after,
      cursor = #prefix + #word,
      label = match,
      source = kind == "" and "custom" or kind,
    }
    if #items >= limit then
      break
    end
  end
  return items
end

function M.ex(line, pos, limit)
  local context = ex_context(line, pos)
  if not context then
    return {}
  end
  local ok, matches = pcall(vim.fn.getcompletion, context.before, "cmdline", true)
  return ok and ex_items(context, matches, limit) or {}
end

local function input_matches(context, model)
  local custom, name = context.kind:match("^(custom[^,]*),(.+)$")
  if not custom then
    return vim.fn.getcompletion(context.query, context.kind, true)
  end
  -- getcompletion() calls custom callbacks with CursorPos=0. Input callbacks
  -- need the actual full line and byte cursor, including any right-hand text.
  local matches
  if name:sub(1, 6) == "v:lua." then
    matches =
      vim.fn.eval(("%s(%s, %s, %d)"):format(name, vim.fn.string(context.query), vim.fn.string(model.text), model.pos))
  else
    matches = vim.fn.call(name, { context.query, model.text, model.pos })
  end
  if custom == "custom" then
    matches = vim.split(matches, "\n", { trimempty = true })
    local pattern = vim.regex("\\m^" .. context.query)
    matches = vim.tbl_filter(function(match)
      return pattern:match_str(match) ~= nil
    end, matches)
  end
  assert(type(matches) == "table", "input completion must return a list")
  return matches
end

function M.request(model, config, callback)
  if model.input then
    local kind = model.input.completion
    local context
    if kind == "native" then
      context = ex_context(model.text, model.pos)
      if not context or context.kind == "" then
        callback({})
        return
      end
    else
      -- input() completion types operate on the whole prompt value.
      context =
        { kind = kind, prefix = "", before = model.text:sub(1, model.pos), after = model.text:sub(model.pos + 1) }
      context.query = context.before
    end
    -- Unlike Ex arguments, native input() file values are not fnameescaped.
    context.escape = false
    local ok, matches = pcall(input_matches, context, model)
    callback(
      ok and ex_items(context, matches, config.completion.max_results) or {},
      not ok and tostring(matches) or nil
    )
    return
  end
  local fuzzy = config.fuzzy
  local is_search = model.firstc == "/" or model.firstc == "?"
  local fallback = not is_search and M.ex(model.text, model.pos, config.completion.max_results) or {}
  if not fuzzy.enabled or (is_search and not fuzzy.search) then
    callback(fallback)
    return
  end
  if vim.fn.executable(fuzzy.executable) ~= 1 then
    callback(fallback, "fzf executable not found: " .. fuzzy.executable)
    return
  end
  local request = require("suggestions.fzf").request(fuzzy)
  local function finish(items, err, matching)
    if not items then
      callback(fallback, err)
      return
    end
    while #items > config.completion.max_results do
      items[#items] = nil
    end
    if fuzzy.highlight and matching then
      for _, item in ipairs(items) do
        item.matches = require("suggestions.match").spans(item.label, matching.query, matching.case)
      end
    end
    callback(items)
  end
  if is_search then
    require("suggestions.fuzzy").search(request, model, finish)
  else
    local context = ex_context(model.text, model.pos)
    if not context then
      callback(fallback)
      return
    end
    context.cwd = model.cwd
    local handled = require("suggestions.fuzzy").ex(request, context, fuzzy, function(matches, err, matching)
      finish(matches and ex_items(context, matches, config.completion.max_results), err, matching)
    end)
    if not handled then
      callback(fallback)
    end
  end
  return request.cancel
end

return M
