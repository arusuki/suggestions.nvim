local M = {}
function M.check()
  vim.health.start("suggestions.nvim")
  if vim.fn.has("nvim-0.11") == 1 then
    vim.health.ok("Neovim 0.11+")
  else
    vim.health.error("Neovim 0.11+ is required")
  end
  local info = require("suggestions").inspect()
  if not info.fuzzy.enabled then
    vim.health.info("fzf completion disabled")
  elseif vim.fn.executable(info.fuzzy.executable) == 1 then
    vim.health.ok("fzf: " .. vim.fn.exepath(info.fuzzy.executable))
  else
    vim.health.warn("fzf executable not found: " .. info.fuzzy.executable .. "; Ex uses native completion")
  end
  if vim.fn.executable(info.shell) == 1 then
    vim.health.ok("zsh: " .. vim.fn.exepath(info.shell))
  else
    vim.health.error("zsh executable not found: " .. info.shell .. "; configure zsh.shell")
  end
  vim.health.info("UI " .. (info.enabled and "enabled" or "disabled") .. "; backend " .. vim.inspect(info.backend))
  if package.loaded["noice"] then
    vim.health.warn("Disable Noice's cmdline UI before enabling suggestions.nvim")
  end
end
return M
