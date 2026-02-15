--- lg semantic search via lg-index API
local M = {}

local config = {
	api_url = "http://192.168.21.58:8081",
	repo = nil, -- auto-detect from git remote
	branch = nil, -- auto-detect from git
}

function M.setup(opts)
	config = vim.tbl_deep_extend("force", config, opts or {})
end

local function detect_repo()
	if config.repo then return config.repo end
	local out = vim.fn.system("git remote get-url origin 2>/dev/null")
	local name = out:match("/([%w%.%-_]+)%.git") or out:match("/([%w%.%-_]+)%s*$")
	return name
end

local function detect_branch()
	if config.branch then return config.branch end
	local out = vim.fn.system("git branch --show-current 2>/dev/null")
	return vim.trim(out)
end

function M.find(query)
	if not query or query == "" then
		vim.ui.input({ prompt = "lg-find: " }, function(input)
			if input and input ~= "" then M.find(input) end
		end)
		return
	end

	local repo = detect_repo()
	local branch = detect_branch()
	if not repo or repo == "" then
		vim.notify("lg-find: can't detect repo", vim.log.levels.ERROR)
		return
	end

	local body = vim.json.encode({ repo = repo, branch = branch, query = query, top_n = 10 })
	local cmd = string.format("curl -s %s/find -d '%s'", config.api_url, body)

	vim.system({ "sh", "-c", cmd }, {}, vim.schedule_wrap(function(obj)
		if obj.code ~= 0 then
			vim.notify("lg-find: request failed", vim.log.levels.ERROR)
			return
		end

		local ok, results = pcall(vim.json.decode, obj.stdout)
		if not ok or not results or #results == 0 then
			if obj.stdout and obj.stdout:match("indexing in progress") then
				vim.notify("lg-find: indexing in progress, try again shortly", vim.log.levels.INFO)
			else
				vim.notify("lg-find: no results", vim.log.levels.WARN)
			end
			return
		end

		local fzf = require("fzf-lua")
		local entries = {}
		for _, r in ipairs(results) do
			table.insert(entries, string.format("%.2f  %s:%d-%d", r.score, r.file, r.start_line, r.end_line))
		end

		fzf.fzf_exec(entries, {
			prompt = "lg-find❯ ",
			actions = {
				["default"] = function(selected)
					local entry = selected[1]
					local file, line = entry:match("%S+%s+(%S+):(%d+)")
					if file and line then
						vim.cmd("edit " .. file)
						vim.api.nvim_win_set_cursor(0, { tonumber(line), 0 })
					end
				end,
				["ctrl-p"] = function(selected)
					local context = require("lg.context")
					for _, entry in ipairs(selected) do
						local file, start_l, end_l = entry:match("%S+%s+(%S+):(%d+)-(%d+)")
						if file then
							vim.cmd("edit " .. file)
							local buf = vim.api.nvim_get_current_buf()
							context.add(buf, tonumber(start_l), tonumber(end_l))
						end
					end
					require("lg.window").refresh()
					vim.notify("lg-find: painted " .. #selected .. " regions as context")
				end,
			},
			fzf_opts = { ["--multi"] = "" },
		})
	end))
end

function M.register()
	local remote = vim.fn.system("git remote get-url origin 2>/dev/null")
	remote = vim.trim(remote)
	if remote == "" then
		vim.notify("lg-find: not a git repo", vim.log.levels.ERROR)
		return
	end
	local repo = detect_repo()
	local body = vim.json.encode({ name = repo, git_url = remote })
	local cmd = string.format("curl -s %s/repos -d '%s'", config.api_url, body)

	vim.system({ "sh", "-c", cmd }, {}, vim.schedule_wrap(function(obj)
		if obj.code ~= 0 then
			vim.notify("lg-find: register failed", vim.log.levels.ERROR)
			return
		end
		vim.notify("lg-find: registered " .. repo .. " — first search will index")
	end))
end

return M
