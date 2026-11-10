local M = {}
M.defaults = {
  enabled = true,
  ui = { max_height = 10, max_ratio = 0.35, min_height = 3, padding = 2, separator = "─" },
  completion = { debounce_ms = 70, max_results = 80, auto = true, empty = "none", history_limit = 10 },
  history = { max_visible = 0, max_results = 10 },
  input = { enabled = false, completion = "native", rules = {} },
  highlights = { shell = {}, match = {}, selected_match = {} },
  fuzzy = {
    enabled = true,
    executable = "fzf",
    timeout_ms = 2000,
    files = true,
    search = true,
    highlight = true,
  },
  zsh = {
    shell = "zsh",
    timeout_ms = 1800,
    startup_timeout_ms = 6000,
    history_limit = 3000,
    history_file = nil,
    env = {},
  },
  keys = {
    next = "<Tab>",
    previous = "<S-Tab>",
    suggestion_next = "<C-n>",
    suggestion_previous = "<C-p>",
    accept = "<Right>",
    accept_word = "<M-f>",
    history_previous = "<Up>",
    history_next = "<Down>",
    confirm = "<CR>",
    close = "<Esc>",
    line_start = "<C-a>",
    line_end = "<C-e>",
    kill_end = "<C-k>",
    word_left = "<M-b>",
  },
}

function M.resolve(opts)
  local result = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  assert(type(result.keys) == "table", "suggestions: keys must be a table")
  for action, keys in pairs(result.keys) do
    assert(
      keys == false or type(keys) == "string" or (type(keys) == "table" and vim.islist(keys)),
      "suggestions: keys." .. action .. " must be a string, a list of strings, or false"
    )
    if type(keys) == "table" then
      for _, lhs in ipairs(keys) do
        assert(type(lhs) == "string" and lhs ~= "", "suggestions: keys." .. action .. " must contain nonempty strings")
      end
    end
  end
  -- Explicit bindings take priority over defaults, including the new C-n/C-p
  -- actions when an existing configuration already uses those keys for Tab.
  local claimed = {}
  for _, keys in pairs((opts or {}).keys or {}) do
    for _, lhs in ipairs(type(keys) == "table" and keys or { keys }) do
      if lhs and lhs ~= "" then
        claimed[vim.api.nvim_replace_termcodes(lhs, true, false, true)] = true
      end
    end
  end
  for action, keys in pairs(result.keys) do
    if ((opts or {}).keys or {})[action] == nil then
      local bindings = {}
      for _, lhs in ipairs(type(keys) == "table" and keys or { keys }) do
        if lhs and lhs ~= "" and not claimed[vim.api.nvim_replace_termcodes(lhs, true, false, true)] then
          bindings[#bindings + 1] = lhs
        end
      end
      result.keys[action] = bindings
    end
  end
  assert(
    type(result.history) == "table"
      and type(result.history.max_visible) == "number"
      and result.history.max_visible >= 0
      and result.history.max_visible < math.huge
      and result.history.max_visible % 1 == 0,
    "suggestions: history.max_visible must be a nonnegative integer"
  )
  assert(
    type(result.history.max_results) == "number"
      and result.history.max_results >= 1
      and result.history.max_results < math.huge
      and result.history.max_results % 1 == 0,
    "suggestions: history.max_results must be a positive integer"
  )
  assert(type(result.input) == "table", "suggestions: input must be a table")
  local function validate_input(options, rule)
    assert(
      (rule and options.enabled == nil) or type(options.enabled) == "boolean",
      "suggestions: input.enabled must be a boolean"
    )
    assert(
      (rule and options.completion == nil) or (type(options.completion) == "string" and options.completion ~= ""),
      "suggestions: input.completion must be a nonempty string"
    )
    if rule then
      assert(type(options.prompt) == "string", "suggestions: input rule.prompt must be a Lua pattern")
      assert(pcall(string.find, "", options.prompt), "suggestions: invalid input prompt pattern")
    end
  end
  validate_input(result.input)
  assert(
    type(result.input.rules) == "table" and vim.islist(result.input.rules),
    "suggestions: input.rules must be a list"
  )
  for _, rule in ipairs(result.input.rules) do
    assert(type(rule) == "table", "suggestions: input rules must be tables")
    validate_input(rule, true)
  end
  assert(type(result.zsh.shell) == "string", "suggestions: zsh.shell must be a path")
  assert(type(result.fuzzy.executable) == "string", "suggestions: fuzzy.executable must be a path")
  assert(
    type(result.fuzzy.timeout_ms) == "number" and result.fuzzy.timeout_ms > 0,
    "suggestions: fuzzy.timeout_ms must be positive"
  )
  for _, key in ipairs({ "enabled", "files", "search", "highlight" }) do
    assert(type(result.fuzzy[key]) == "boolean", "suggestions: fuzzy." .. key .. " must be a boolean")
  end
  for _, key in ipairs({ "shell", "match", "selected_match" }) do
    assert(type(result.highlights[key]) == "table", "suggestions: highlights." .. key .. " must be a table")
  end
  for _, key in ipairs({ "max_height", "min_height", "padding" }) do
    assert(
      type(result.ui[key]) == "number" and result.ui[key] >= 0,
      "suggestions: ui." .. key .. " must be a nonnegative number"
    )
  end
  assert(result.ui.max_height >= 3, "suggestions: max_height must be at least 3")
  assert(result.ui.max_ratio > 0 and result.ui.max_ratio <= 1, "suggestions: max_ratio must be in (0, 1]")
  assert(result.completion.max_results >= 1, "suggestions: max_results must be positive")
  assert(result.completion.debounce_ms >= 0, "suggestions: debounce_ms must be nonnegative")
  assert(
    result.completion.empty == "none" or result.completion.empty == "history",
    'suggestions: completion.empty must be "none" or "history"'
  )
  assert(
    type(result.completion.history_limit) == "number"
      and result.completion.history_limit >= 1
      and result.completion.history_limit < math.huge
      and result.completion.history_limit % 1 == 0,
    "suggestions: completion.history_limit must be a positive integer"
  )
  assert(result.zsh.timeout_ms > 0 and result.zsh.startup_timeout_ms > 0, "suggestions: timeouts must be positive")
  assert(result.zsh.history_limit > 0, "suggestions: history_limit must be positive")
  assert(type(result.ui.separator) == "string", "suggestions: ui.separator must be a string")
  result.zsh.max_results = result.completion.max_results
  return result
end

function M.input(config, prompt)
  local options = { enabled = config.enabled, completion = config.completion }
  for _, rule in ipairs(config.rules) do
    if prompt:find(rule.prompt) then
      if rule.enabled ~= nil then
        options.enabled = rule.enabled
      end
      options.completion = rule.completion or options.completion
      break
    end
  end
  return options
end
return M
