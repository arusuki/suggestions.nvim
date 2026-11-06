local M = {}

-- Only enumerate contexts whose empty query is meaningful. Custom completion
-- callbacks and expression/value contexts retain Neovim's native behavior.
local enumerable = {}
for _, kind in ipairs({
  "command",
  "option",
  "buffer",
  "help",
  "color",
  "compiler",
  "filetype",
  "event",
  "augroup",
  "highlight",
  "history",
  "packadd",
  "syntax",
  "environment",
  "user",
}) do
  enumerable[kind] = true
end

local function native(pattern, kind)
  local ok, values = pcall(vim.fn.getcompletion, pattern, kind, true)
  return ok and values or {}
end

local function relative(path, cwd)
  local a, b = vim.split(path, "/", { trimempty = true }), vim.split(cwd, "/", { trimempty = true })
  local common = 0
  while a[common + 1] and a[common + 1] == b[common + 1] do
    common = common + 1
  end
  local parts = {}
  for _ = common + 1, #b do
    parts[#parts + 1] = ".."
  end
  for i = common + 1, #a do
    parts[#parts + 1] = a[i]
  end
  return table.concat(parts, "/")
end

local function files(request, context, callback)
  local root = vim.fs.root(context.cwd, { ".git", ".hg" }) or context.cwd
  local dirs = context.kind == "dir" or context.kind == "dir_in_path"
  local hidden = context.query:match("^%.") or context.query:find("/%.")
  local argv
  if vim.fn.executable("fd") == 1 then
    argv = { "fd", "--print0", "--color=never", "--exclude", ".git", "--exclude", ".hg", "--type", "d" }
    if not dirs then
      vim.list_extend(argv, { "--type", "f", "--type", "l" })
    end
    if hidden then
      argv[#argv + 1] = "--hidden"
    end
  else
    argv = { "find", ".", "(", "-name", ".git", "-o", "-name", ".hg" }
    if not hidden then
      vim.list_extend(argv, { "-o", "(", "-name", ".*", "!", "-name", ".", ")" })
    end
    vim.list_extend(argv, { ")", "-prune", "-o" })
    if dirs then
      vim.list_extend(argv, { "-type", "d" })
    end
    argv[#argv + 1] = "-print0"
  end
  request.run(argv, { cwd = root }, function(result)
    if result.code ~= 0 then
      callback(nil, "file collection failed (" .. result.code .. "): " .. (result.stderr or ""))
      return
    end
    local values = {}
    for path in (result.stdout or ""):gmatch("([^%z]+)%z") do
      path = path:gsub("^%./", ""):gsub("/$", "")
      if path ~= "." and path ~= "" then
        local absolute = root .. "/" .. path
        local value = relative(absolute, context.cwd)
        if dirs or vim.fn.isdirectory(absolute) == 1 then
          value = value .. "/"
        end
        values[#values + 1] = value
      end
    end
    table.sort(values)
    callback(values)
  end)
end

local function help_tags()
  local values = {}
  for _, path in ipairs(vim.api.nvim_get_runtime_file("doc/tags*", true)) do
    local file = io.open(path, "r")
    if file then
      for line in file:lines() do
        local tag = line:match("^([^\t]+)\t")
        if tag and not tag:match("^!_TAG_") then
          values[#values + 1] = tag
        end
      end
      file:close()
    end
  end
  return values
end

function M.ex(request, context, config, callback)
  local kind, query = context.kind, context.query
  local function filter(values, err)
    if not values then
      callback(nil, err)
      return
    end
    request.filter(values, query, nil, callback)
  end
  if kind == "file" or kind == "dir" or kind == "dir_in_path" then
    -- Special paths and wildcards belong to Neovim's path expansion rules.
    if not config.files or query:find("^[~/\\%%#<$]") or query:match("^%.%.") or query:find("[*?%[%]$]") then
      return false
    end
    query = query:gsub("\\(.)", "%1"):gsub("^%./", "")
    files(request, context, filter)
  elseif enumerable[kind] then
    if kind == "help" then
      filter(help_tags())
    else
      -- Keep command context (:set no/inv, :autocmd, ranges, etc.) while
      -- removing only the query. Never prefilter with the fuzzy query.
      if kind == "option" then
        local modifier = query:match("^(no)") or query:match("^(inv)")
        if modifier then
          query = query:sub(#modifier + 1)
          context.prefix = context.prefix .. modifier
        end
      end
      filter(native(context.prefix, "cmdline"))
    end
  else
    return false
  end
  return true
end

function M.search(request, model, callback)
  local values, seen = {}, {}
  -- Respect the originating buffer's 'iskeyword', including Unicode and '_'.
  vim.api.nvim_buf_call(model.buf, function()
    for _, line in ipairs(vim.api.nvim_buf_get_lines(model.buf, 0, -1, false)) do
      local start = 0
      while start < #line do
        local match = vim.fn.matchstrpos(line, [[\k\+]], start)
        if match[2] < 0 then
          break
        end
        if not seen[match[1]] then
          seen[match[1]] = true
          values[#values + 1] = match[1]
        end
        start = match[3]
      end
    end
  end)
  local case, modifier
  local query = model.text:sub(1, model.pos):gsub("(\\+)([cC])", function(slashes, flag)
    if #slashes % 2 == 0 then
      return slashes .. flag
    end
    -- Like Neovim, any explicit \c wins even when a later \C is present.
    if modifier ~= "\\c" then
      modifier = "\\" .. flag
      case = flag == "c" and "--ignore-case" or "--no-ignore-case"
    end
    return slashes:sub(2)
  end)
  local after = model.text:sub(model.pos + 1)
  request.filter(values, query, case, function(matches, err)
    if not matches then
      callback(nil, err)
      return
    end
    local items = {}
    for _, match in ipairs(matches) do
      -- Very nomagic makes accepted words literal regardless of 'magic'.
      local word = "\\V" .. (modifier or "") .. vim.fn.escape(match, "\\/?")
      items[#items + 1] = {
        text = word .. (after ~= "" and "\\m" .. after or ""),
        cursor = #word,
        label = match,
        source = "search",
      }
    end
    callback(items)
  end)
end

return M
