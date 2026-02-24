local M = {}

local function get_paint() return require("lg.paint") end
local function get_context() return require("lg.context") end

local function get_picker_opts()
	local ok, picker = pcall(require, "gitty.providers.github-compare.picker-utils")
	if ok then
		local branch = vim.fn.system("git branch --show-current"):gsub("%s+", "")
		return picker.create_themed_git_log_cmd(branch, 50), picker.create_commit_preview_command()
	end
	return "git log --oneline -n 50",
		"HASH=$(echo {} | awk '{print $1}') && git show --color=always $HASH 2>/dev/null"
end

local function apply_to_hunks(commits, adder)
	local range = #commits == 1 and (commits[1] .. "~1.." .. commits[1])
		or (commits[#commits] .. ".." .. commits[1])
	local diff = vim.fn.system("git diff " .. range .. " --unified=0")
	local cwd = vim.fn.getcwd() .. "/"
	local file, count = nil, 0

	for line in diff:gmatch("[^\n]+") do
		local f = line:match("^%+%+%+ b/(.+)")
		if f then file = cwd .. f end
		if file then
			local s, c = line:match("^@@ .+ %+(%d+),?(%d*)")
			if s then
				s, c = tonumber(s), tonumber(c) or 1
				if c > 0 and s > 0 then
					local bufnr = vim.fn.bufnr(file)
					if bufnr == -1 then
						bufnr = vim.fn.bufadd(file)
						vim.fn.bufload(bufnr)
					end
					local max = vim.api.nvim_buf_line_count(bufnr)
					local end_line = math.min(s + c - 1, max)
					s = math.min(s, max)
					adder(bufnr, s, end_line)
					count = count + 1
				end
			end
		end
	end
	return count
end

function M.pick()
	local fzf = require("fzf-lua")
	local log_cmd, preview_cmd = get_picker_opts()

	fzf.fzf_exec(log_cmd, {
		prompt = "Paint commits> ",
		fzf_args = "--multi",
		fzf_opts = {
			["--header"] = ":: ENTER=paint :: CTRL-P=context paint :: TAB=multi-select ::",
			["--preview"] = preview_cmd,
		},
		actions = {
			["default"] = function(selected)
				if not selected or #selected == 0 then return end
				local commits = {}
				for _, sel in ipairs(selected) do
					local hash = sel:match("^(%w+)")
					if hash then table.insert(commits, hash) end
				end
				if #commits == 0 then return end
				local n = apply_to_hunks(commits, function(b, s, e) get_paint().add(b, s, e) end)
				vim.notify(string.format("Painted %d hunks from %d commit(s)", n, #commits), vim.log.levels.INFO)
				pcall(function() require("lg.window").refresh() end)
			end,
			["ctrl-p"] = function(selected)
				if not selected or #selected == 0 then return end
				local commits = {}
				for _, sel in ipairs(selected) do
					local hash = sel:match("^(%w+)")
					if hash then table.insert(commits, hash) end
				end
				if #commits == 0 then return end
				local n = apply_to_hunks(commits, function(b, s, e) get_context().add(b, s, e) end)
				vim.notify(string.format("Context painted %d hunks from %d commit(s)", n, #commits), vim.log.levels.INFO)
				pcall(function() require("lg.window").refresh() end)
			end,
		},
	})
end

--- FZF picker showing all currently painted regions
function M.list_regions()
	local fzf = require("fzf-lua")
	local regions = get_paint().get_all()
	local ctx_regions = get_context().get_all()

	local entries = {}
	local cwd = vim.fn.getcwd() .. "/"
	local yellow = "\27[1;33m"
	local blue = "\27[1;36m"
	local dim = "\27[2m"
	local reset = "\27[0m"

	for _, r in ipairs(regions) do
		local path = r.file:sub(1, #cwd) == cwd and r.file:sub(#cwd + 1) or r.file
		local preview = (r.lines[1] or ""):gsub("^%s+", ""):sub(1, 60)
		table.insert(entries, string.format("%s[paint]%s %s%s%s:%d-%d  %s%s%s", yellow, reset, blue, path, reset, r.start_line, r.end_line, dim, preview, reset))
	end
	for _, r in ipairs(ctx_regions) do
		local path = r.file:sub(1, #cwd) == cwd and r.file:sub(#cwd + 1) or r.file
		local preview = (r.lines[1] or ""):gsub("^%s+", ""):sub(1, 60)
		table.insert(entries, string.format("%s[ctx]%s   %s%s%s:%d-%d  %s%s%s", blue, reset, blue, path, reset, r.start_line, r.end_line, dim, preview, reset))
	end

	if #entries == 0 then
		vim.notify("No painted regions", vim.log.levels.INFO)
		return
	end

	fzf.fzf_exec(entries, {
		prompt = "Painted regions> ",
		fzf_args = "--multi",
		winopts = { width = 0.6, height = 0.6 },
		fzf_opts = {
			["--ansi"] = "",
			["--header"] = ":: ENTER=jump to region ::",
			["--preview"] = "FILE=$(echo {} | sed 's/\\x1b\\[[0-9;]*m//g' | grep -oP '\\S+:\\d+-\\d+' | head -1) && F=${FILE%%:*} && RANGE=${FILE#*:} && S=${RANGE%-*} && E=${RANGE#*-} && bat --color=always --highlight-line=$S:$E --line-range=$((S>5?S-5:1)):$((E+5)) " .. vim.fn.getcwd() .. "/$F 2>/dev/null || echo 'No preview'",
		},
		actions = {
			["default"] = function(selected)
				if not selected or #selected == 0 then return end
				for _, sel in ipairs(selected) do
					local raw = sel:gsub("\27%[[%d;]*m", "")
					local file, line = raw:match("%s([^:]+):(%d+)")
					if file and line then
						local cur = vim.fn.getcwd() .. "/"
						local full = file:match("^/") and file or (cur .. file)
						vim.cmd("edit " .. vim.fn.fnameescape(full))
						vim.api.nvim_win_set_cursor(0, { tonumber(line), 0 })
					end
				end
			end,
		},
	})
end

return M
