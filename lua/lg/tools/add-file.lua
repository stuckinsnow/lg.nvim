--- Attach a file as context: direct path, or pick via input / mini.files / fzf

local context = require("lg.tools.context")
local window = require("lg.ui.window")

local M = {}

function M.open(path)
	if path and path ~= "" then
		context.add_file(path)
		window.refresh()
		return
	end
	local actions = {
		{
			label = "Paste path",
			fn = function()
				vim.ui.input({ prompt = "File path: ", completion = "file" }, function(p)
					if p and p ~= "" then
						context.add_file(p)
						window.refresh()
					end
				end)
			end,
		},
		{
			label = "Browse filesystem (mini.files)",
			fn = function()
				local mf = require("mini.files")
				mf.open("/", false)
				local group = vim.api.nvim_create_augroup("lg_minifiles_attach", { clear = true })
				vim.api.nvim_create_autocmd("User", {
					group = group,
					pattern = "MiniFilesBufferCreate",
					callback = function(ev)
						vim.keymap.set("n", "<CR>", function()
							local entry = mf.get_fs_entry()
							if not entry then
								return
							end
							if entry.fs_type == "directory" then
								mf.go_in()
								return
							end
							context.add_file(entry.path)
							window.refresh()
							mf.close()
							vim.notify("lg: attached " .. vim.fn.fnamemodify(entry.path, ":t"), vim.log.levels.INFO)
						end, { buffer = ev.data.buf_id, desc = "Attach file" })
					end,
				})
				vim.api.nvim_create_autocmd("User", {
					group = group,
					pattern = "MiniFilesExplorerClose",
					once = true,
					callback = function()
						vim.api.nvim_del_augroup_by_name("lg_minifiles_attach")
					end,
				})
			end,
		},
		{
			label = "Project files (fzf)",
			fn = function()
				require("fzf-lua").files({
					prompt = "Attach> ",
					winopts = { title = " Attach File ", title_pos = "center", height = 0.5, width = 0.6 },
					actions = {
						["default"] = function(selected)
							if not selected or #selected == 0 then
								return
							end
							for _, entry in ipairs(selected) do
								local file = require("fzf-lua").path.entry_to_file(entry).path
								if file then
									context.add_file(file)
								end
							end
							window.refresh()
						end,
					},
				})
			end,
		},
	}
	vim.ui.select(
		vim.tbl_map(function(a)
			return a.label
		end, actions),
		{ prompt = "Attach file:" },
		function(_, idx)
			if idx then
				actions[idx].fn()
			end
		end
	)
end

return M
