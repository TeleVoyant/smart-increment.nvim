---@mod smart-increment A Neovim plugin for incremental paste from register.
---
--- Copies text from a register, finds numbers within it, and lets you
--- repeatedly paste with incremented/decremented values. The register
--- contents are updated after each paste so that subsequent pastes
--- continue the sequence.
---
--- Usage:
---   1. Yank some text containing numbers (e.g., `item_001`).
---   2. Press `<leader>a` — you'll be prompted for direction (+/-) and step.
---   3. The plugin pastes the text with numbers adjusted and updates the register.
---   4. Press `<leader>a` again — pastes the next value immediately (no prompt).
---   5. Press `<leader>ar` to reset the plugin state.
---
--- @brief [[
--- require("smart-increment").setup()
--- @brief ]]

local M = {}

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

---@class SmartIncrementState
---@field sign number 1 or -1
---@field amount number step size per paste
---@field register string single-char register name being tracked
---@field last_register_content string snapshot of register content at last operation
---@field active boolean whether the plugin has been configured for the current register

---@type SmartIncrementState|nil
local state = nil

-------------------------------------------------------------------------------
-- Configuration (defaults)
-------------------------------------------------------------------------------

---@class SmartIncrementKeymaps
---@field increment_paste string|false keymap for increment paste (false to disable)
---@field reset string|false keymap for reset (false to disable)

---@class SmartIncrementConfig
---@field register string register to watch (default: `"`)
---@field linewise_paste boolean if true, paste on a new line; if false, paste inline after cursor
---@field number_pattern string Lua pattern for matching numbers
---@field keymaps SmartIncrementKeymaps keymap configuration (set to false to disable all)

---@type SmartIncrementConfig
local config = {
	register = '"',
	linewise_paste = false,
	number_pattern = "%-?%d+",
	keymaps = {
		increment_paste = "<leader>a",
		reset = "<leader>ar",
	},
}

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

--- Check whether the given text contains at least one number.
---@param text string
---@return boolean
local function has_numbers(text)
	return text:find("%d") ~= nil
end

--- Format a new number to preserve the width / leading zeros of the original.
---@param original string the matched number string (e.g., "007")
---@param new_number number the computed replacement value
---@return string
local function format_number(original, new_number)
	-- Strip a leading minus from the original to measure digit width.
	local digits_only = original:gsub("^%-", "")
	local width = #digits_only

	local formatted = tostring(math.abs(new_number))

	-- Pad with leading zeros if the original had them.
	if #formatted < width then
		formatted = string.rep("0", width - #formatted) .. formatted
	end

	if new_number < 0 then
		formatted = "-" .. formatted
	end

	return formatted
end

--- Apply increment/decrement to every number found in `text`.
---@param text string
---@param sign number 1 or -1
---@param amount number
---@return string
local function process_text(text, sign, amount)
	return text:gsub(config.number_pattern, function(num_str)
		local num = tonumber(num_str)
		if not num then
			return num_str
		end
		return format_number(num_str, num + (sign * amount))
	end)
end

--- Read the current contents of the tracked register.
---@return string
local function read_register()
	return vim.fn.getreg(config.register)
end

--- Write new contents into the tracked register, preserving register type.
---@param content string
local function write_register(content)
	local reg_type = vim.fn.getregtype(config.register)
	vim.fn.setreg(config.register, content, reg_type)
end

--- Prompt the user for increment direction and step amount.
---@return {sign: number, amount: number}|nil  nil if the user cancels or enters invalid input
local function prompt_config()
	local direction = vim.fn.input("Increment or decrement? (+/-): ")

	-- Allow user to cancel with <Esc> (returns empty string).
	if direction ~= "+" and direction ~= "-" then
		vim.notify("Cancelled or invalid choice. Use + or -.", vim.log.levels.WARN)
		return nil
	end

	local raw_amount = vim.fn.input("Step amount: ")
	local amount = tonumber(raw_amount)

	if not amount or amount <= 0 then
		vim.notify("Invalid amount. Must be a positive number.", vim.log.levels.ERROR)
		return nil
	end

	return {
		sign = direction == "+" and 1 or -1,
		amount = amount,
	}
end

--- Paste text at the cursor position.
--- Respects the register type (charwise vs linewise).
---@param text string
local function paste(text)
	local reg_type = vim.fn.getregtype(config.register)

	if config.linewise_paste or reg_type:sub(1, 1) == "V" then
		-- Linewise paste: insert below current line.
		local row = vim.api.nvim_win_get_cursor(0)[1]
		local lines = vim.split(text, "\n", { trimempty = false })
		vim.api.nvim_buf_set_lines(0, row, row, false, lines)
		-- Move cursor to the first pasted line.
		vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
	else
		-- Charwise paste: insert after cursor (like `p`).
		-- We use the native paste command via the register to get correct positioning.
		write_register(text)
		vim.cmd('normal! "' .. config.register .. "p")
	end
end

--- Detect whether the user has yanked new content into the register since
--- the last operation, which means we should auto-reset.
---@return boolean
local function register_changed()
	if not state then
		return false
	end
	return read_register() ~= state.last_register_content
end

-------------------------------------------------------------------------------
-- Core actions
-------------------------------------------------------------------------------

--- Reset the plugin to its initial state. Next `<leader>a` will re-prompt.
function M.reset()
	state = nil
	vim.notify("smart-increment: reset", vim.log.levels.INFO)
end

--- Main entry point — called on `<leader>a`.
function M.increment_paste()
	local reg_content = read_register()

	-- Auto-reset if the register contents changed externally (new yank).
	if state and register_changed() then
		state = nil
	end

	-- First invocation (or after reset): validate register and prompt.
	if not state then
		if not has_numbers(reg_content) then
			vim.notify("smart-increment: no numbers found in register @" .. config.register, vim.log.levels.WARN)
			return
		end

		local user_config = prompt_config()
		if not user_config then
			return
		end

		state = {
			sign = user_config.sign,
			amount = user_config.amount,
			register = config.register,
			last_register_content = reg_content,
			active = true,
		}
	end

	-- Increment the current register content and paste.
	local current = read_register()
	local incremented = process_text(current, state.sign, state.amount)

	paste(incremented)

	-- Update the register so the NEXT paste starts from this value.
	write_register(incremented)
	state.last_register_content = incremented
end

-------------------------------------------------------------------------------
-- Setup
-------------------------------------------------------------------------------

--- Initialise the plugin. Call from your config:
---
--- ```lua
--- require("smart-increment").setup({
---   register = '"',          -- register to track (default: unnamed)
---   linewise_paste = false,  -- force linewise paste behaviour
---   keymaps = {
---     increment_paste = "<leader>a",  -- set to false to disable
---     reset = "<leader>ar",           -- set to false to disable
---   },
--- })
--- ```
---
--- Functions are also exposed on the module for manual keymap binding:
---   require("smart-increment").increment_paste()
---   require("smart-increment").reset()
---
---@param opts SmartIncrementConfig|nil
function M.setup(opts)
	opts = opts or {}
	config = vim.tbl_deep_extend("force", config, opts)

	-- Keymaps ------------------------------------------------------------------
	-- Users can override keys via config.keymaps, or set a key to `false`
	-- to skip that binding entirely (useful when binding manually).

	if config.keymaps.increment_paste then
		vim.keymap.set("n", config.keymaps.increment_paste, M.increment_paste, {
			desc = "smart-increment: paste with incremented numbers",
		})
	end

	if config.keymaps.reset then
		vim.keymap.set("n", config.keymaps.reset, M.reset, {
			desc = "smart-increment: reset state",
		})
	end

	-- Auto-reset when the user yanks new content into the tracked register.
	-- This uses the TextYankPost autocommand to detect register changes
	-- without polling.
	vim.api.nvim_create_autocmd("TextYankPost", {
		group = vim.api.nvim_create_augroup("SmartIncrement", { clear = true }),
		desc = "Auto-reset smart-increment when tracked register content changes",
		callback = function()
			if not state then
				return
			end
			-- v:event gives us the register that was just written to.
			local event = vim.v.event
			if event.regname == config.register or (event.regname == "" and config.register == '"') then
				-- The user yanked new content — reset so next <leader>a re-prompts.
				state = nil
			end
		end,
	})
end

return M
