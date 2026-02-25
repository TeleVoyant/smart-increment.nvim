# smart-increment.nvim

A Neovim plugin for **sequential paste with auto-incrementing numbers**.

Yank text containing numbers, then paste repeatedly — each paste automatically
increments (or decrements) every number in the text by your chosen step.

## Use Case

You have a line like `local item_001 = create("widget_01")` and want to quickly
produce `item_002`, `item_003`, etc. without manual editing:

1. Yank the line.
2. Press `<leader>a` → choose `+` and step `1`.
3. Press `<leader>a` again and again — each paste bumps the numbers up.

## Features

- **Prompted once, reused forever** — direction and step are asked only on
  first use (or after reset).
- **Auto-reset on new yank** — when you yank new content into the tracked
  register, the plugin resets automatically so you start fresh.
- **Manual reset** — press `<leader>ar` to reset at any time.
- **Preserves leading zeros** — `007` incremented by 1 → `008`.
- **Handles negative numbers** — `-3` incremented by 5 → `2`.
- **Configurable register** — defaults to the unnamed register (`"`), but you
  can track any register.

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
  register = '"',         -- register to track (default: unnamed)
  linewise_paste = false,  -- force linewise paste (default: follows register type)
  keymaps = {
    increment_paste = "<leader>a",  -- set to false to disable
    reset = "<leader>ar",           -- set to false to disable
  },
})
```

### Custom Keymaps

Override the defaults:

```lua
require("smart-increment").setup({
  keymaps = {
    increment_paste = "<leader>i",
    reset = "<leader>ir",
  },
})
```

### Manual Keymaps

Disable default keymaps and bind yourself:

```lua
local si = require("smart-increment")
si.setup({
  keymaps = {
    increment_paste = false,
    reset = false,
  },
})

vim.keymap.set("n", "<C-a>", si.increment_paste, { desc = "Increment paste" })
vim.keymap.set("n", "<C-a>r", si.reset, { desc = "Reset increment" })
```

## API

The following functions are exposed on the module and can be called directly:

| Function                                       | Description                       |
| ---------------------------------------------- | --------------------------------- |
| `require("smart-increment").increment_paste()` | Increment and paste from register |
| `require("smart-increment").reset()`           | Reset plugin state                |
| `require("smart-increment").setup(opts?)`      | Initialise plugin with options    |

## Keymaps

| Key          | Mode   | Action                                      |
| ------------ | ------ | ------------------------------------------- |
| `<leader>a`  | Normal | Increment/decrement and paste from register |
| `<leader>ar` | Normal | Reset plugin state                          |

## How It Works

```
yank "item_001"
    │
    ▼
<leader>a  ──► prompt: +/- and step
    │
    ▼
paste "item_002", register now holds "item_002"
    │
    ▼
<leader>a  ──► paste "item_003", register now holds "item_003"
    │
    ▼
new yank or <leader>ar  ──► state reset
```

## License

MIT
