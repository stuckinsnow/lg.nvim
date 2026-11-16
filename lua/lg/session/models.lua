--- Model and provider (backend) selection UI.

local client = require("lg.session.client")
local protocol = require("lg.session.protocol")
local status = require("lg.status")

local M = {}

-- Session internals injected once via M.init().
local ctx = {}

function M.init(c)
	ctx = c
end

-- ── Ephemeral override (used by the quick-chat subagent) ───────────
local ephemeral_override = nil

function M.set_override(o)
	ephemeral_override = o
end

function M.clear_override()
	ephemeral_override = nil
end

function M.current_model()
	if ephemeral_override then
		return ephemeral_override.model
	end
	local sm = ctx.get_models()
	if sm then
		return sm.currentModelId
	end
	return ctx.load_state().model
end

function M.current_provider()
	if ephemeral_override then
		return ephemeral_override.provider
	end
	return ctx.get_provider()
end

--- Internal flat model picker. With `provider_filter`, only models whose id is
--- prefixed by `<provider_filter>/` are shown.
function M.pick_model(provider_filter)
	ctx.connect(function(sid)
		if not sid then
			vim.notify("lg: no models available", vim.log.levels.WARN)
			return
		end
		-- Refetch: opencode replaces its model list after the first prompt.
		client.get_models(function(resp)
			if resp.models then
				ctx.set_models(resp.models)
			end
			local provider = ctx.get_provider()
			if not ctx.get_models() and provider ~= "opencode" then
				vim.notify("lg: no models available", vim.log.levels.WARN)
				return
			end

			local function show_picker()
				vim.schedule(function()
				-- Only include models under this provider prefix (e.g.
				-- "github-copilot") when a filter is given.
				local function matches(id)
					return not provider_filter or vim.startswith(id or "", provider_filter .. "/")
				end

				local labels = {}
				local by_label = {}
				local sm = ctx.get_models()
				if not sm then
					vim.notify("lg: no models available", vim.log.levels.WARN)
					return
				end
				local current = sm.currentModelId
				local default_model = sm.defaultModelId
				local provider = ctx.get_provider()

				-- Keep the provider's default separate from the current model. The
				-- current model may be lg's restored override.
				if provider == "opencode" and default_model and matches(default_model) then
					local label = "OpenCode default  →  " .. default_model
					table.insert(labels, label)
					by_label[label] = { id = default_model, use_default = true }
				end

				for _, m in ipairs(sm.availableModels or {}) do
					if matches(m.modelId) then
						local label = m.modelId
						if m.rateMultiplier then
							label = string.format("%-22s  %gx", m.modelId, m.rateMultiplier)
						end
						if m.modelId == current then
							label = label .. "  (current)"
						end
						table.insert(labels, label)
						by_label[label] = { id = m.modelId, use_default = false }
					end
				end

				if #labels == 0 then
					vim.notify(
						"lg: no models available" .. (provider_filter and (" for " .. provider_filter) or ""),
						vim.log.levels.WARN
					)
					return
				end

				local prompt = provider_filter
						and ("lg model — " .. provider_filter .. " (current: " .. (current or "?") .. "):")
					or ("lg model (current: " .. (current or "?") .. "):")
				vim.ui.select(labels, { prompt = prompt }, function(choice)
					if not choice then
						return
					end
					local selection = by_label[choice]
					local model_id = selection and selection.id
					local use_default = selection and selection.use_default
					if not model_id or (model_id == current and not use_default) then
						return
					end
					local function save_model_state()
						ctx.save_state({
							provider = ctx.get_provider(),
							model = use_default and nil or model_id,
							use_default_model = use_default or false,
						})
					end

					local function apply_switch(strategy)
						if strategy == "clear" then
							ctx.reset()
							save_model_state()
							vim.notify("lg: model → " .. model_id .. " (session cleared)", vim.log.levels.INFO)
						elseif strategy == "handoff" then
							-- Ask old model to write a handoff prompt, then reset and send it
							status.start("Writing handoff…")
							local handoff_prompt =
								"Write a concise handoff summary for a new AI model that is taking over this conversation. Include: what the user is working on, what has been done so far, and what the user wants next. Output ONLY the handoff text, no preamble."
							local handoff_text = ""
							local unsub = client.on("text", function(ev)
								if ev.session_id == sid then
									handoff_text = handoff_text .. (ev.text or "")
								end
							end)
							ctx.set_on_done(function()
								ctx.set_busy(false)
								unsub()
								vim.schedule(function()
									status.stop("Handoff ready")
									ctx.reset()
									save_model_state()
									-- Connect creates fresh session with new model
									ctx.connect(function(new_sid)
										if not new_sid then
											return
										end
										client.set_model(new_sid, model_id)
										ctx.set_current_model(model_id)
										local messages = protocol.build_prompt(
											{},
											{},
											"Context from previous session (different model):\n\n"
												.. handoff_text
												.. "\n\nAcknowledge briefly and wait for my next instruction."
										)
										status.start("Sending handoff…")
										ctx.set_on_done(function()
											ctx.set_busy(false)
											status.stop("Model → " .. model_id)
											require("lg.ui.window").add_status(
												"Model switched → " .. model_id .. " (with handoff)"
											)
										end)
										ctx.set_busy(true)
										client.prompt(new_sid, messages)
									end)
								end)
							end)
							ctx.set_busy(true)
							client.prompt(sid, { { type = "text", text = handoff_prompt } })
						end
					end

					-- If no active session history, just switch directly
					if not ctx.get_main_session_id() then
						save_model_state()
						vim.notify("lg: model → " .. model_id, vim.log.levels.INFO)
						return
					end

					-- No conversation yet — just switch model in place
					if not ctx.get_has_history() then
						client.set_model(ctx.get_main_session_id(), model_id)
						ctx.set_current_model(model_id)
						save_model_state()
						vim.notify("lg: model → " .. model_id, vim.log.levels.INFO)
						return
					end

					vim.ui.select(
						{ "Clear & reset", "Handoff to new model" },
						{ prompt = "Switch to " .. model_id .. ":" },
						function(_, idx)
							if idx == 1 then
								apply_switch("clear")
							elseif idx == 2 then
								apply_switch("handoff")
							end
						end
					)
				end)
				end)
			end

			if provider ~= "opencode" then
				show_picker()
				return
			end

			-- OpenCode first exposes a broad configured list and then replaces it
			-- with the entitlement-aware list. Do not render the first snapshot.
			local settled = false
			local unsubscribe
			unsubscribe = client.on("models_updated", function(ev)
				if settled or ev.session_id ~= sid then
					return
				end
				settled = true
				unsubscribe()
				client.get_models(function(latest)
					if latest.models then
						ctx.set_models(latest.models)
					end
					show_picker()
				end)
			end)
			-- A provider that never emits a refresh must not leave the picker
			-- blocked forever; use the latest cache after one deadline.
			vim.defer_fn(function()
				if settled then
					return
				end
				settled = true
				unsubscribe()
				show_picker()
			end, 2000)
		end)
	end)
end

--- Pick a model. For backends whose model ids are `provider/model` (e.g.
--- opencode), this first prompts for the provider, then the model within it.
--- For flat backends (e.g. kiro) it goes straight to the model picker.
function M.select_model()
	ctx.connect(function(sid)
		local sm = ctx.get_models()
		if not sid or not sm then
			vim.notify("lg: no models available", vim.log.levels.WARN)
			return
		end
		-- Derive the unique provider prefixes from the available model ids.
		local seen = {}
		local provs = {}
		for _, m in ipairs(sm.availableModels or {}) do
			local prefix = (m.modelId or ""):match("^([^/]+)/")
			if prefix and not seen[prefix] then
				seen[prefix] = true
				table.insert(provs, prefix)
			end
		end
		if #provs == 0 then
			-- No provider prefixes (e.g. kiro) — go straight to the model picker.
			M.pick_model()
			return
		end
		table.sort(provs)
		local current = sm.currentModelId or ""
		local current_prefix = current:match("^([^/]+)/")
		local labels = {}
		local by_label = {}
		for _, p in ipairs(provs) do
			local label = p
			if p == current_prefix then
				label = label .. "  (current)"
			end
			table.insert(labels, label)
			by_label[label] = p
		end
		vim.schedule(function()
			vim.ui.select(labels, { prompt = "lg cli provider:" }, function(choice)
				if not choice then
					return
				end
				M.pick_model(by_label[choice])
			end)
		end)
	end)
end

--- Switch the lg backend (kiro / opencode).
function M.select_provider()
	local providers = ctx.providers
	local provider = ctx.get_provider()
	local names = {}
	for key, p in pairs(providers) do
		local label = p.name
		if provider == key then
			label = label .. " (current)"
		end
		table.insert(names, { key = key, label = label })
	end
	table.sort(names, function(a, b)
		return a.label < b.label
	end)

	vim.ui.select(
		vim.tbl_map(function(n)
			return n.label
		end, names),
		{ prompt = "lg provider (current: " .. (providers[provider].name or "?") .. "):" },
		function(choice, idx)
			if not choice or not idx then
				return
			end
			local picked = names[idx].key
			if picked == provider and ctx.get_main_session_id() then
				return
			end
			ctx.set_provider(picked)
			ctx.clear()
			-- Model ids are provider-specific. Never carry the previous provider's
			-- model into the new session; let the selected provider report its own
			-- default instead.
			ctx.save_state({ provider = picked, use_default_model = true })
			vim.notify("lg: provider → " .. providers[picked].name, vim.log.levels.INFO)
			-- Provider and model selection are separate operations. The new
			-- provider owns model discovery and starts on its reported default;
			-- open the model picker explicitly when a non-default is wanted.
		end
	)
end

return M
