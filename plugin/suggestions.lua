if vim.g.loaded_suggestions then
  return
end
vim.g.loaded_suggestions = true
for name, method in pairs({ SuggestionsEnable = "enable", SuggestionsDisable = "disable", SuggestionsToggle = "toggle" }) do
  vim.api.nvim_create_user_command(name, function()
    require("suggestions")[method]()
  end, {})
end
