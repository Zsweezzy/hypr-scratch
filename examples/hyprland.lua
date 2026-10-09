-- The class match is anchored (an unanchored one also grabs the test sink); `rounding` must equal data/style.css `border-radius`.

hl.window_rule({
	name = "hypr-scratch-overlay",
	match = { class = [[^dev\.Zsweezzy\.HyprScratch$]] },
	float = true,
	center = true,
	pin = true,
	border_size = 0,
	no_shadow = true,
	no_anim = true,
	no_blur = false,
	rounding = 10,
	suppress_event = "maximize fullscreen",
})

-- Open it with an absolute path: binds run with a minimal environment.
bind("SUPER", "N", function()
	hl.exec(os.getenv("HOME") .. "/.local/bin/hypr-scratch")
end)

-- Click-away dismissal, both buttons; `non_consuming` keeps the click from being swallowed.
bind("", "mouse:272", function()
	hl.exec(os.getenv("HOME") .. "/.local/bin/hypr-scratch --outside-click")
end, { non_consuming = true })

bind("", "mouse:273", function()
	hl.exec(os.getenv("HOME") .. "/.local/bin/hypr-scratch --outside-click")
end, { non_consuming = true })
