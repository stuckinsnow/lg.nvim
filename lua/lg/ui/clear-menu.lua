--- fzf menu for clearing paint, context, marks, hints and session state

local M = {}

function M.open()
	local lg = require("lg")
	local actions = {
		{
			icon = "󰏝",
			label = "Paint regions",
			fn = function()
				lg.clear()
			end,
		},
		{
			icon = "󰗅",
			label = "Context regions",
			fn = function()
				lg.clear_context()
			end,
		},
		{
			icon = "󰕍",
			label = "Last paint",
			fn = function()
				lg.clear_last()
			end,
		},
		{
			icon = "󰈮",
			label = "Edit markers",
			fn = function()
				lg.clear_marks()
			end,
		},
		{
			icon = "󰌪",
			label = "Info paint",
			fn = function()
				lg.clear_info_paint()
			end,
		},
		{
			icon = "󱃓",
			label = "AI hints",
			fn = function()
				lg.clear_hints()
			end,
		},
		{
			icon = "󰚃",
			label = "Session (full reset)",
			fn = function()
				lg.clear_session()
			end,
		},
		{
			icon = "󰈈",
			label = "Follow highlights",
			fn = function()
				local ns = vim.api.nvim_create_namespace("lg_follow_read")
				for _, buf in ipairs(vim.api.nvim_list_bufs()) do
					if vim.api.nvim_buf_is_valid(buf) then
						vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
					end
				end
			end,
		},
		{
			icon = "󰗩",
			label = "Everything",
			fn = function()
				lg.clear_session()
			end,
		},
	}

	local entries = {}
	for _, a in ipairs(actions) do
		table.insert(entries, a.icon .. "  " .. a.label)
	end

	require("fzf-lua").fzf_exec(entries, {
		prompt = "  ",
		winopts = {
			title = " 󰃢 Clear ",
			title_pos = "center",
			height = 0.35,
			width = 0.35,
		},
		actions = {
			["default"] = function(selected)
				if not selected or #selected == 0 then
					return
				end
				for i, e in ipairs(entries) do
					if e == selected[1] then
						actions[i].fn()
						return
					end
				end
			end,
		},
	})
end

return M
