---@mod smart-increment A Neovim plugin for incremental paste and search-replace from register.
---
--- Yank text containing numbers, then repeatedly paste or search-and-replace
--- with auto-incrementing/decrementing values. Three modes:
---
---   1. **Paste** — classic paste with increment (supports multiline).
---   2. **Search & Replace (current line)** — finds the best match on the
---      cursor line and replaces it with the incremented register content.
---   3. **Search & Replace (multi-line)** — searches across a range of lines
---      (whole file, from a line number, or visual selection) and replaces
---      every match, incrementing after each replacement.
---
--- Usage:
---   1. Yank some text containing numbers (e.g., `item_001`).
---   2. Press `<leader>ss` — prompted for mode, direction, and step.
---   3. Press `<leader>ss` again — repeats without prompting.
---   4. Press `<leader>sS` to reset.
---
--- @brief [[
--- require("smart-increment").setup()
--- @brief ]]

local M = {}

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------

---@enum SmartIncrementMode
local MODE = {
  PASTE = "paste",
  SR_LINE = "sr_line",       -- search & replace on current line
  SR_MULTI = "sr_multi",     -- search & replace across multiple lines
}

local MODE_LABELS = {
  [MODE.PASTE] = "Paste only",
  [MODE.SR_LINE] = "Search & Replace (current line)",
  [MODE.SR_MULTI] = "Search & Replace (multi-line)",
}

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

---@class SmartIncrementState
---@field sign number 1 or -1
---@field amount number step size
---@field mode SmartIncrementMode selected operating mode
---@field register string register name being tracked
---@field original_content string register content at the time of first prompt (before any increment)
---@field last_register_content string snapshot after last operation (for change detection)
---@field sr_multi_opts? {scope: string, start_line?: number, direction?: string}

---@type SmartIncrementState|nil
local state = nil

-------------------------------------------------------------------------------
-- Configuration
-------------------------------------------------------------------------------

---@class SmartIncrementKeymaps
---@field increment_paste string|false keymap for main action (false to disable)
---@field reset string|false keymap for reset (false to disable)

---@class SmartIncrementConfig
---@field register string register to watch (default: `"`)
---@field linewise_paste boolean force linewise paste in paste mode
---@field number_pattern string Lua pattern for matching numbers
---@field sr_multi_report boolean show detailed report after SR multi-line (default: false)
---@field keymaps SmartIncrementKeymaps

---@type SmartIncrementConfig
local config = {
  register = '"',
  linewise_paste = false,
  number_pattern = "%-?%d+",
  sr_multi_report = false,
  keymaps = {
    increment_paste = "<leader>ss",
    reset = "<leader>sS",
  },
}

-------------------------------------------------------------------------------
-- Helpers: Numbers
-------------------------------------------------------------------------------

--- Check whether the given text contains at least one digit.
---@param text string
---@return boolean
local function has_numbers(text)
  return text:find("%d") ~= nil
end

--- Format a number preserving the original's width and leading zeros.
---@param original string the matched number string (e.g., "007")
---@param new_number number the replacement value
---@return string
local function format_number(original, new_number)
  local digits_only = original:gsub("^%-", "")
  local width = #digits_only
  local formatted = tostring(math.abs(new_number))

  if #formatted < width then
    formatted = string.rep("0", width - #formatted) .. formatted
  end

  if new_number < 0 then
    formatted = "-" .. formatted
  end

  return formatted
end

--- Increment/decrement every number in `text`.
---@param text string
---@param sign number 1 or -1
---@param amount number
---@return string
local function process_text(text, sign, amount)
  return text:gsub(config.number_pattern, function(num_str)
    local num = tonumber(num_str)
    if not num then return num_str end
    return format_number(num_str, num + (sign * amount))
  end)
end

-------------------------------------------------------------------------------
-- Helpers: Register
-------------------------------------------------------------------------------

--- Read the tracked register's contents.
---@return string
local function read_register()
  return vim.fn.getreg(config.register)
end

--- Write to the tracked register, preserving its type (charwise/linewise).
---@param content string
local function write_register(content)
  local reg_type = vim.fn.getregtype(config.register)
  vim.fn.setreg(config.register, content, reg_type)
end

--- Check if the register content is multiline.
---@param content string
---@return boolean
local function is_multiline(content)
  -- Strip a single trailing newline (linewise yank artefact) before checking.
  local stripped = content:gsub("\n$", "")
  return stripped:find("\n") ~= nil
end

--- Detect if the user has yanked new content since our last operation.
---@return boolean
local function register_changed()
  if not state then return false end
  return read_register() ~= state.last_register_content
end

-------------------------------------------------------------------------------
-- Helpers: Pattern matching for search & replace
-------------------------------------------------------------------------------

--- Build a Lua pattern from register content where numbers are replaced with
--- a capture group. This lets us find "the same text but with different numbers"
--- on a line.
---
--- Example: "item_001_foo" -> "item_(%-?%d+)_foo"
---
---@param text string register content (single line)
---@return string pattern  Lua pattern with number slots as captures
---@return number capture_count  how many number captures in the pattern
local function build_search_pattern(text)
  local parts = {}
  local last_end = 1
  local capture_count = 0

  local search_start = 1
  while search_start <= #text do
    local match_start, match_end = text:find(config.number_pattern, search_start)
    if not match_start then break end

    -- Escape the literal text between numbers.
    local literal = text:sub(last_end, match_start - 1)
    literal = literal:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
    table.insert(parts, literal)

    -- Replace each number with a capture group matching digits
    -- (and optional leading minus).
    table.insert(parts, "(%-?%d+)")
    capture_count = capture_count + 1

    last_end = match_end + 1
    search_start = match_end + 1
  end

  -- Trailing literal after the last number.
  local tail = text:sub(last_end)
  tail = tail:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
  table.insert(parts, tail)

  return table.concat(parts), capture_count
end

--- Compute a similarity score between two strings.
--- Compares structural "skeletons" (text with numbers stripped).
---@param a string
---@param b string
---@return number score between 0 and 1
local function similarity(a, b)
  if a == b then return 1.0 end
  if #a == 0 or #b == 0 then return 0.0 end

  -- Strip numbers and compare skeletons.
  local skel_a = a:gsub(config.number_pattern, "")
  local skel_b = b:gsub(config.number_pattern, "")

  if skel_a == skel_b then return 0.9 end

  -- Fallback: positional character overlap ratio.
  local shorter, longer = a, b
  if #a > #b then shorter, longer = b, a end

  local matches = 0
  for i = 1, #shorter do
    if shorter:sub(i, i) == longer:sub(i, i) then
      matches = matches + 1
    end
  end

  return matches / #longer
end

--- Minimum similarity threshold for a match to be accepted in SR_LINE mode.
local SIMILARITY_THRESHOLD = 0.5

--- Extract the search line from register content.
--- For multiline registers in S&R modes, uses only the first line and warns.
---@param reg_content string
---@return string first_line
local function extract_search_line(reg_content)
  if is_multiline(reg_content) then
    vim.notify(
      "smart-increment: multiline register — using first line for search.",
      vim.log.levels.WARN
    )
  end
  return reg_content:gsub("\n.*", "")
end

--- Update the register after a S&R operation.
--- For multiline registers, only the first line is replaced; remaining lines
--- are preserved.
---@param reg_content string original full register content
---@param new_first_line string the incremented first line
local function update_register_sr(reg_content, new_first_line)
  if is_multiline(reg_content) then
    local rest = reg_content:match("\n(.*)$") or ""
    local new_reg = new_first_line .. (rest ~= "" and ("\n" .. rest) or "")
    write_register(new_reg)
    state.last_register_content = new_reg
  else
    write_register(new_first_line)
    state.last_register_content = new_first_line
  end
end

-------------------------------------------------------------------------------
-- Helpers: Prompts
-------------------------------------------------------------------------------

--- Prompt for increment direction and step amount.
---@return {sign: number, amount: number}|nil
local function prompt_direction_and_step()
  local direction = vim.fn.input("Increment or decrement? (+/-): ")
  if direction ~= "+" and direction ~= "-" then
    vim.notify("Cancelled or invalid. Use + or -.", vim.log.levels.WARN)
    return nil
  end

  local raw = vim.fn.input("Step amount: ")
  local amount = tonumber(raw)
  if not amount or amount <= 0 then
    vim.notify("Invalid amount. Must be a positive number.", vim.log.levels.ERROR)
    return nil
  end

  return {
    sign = direction == "+" and 1 or -1,
    amount = amount,
  }
end

--- Prompt for operating mode.
---@return SmartIncrementMode|nil
local function prompt_mode()
  local choice = vim.fn.input(
    "Mode — [1] Paste  [2] S&R current line  [3] S&R multi-line: "
  )

  if choice == "1" then return MODE.PASTE
  elseif choice == "2" then return MODE.SR_LINE
  elseif choice == "3" then return MODE.SR_MULTI
  else
    vim.notify("Invalid mode selection.", vim.log.levels.WARN)
    return nil
  end
end

--- Prompt for multi-line search & replace scope.
--- Only called once, when mode is SR_MULTI and not in visual mode.
---@return {scope: string, start_line?: number, direction?: string}|nil
local function prompt_sr_multi_scope()
  local scope = vim.fn.input(
    "Scope — [1] Whole file  [2] From line number: "
  )

  if scope == "1" then
    return { scope = "whole" }
  elseif scope == "2" then
    local raw_line = vim.fn.input("Start line number: ")
    local start_line = tonumber(raw_line)
    if not start_line or start_line < 1 then
      vim.notify("Invalid line number.", vim.log.levels.ERROR)
      return nil
    end

    local dir = vim.fn.input("Direction — [d] Down (towards end)  [u] Up (towards top): ")
    if dir ~= "d" and dir ~= "u" then
      vim.notify("Invalid direction. Use d or u.", vim.log.levels.WARN)
      return nil
    end

    return {
      scope = "from_line",
      start_line = start_line,
      direction = dir == "d" and "down" or "up",
    }
  else
    vim.notify("Invalid scope selection.", vim.log.levels.WARN)
    return nil
  end
end

-------------------------------------------------------------------------------
-- Helpers: Paste
-------------------------------------------------------------------------------

--- Paste text at cursor. Respects register type and config.linewise_paste.
---@param text string
local function paste_text(text)
  local reg_type = vim.fn.getregtype(config.register)

  if config.linewise_paste or reg_type:sub(1, 1) == "V" then
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local lines = vim.split(text, "\n", { trimempty = false })
    vim.api.nvim_buf_set_lines(0, row, row, false, lines)
    vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
  else
    -- Use native paste for correct charwise cursor positioning.
    write_register(text)
    vim.cmd('normal! "' .. config.register .. "p")
  end
end

-------------------------------------------------------------------------------
-- Core: Mode handlers
-------------------------------------------------------------------------------

--- Handle PASTE mode.
--- Increments register content, pastes it, and updates the register.
local function handle_paste()
  local current = read_register()
  local incremented = process_text(current, state.sign, state.amount)

  paste_text(incremented)

  write_register(incremented)
  state.last_register_content = incremented
end

--- Handle SEARCH & REPLACE (current line) mode.
--- Finds the best structural match on the cursor line, replaces it with
--- the incremented register content. Does NOT increment on failed match.
local function handle_sr_line()
  local reg_content = read_register()
  local search_text = extract_search_line(reg_content)

  local pattern, cap_count = build_search_pattern(search_text)
  if cap_count == 0 then
    vim.notify("smart-increment: no number placeholders in pattern.", vim.log.levels.WARN)
    return
  end

  local line = vim.api.nvim_get_current_line()

  -- Find all pattern matches on the line and pick the best one by similarity.
  local best_match = nil
  local best_score = -1
  local search_start = 1

  while search_start <= #line do
    local match_start, match_end = line:find(pattern, search_start)
    if not match_start then break end

    local matched_text = line:sub(match_start, match_end)
    local score = similarity(search_text, matched_text)

    if score > best_score then
      best_score = score
      best_match = {
        start_pos = match_start,
        end_pos = match_end,
        text = matched_text,
      }
    end

    search_start = match_start + 1
  end

  if not best_match or best_score < SIMILARITY_THRESHOLD then
    vim.notify(
      "smart-increment: no matching pattern found on current line.",
      vim.log.levels.WARN
    )
    -- Intentionally do NOT increment — preserve register for retry.
    return
  end

  -- Increment and replace.
  local incremented = process_text(search_text, state.sign, state.amount)

  local new_line = line:sub(1, best_match.start_pos - 1)
    .. incremented
    .. line:sub(best_match.end_pos + 1)

  vim.api.nvim_set_current_line(new_line)

  update_register_sr(reg_content, incremented)
end

--- Handle SEARCH & REPLACE (multi-line) mode.
--- Replaces every pattern match across the specified range.
--- Each successful replacement uses the next incremented value, so matches
--- are replaced sequentially (match1 → +1, match2 → +2, …).
---
---@param visual_start? number start line of visual selection (1-indexed)
---@param visual_end? number end line of visual selection (1-indexed)
local function handle_sr_multi(visual_start, visual_end)
  local reg_content = read_register()
  local search_text = extract_search_line(reg_content)

  local pattern, cap_count = build_search_pattern(search_text)
  if cap_count == 0 then
    vim.notify("smart-increment: no number placeholders in pattern.", vim.log.levels.WARN)
    return
  end

  -- Determine line range and iteration order.
  local total_lines = vim.api.nvim_buf_line_count(0)
  local line_indices = {}

  if visual_start and visual_end then
    -- Visual selection overrides stored scope.
    for i = visual_start, visual_end do
      table.insert(line_indices, i)
    end
  elseif state.sr_multi_opts then
    local opts = state.sr_multi_opts
    if opts.scope == "whole" then
      for i = 1, total_lines do
        table.insert(line_indices, i)
      end
    elseif opts.scope == "from_line" then
      local start = math.max(1, math.min(opts.start_line, total_lines))
      if opts.direction == "down" then
        for i = start, total_lines do
          table.insert(line_indices, i)
        end
      else -- "up"
        for i = start, 1, -1 do
          table.insert(line_indices, i)
        end
      end
    end
  else
    -- Fallback (shouldn't happen, but safe default).
    for i = 1, total_lines do
      table.insert(line_indices, i)
    end
  end

  -- Walk through lines, replacing all matches left-to-right.
  -- Each replacement advances the counter independently.
  local current_text = search_text
  local first_value = nil     -- first replacement value (for range report)
  local total_replacements = 0
  local lines_modified = 0
  local lines_scanned = #line_indices
  local modified_line_numbers = {}  -- track which lines were touched

  for _, lnum in ipairs(line_indices) do
    local line = vim.fn.getline(lnum)
    local new_line = ""
    local search_start = 1
    local line_modified = false
    local replacements_on_line = 0

    while search_start <= #line do
      local match_start, match_end = line:find(pattern, search_start)
      if not match_start then
        new_line = new_line .. line:sub(search_start)
        break
      end

      -- Append text before the match.
      new_line = new_line .. line:sub(search_start, match_start - 1)

      -- Increment and replace.
      current_text = process_text(current_text, state.sign, state.amount)
      new_line = new_line .. current_text

      if not first_value then
        first_value = current_text
      end

      total_replacements = total_replacements + 1
      replacements_on_line = replacements_on_line + 1
      line_modified = true

      search_start = match_end + 1
    end

    if line_modified then
      vim.fn.setline(lnum, new_line)
      lines_modified = lines_modified + 1
      table.insert(modified_line_numbers, lnum)
    end
  end

  if total_replacements == 0 then
    vim.notify("smart-increment: no matches found in range.", vim.log.levels.WARN)
    return
  end

  -- Default: concise one-line summary (always shown).
  vim.notify(
    string.format(
      "smart-increment: %d replacement(s), %d line(s) modified.",
      total_replacements, lines_modified
    ),
    vim.log.levels.INFO
  )

  -- Optional: detailed multi-line report (if enabled in config).
  if config.sr_multi_report then
    local direction_label = state.sign == 1 and "+" or "-"
    local scope_label = "whole file"
    if visual_start and visual_end then
      scope_label = string.format("visual selection (L%d–L%d)", visual_start, visual_end)
    elseif state.sr_multi_opts then
      local sopts = state.sr_multi_opts
      if sopts.scope == "from_line" then
        scope_label = string.format("from L%d %s", sopts.start_line, sopts.direction)
      end
    end

    -- Summarise modified line numbers compactly.
    local line_list
    if #modified_line_numbers <= 10 then
      local strs = {}
      for _, n in ipairs(modified_line_numbers) do
        table.insert(strs, tostring(n))
      end
      line_list = table.concat(strs, ", ")
    else
      local strs = {}
      for i = 1, 8 do
        table.insert(strs, tostring(modified_line_numbers[i]))
      end
      line_list = table.concat(strs, ", ")
        .. string.format(" … +%d more", #modified_line_numbers - 8)
    end

    local report = table.concat({
      "── smart-increment: detailed report ──",
      string.format("  Scope        : %s", scope_label),
      string.format("  Pattern      : %s", search_text),
      string.format("  Step         : %s%s", direction_label, state.amount),
      string.format("  Lines scanned: %d", lines_scanned),
      string.format("  Lines modified: %d", lines_modified),
      string.format("  Replacements : %d", total_replacements),
      string.format("  Value range  : %s → %s", first_value or "?", current_text),
      string.format("  Modified     : L%s", line_list),
    }, "\n")

    vim.notify(report, vim.log.levels.INFO)
  end

  -- Update register to the last incremented value.
  update_register_sr(reg_content, current_text)
end

-------------------------------------------------------------------------------
-- Core: Main dispatch
-------------------------------------------------------------------------------

--- Internal dispatcher — routes to the correct handler based on state.mode.
---@param opts? {visual: boolean}
local function do_increment(opts)
  opts = opts or {}
  local reg_content = read_register()

  -- Auto-reset if the register changed externally (new yank).
  if state and register_changed() then
    state = nil
  end

  -- First invocation or post-reset: validate and prompt.
  if not state then
    -- Guard: empty register.
    if not reg_content or reg_content == "" then
      vim.notify(
        "smart-increment: register @" .. config.register .. " is empty.",
        vim.log.levels.WARN
      )
      return
    end

    -- Guard: no numbers.
    if not has_numbers(reg_content) then
      vim.notify(
        "smart-increment: no numbers found in register @" .. config.register .. ".",
        vim.log.levels.WARN
      )
      return
    end

    -- Prompt: mode selection.
    local mode = prompt_mode()
    if not mode then return end

    -- Prompt: direction and step.
    local dir_step = prompt_direction_and_step()
    if not dir_step then return end

    -- Prompt: SR_MULTI scope (only when NOT in visual mode — visual overrides).
    local sr_multi_opts = nil
    if mode == MODE.SR_MULTI and not opts.visual then
      sr_multi_opts = prompt_sr_multi_scope()
      if not sr_multi_opts then return end
    end

    state = {
      sign = dir_step.sign,
      amount = dir_step.amount,
      mode = mode,
      register = config.register,
      original_content = reg_content,
      last_register_content = reg_content,
      sr_multi_opts = sr_multi_opts,
    }
  end

  -- Dispatch.
  if state.mode == MODE.PASTE then
    handle_paste()
  elseif state.mode == MODE.SR_LINE then
    handle_sr_line()
  elseif state.mode == MODE.SR_MULTI then
    if opts.visual then
      local vs = vim.fn.getpos("'<")[2]
      local ve = vim.fn.getpos("'>")[2]
      handle_sr_multi(vs, ve)
    else
      handle_sr_multi()
    end
  end
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

--- Increment and paste / search-replace (normal mode entry point).
function M.increment_paste()
  do_increment({ visual = false })
end

--- Increment and search-replace (visual mode entry point).
--- In SR_MULTI mode, operates only on the visual selection.
--- In other modes, behaves identically to normal mode.
function M.increment_paste_visual()
  -- Leave visual mode so '< '> marks are set correctly.
  local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
  vim.api.nvim_feedkeys(esc, "nx", false)

  -- If state already exists and is SR_MULTI, pass visual flag.
  -- If state doesn't exist yet, we pass visual=true so the initial prompt
  -- skips the scope question (visual selection IS the scope).
  local will_be_visual = (state and state.mode == MODE.SR_MULTI) or true
  do_increment({ visual = will_be_visual })
end

--- Reset the plugin state. Next keypress will re-prompt for everything.
function M.reset()
  state = nil
  vim.notify("smart-increment: reset", vim.log.levels.INFO)
end

--- Return a copy of the current state (for debugging or statusline).
---@return SmartIncrementState|nil
function M.get_state()
  if not state then return nil end
  return vim.deepcopy(state)
end

--- Check whether the plugin is currently configured and active.
---@return boolean
function M.is_active()
  return state ~= nil
end

--- Return the current mode label, or nil if inactive.
---@return string|nil
function M.get_mode_label()
  if not state then return nil end
  return MODE_LABELS[state.mode]
end

-------------------------------------------------------------------------------
-- Setup
-------------------------------------------------------------------------------

--- Initialise the plugin.
---
--- ```lua
--- require("smart-increment").setup({
---   register = '"',
---   linewise_paste = false,
---   sr_multi_report = false,   -- true to show detailed report after S&R multi
---   keymaps = {
---     increment_paste = "<leader>ss",   -- false to disable
---     reset = "<leader>sS",            -- false to disable
---   },
--- })
--- ```
---
--- Exposed API for manual keymaps or scripting:
---   require("smart-increment").increment_paste()
---   require("smart-increment").increment_paste_visual()
---   require("smart-increment").reset()
---   require("smart-increment").is_active()
---   require("smart-increment").get_state()
---   require("smart-increment").get_mode_label()
---
---@param opts SmartIncrementConfig|nil
function M.setup(opts)
  opts = opts or {}
  config = vim.tbl_deep_extend("force", config, opts)

  -- Keymaps ------------------------------------------------------------------

  if config.keymaps.increment_paste then
    vim.keymap.set("n", config.keymaps.increment_paste, M.increment_paste, {
      desc = "smart-increment: increment and paste / search-replace",
    })
    vim.keymap.set("v", config.keymaps.increment_paste, M.increment_paste_visual, {
      desc = "smart-increment: increment and search-replace (visual selection)",
    })
  end

  if config.keymaps.reset then
    vim.keymap.set("n", config.keymaps.reset, M.reset, {
      desc = "smart-increment: reset state",
    })
  end

  -- Autocommand: auto-reset on new yank into tracked register ----------------

  vim.api.nvim_create_autocmd("TextYankPost", {
    group = vim.api.nvim_create_augroup("SmartIncrement", { clear = true }),
    desc = "Auto-reset smart-increment when tracked register content changes",
    callback = function()
      if not state then return end
      local event = vim.v.event
      if event.regname == config.register
        or (event.regname == "" and config.register == '"')
      then
        state = nil
      end
    end,
  })
end

return M
