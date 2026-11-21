--- Protocol: builds ACP prompt messages from painted regions

local M = {}

local function append_images(parts)
	local images = require("lg.tools.context").take_images()
	if #images == 0 then
		return
	end
	for _, img in ipairs(images) do
		table.insert(parts, {
			type = "image",
			mimeType = img.mime_type,
			data = img.data,
		})
	end
	local ok, win = pcall(require, "lg.ui.window")
	if ok and win.refresh then
		vim.schedule(win.refresh)
	end
end

--- Build the prompt content array for session/prompt
--- @param regions table[] editable regions from paint.get_all()
--- @param context_regions table[] read-only regions from context.get_all()
--- @param user_prompt string
--- @param lsp_context? string
--- @param tsc_context? string
--- @param edit_token? string
--- @return table[] ACP prompt content blocks
function M.build_prompt(regions, context_regions, user_prompt, lsp_context, tsc_context, edit_token, opts)
	local parts = {}
	opts = opts or {}

	-- Scoped context (for hint/suggest — regions the AI should focus on)
	if opts.scope and #context_regions > 0 then
		local ctx = { "### Painted regions (focus your " .. opts.scope .. " ONLY on these regions):\n" }
		for i, r in ipairs(context_regions) do
			local fname = r.file ~= "" and vim.fn.fnamemodify(r.file, ":~:.") or "[unnamed]"
			table.insert(
				ctx,
				string.format(
					"Region %d — %s lines %d–%d:\n```\n%s\n```",
					i - 1,
					fname,
					r.start_line,
					r.end_line,
					table.concat(r.lines, "\n")
				)
			)
		end
		table.insert(parts, { type = "text", text = table.concat(ctx, "\n") })
		-- User message
		table.insert(parts, { type = "text", text = user_prompt })
		append_images(parts)
		return parts
	end

	-- Editable regions
	if #regions > 0 then
		local max_id = #regions - 1
		local header = "You have "
			.. #regions
			.. " painted region(s) (region_id 0"
			.. (max_id > 0 and ("–" .. max_id) or "")
			.. "). Edit ONLY these regions. Do NOT edit any other regions. The full code of each region is shown below — call paint_edit directly with ALL edits in one call unless you actually need to read surrounding context first."
		if edit_token then
			header = header
				.. "\n\nEdit token: `"
				.. edit_token
				.. "` — pass this as edit_token in every paint_edit and get_painted_regions call."
		end
		local ctx = { header .. "\n" }
		for i, r in ipairs(regions) do
			local fname = r.file ~= "" and vim.fn.fnamemodify(r.file, ":~:.") or "[unnamed]"
			table.insert(
				ctx,
				string.format(
					"Region %d — %s lines %d–%d:\n```\n%s\n```",
					i - 1,
					fname,
					r.start_line,
					r.end_line,
					table.concat(r.lines, "\n")
				)
			)
		end
		table.insert(parts, { type = "text", text = table.concat(ctx, "\n") })
	end

	-- Read-only context
	if #context_regions > 0 then
		local ctx = { "### Context (read-only reference, do NOT edit these):\n" }
		for i, r in ipairs(context_regions) do
			local fname = r.file ~= "" and vim.fn.fnamemodify(r.file, ":~:.") or "[unnamed]"
			table.insert(
				ctx,
				string.format(
					"Context %d — %s lines %d–%d:\n```\n%s\n```",
					i - 1,
					fname,
					r.start_line,
					r.end_line,
					table.concat(r.lines, "\n")
				)
			)
		end
		table.insert(parts, { type = "text", text = table.concat(ctx, "\n") })
	end

	-- File context
	local files = require("lg.tools.context").get_files()
	if #files > 0 then
		local ctx = { "### Files (read these for additional context):\n" }
		for _, f in ipairs(files) do
			table.insert(ctx, f)
		end
		table.insert(parts, { type = "text", text = table.concat(ctx, "\n") })
	end

	-- LSP diagnostics context
	if lsp_context then
		table.insert(parts, { type = "text", text = "### LSP diagnostics (from open buffers):\n" .. lsp_context })
	end

	-- TSC output
	if tsc_context then
		table.insert(
			parts,
			{
				type = "text",
				text = "### tsc --noEmit output (project-wide type errors):\n```\n" .. tsc_context .. "```",
			}
		)
	end

	-- User message
	table.insert(parts, { type = "text", text = user_prompt })
	append_images(parts)

	return parts
end

return M
