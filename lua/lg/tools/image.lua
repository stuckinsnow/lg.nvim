--- Clipboard image reader for attaching screenshots to ACP prompts.

local M = {}

local IMAGE_MIMES = { "image/png", "image/jpeg", "image/webp" }

--- Format byte count for display (e.g. "142 KB").
--- @param bytes integer
--- @return string
function M.format_size(bytes)
	if bytes < 1024 then
		return bytes .. " B"
	elseif bytes < 1024 * 1024 then
		return string.format("%.0f KB", bytes / 1024)
	else
		return string.format("%.1f MB", bytes / (1024 * 1024))
	end
end

--- Base64-encode raw bytes without newlines.
--- @param bytes string
--- @return string
function M.encode_base64(bytes)
	if vim.base64 and vim.base64.encode then
		return vim.base64.encode(bytes)
	end
	local obj = vim.system({ "base64", "-w0" }, { stdin = bytes, text = false }):wait()
	if obj.code ~= 0 then
		return ""
	end
	return (obj.stdout or ""):gsub("%s+", "")
end

--- Pick the first supported image MIME type present in a newline-separated list.
--- @param targets string
--- @return string?
function M._pick_mime(targets)
	local available = {}
	for line in (targets or ""):gmatch("[^\r\n]+") do
		available[vim.trim(line)] = true
	end
	for _, mime in ipairs(IMAGE_MIMES) do
		if available[mime] then
			return mime
		end
	end
	return nil
end

--- Read an image from the system clipboard.
--- Supports Wayland (wl-paste), X11 (xclip), and macOS (pngpaste).
--- @return { data: string, mime_type: string, size: integer }? img, string? err
function M.read_clipboard()
	local raw, mime

	if vim.env.WAYLAND_DISPLAY and vim.env.WAYLAND_DISPLAY ~= "" and vim.fn.executable("wl-paste") == 1 then
		local list = vim.system({ "wl-paste", "--list-types" }, { text = true }):wait()
		mime = list.code == 0 and M._pick_mime(list.stdout) or nil
		if not mime then
			return nil, "no image in clipboard"
		end
		local obj = vim.system({ "wl-paste", "--no-newline", "--type", mime }, { text = false }):wait()
		if obj.code ~= 0 or not obj.stdout or #obj.stdout == 0 then
			return nil, "failed to read clipboard image"
		end
		raw = obj.stdout
	elseif vim.fn.executable("xclip") == 1 then
		local list = vim.system({ "xclip", "-selection", "clipboard", "-t", "TARGETS", "-o" }, { text = true }):wait()
		mime = list.code == 0 and M._pick_mime(list.stdout) or nil
		if not mime then
			return nil, "no image in clipboard"
		end
		local obj = vim.system({ "xclip", "-selection", "clipboard", "-t", mime, "-o" }, { text = false }):wait()
		if obj.code ~= 0 or not obj.stdout or #obj.stdout == 0 then
			return nil, "failed to read clipboard image"
		end
		raw = obj.stdout
	elseif vim.fn.has("mac") == 1 and vim.fn.executable("pngpaste") == 1 then
		local obj = vim.system({ "pngpaste", "-" }, { text = false }):wait()
		if obj.code ~= 0 or not obj.stdout or #obj.stdout == 0 then
			return nil, "no image in clipboard"
		end
		raw = obj.stdout
		mime = "image/png"
	else
		return nil, "no clipboard image tool found (install xclip, wl-paste, or pngpaste)"
	end

	return {
		data = M.encode_base64(raw),
		mime_type = mime,
		size = #raw,
	}
end

return M
