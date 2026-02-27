--- Search: ripgrep via fzf-lua grep → multi-select → add as context

local context = require("lg.context")

local M = {}

local CONTEXT_LINES = 0

function M.open()
	vim.ui.input({ prompt = "rg pattern: " }, function(pattern)
		if not pattern or pattern == "" then
			return
		end

		require("fzf-lua").grep({
			search = pattern,
			no_esc = true,
			prompt = "Add as context (tab=multi): ",
			winopts = { height = 0.6, width = 0.6 },
			fzf_opts = { ["--multi"] = "" },
			actions = {
				["default"] = function(selected)
					local added = 0
					for _, sel in ipairs(selected) do
						local entry = require("fzf-lua").path.entry_to_file(sel)
						if entry and entry.path and entry.line then
							local abs = vim.fn.fnamemodify(entry.path, ":p")
							local bufnr = vim.fn.bufadd(abs)
							vim.fn.bufload(bufnr)
							local total = vim.api.nvim_buf_line_count(bufnr)
							local first = math.max(1, entry.line - CONTEXT_LINES)
							local last = math.min(total, entry.line + CONTEXT_LINES)
							context.add(bufnr, first, last, pattern)
							added = added + 1
						end
					end
					vim.schedule(function()
						require("lg.window").refresh()
						vim.notify(string.format("lg: added %d context region(s) for '%s'", added, pattern))
					end)
				end,
			},
		})
	end)
end

return M
