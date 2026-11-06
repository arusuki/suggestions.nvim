"""Render actual Neovim ext_linegrid output. Requires tests/requirements.txt.

python tests/preview.py [output-directory]
No mock screen: every cell and highlight comes from the running editor.
"""

from pathlib import Path
import sys
import time
from PIL import Image, ImageDraw, ImageFont
from integration import Integration, ROOT


class Screen:
    def __init__(self):
        self.cells = []
        self.highlights = {0: {}}
        self.foreground, self.background = 0xE0E2EA, 0x14161B
        self.cursor = None

    def read(self, nvim):
        nvim.api.get_mode()  # Drain pending redraw notifications.
        queue = nvim._session._pending_messages
        while queue:
            message = queue.popleft()
            if message.name != "redraw":
                continue
            for event in message.args:
                for data in event[1:]:
                    if event[0] == "grid_resize" and data[0] == 1:
                        self.cells = [[(" ", 0)] * data[1] for _ in range(data[2])]
                    elif event[0] == "grid_clear" and data[0] == 1:
                        self.cells = [
                            [(" ", 0)] * len(self.cells[0]) for _ in self.cells
                        ]
                    elif event[0] == "default_colors_set":
                        self.foreground, self.background = data[:2]
                    elif event[0] == "hl_attr_define":
                        self.highlights[data[0]] = data[1]
                    elif event[0] == "grid_cursor_goto" and data[0] == 1:
                        self.cursor = (data[2], data[1])
                    elif event[0] == "grid_line" and data[0] == 1:
                        _, row, col, cells, *_ = data
                        hl = 0
                        for cell in cells:
                            if len(cell) > 1:
                                hl = cell[1]
                            for _ in range(cell[2] if len(cell) > 2 else 1):
                                if col < len(self.cells[row]):
                                    self.cells[row][col] = (cell[0], hl)
                                col += 1
                    elif event[0] == "grid_scroll" and data[0] == 1:
                        _, top, bottom, left, right, rows, _ = data
                        old = [list(row) for row in self.cells]
                        for row in range(top, bottom):
                            for col in range(left, right):
                                self.cells[row][col] = (
                                    old[row + rows][col]
                                    if top <= row + rows < bottom
                                    else (" ", 0)
                                )

    def render(self):
        cell_w, cell_h = 11, 23
        font_path = "/System/Library/Fonts/Menlo.ttc"
        if not Path(font_path).exists():
            font_path = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
        font = ImageFont.truetype(font_path, 17)
        image = Image.new(
            "RGB", (len(self.cells[0]) * cell_w, len(self.cells) * cell_h)
        )
        draw = ImageDraw.Draw(image)

        def color(value):
            if value < 0:
                value = 0
            return ((value >> 16) & 255, (value >> 8) & 255, value & 255)

        for y, row in enumerate(self.cells):
            for x, (text, hl) in enumerate(row):
                attr = self.highlights.get(hl, {})
                fg, bg = (
                    attr.get("foreground", self.foreground),
                    attr.get("background", self.background),
                )
                if attr.get("reverse"):
                    fg, bg = bg, fg
                draw.rectangle(
                    (x * cell_w, y * cell_h, (x + 1) * cell_w, (y + 1) * cell_h),
                    fill=color(bg),
                )
                if text and text != " ":
                    draw.text(
                        (x * cell_w, y * cell_h + 2), text, font=font, fill=color(fg)
                    )
        if self.cursor:
            x, y = self.cursor
            draw.rectangle(
                (x * cell_w, y * cell_h, (x * cell_w) + 1, (y + 1) * cell_h - 1),
                fill=color(self.foreground),
            )
        return image


def main():
    output = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "assets"
    output.mkdir(parents=True, exist_ok=True)
    Integration.setUpClass()
    nvim = Integration.nvim
    screen, frames = Screen(), []
    try:
        nvim.command("cd " + nvim.funcs.fnameescape(str(ROOT)))
        nvim.command("edit " + nvim.funcs.fnameescape(str(ROOT / "minimal.lua")))
        nvim.command("set number laststatus=3 noshowmode termguicolors")
        nvim.command("syntax on")
        nvim.ui_try_resize(100, 28)
        for keys in (":", "!git ", "st", "<Right>", "<Esc>"):
            nvim.input(keys)
            time.sleep(0.4)
            screen.read(nvim)
            frames.append(screen.render())
        frames[2].save(output / "preview.png")
        frames[0].save(
            output / "demo.gif",
            save_all=True,
            append_images=frames[1:],
            duration=[900, 1100, 1800, 1200, 900],
            loop=0,
        )
        nvim.options["background"] = "light"
        nvim.command("colorscheme default")
        nvim.input(":!git st")
        time.sleep(0.4)
        screen.read(nvim)
        screen.render().save(output / "preview-light.png")
        print(output)
    finally:
        Integration.tearDownClass()


if __name__ == "__main__":
    main()
