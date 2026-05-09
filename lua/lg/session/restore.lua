--- Session restore: list previous sessions and reload one.

local client = require("lg.session.client")
local status = require("lg.status")

local M = {}

--- @type fun(on_ready: fun(ok: boolean))
M._ensure_acp = nil
--- @type fun(mode_id: string): string
M._resolve_mode = nil
--- @type fun(): string?  get main_session_id
M._get_sid = nil
--- @type fun(sid: string?)  set main_session_id
M._set_sid = nil
--- @type fun()  setup event handlers
M._setup_event_handlers = nil
--- @type fun()  refresh session count
M._refresh_count = nil
--- @type fun(models: table)
M._set_models = nil

-- ── Session listing ────────────────────────────────────────────────

local function list_sessions_acp(on_done)
	M._ensure_acp(function(ok)
		if not ok then
			on_done({})
			return
		end
		client.list_sessions(vim.fn.getcwd(), function(resp)
			if resp.error or not resp.data then
				on_done({})
				return
			end
			local ok2, data = pcall(vim.json.decode, type(resp.data) == "string" and resp.data or vim.json.encode(resp.data))
			if not ok2 then
				on_done({})
				return
			end
			local sessions = {}
			local list = data.sessions or data
			if type(list) ~= "table" then
				on_done({})
				return
			end
			for _, s in ipairs(list) do
				local title = s.title or ""
				if not title:match("^ACP Session ") and not title:match("^New session %- ") then
					table.insert(sessions, {
						id = s.sessionId or s.id,
						cwd = s.cwd or "",
						date = s.date or (s.updatedAt or ""):sub(1, 16):gsub("T", " "),
						title = title ~= "" and title or "(untitled)",
						preview = s.preview or "",
					})
				end
			end
			table.sort(sessions, function(a, b) return a.date > b.date end)
			on_done(sessions)
		end)
	end)
end

-- ── Picker ─────────────────────────────────────────────────────────

local function show_picker(sessions)
	if #sessions == 0 then
		vim.notify("lg: no previous sessions for this project", vim.log.levels.INFO)
		return
	end

	local entries = {}
	local has_preview = false
	local preview_dir = "/dev/shm/lg-session-preview"
	vim.fn.delete(preview_dir, "rf")
	vim.fn.mkdir(preview_dir, "p")
	for i, s in ipairs(sessions) do
		if s.preview ~= "" then has_preview = true end
		local pf = io.open(preview_dir .. "/" .. s.id, "w")
		if pf then
			pf:write(s.preview ~= "" and s.preview or s.title)
			pf:close()
		end
		entries[i] = s.id .. "\t" .. string.format("\x1b[36m%s\x1b[0m  \x1b[33m%s\x1b[0m", s.date, s.title)
	end

	local fzf_opts = {
		["--ansi"] = "",
		["--delimiter"] = "\t",
		["--with-nth"] = "2..",
	}
	if has_preview then
		fzf_opts["--preview"] = "CLICOLOR_FORCE=1 glow -s dark " .. preview_dir .. "/{1}"
		fzf_opts["--preview-window"] = "right:50%:wrap"
	else
		fzf_opts["--preview-window"] = "hidden"
	end

	require("fzf-lua").fzf_exec(entries, {
		prompt = "  ",
		fzf_opts = fzf_opts,
		winopts = {
			title = " 󰋚 Restore Session ",
			title_pos = "center",
			height = 0.6,
			width = has_preview and 0.75 or 0.6,
		},
		actions = {
			["default"] = function(selected)
				vim.fn.delete(preview_dir, "rf")
				if not selected or #selected == 0 then return end
				local sid = selected[1]:match("^([^\t]+)")
				if sid then M.load(sid) end
			end,
			["ctrl-x"] = function(selected)
				if not selected or #selected == 0 then return end
				for _, item in ipairs(selected) do
					local sid = item:match("^([^\t]+)")
					if sid then
						client.delete_session(sid, function() end)
						vim.notify("lg: deleted session " .. sid:sub(1, 8), vim.log.levels.INFO)
					end
				end
				vim.fn.delete(preview_dir, "rf")
				M.pick()
			end,
		},
	})
end

-- ── Public API ─────────────────────────────────────────────────────

function M.pick()
	list_sessions_acp(function(sessions)
		vim.schedule(function() show_picker(sessions) end)
	end)
end

function M.load(session_id)
	local function do_load()
		local old = M._get_sid()
		if old then
			client.destroy_session(old)
			M._set_sid(nil)
		end
		require("lg.ui.window").clear_history()

		status.start("Restoring session...")
		M._restoring = true

		M._ensure_acp(function(ok)
			if not ok then
				status.stop("Connection failed")
				return
			end

			M._setup_event_handlers()
			M._set_sid(session_id)

			local unsub
			unsub = client.on("session_loaded", function(ev)
				if ev.session_id ~= session_id then return end
				if unsub then unsub() end
				M._restoring = false
				client.set_mode(session_id, M._resolve_mode("lg"), "lg")
				client.get_models(function(resp)
					if resp.models then M._set_models(resp.models) end
				end)
				status.stop("Session restored")
				vim.api.nvim_exec_autocmds("User", { pattern = "LgRequestFinished" })
			end)

			client.load_session(session_id, vim.fn.getcwd(), function(resp)
				if resp.error then
					if unsub then unsub() end
					M._restoring = false
					status.stop("Restore failed: " .. resp.error)
					M._set_sid(nil)
					return
				end
				M._set_sid(resp.session_id)
				M._refresh_count()
			end)
		end)
	end

	if M._get_sid() then
		vim.ui.select({ "Yes", "No" }, { prompt = "Clear current session and restore?" }, function(choice)
			if choice == "Yes" then do_load() end
		end)
	else
		do_load()
	end
end

return M
