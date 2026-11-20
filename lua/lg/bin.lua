--- Resolves the path of lg's compiled Go binary (`lg`).
---
--- The binary is gitignored, so a fresh clone of the plugin ships none. It is
--- looked up in a stable directory *outside* the plugin, which means one build
--- serves every checkout — a lazy.nvim clone and a local dev copy both find
--- the same binary:
---
---   1. `vim.g.lg_bin_dir` / `$LG_BIN_DIR`  — explicit override
---   2. `stdpath("data")/lg/bin/lg`         — where build.sh installs it
---   3. `<plugin root>/lg`                  — in-tree build (dev checkout)
---
--- Build it with `:LgBuild`, or `./build.sh` from the plugin directory.

local M = {}

--- All binary names built by build.sh.
M.names = { "lg" }

--- Plugin root, derived from this file's location (lua/lg/bin.lua -> ../../..).
M.root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")

--- Directory the binary is installed to. Kept in sync with build.sh.
--- @return string
function M.dir()
	return vim.g.lg_bin_dir or vim.env.LG_BIN_DIR or (vim.fn.stdpath("data") .. "/lg/bin")
end

--- Every path the binary may live at, in resolution order.
--- @param name? string defaults to "lg"
--- @return string[]
function M.candidates(name)
	name = name or "lg"
	return {
		M.dir() .. "/" .. name,
		M.root .. "/" .. name,
	}
end

--- Resolve the binary, or nil when it has not been built.
--- @param name? string defaults to "lg"
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

--- Resolve the binary, warning once (per session) with a fix when it is absent.
--- @param name? string defaults to "lg"
--- @return string? path
function M.require(name)
	name = name or "lg"
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
		vim.notify("lg: Go is required to build the binary (https://go.dev/dl)", vim.log.levels.ERROR)
		if on_done then
			on_done(false)
		end
		return
	end

	vim.notify("lg: building binary...", vim.log.levels.INFO)
	vim.system({ "sh", script }, { cwd = M.root, text = true }, function(res)
		vim.schedule(function()
			local ok = res.code == 0
			if ok then
				warned = {}
				vim.notify("lg: binary built into " .. M.dir(), vim.log.levels.INFO)
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
