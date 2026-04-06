local M = {}

local function get_paint() return require("lg.ui.paint") end
local function get_context() return require("lg.tools.context") end

local function get_picker_opts()
	local ok, picker = pcall(require, "gitty.providers.github-compare.picker-utils")
	if ok then
		local branch = vim.fn.system("git branch --show-current"):gsub("%s+", "")
		return picker.create_themed_git_log_cmd(branch, 50), picker.create_commit_preview_command()
	end
	return "git log --oneline -n 50",
		"HASH=$(echo {} | awk '{print $1}') && git show --color=always $HASH 2>/dev/null"
end

--- Get files touched by the given commits
local function get_changed_files(commits)
	local files = {}
	for _, hash in ipairs(commits) do
		local out = vim.fn.system({ "git", "diff-tree", "--no-commit-id", "-r", "--name-only", hash })
		for f in out:gmatch("[^\n]+") do
			files[f] = true
		end
	end
	return vim.tbl_keys(files)
end

--- Use git blame to find lines in the current file attributed to any of the given commits
local function blame_lines_for_commits(rel_path, commit_set)
	local out = vim.fn.system({ "git", "blame", "--porcelain", "--", rel_path })
	if vim.v.shell_error ~= 0 then return {} end

	local lines = {}
	for line in out:gmatch("[^\n]+") do
		-- Porcelain blame: header lines start with a 40-char hash, orig_line, final_line [, num_lines]
		local hash, lnum = line:match("^(%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x) %d+ (%d+)")
		if hash and commit_set[hash] then
			table.insert(lines, tonumber(lnum))
		end
	end

	table.sort(lines)
	return lines
end

--- Collapse consecutive line numbers into ranges
local function collapse_ranges(sorted_lines)
	if #sorted_lines == 0 then return {} end
	local ranges = {}
	local s, e = sorted_lines[1], sorted_lines[1]
	for i = 2, #sorted_lines do
		if sorted_lines[i] == e + 1 then
			e = sorted_lines[i]
		else
			table.insert(ranges, { s, e })
			s, e = sorted_lines[i], sorted_lines[i]
		end
	end
	table.insert(ranges, { s, e })
	return ranges
end

local function apply_to_hunks(commits, adder)
	-- Build a set of full commit hashes (blame outputs full hashes)
	local commit_set = {}
	for _, short in ipairs(commits) do
		local full = vim.fn.system({ "git", "rev-parse", short }):gsub("%s+", "")
		if full ~= "" then commit_set[full] = true end
	end

	local changed_files = get_changed_files(commits)
	local cwd = vim.fn.getcwd() .. "/"
	local count = 0

	for _, rel_path in ipairs(changed_files) do
		local full_path = cwd .. rel_path
		-- Only process files that still exist
		if vim.fn.filereadable(full_path) == 1 then
			local lines = blame_lines_for_commits(rel_path, commit_set)
			local ranges = collapse_ranges(lines)
			if #ranges > 0 then
				local bufnr = vim.fn.bufnr(full_path)
				if bufnr == -1 then
					bufnr = vim.fn.bufadd(full_path)
					vim.fn.bufload(bufnr)
				end
				for _, r in ipairs(ranges) do
					adder(bufnr, r[1], r[2])
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
				pcall(function() require("lg.ui.window").refresh() end)
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
				pcall(function() require("lg.ui.window").refresh() end)
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
