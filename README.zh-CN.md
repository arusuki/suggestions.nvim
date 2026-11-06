# suggestions.nvim

[English](README.md) | 简体中文

把 Neovim 命令行变成从编辑器底部展开的 minibuffer。普通 Ex 命令和 `:!` 都支持 fish 风格的历史灰字预测；输入 `:!` 时，由真正的 **zsh / ZLE** 提供补全。

![真实 Neovim UI 输出](assets/demo.gif)

全宽贴底、无外框、主题自适应；输入行固定在最底部，候选向上展开。面板通过 `cmdheight` 预留空间，编辑区随高度变化收缩，退出后恢复原布局。光标使用实际终端光标。

## 快速试用

需要 **Neovim 0.11+、zsh 5.8+**，适用于 macOS / Linux。插件运行时没有第三方 Lua、Python 或 tmux 依赖。

在这个项目目录运行：

```sh
nvim -u ./minimal.lua
```

按 `:`，输入 `!git st`、`!cd ~/` 或 `!ls `。灰字优先来自 zsh 历史，没有历史匹配时使用第一个可延伸当前输入的补全。按右方向键采纳。

普通命令也可试试 `:set nu` 或 `:edit al`：灰字优先使用 Neovim `:` 历史中最近一条能延伸当前输入的命令，否则使用第一条能延伸输入的原生补全。与输入相同或需要改写前文的候选会被跳过；Tab 显式选中后，以选中项为准。

使用 lazy.nvim 安装：

```lua
{
  "arusuki/suggestions.nvim",
  lazy = false,
  opts = {},
}
```

加载本地项目时，将仓库字符串换成 `dir = vim.fn.expand("~/dev/suggestions.nvim")`。直接安装到 `pack/*/start` 或已加入 `runtimepath` 时：

```lua
require("suggestions").setup()
```

## 交互

| 按键 | 行为 |
| --- | --- |
| `→` | 行末采纳灰字；有显式选中候选时采纳该项；否则移动光标 |
| `Alt-f` | 按词采纳灰字；否则向前移动一个词 |
| `Alt-b` | 向后移动一个词 |
| `Tab` / `Shift-Tab` | 选择下一个 / 上一个候选，循环选择 |
| `↑` / `↓` | 按输入前缀翻阅 zsh 历史；选中候选后改为移动选择 |
| `Enter` | 确认显式选中的候选；没有选择时执行当前输入 |
| `Ctrl-a` / `Ctrl-e` | 行首 / 行尾；行末有灰字时 `Ctrl-e` 采纳它 |
| `Ctrl-k` | 删除光标到行尾的内容 |
| `Ctrl-u` / `Ctrl-w` | Neovim 原生的向前删行 / 删词 |
| `Esc` / `Ctrl-c` | 取消命令，收起面板 |

自动出现的候选不会被预选。输入完整命令后，直接回车即可执行，未采纳的灰字不会被执行。

普通 Ex 命令使用 Neovim 原生补全上下文，包括文件、选项、Lua 和用户命令。`:%s`、可视选区范围、搜索、寄存器插入、`Ctrl-r =` 嵌套表达式和原生执行语义仍由 Neovim 处理。搜索及其他提示框也使用同一面板，但不请求 zsh 补全。

灰字只在非空命令的行末显示，搜索和嵌套表达式提示不显示灰字。Ex 历史直接使用 Neovim 已加载的历史（含 ShaDa 和当前会话），遵循 `'history'` 设置和原生历史删除操作；多行历史不用于灰字。未选中候选时，Ex 的 `↑` / `↓` 保留原生历史导航。设置 `completion.auto = false` 后，Ex 历史灰字仍会显示，补全需按 Tab 请求。

`!cmd`、`2,4!cmd`、`read !cmd`、`write !cmd` 可使用 zsh 补全。候选保留 zsh 生成的引号、空格转义、目录斜杠和光标右侧文本；补全以发起命令的窗口工作目录为准，支持 `:lcd`。

## 配置

```lua
require("suggestions").setup({
  enabled = true,
  ui = {
    max_height = 10,
    max_ratio = 0.35,  -- 同时限制为屏幕高度的 35%
    min_height = 3,
    padding = 2,
    separator = "─",
  },
  completion = {
    auto = true,      -- false：按 Tab 后请求补全
    debounce_ms = 70,
    max_results = 80,
  },
  zsh = {
    shell = "zsh",    -- 也可使用绝对路径
    timeout_ms = 1800,
    startup_timeout_ms = 6000,
    history_limit = 3000,
    -- history_file = vim.fn.expand("~/.zsh_history"),
    -- env = { ZDOTDIR = vim.fn.expand("~/.config/zsh") },
  },
  keys = {
    accept = "<Right>",
    accept_word = "<M-f>",
    -- word_left = false, -- false 禁用某个插件映射
  },
})
```

默认读取交互式 zsh 的启动配置，所以已有 `compinit`、`compdef`、aliases 和 `fpath` 可直接使用。没有初始化补全时，后端使用 `compinit -i -D` 初始化。历史路径优先取 `history_file`，否则使用 zsh 配置里的 `$HISTFILE`，最后回退到 `~/.zsh_history`。历史在后端启动时加载，当前 Neovim 会话中提交的 shell 命令追加到内存；不会改写终端历史文件。

补全后端与执行后端分开：**`:!` 仍由 Neovim 原生执行，使用 `&shell` 和 `&shellcmdflag`**。如果希望执行也加载同一份交互式 zsh 配置，例如使用 aliases，可在自己的配置中设置：

```lua
vim.opt.shell = vim.fn.exepath("zsh")
vim.opt.shellcmdflag = "-ic"
```

这仍是 `:!` 的一次性命令执行，不是持久化终端会话；`!cd` 不改变 Neovim 的目录。交互式 TUI 程序使用 `:terminal`。

可覆盖以下高亮组：`SuggestionsNormal`、`SuggestionsMuted`、`SuggestionsGhost`、`SuggestionsBorder`、`SuggestionsAccent`、`SuggestionsSelection`。默认配色取自当前主题，并在 `ColorScheme` 后重新适配。

## 管理与兼容

- `:SuggestionsEnable` / `:SuggestionsDisable` / `:SuggestionsToggle`
- `:SuggestionsReload` 重新读取 zsh 配置和磁盘历史；Lua API：`require("suggestions").reload()`
- `:checkhealth suggestions`
- `:lua vim.print(require("suggestions").inspect())` 查看当前状态、后端错误和请求状态

修改 `.zshrc` 中的 `compdef`、aliases、`fpath` 或补全函数后，执行：

```vim
:SuggestionsReload
```

该命令立即重启后台 zsh，保留插件配置、按键映射、当前输入和本次 Neovim 会话中的 shell 历史；旧补全请求及候选会被清除。开启自动补全时，会重新补全当前输入。插件处于禁用状态时，此命令不启动后端。启动是异步的，失败信息可通过 `inspect()` 查看。

后端是独立的交互式、非登录 zsh，遵循 [zsh 启动文件规则](https://zsh.sourceforge.io/Doc/Release/Files.html)：默认读取 `.zshenv` 和 `.zshrc`，支持 `$ZDOTDIR`，不会主动读取 `.zprofile` 或 `.zlogin`。其他终端里临时定义的函数和 aliases 不会同步。插件接管补全菜单与按键，重置部分 shell 选项，并清空 `precmd_functions`、`preexec_functions`、`chpwd_functions`，因此不保证与终端 Tab 的所有行为完全一致。

不要同时启用多个命令行渲染器。使用 Noice 时关闭其 `cmdline`；使用 wilder 或 cmp-cmdline 时关闭它们的命令行补全 / 渲染。普通 Insert 模式的补全插件不受影响。关闭插件会恢复被覆盖的命令行映射及 `cmdheight`，并结束后台 zsh。

zsh 缺失、启动超时或补全超时时，面板会显示后端不可用，Ex 命令和原生执行仍可使用。下次请求会重启后端。耗时的 `.zshrc` 或补全函数可通过对应 timeout 选项调整。

界面是单行命令输入，长输入随光标水平滚动。暂不显示 zsh 候选的描述列，也不做跨终端实时历史同步。Neovim 的 `vim.ui_attach` 和 `nvim__redraw` 仍属于实验 API；兼容性由集成测试覆盖。

## 实现与验证

参考 [terminal_mate.nvim 的后台 zsh 思路](https://github.com/beardnick/terminal_mate.nvim/blob/main/lua/terminal_mate/zsh_completion.lua)，这里独立实现了面向原生命令行的后端与 UI：

- `vim.ui_attach(ext_cmdline)` 接管显示，输入、解析和执行仍保留在原生 command-line mode。
- 持久 PTY 中的 zsh 使用 `vared` 和 ZLE completion widget 运行真实补全；逐项读取 ZLE 插入结果，而非重新拼接 shell token。
- 命令文本通过私有目录内的 NUL 分隔文件传递，不作为 PTY 按键或 `eval` 代码发送。补全函数本身仍会像终端补全一样运行其所需的程序。
- 防抖、请求串行化和版本校验避免旧结果覆盖新输入；超时、退出及禁用会清理进程和临时文件。

```sh
python3 -m venv .venv
.venv/bin/pip install -r tests/requirements.txt
.venv/bin/python -m unittest discover -s tests -p integration.py -v
.venv/bin/python tests/preview.py
```

测试连接真实 Neovim UI 和真实 zsh，覆盖路径引号、中文光标、多个候选、自定义补全、shell / Ex 历史灰字、补全兜底、取消、过期请求、超时恢复、配置重载、布局及屏幕光标。`tests/preview.py` 从 Neovim 实际 `ext_linegrid` 输出生成暗色 / 亮色预览与 GIF。

## 参考与致谢

- [terminal_mate.nvim](https://github.com/beardnick/terminal_mate.nvim)：后台 zsh 补全方案的灵感来源，具体参考实现见上文。
- [zsh 启动文件](https://zsh.sourceforge.io/Doc/Release/Files.html)：配置文件的加载顺序和 `ZDOTDIR`。
- [zsh 补全系统](https://zsh.sourceforge.io/Doc/Release/Completion-System.html)：`compinit`、`compdef` 和 `fpath`。
- [Neovim shell 选项](https://neovim.io/doc/user/options.html#'shellcmdflag')：命令执行使用的 `shell` / `shellcmdflag`。

[MIT License](LICENSE).
