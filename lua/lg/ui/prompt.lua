--- Prompt: floating input buffer for multi-line prompts

local M = {}

--- @class PromptFlags
--- @field has_file_lsp boolean
--- @field has_lsp boolean
--- @field has_tsc boolean
--- @field has_diag boolean
--- @field has_auto_paint boolean
--- @field has_git boolean
--- @field has_devlens boolean
--- @field has_hint boolean
--- @field has_annotate boolean
--- @field has_sub boolean
--- @field has_suggest boolean
--- @field has_ask boolean

local function title(info, img_count)
	local img_part = (img_count and img_count > 0)
			and ("│ " .. img_count .. (img_count == 1 and " img " or " imgs "))
		or ""
	return " lg prompt (ctrl-s send, ctrl-v img, q/esc cancel) "
		.. img_part
		.. (info and ("│ " .. info .. " ") or "")
end

local _win_meta = {}

--- Update the status shown after the title of an open prompt window
--- @param win integer
--- @param info string
function M.set_info(win, info)
	if vim.api.nvim_win_is_valid(win) then
		local meta = _win_meta[win]
		if meta then
			meta.info = info
		end
		vim.api.nvim_win_set_config(win, { title = title(info, meta and meta.img_count or 0), title_pos = "center" })
	end
end

--- Open a floating buffer for prompt input, call cb(text, flags) on submit
--- @param cb fun(text: string, flags: PromptFlags)
--- @param on_cancel? fun()
--- @param info? string extra status shown after the title (e.g. mode, provider/model)
--- @return integer win
function M.open(cb, on_cancel, info)
	local ctx_pct = require("lg.ui.window").get_context_pct()
	if ctx_pct then require("lg.kitty").set(ctx_pct) end
	local ui = vim.api.nvim_list_uis()[1]
	local width = math.floor(ui.width * 0.6)
	local height = 8

	local context = require("lg.tools.context")
	local pasted_images = {}
	local function total_images()
		return #context.get_images() + #pasted_images
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].filetype = "markdown"
	vim.diagnostic.enable(false, { bufnr = buf })

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((ui.height - height) / 2),
		col = math.floor((ui.width - width) / 2),
		style = "minimal",
		border = "rounded",
		title = title(info, total_images()),
		title_pos = "center",
	})
	_win_meta[win] = { info = info, img_count = total_images() }

	local function refresh_title()
		local meta = _win_meta[win]
		if meta and vim.api.nvim_win_is_valid(win) then
			meta.img_count = total_images()
			vim.api.nvim_win_set_config(win, { title = title(meta.info, meta.img_count), title_pos = "center" })
		end
	end

	local function paste_image(fallback_text)
		local image = require("lg.tools.image")
		local img, err = image.read_clipboard()
		if img then
			for _, list in ipairs({ context.get_images(), pasted_images }) do
				for _, existing in ipairs(list) do
					if existing.data == img.data and existing.mime_type == img.mime_type then
						vim.notify("lg: image already attached", vim.log.levels.INFO)
						return
					end
				end
			end
			table.insert(pasted_images, img)
			refresh_title()
			vim.notify(
				string.format("lg: attached image #%d (%s)", total_images(), image.format_size(img.size)),
				vim.log.levels.INFO
			)
			return
		end
		if fallback_text then
			local text = vim.fn.getreg("+")
			if text ~= "" then
				vim.api.nvim_paste(text, false, -1)
				return
			end
		end
		vim.notify("lg: " .. (err or "no image in clipboard"), vim.log.levels.WARN)
	end

	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true
	vim.cmd("startinsert")

	local function submit()
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local text = vim.trim(table.concat(lines, "\n"))
		local n_imgs = total_images()
		vim.cmd("stopinsert")
		_win_meta[win] = nil
		vim.api.nvim_win_close(win, true)
		vim.api.nvim_buf_delete(buf, { force = true })
		require("lg.kitty").clear()
		if text ~= "" or n_imgs > 0 then
			for _, img in ipairs(pasted_images) do
				context.add_image(img)
			end
			if text == "" then
				text = "See attached image(s)."
			end
			cb(text, {
				has_file_lsp = text:match("#file_lsp") ~= nil,
				has_lsp = text:match("#lsp") ~= nil and not text:match("#file_lsp"),
				has_tsc = text:match("@TSC") ~= nil,
				has_diag = text:match("@DIAG") ~= nil,
				has_auto_paint = text:match("@INFO") ~= nil,
				has_git = text:match("@GIT") ~= nil,
				has_devlens = text:match("@DEVLENS") ~= nil,
				has_hint = text:match("@REVIEW") ~= nil,
				has_annotate = text:match("@ANNOTATE") ~= nil,
				has_sub = text:match("@SUB") ~= nil,
				has_suggest = text:match("@SUGGEST") ~= nil,
				has_help = text:match("@HELP") ~= nil,
				has_ask = text:match("@ASK") ~= nil,
			})
		end
	end

	local function cancel()
		_win_meta[win] = nil
		vim.api.nvim_win_close(win, true)
		vim.api.nvim_buf_delete(buf, { force = true })
		require("lg.kitty").clear()
		if on_cancel then
			on_cancel()
		end
	end

	vim.keymap.set("n", "q", cancel, { buffer = buf })
	vim.keymap.set("n", "<Esc>", cancel, { buffer = buf })
	vim.keymap.set("n", "<CR>", submit, { buffer = buf })
	vim.keymap.set({ "n", "i" }, "<C-s>", submit, { buffer = buf })
	vim.keymap.set("i", "<C-v>", function() paste_image(true) end, { buffer = buf, desc = "Paste clipboard image (or text)" })
	vim.keymap.set({ "n", "i" }, "<M-v>", function() paste_image(false) end, { buffer = buf, desc = "Paste clipboard image" })
	return win
end

return M
