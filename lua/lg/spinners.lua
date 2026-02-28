--- Spinners: manage loading indicators on painted regions

local M = {}

local config = { spinner_type = "hint" }

function M.setup(opts)
	config.spinner_type = opts.spinner_type or "hint"
end

--- Start spinners for regions, return a handle with :stop()
--- @param regions table[]
--- @return { stop: fun() }
function M.start(regions)
	local mod = config.spinner_type == "block" and "lg.block-spinner"
		or config.spinner_type == "center" and "lg.spinner"
		or config.spinner_type == "wave" and "lg.wave-spinner"
		or "lg.hint-spinner"
	local Spinner = require(mod)
	local instances = {}
	for _, r in ipairs(regions) do
		local ns = vim.api.nvim_create_namespace("lg_spinner_" .. r.bufnr .. "_" .. r.start_line)
		local spinner = Spinner.new({
			bufnr = r.bufnr,
			ns_id = ns,
			line_num = r.start_line,
			start_line = r.start_line,
			end_line = r.end_line,
		})
		if spinner then
			spinner:start()
			table.insert(instances, spinner)
		end
	end
	return {
		stop = function()
			for _, s in ipairs(instances) do s:stop() end
			instances = {}
		end,
	}
end

--- Legacy: stop all (noop now, use handle:stop())
function M.stop() end

return M
