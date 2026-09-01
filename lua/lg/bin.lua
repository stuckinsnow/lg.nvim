--- Resolves the paths of lg's compiled Go binaries.
---
--- The binaries are gitignored, so a fresh clone of the plugin ships none of
--- them. They are looked up in a stable directory *outside* the plugin, which
--- means one build serves every checkout — a lazy.nvim clone and a local dev
--- copy both find the same binaries:
---
---   1. `vim.g.lg_bin_dir` / `$LG_BIN_DIR`  — explicit override
---   2. `stdpath("data")/lg/bin`            — where build.sh installs them
---   3. `<plugin root>/<subdir>/<name>`     — in-tree build (dev checkout)
---
--- Build them with `:LgBuild`, or `./build.sh` from the plugin directory.

local M = {}

--- Binary name -> module subdirectory it is built in.
--- The subdirectory is only needed for the in-tree fallback.
local subdirs = {
	["lg-acp"] = "acp",
	["lg-git-mcp"] = "git-mcp",
	["lg-hint-mcp"] = "hint-mcp",
	["lg-lsp"] = "lsp",
	["lg-mcp"] = "mcp",
	["lg-tap"] = "tap",
}

--- All binary names, in a stable order.
M.names = vim.tbl_keys(subdirs)
table.sort(M.names)

--- Plugin root, derived from this file's location (lua/lg/bin.lua -> ../../..).
M.root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")

--- Directory the binaries are installed to. Kept in sync with build.sh.
--- @return string
function M.dir()
	return vim.g.lg_bin_dir or vim.env.LG_BIN_DIR or (vim.fn.stdpath("data") .. "/lg/bin")
end

--- Every path a binary may live at, in resolution order.
--- @param name string
--- @return string[]
function M.candidates(name)
	local paths = { M.dir() .. "/" .. name }
	local sub = subdirs[name]
	if sub then
		table.insert(paths, M.root .. "/" .. sub .. "/" .. name)
	end
	return paths
end

--- Resolve a binary, or nil when it has not been built.
--- @param name string
--- @return string? path
function M.find(name)
	for _, path in ipairs(M.candidates(name)) do
		if vim.fn.executable(path) == 1 then
			return path
		end
	end
	return nil
end

--- Binaries that could not be found.
--- @return string[]
function M.missing()
	return vim.tbl_filter(function(name)
		return M.find(name) == nil
	end, M.names)
end

local warned = {}

--- Resolve a binary, warning once (per session) with a fix when it is absent.
--- @param name string
--- @return string? path
function M.require(name)
	local path = M.find(name)
	if path then
		return path
	end
	if not warned[name] then
		warned[name] = true
		vim.notify(
			("lg: %s is not built — run :LgBuild (needs Go), then restart"):format(name),
			vim.log.levels.ERROR
		)
	end
	return nil
end

--- Run build.sh asynchronously. Used by :LgBuild.
--- @param on_done? fun(ok: boolean)
function M.build(on_done)
	local script = M.root .. "/build.sh"
	if vim.fn.filereadable(script) == 0 then
		vim.notify("lg: build.sh not found in " .. M.root, vim.log.levels.ERROR)
		if on_done then
			on_done(false)
		end
		return
	end
	if vim.fn.executable("go") == 0 then
		vim.notify("lg: Go is required to build the binaries (https://go.dev/dl)", vim.log.levels.ERROR)
		if on_done then
			on_done(false)
		end
		return
	end

	vim.notify("lg: building binaries...", vim.log.levels.INFO)
	vim.system({ "sh", script }, { cwd = M.root, text = true }, function(res)
		vim.schedule(function()
			local ok = res.code == 0
			if ok then
				warned = {}
				vim.notify("lg: binaries built into " .. M.dir(), vim.log.levels.INFO)
			else
				local err = vim.trim((res.stderr or "") .. "\n" .. (res.stdout or ""))
				vim.notify("lg: build failed\n" .. err, vim.log.levels.ERROR)
			end
			if on_done then
				on_done(ok)
			end
		end)
	end)
end

return M
