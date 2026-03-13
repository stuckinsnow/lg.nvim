--- Smart paint: treesitter-aware region selection via FZF picker

local M = {}

local node_labels = {
	function_declaration = "function",
	function_definition = "function",
	method_declaration = "method",
	method_definition = "method",
	arrow_function = "arrow function",
	function_item = "function",
	class_declaration = "class",
	class_definition = "class",
	struct_item = "struct",
	interface_declaration = "interface",
	type_alias_declaration = "type alias",
	if_statement = "if",
	if_expression = "if",
	for_statement = "for loop",
	for_expression = "for loop",
	while_statement = "while loop",
	do_statement = "do block",
	switch_statement = "switch",
	match_expression = "match",
	impl_item = "impl block",
	export_statement = "export",
}

local function collect_ancestors()
	local buf = vim.api.nvim_get_current_buf()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local row, col = cursor[1] - 1, cursor[2]

	local ok, parser = pcall(vim.treesitter.get_parser, buf)
	if not ok or not parser then return nil end

	local tree = parser:parse()[1]
	if not tree then return nil end

	local node = tree:root():descendant_for_range(row, col, row, col)
	if not node then return nil end

	local seen = {}
	local results = {}
	local cur = node

	while cur do
		local label = node_labels[cur:type()]
		if label and not seen[label] then
			local sr, _, er, _ = cur:range()
			seen[label] = true
			table.insert(results, { label = label, start_line = sr + 1, end_line = er + 1 })
		end
		cur = cur:parent()
	end

	local max = vim.api.nvim_buf_line_count(buf)
	if not seen["file"] then
		table.insert(results, { label = "entire file", start_line = 1, end_line = max })
	end

	return results
end

function M.pick()
	local nodes = collect_ancestors()
	if not nodes or #nodes == 0 then
		vim.notify("lg: no treesitter nodes at cursor", vim.log.levels.WARN)
		return
	end

	local icons = {
		["function"] = "󰊕", method = "󰊕", ["arrow function"] = "󰘧",
		class = "󰠱", struct = "", interface = "",
		["type alias"] = "", ["impl block"] = "",
		["if"] = "󰘬", ["for loop"] = "󰑖", ["while loop"] = "󰑖",
		["do block"] = "󰑖", switch = "󰘬", match = "󰘬",
		export = "󰈇", ["entire file"] = "󰈔",
	}

	local entries = {}
	for _, n in ipairs(nodes) do
		local icon = icons[n.label] or "●"
		local lines = n.end_line - n.start_line + 1
		table.insert(entries, string.format("%s  %-18s  %d lines  (%d-%d)", icon, n.label, lines, n.start_line, n.end_line))
	end

	local file = vim.api.nvim_buf_get_name(0)
	local fname = vim.fn.fnamemodify(file, ":t")

	local preview_cmd = string.format(
		"RANGE=$(echo {} | grep -oP '\\(\\K[0-9]+-[0-9]+') && S=${RANGE%%-*} && E=${RANGE##*-} && bat --color=always --line-range=$S:$E --style=numbers %s",
		vim.fn.shellescape(file)
	)

	require("fzf-lua").fzf_exec(entries, {
		prompt = "  ",
		winopts = {
			title = " 󱉫 Smart Paint · " .. fname .. " ",
			title_pos = "center",
			height = 0.6,
			width = 0.7,
			preview = { layout = "horizontal", horizontal = "right:55%" },
		},
		fzf_opts = {
			["--header"] = ":: ENTER=paint :: ctrl-p=context paint ::",
			["--preview"] = preview_cmd,
		},
		actions = {
			["default"] = function(selected)
				if not selected or #selected == 0 then return end
				for i, e in ipairs(entries) do
					if e == selected[1] then
						local n = nodes[i]
						local buf = vim.api.nvim_get_current_buf()
						require("lg.ui.paint").add(buf, n.start_line, n.end_line)
						pcall(function() require("lg.ui.window").refresh() end)
						return
					end
				end
			end,
			["ctrl-p"] = function(selected)
				if not selected or #selected == 0 then return end
				for i, e in ipairs(entries) do
					if e == selected[1] then
						local n = nodes[i]
						local buf = vim.api.nvim_get_current_buf()
						require("lg.tools.context").add(buf, n.start_line, n.end_line)
						pcall(function() require("lg.ui.window").refresh() end)
						return
					end
				end
			end,
		},
	})
end

return M
