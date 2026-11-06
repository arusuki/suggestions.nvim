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

function M.ex(line, pos, limit)
  local kind = vim.fn.getcmdcompltype()
  -- Lua user-command callbacks can have an empty completion type even though
  -- getcompletion() supplies matches. Let the native lookup decide.
  local pattern = vim.fn.getcmdcomplpat()
  local before, after = line:sub(1, pos), line:sub(pos + 1)
  -- Use Neovim's own context parser (spaces in paths, :set, user commands,
  -- Lua expressions, etc.), never guess a replacement range from whitespace.
  if before:sub(#before - #pattern + 1) ~= pattern then
    return {}
  end
  local prefix = before:sub(1, #before - #pattern)
  local ok, matches = pcall(vim.fn.getcompletion, before, "cmdline", true)
  if not ok then
    return {}
  end
  local items = {}
  for _, match in ipairs(matches) do
    local word = match
    if kind == "file" or kind == "dir" or kind == "file_in_path" or kind == "dir_in_path" or kind == "buffer" then
      word = vim.fn.escape(word, ' \\%#|"')
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

return M
