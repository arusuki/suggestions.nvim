local M = {}
M.defaults = {
  enabled = true,
  ui = { max_height = 10, max_ratio = 0.35, min_height = 3, padding = 2, separator = "─" },
  completion = { debounce_ms = 70, max_results = 80, auto = true },
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
  assert(type(result.zsh.shell) == "string", "suggestions: zsh.shell must be a path")
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
  assert(result.zsh.timeout_ms > 0 and result.zsh.startup_timeout_ms > 0, "suggestions: timeouts must be positive")
  assert(result.zsh.history_limit > 0, "suggestions: history_limit must be positive")
  assert(type(result.ui.separator) == "string", "suggestions: ui.separator must be a string")
  result.zsh.max_results = result.completion.max_results
  return result
end
return M
