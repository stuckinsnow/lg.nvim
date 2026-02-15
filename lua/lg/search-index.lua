--- lg semantic search via lg-index API
local M = {}
local status = require("lg.status")

local config = {
	api_url = "http://192.168.21.58:8081",
	repo = nil,
	branch = nil,
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

local function curl_json(path, body, cb)
	local cmd = string.format("curl -s %s%s -d '%s'", config.api_url, path, vim.json.encode(body))
	vim.system({ "sh", "-c", cmd }, {}, vim.schedule_wrap(function(obj)
		if obj.code ~= 0 then cb(nil) return end
		local ok, data = pcall(vim.json.decode, obj.stdout)
		if ok then cb(data) else cb(nil) end
	end))
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

	status.start("Checking index…")

	curl_json("/status", { repo = repo, branch = branch }, function(st)
		if not st then
			status.stop("Can't reach indexer")
			return
		end
		if st.indexing then
			status.stop("Indexing in progress, try again shortly")
			return
		end
		if not st.indexed then
			status.stop("Not indexed — register with <leader>aR first")
			return
		end

		status.update("Searching: " .. query)

		curl_json("/find", { repo = repo, branch = branch, query = query, top_n = 10 }, function(results)
			if not results or #results == 0 then
				status.stop("No results")
				return
			end

			status.stop("Found " .. #results .. " results")

			-- store results for preview/context
			local result_map = {}
			local fzf = require("fzf-lua")
			local entries = {}
			for _, r in ipairs(results) do
				local key = string.format("%.2f  %s:%d-%d", r.score, r.file, r.start_line, r.end_line)
				table.insert(entries, key)
				result_map[key] = r
			end

			fzf.fzf_exec(entries, {
				prompt = "lg-find❯ ",
				winopts = { height = 0.4, width = 0.6 },
				previewer = false,
				preview = {
					type = "cmd",
					fn = function(items)
						local r = result_map[items[1]]
						if r and r.content then
							return string.format("echo %s", vim.fn.shellescape(r.content))
						end
						return "echo 'no preview'"
					end,
				},
				actions = {
					["default"] = function(selected)
						local file, line = selected[1]:match("%S+%s+(%S+):(%d+)")
						if file and line then
							vim.cmd("edit " .. file)
							vim.api.nvim_win_set_cursor(0, { tonumber(line), 0 })
						end
					end,
					["ctrl-p"] = function(selected)
						local paint = require("lg.paint")
						local count = 0
						for _, entry in ipairs(selected) do
							local file, start_l, end_l = entry:match("%S+%s+(%S+):(%d+)-(%d+)")
							if file then
								vim.cmd("edit " .. file)
								local buf = vim.api.nvim_get_current_buf()
								paint.mark(buf, tonumber(start_l), tonumber(end_l))
								count = count + 1
							end
						end
						require("lg.window").refresh()
						vim.notify(string.format("lg-find: painted %d regions", count))
					end,
				},
				fzf_opts = { ["--multi"] = "" },
			})
		end)
	end)
end

function M.register()
	local remote = vim.fn.system("git remote get-url origin 2>/dev/null")
	remote = vim.trim(remote)
	if remote == "" then
		vim.notify("lg-find: not a git repo", vim.log.levels.ERROR)
		return
	end
	local repo = detect_repo()
	status.start("Registering " .. repo)
	curl_json("/repos", { name = repo, git_url = remote }, function(data)
		if not data then
			status.stop("Register failed")
			return
		end
		status.stop("Registered " .. repo)
	end)
end

return M
