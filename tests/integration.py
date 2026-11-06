"""Exercise the real Neovim command line and a real interactive zsh.

Run: python -m unittest discover -s tests -p integration.py -v
Tests use isolated zsh startup/history files and never execute user commands.
"""

import os
import tempfile
import time
import unittest
from pathlib import Path

import pynvim

ROOT = Path(__file__).resolve().parents[1]


class Integration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="suggestions-tests-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.folder = Path(cls.temp.name)
        cls.cwd = cls.folder / "workspace"
        cls.cwd.mkdir()
        for name in (
            "alpha.txt",
            "alpine.txt",
            "beta.txt",
            "space file.txt",
            "中文文件.txt",
        ):
            (cls.cwd / name).touch()
        (cls.cwd / "a-directory").mkdir()
        (cls.cwd / "a-directory" / "inside.txt").touch()
        (cls.folder / "history").write_text(
            ": 1700000000:0;git status --short\n"
            ": 1700000001:0;git status --branch\n"
            ": 1700000002:0;echo 中文 history\n",
            encoding="utf-8",
        )
        # Ubuntu's /etc/zsh/zshrc runs compinit before our .zshrc. Its
        # permission prompt can block an unattended PTY on runner images.
        (cls.folder / ".zshenv").write_text(
            "skip_global_compinit=1\n", encoding="utf-8"
        )
        (cls.folder / ".zshrc").write_text(
            "autoload -Uz compinit; compinit -i -D\n"
            "alias gst='git status'\n"
            "_sg_test() { compadd -- --alpha --beta --gamma; }\n"
            "compdef _sg_test sg-test\n"
            "_sg_slow() { sleep 0.15; compadd -- slow-result; }\n"
            "compdef _sg_slow sg-slow\n"
            "HISTSIZE=3000\n",
            encoding="utf-8",
        )
        cls.old_log = os.environ.get("NVIM_LOG_FILE")
        cls.addClassCleanup(cls.restore_log_env)
        os.environ["NVIM_LOG_FILE"] = str(cls.folder / "nvim.log")
        cls.nvim = pynvim.attach(
            "child",
            argv=[
                os.environ.get("NVIM", "nvim"),
                "--embed",
                "--headless",
                "-n",
                "-u",
                "NONE",
                "-i",
                "NONE",
            ],
        )
        cls.addClassCleanup(cls.close_nvim)
        cls.nvim.ui_attach(100, 32, rgb=True, ext_linegrid=True)
        cls.nvim.exec_lua("vim.opt.runtimepath:prepend(...)", str(ROOT))
        cls.nvim.command("runtime plugin/suggestions.lua")
        cls.nvim.command("cd " + cls.nvim.funcs.fnameescape(str(cls.cwd)))
        cls.nvim.options["cmdheight"] = 0
        cls.nvim.exec_lua(
            """
          require('suggestions').setup({
            completion = { debounce_ms = 20 },
            zsh = { env = { ZDOTDIR = ... }, history_file = select(2, ...) },
          })
        """,
            str(cls.folder),
            str(cls.folder / "history"),
        )
        cls.nvim.input(":!git che")
        cls.wait_for(lambda: cls.current().get("items"), "zsh startup", timeout=8)
        cls.nvim.input("<Esc>")
        cls.wait_for(lambda: not cls.inspect().get("current"), "initial close")

    @classmethod
    def close_nvim(cls):
        try:
            if cls.nvim.api.get_mode()["mode"] != "n":
                cls.nvim.input("<C-c>")
            cls.nvim.command("qa!")
        except (EOFError, OSError):
            pass
        cls.nvim.close()

    @classmethod
    def restore_log_env(cls):
        if cls.old_log is None:
            os.environ.pop("NVIM_LOG_FILE", None)
        else:
            os.environ["NVIM_LOG_FILE"] = cls.old_log

    @classmethod
    def inspect(cls):
        return cls.nvim.exec_lua("return require('suggestions').inspect()")

    @classmethod
    def current(cls):
        return cls.inspect().get("current", {})

    @classmethod
    def wait_for(cls, condition, description="condition", timeout=5):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if condition():
                return
            time.sleep(0.015)
        raise AssertionError(
            "Timed out waiting for " + description + ": " + repr(cls.inspect())
        )

    def setUp(self):
        if self.nvim.api.get_mode()["mode"] != "n":
            self.nvim.input("<C-c>")
        self.wait_for(lambda: not self.inspect().get("current"), "normal mode")
        self.nvim.funcs.histdel(":")
        self.nvim.current.buffer[:] = ["one", "two", "three", "four", "five"]
        self.nvim.current.window.cursor = (1, 0)

    def tearDown(self):
        if self.nvim.api.get_mode()["mode"] != "n":
            self.nvim.input("<C-c>")
        self.wait_for(lambda: not self.inspect().get("current"), "close")
        errors = self.nvim.command_output("messages")
        self.assertNotIn("Error", errors)
        self.assertTrue(self.inspect()["enabled"])

    def enter(self, text, expected=None):
        self.nvim.input(text)
        self.wait_for(lambda: self.current().get("text") == text[1:], "cmdline show")
        if expected:
            self.wait_for(
                lambda: any(expected in x["text"] for x in self.current()["items"]),
                expected,
            )

    def key(self, key):
        self.nvim.input(key)
        time.sleep(0.045)

    def line(self):
        return self.nvim.funcs.getcmdline()

    def backend(self, text, cursor=None, cwd=None):
        cursor = len(text.encode()) if cursor is None else cursor
        self.nvim.exec_lua(
            """
          _G.sg_test_result = nil
          require('suggestions.backend').request(..., function(items, err)
            _G.sg_test_result = { items = items, error = err, done = true }
          end)
        """.replace(
                "request(...,",
                "request(select(1, ...), select(2, ...), select(3, ...),",
            ),
            text,
            cursor,
            str(cwd or self.cwd),
        )
        self.wait_for(
            lambda: self.nvim.exec_lua("return _G.sg_test_result ~= nil"),
            "backend response",
        )
        result = self.nvim.exec_lua("return _G.sg_test_result")
        self.assertFalse(result.get("error"), result)
        return result.get("items", [])

    def test_native_git_and_right_accept(self):
        # `git che` also matches check-attr/check-ignore on some zsh versions.
        self.enter(":!git checko", "checkout")
        # ZLE's trailing-space behavior also varies; preserve its exact result.
        expected = self.current()["items"][0]["text"]
        self.assertEqual(expected.rstrip(), "!git checkout")
        self.assertEqual(self.current()["ghost"], expected[len("!git checko") :])
        self.key("<Right>")
        self.assertEqual(self.line(), expected)

    def test_multiple_native_matches(self):
        items = self.backend("ls ")
        self.assertEqual(len(items), 6)
        self.assertEqual(len({x["text"] for x in items}), 6)
        self.assertTrue(any("中文文件.txt" in x["text"] for x in items))

    def test_custom_compdef_and_aliases(self):
        self.assertEqual(len(self.backend("sg-test --")), 3)
        self.assertTrue(any(x["text"].strip() == "gst" for x in self.backend("gs")))

    def test_quoted_and_escaped_paths(self):
        for text in ["cat 'space f", 'cat "space f', "cat space\\ f"]:
            with self.subTest(text=text):
                items = self.backend(text)
                self.assertEqual(len(items), 1)
                self.assertIn("file.txt", items[0]["text"])
                self.assertTrue(items[0]["text"].startswith(text))

    def test_directory_context_and_nested_path(self):
        items = self.backend("cd a")
        self.assertEqual([x["text"] for x in items], ["cd a-directory/"])
        self.assertIn("inside.txt", self.backend("cat a-directory/in")[0]["text"])

    def test_cursor_middle_and_multibyte(self):
        items = self.backend("cat al --tail", len("cat al"))
        self.assertEqual(len(items), 2)
        for item in items:
            self.assertTrue(item["text"].endswith(" --tail"))
            self.assertLess(item["cursor"], len(item["text"].encode()))
        item = self.backend("cat 中文")[0]
        self.assertIn("中文文件.txt", item["text"])
        self.assertEqual(item["cursor"], len(item["text"].encode()))

    def test_request_is_data_not_keystrokes(self):
        sentinel = self.cwd / "must-not-exist"
        self.backend("echo ignored\ntouch " + str(sentinel) + "\n\x1b\r")
        self.assertFalse(sentinel.exists())

    def test_history_priority_and_accept_word(self):
        self.enter(":!git st", "status")
        self.wait_for(
            lambda: self.current().get("ghost") == "atus --branch", "history suggestion"
        )
        self.key("<M-f>")
        self.assertEqual(self.line(), "!git status ")
        self.key("<Right>")
        self.assertEqual(self.line(), "!git status --branch")

    def test_history_includes_latest_entry(self):
        self.enter(":!echo 中")
        self.wait_for(
            lambda: self.current().get("ghost") == "文 history", "newest history entry"
        )

    def test_screen_drawer_and_cursor_are_at_bottom(self):
        self.enter(":!git st", "status")
        text = self.nvim.exec_lua("""
          local result = ''
          for c = 1, vim.o.columns do result = result .. vim.fn.screenstring(vim.o.lines, c) end
          return result
        """)
        self.assertIn("!git status --branch", text)
        info = self.nvim.funcs.getwininfo(self.inspect()["ui"]["win"])[0]
        self.assertEqual(info["topline"], 1)
        events = [
            event
            for msg in self.nvim._session._pending_messages
            if msg.name == "redraw"
            for event in msg.args
            if event[0] == "grid_cursor_goto"
        ]
        self.assertEqual(events[-1][-1][1], 31)

    def test_history_navigation_restores_draft(self):
        self.enter(":!git st", "status")
        self.key("<Up>")
        self.assertEqual(self.line(), "!git status --branch")
        self.key("<Up>")
        self.assertEqual(self.line(), "!git status --short")
        self.key("<Down><Down>")
        self.assertEqual(self.line(), "!git st")

    def test_ex_history_priority_and_accept_word(self):
        for entry in (
            "set number relativenumber",
            "set number norelativenumber",
            "set nu",
            "set number\necho 'multiline'",
        ):
            self.nvim.funcs.histadd(":", entry)
        self.enter(":set nu", "number")
        self.assertEqual(self.current()["ghost"], "mber norelativenumber")
        self.assertEqual(self.current()["selected"], 0)
        self.assertEqual(self.line(), "set nu")
        self.key("<M-f>")
        self.assertEqual(self.line(), "set number ")
        self.wait_for(
            lambda: self.current().get("ghost") == "norelativenumber",
            "remaining history",
        )
        self.key("<Right>")
        self.assertEqual(self.line(), "set number norelativenumber")

    def test_ex_history_without_completion_and_unicode(self):
        command = 'let g:suggestions_prediction = "中文 history"'
        self.nvim.funcs.histadd(":", command)
        self.enter(':let g:suggestions_prediction = "中')
        self.wait_for(
            lambda: self.current().get("ghost") == '文 history"', "Unicode Ex history"
        )
        self.assertFalse(self.current()["items"])
        self.key("<C-e>")
        self.assertEqual(self.line(), command)
        self.assertEqual(self.nvim.funcs.getcmdpos(), len(command.encode()) + 1)
        self.assertEqual(self.nvim.funcs.exists("g:suggestions_prediction"), 0)

    def test_ex_history_tracks_native_execution_and_deletion(self):
        command = "let g:suggestions_session_history = 42"
        self.enter(":" + command)
        self.key("<CR>")
        self.assertEqual(self.nvim.funcs.histget(":", -1), command)
        self.enter(":let g:suggestions_session_history = ")
        self.wait_for(lambda: self.current().get("ghost") == "42", "session history")
        self.key("<Esc>")
        self.nvim.funcs.histdel(":")
        self.enter(":let g:suggestions_session_history = ")
        self.assertFalse(self.current().get("ghost"))

    def test_ex_completion_fallback_and_selected_preview(self):
        self.nvim.funcs.histadd(":", "set nu")  # An exact entry must not hide fallback.
        self.enter(":set nu", "number")
        self.assertEqual(self.current()["ghost"], "mber")
        self.key("<Right>")
        self.assertEqual(self.line(), "set number")
        self.key("<Esc>")
        self.nvim.funcs.histadd(":", "set number norelativenumber")
        self.enter(":set nu", "number")
        self.assertEqual(self.current()["ghost"], "mber norelativenumber")
        self.key("<Tab>")
        self.assertEqual(self.current()["ghost"], "mber")
        self.key("<Right>")
        self.assertEqual(self.line(), "set number")

    def test_ex_fallback_skips_equal_and_rewriting_candidates(self):
        self.nvim.exec_lua("""
          vim.api.nvim_create_user_command('SuggestionsTestGhost', function() end, {
            nargs = '*', complete = function() return { 'other', 'pre', 'prefix', 'prelude' } end,
          })
        """)
        try:
            self.enter(":SuggestionsTestGhost pre", "prefix")
            self.assertEqual(
                [item["label"] for item in self.current()["items"]],
                ["other", "pre", "prefix", "prelude"],
            )
            self.assertEqual(self.current()["ghost"], "fix")
            self.key("<Tab>")
            self.assertFalse(self.current().get("ghost"))
            self.key("<Right>")
            self.assertEqual(self.line(), "SuggestionsTestGhost other")
        finally:
            self.key("<Esc>")
            self.nvim.api.del_user_command("SuggestionsTestGhost")

    def test_ex_ghost_only_at_end_and_nonempty_command(self):
        self.nvim.funcs.histadd(":", "set number norelativenumber")
        self.enter(":")
        self.assertFalse(self.current().get("ghost"))
        self.key("set nu")
        self.wait_for(lambda: self.current().get("ghost"), "Ex ghost")
        self.key("<Left>")
        self.assertFalse(self.current().get("ghost"))
        self.key("<C-e>")
        self.assertEqual(self.line(), "set nu")
        self.wait_for(lambda: self.current().get("ghost"), "restored Ex ghost")

    def test_ex_unaccepted_ghost_does_not_execute(self):
        self.nvim.funcs.histadd(":", "let g:suggestions_actual = 10")
        self.enter(":let g:suggestions_actual = 1")
        self.wait_for(lambda: self.current().get("ghost") == "0", "unaccepted suffix")
        self.key("<CR>")
        self.assertEqual(self.nvim.vars["suggestions_actual"], 1)

    def test_ex_file_ghost_preserves_escaping_and_unicode(self):
        for prefix, expected in (
            ("space", "space\\ file.txt"),
            ("中文", "中文文件.txt"),
        ):
            with self.subTest(prefix=prefix):
                self.enter(
                    ":edit " + prefix,
                    "file.txt" if prefix == "space" else "中文文件.txt",
                )
                self.assertEqual(self.current()["ghost"], expected[len(prefix) :])
                self.key("<Right>")
                self.assertEqual(self.line(), "edit " + expected)
                self.assertEqual(
                    self.nvim.funcs.getcmdpos(), len(("edit " + expected).encode()) + 1
                )
                self.key("<Esc>")

    def test_selection_and_enter_do_not_execute(self):
        self.enter(":set nu", "number")
        before = self.nvim.current.window.options["number"]
        self.key("<Tab><CR>")
        self.assertEqual(self.line(), "set number")
        self.assertEqual(self.nvim.current.window.options["number"], before)
        self.key("<CR>")
        self.assertTrue(self.nvim.current.window.options["number"])

    def test_confirm_already_complete_item_and_reverse_selection(self):
        self.enter(":set number", "number")
        self.key("<S-Tab>")
        self.assertEqual(self.current()["selected"], len(self.current()["items"]))
        self.key("<Tab><CR>")
        self.assertEqual(self.line(), "set number")
        self.key("<CR>")
        self.assertEqual(self.nvim.api.get_mode()["mode"], "n")

    def test_escape_never_executes(self):
        self.enter(":let g:suggestions_should_not_run = 1")
        self.key("<Esc>")
        self.assertEqual(self.nvim.funcs.exists("g:suggestions_should_not_run"), 0)
        self.assertEqual(self.nvim.api.get_mode()["mode"], "n")

    def test_dynamic_height_and_restore(self):
        self.enter(":!ls ", "alpha")
        self.assertEqual(self.inspect()["ui"]["height"], 9)
        self.key("a-directory/in")
        self.wait_for(lambda: len(self.current().get("items", [])) == 1, "one match")
        self.assertEqual(self.inspect()["ui"]["height"], 4)
        self.key("<Esc>")
        self.assertEqual(self.nvim.options["cmdheight"], 0)

    def test_ex_file_completion_with_spaces(self):
        self.enter(":edit space", "file.txt")
        self.key("<Tab><CR>")
        self.assertEqual(self.line(), "edit space\\ file.txt")

    def test_ex_substitution_and_visual_range(self):
        self.enter(":%s/one/changed/")
        self.key("<CR>")
        self.assertEqual(self.nvim.current.buffer[0], "changed")
        self.key("Vj:")
        self.assertEqual(self.line(), "'<,'>")
        self.key("s/two/TWO/<CR>")
        self.assertEqual(self.nvim.current.buffer[1], "TWO")

    def test_filter_prefix_and_no_false_shell_detection(self):
        self.enter(":2,4!sor", "sort")
        self.assertEqual(self.current()["shell"], "2,4!")
        self.key("<Esc>")
        self.enter(':echo "!"')
        self.assertFalse(self.current().get("shell"))

    def test_search_and_nested_expression(self):
        self.nvim.funcs.histadd(":", "two more")
        self.enter("/two")
        self.assertFalse(self.current().get("ghost"))
        self.key("<CR>")
        self.assertEqual(self.nvim.current.window.cursor[0], 2)
        self.enter(":echo ")
        self.nvim.funcs.histadd(":", "1+234")
        self.key("<C-r>=1+2")
        self.assertEqual(self.current()["firstc"], "=")
        self.assertFalse(self.current().get("ghost"))
        self.key("<CR>")
        self.assertEqual(self.line(), "echo 3")

    def test_stale_completion_cannot_replace_new_input(self):
        self.enter(":!sg-slow ")
        time.sleep(0.05)
        self.key("<C-u>!git --ver")
        self.wait_for(
            lambda: any("--version" in x["text"] for x in self.current()["items"]),
            "latest response",
        )
        self.assertNotIn("slow-result", repr(self.current()["items"]))

    def test_resize_and_long_unicode_input(self):
        self.nvim.ui_try_resize(42, 16)
        self.enter(":!echo " + "中文" * 40)
        self.key("<Left><Left>")
        self.assertTrue(self.inspect()["enabled"])
        config = self.nvim.api.win_get_config(self.inspect()["ui"]["win"])
        self.assertEqual(config["width"], 42)
        self.assertLessEqual(config["height"], 5)
        self.key("<Esc>")
        self.nvim.ui_try_resize(100, 32)

    def test_layout_focus_is_preserved(self):
        win, buf = self.nvim.current.window.handle, self.nvim.current.buffer.handle
        self.enter(":!ls ", "alpha")
        self.assertEqual(self.nvim.current.window.handle, win)
        self.assertEqual(self.nvim.current.buffer.handle, buf)
        drawer = self.inspect()["ui"]
        self.assertEqual(
            self.nvim.api.win_get_config(drawer["win"])["row"], 32 - drawer["height"]
        )
        self.key("<Esc>")
        self.assertEqual(len(self.nvim.windows), 1)

    def test_window_local_cwd(self):
        self.nvim.command(
            "lcd " + self.nvim.funcs.fnameescape(str(self.cwd / "a-directory"))
        )
        try:
            self.enter(":!cat in", "inside.txt")
            self.assertEqual(
                Path(self.current()["cwd"]).resolve(),
                (self.cwd / "a-directory").resolve(),
            )
        finally:
            self.key("<Esc>")
            self.nvim.command("lcd " + self.nvim.funcs.fnameescape(str(self.cwd)))

    def test_reload_reads_config_and_history(self):
        rc = self.folder / ".zshrc"
        history = self.folder / "history"
        old_rc, old_history = rc.read_text(), history.read_text()
        mapping = self.nvim.funcs.maparg("<Tab>", "c", False, True)
        self.assertEqual(len(self.backend("sg-test --")), 3)
        self.nvim.exec_lua(
            "require('suggestions.backend').remember('sg-session remembered')"
        )
        try:
            rc.write_text(
                old_rc + "\n_sg_test() { compadd -- --reloaded; }\n"
                "alias sg-reloaded-alias='git status'\n"
            )
            history.write_text(old_history + ": 1700000003:0;sg-disk refreshed\n")
            self.nvim.command("SuggestionsReload")
            self.wait_for(lambda: self.inspect()["backend"]["ready"], "reload")
            self.assertEqual(
                [x["text"].rstrip() for x in self.backend("sg-test --")],
                ["sg-test --reloaded"],
            )
            self.assertIn(
                "sg-reloaded-alias",
                [x["text"].rstrip() for x in self.backend("sg-reloaded-a")],
            )
            for prefix, expected in (
                ("sg-session", "sg-session remembered"),
                ("sg-disk", "sg-disk refreshed"),
            ):
                self.assertIn(
                    expected,
                    self.nvim.exec_lua(
                        "return require('suggestions.backend').history(...)", prefix
                    ),
                )
            self.assertEqual(self.nvim.funcs.maparg("<Tab>", "c", False, True), mapping)
        finally:
            rc.write_text(old_rc)
            history.write_text(old_history)
            self.nvim.command("SuggestionsReload")
            self.wait_for(lambda: self.inspect()["backend"]["ready"], "restore zsh")

    def test_reload_during_completion_preserves_input(self):
        self.enter(":!sg-slow ")
        self.wait_for(lambda: self.inspect()["backend"]["pending"], "slow request")
        self.nvim.exec_lua("require('suggestions').reload()")
        self.assertEqual(self.line(), "!sg-slow ")
        self.key("<C-u>!sg-test --")
        self.wait_for(lambda: len(self.current()["items"]) == 3, "fresh completion")
        time.sleep(0.2)
        self.assertNotIn("slow-result", repr(self.current()["items"]))
        self.assertFalse(self.current().get("error"))

    def test_reload_keeps_plugin_disabled(self):
        self.nvim.command("SuggestionsDisable")
        try:
            self.nvim.command("SuggestionsReload")
            self.assertFalse(self.inspect()["enabled"])
            self.assertFalse(self.inspect()["backend"]["running"])
        finally:
            self.nvim.command("SuggestionsEnable")

    def test_z_backend_timeout_recovers(self):
        self.nvim.exec_lua(
            """
          local config = require('suggestions.config').resolve({
            zsh = { env = { ZDOTDIR = ... }, timeout_ms = 40 },
          })
          require('suggestions.backend').setup(config.zsh)
          _G.sg_timeout = nil
          require('suggestions.backend').request('sg-slow ', 8, vim.fn.getcwd(), function(_, err)
            _G.sg_timeout = err or false
          end)
        """,
            str(self.folder),
        )
        self.wait_for(
            lambda: self.nvim.exec_lua("return _G.sg_timeout ~= nil"), "timeout"
        )
        self.assertIn("timed out", self.nvim.exec_lua("return _G.sg_timeout"))
        self.assertFalse(self.inspect()["backend"]["running"])
        self.assertTrue(self.backend("sg-test --a"))

    def test_z_disable_and_reenable(self):
        self.nvim.exec_lua("""
          require('suggestions').disable()
          vim.keymap.set('c', '<Tab>', '<C-z>', { desc = 'original mapping' })
          require('suggestions').enable()
        """)
        self.enter(":set nu", "number")
        self.nvim.exec_lua("require('suggestions').disable()")
        self.assertFalse(self.inspect()["enabled"])
        self.assertFalse(self.inspect()["backend"]["running"])
        self.assertEqual(self.nvim.options["cmdheight"], 0)
        self.assertEqual(
            self.nvim.funcs.maparg("<Tab>", "c", False, True)["desc"],
            "original mapping",
        )
        self.key("<C-c>")
        self.nvim.exec_lua(
            "vim.keymap.del('c', '<Tab>'); require('suggestions').enable()"
        )

    def test_z_manual_completion_and_missing_shell(self):
        self.nvim.exec_lua("""
          require('suggestions').setup({ completion = { auto = false }, zsh = { shell = '/nonexistent/zsh' } })
        """)
        self.nvim.funcs.histadd(":", "set number norelativenumber")
        self.enter(":set nu")
        self.assertFalse(self.current()["items"])
        self.assertEqual(self.current()["ghost"], "mber norelativenumber")
        self.assertFalse(self.inspect()["backend"]["running"])
        self.key("<Tab>")
        self.assertEqual(self.current()["selected"], 1)
        self.assertEqual(self.current()["ghost"], "mber")
        self.key("<CR>")
        self.assertEqual(self.line(), "set number")
        self.key("<Esc>")
        self.enter(":!echo abc")
        self.key("<Tab>")
        self.assertIn("not found", self.current()["error"])
        self.assertTrue(self.inspect()["enabled"])
        self.key("<Esc>")
        self.nvim.exec_lua("require('suggestions').setup()")


if __name__ == "__main__":
    unittest.main(verbosity=2)
