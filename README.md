# smart-increment.nvim

A Neovim plugin for **sequential paste and search-replace with auto-incrementing numbers**.

Yank text containing numbers, then paste or search-and-replace repeatedly —
each action automatically increments (or decrements) every number by your
chosen step.

## Modes

### 1. Paste

Classic mode. Increments register content and pastes it. Supports multiline.

```
yank "item_001" → <leader>ss → paste "item_002"
                  <leader>ss → paste "item_003"
```

### 2. Search & Replace (current line)

Finds the best structural match on the cursor line and replaces it with the
incremented value. If no match is found, the register is **not** incremented
(safe to retry on another line).

```
buffer line:   local item_005 = create("widget")
register:      item_001
               ↓ <leader>ss
buffer line:   local item_002 = create("widget")
```

### 3. Search & Replace (multi-line)

Searches across a range of lines and replaces every match. Each replacement
gets the next sequential value.

**Scope options** (prompted once):

- **Whole file** — scans all lines top to bottom.
- **From line number** — scans from a starting line, either down or up.
- **Visual selection** — if you press `<leader>ss` in visual mode, only
  selected lines are searched (no scope prompt).

```
register: item_001, step +1

  line 10:  item_001 = a       →  item_002 = a
  line 11:  item_001 = b       →  item_003 = b
  line 12:  other_stuff             (unchanged)
  line 13:  item_001 = c       →  item_004 = c
```

## Features

- **Three modes** — paste, single-line S&R, multi-line S&R.
- **Prompted once** — mode, direction, and step are asked only on first use.
- **Auto-reset on new yank** — new content in the register resets the plugin.
- **Manual reset** — `<leader>sS` resets at any time.
- **Preserves leading zeros** — `007` + 1 → `008`.
- **Handles negative numbers** — `-3` + 5 → `2`.
- **Multiline register support** — paste mode handles multiline; S&R modes
  use the first line for matching (remaining lines preserved in register).
- **Visual mode support** — in S&R multi-line mode, visual selection defines
  the search range.
- **Edge case handling** — empty register, no numbers, no matches, invalid
  input — all handled gracefully with notifications.

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "TeleVoyant/smart-increment.nvim",
  config = function()
    require("smart-increment").setup()
  end,
}
```

Using [packer.nvim](https://github.com/wbthomason/packer.nvim):

```lua
use {
  "TeleVoyant/smart-increment.nvim",
  config = function()
    require("smart-increment").setup()
  end,
}
```

## Configuration

All options are optional:

```lua
require("smart-increment").setup({
  register = '"',            -- register to track (default: unnamed)
  linewise_paste = false,     -- force linewise paste in paste mode
  sr_multi_report = false,    -- show detailed report after S&R multi-line
  similarity_threshold = 0.5 -- between 0 and 1, for SR_LINE pattern match acceptance
  keymaps = {
    increment_paste = "<leader>ss",   -- false to disable
    reset = "<leader>sS",            -- false to disable
  },
})
```

### `sr_multi_report`

When `false` (default), S&R multi-line shows a concise one-liner:

```
smart-increment: 15 replacement(s), 12 line(s) modified.
```

When `true`, an additional detailed report is shown:

```
── smart-increment: detailed report ──
  Scope        : whole file
  Pattern      : item_001
  Step         : +1
  Lines scanned: 150
  Lines modified: 12
  Replacements : 15
  Value range  : item_002 → item_016
  Modified     : L10, 11, 13, 25, 30, 31, 42, 50, 61, 73
```

### Custom Keymaps

```lua
require("smart-increment").setup({
  keymaps = {
    increment_paste = "<leader>i",
    reset = "<leader>ir",
  },
})
```

### Manual Keymaps

```lua
local si = require("smart-increment")
si.setup({
  keymaps = { increment_paste = false, reset = false },
})

vim.keymap.set("n", "<C-a>", si.increment_paste)
vim.keymap.set("v", "<C-a>", si.increment_paste_visual)
vim.keymap.set("n", "<C-a>r", si.reset)
```

## Default Keymaps

| Key          | Mode   | Action                      |
| ------------ | ------ | --------------------------- |
| `<leader>ss` | Normal | Main action (paste / S&R)   |
| `<leader>ss` | Visual | S&R multi-line on selection |
| `<leader>sS` | Normal | Reset plugin state          |

## API

| Function                   | Description                                  |
| -------------------------- | -------------------------------------------- |
| `increment_paste()`        | Main action (normal mode)                    |
| `increment_paste_visual()` | Main action (visual mode)                    |
| `reset()`                  | Reset plugin state                           |
| `is_active()`              | Returns `true` if plugin is configured       |
| `get_state()`              | Returns a copy of internal state (for debug) |
| `get_mode_label()`         | Returns current mode name, or `nil`          |
| `setup(opts?)`             | Initialise with options                      |

## How It Works

```
yank "item_001"
    │
    ▼
<leader>ss
    │
    ├─ [1] Paste      → prompt +/- and step → paste incremented → update register
    ├─ [2] S&R line   → prompt +/- and step → find match on cursor line → replace
    └─ [3] S&R multi  → prompt +/- and step → prompt scope → replace all matches
    │
    ▼
<leader>ss  (repeat — no prompts)
    │
    ▼
new yank or <leader>sS → state reset → next <leader>ss re-prompts
```

## License

MIT
