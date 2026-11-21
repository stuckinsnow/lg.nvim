-- Tests for clipboard image attachment & ACP image content blocks.
-- Run: nvim --headless -l tests/test_image_paste.lua

vim.opt.runtimepath:append(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h"))

local failures = 0
local function check(name, got, want)
	if got ~= want then
		failures = failures + 1
		print(("FAIL %s\n  got:  %s\n  want: %s"):format(name, vim.inspect(got), vim.inspect(want)))
	else
		print("ok   " .. name)
	end
end

local image = require("lg.tools.image")
local context = require("lg.tools.context")
local protocol = require("lg.session.protocol")

check("format_size bytes", image.format_size(512), "512 B")
check("format_size KB", image.format_size(145408), "142 KB")
check("format_size MB", image.format_size(1572864), "1.5 MB")

check("encode_base64", image.encode_base64("hello"), "aGVsbG8=")
check("pick_mime prefers png", image._pick_mime("TARGETS\nimage/jpeg\nimage/png\n"), "image/png")
check("pick_mime falls back to jpeg", image._pick_mime("UTF8_STRING\nimage/jpeg\n"), "image/jpeg")
check("pick_mime returns nil for text only", image._pick_mime("UTF8_STRING\ntext/plain\n"), nil)

context.clear()
context.add_image({ data = "aGVsbG8=", mime_type = "image/png", size = 5 })
check("image stored in context", #context.get_images(), 1)

local window = require("lg.ui.window")
window.add_prompt("what is in this screenshot?")
check("chat history shows attached image", window.get_history():find("🖼 [1 image attached (5 B)]", 1, true) ~= nil, true)

local parts = protocol.build_prompt({}, {}, "what is in this screenshot?")
check("prompt has text + image block", #parts, 2)
check("first block is text", parts[1].type, "text")
check("second block is image", parts[2].type, "image")
check("image mimeType", parts[2].mimeType, "image/png")
check("image data", parts[2].data, "aGVsbG8=")
check("images consumed after build_prompt", #context.get_images(), 0)

-- Second prompt should not re-attach the consumed image.
local parts2 = protocol.build_prompt({}, {}, "follow up")
check("follow-up prompt has no image", #parts2, 1)

print(failures == 0 and "\nall passed" or ("\n" .. failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
