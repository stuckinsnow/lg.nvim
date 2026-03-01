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
	if config.repo then
		return config.repo
	end
	local out = vim.fn.system("git remote get-url origin 2>/dev/null")
	local name = out:match("/([%w%.%-_]+)%.git") or out:match("/([%w%.%-_]+)%s*$")
	return name
end

local function detect_branch()
	if config.branch then
		return config.branch
	end
	local out = vim.fn.system("git branch --show-current 2>/dev/null")
	return vim.trim(out)
end

local function curl_json(path, body, cb)
	local cmd = string.format("curl -s %s%s -d '%s'", config.api_url, path, vim.json.encode(body))
	vim.system(
		{ "sh", "-c", cmd },
		{},
		vim.schedule_wrap(function(obj)
			if obj.code ~= 0 then
				cb(nil)
				return
			end
			local ok, data = pcall(vim.json.decode, obj.stdout)
			if ok then
				cb(data)
			else
				cb(nil)
			end
		end)
	)
end

local function detect_head(branch)
	local out = vim.fn.system("git rev-parse origin/" .. branch .. " 2>/dev/null")
	return vim.trim(out)
end

function M.find(query)
	if not query or query == "" then
		vim.ui.input({ prompt = "lg-find: " }, function(input)
			if input and input ~= "" then
				M.find(input)
			end
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
			local msg = "Indexing in progress"
			if st.progress and st.total then
				msg = string.format("Indexing: %d/%d chunks", st.progress, st.total)
			end
			if not st.indexed then
				status.stop(msg)
				return
			end
			status.flash(msg)
		end
		if not st.indexed then
			curl_json("/find", { repo = repo, branch = branch, query = query, top_n = 1 }, function() end)
			status.stop("Indexing started — try again shortly")
			return
		end

		status.update("Searching: " .. query)

		curl_json("/find", { repo = repo, branch = branch, query = query, top_n = 10, head = detect_head(branch) }, function(results)
			if not results or #results == 0 then
				status.stop("No results")
				return
			end

			status.stop("Found " .. #results .. " results")

			local fzf = require("fzf-lua")
			local entries = {}
			local root = vim.fn.systemlist("git rev-parse --show-toplevel")[1] or "."
			local result_map = {}
			local function strip_ansi(s) return s:gsub("\27%[[%d;]*m", "") end
			for _, r in ipairs(results) do
				local dir = vim.fn.fnamemodify(r.file, ":h")
				local fname = vim.fn.fnamemodify(r.file, ":t")
				local entry = string.format(
					"\27[32m%.2f\27[0m  \27[1m%s\27[0m \27[90m%s\27[0m  \27[35m:%d\27[0m\t%s/%s\t%d",
					r.score, fname, dir, r.start_line, root, r.file, r.start_line
				)
				table.insert(entries, entry)
				result_map[strip_ansi(entry)] = r
			end

			fzf.fzf_exec(entries, {
				prompt = "lg-find❯ ",
				winopts = { height = 0.6, width = 0.6 },
				preview = "bat --color=always --style=numbers --highlight-line={-1} {-2}",
				fzf_opts = {
					["--ansi"] = "",
					["--multi"] = "",
					["--delimiter"] = "\t",
					["--with-nth"] = "1",
					["--preview-window"] = "right:50%:wrap:+{-1}-10",
					["--header"] = ":: tab=select | ctrl-p=add as context | enter=open file",
				},
				actions = {
					["default"] = function(selected)
						if not selected or #selected == 0 then return end
						for i, entry in ipairs(selected) do
							local r = result_map[strip_ansi(entry)]
							if r then
								local path = root .. "/" .. r.file
								if i == 1 then
									vim.cmd("edit +" .. r.start_line .. " " .. path)
								else
									vim.cmd("badd +" .. r.start_line .. " " .. path)
								end
							end
						end
					end,
					["ctrl-p"] = function(selected)
						local context = require("lg.tools.context")
						local sel_results = {}
						for _, entry in ipairs(selected) do
							local r = result_map[strip_ansi(entry)]
							if r then table.insert(sel_results, r) end
						end
						context.add_search(query, sel_results)
						require("lg.ui.window").refresh()
						vim.notify(string.format("lg-find: added %d results as context", #sel_results))
					end,
				},
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
