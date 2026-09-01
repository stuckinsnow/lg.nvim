--- `:checkhealth lg` — reports whether the Go binaries are available.

local bin = require("lg.bin")

local M = {}

function M.check()
	local h = vim.health
	h.start("lg")

	if vim.fn.executable("go") == 1 then
		local out = vim.system({ "go", "version" }, { text = true }):wait()
		h.ok(vim.trim(out.stdout ~= "" and out.stdout or "go found"))
	else
		h.warn("go not found", { "Only needed to build the binaries with :LgBuild" })
	end

	h.info("install dir: " .. bin.dir())
	h.info("plugin root: " .. bin.root)

	for _, name in ipairs(bin.names) do
		local path = bin.find(name)
		if path then
			h.ok(("%s -> %s"):format(name, path))
		else
			h.error(name .. " not built", {
				"Run :LgBuild",
				"Looked in: " .. table.concat(bin.candidates(name), ", "),
			})
		end
	end
end

return M
