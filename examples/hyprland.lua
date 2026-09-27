-- hypr-scratch: window rule and binds for a Hyprland *Lua* config.
--
-- For a plain `.conf`, the same thing in Hyprland's own syntax:
--
--     windowrulev2 = float, class:^(dev\.maxii\.HyprScratch)$, match:^(hypr-scratch)$
--     windowrulev2 = center, class:^(dev\.maxii\.HyprScratch)$, match:^(hypr-scratch)$
--     windowrulev2 = pin, class:^(dev\.maxii\.HyprScratch)$, match:^(hypr-scratch)$
--     windowrulev2 = border_size 0, class:^(dev\.maxii\.HyprScratch)$, match:^(hypr-scratch)$
--     windowrulev2 = no_shadow, class:^(dev\.maxii\.HyprScratch)$, match:^(hypr-scratch)$
--     windowrulev2 = no_anim, class:^(dev\.maxii\.HyprScratch)$, match:^(hypr-scratch)$
--     windowrulev2 = no_blur, class:^(dev\.maxii\.HyprScratch)$, match:^(hypr-scratch)$
--     windowrulev2 = rounding 10, class:^(dev\.maxii\.HyprScratch)$, match:^(hypr-scratch)$
--     windowrulev2 = suppress_event maximize fullscreen, class:^(dev\.maxii\.HyprScratch)$, match:^(hypr-scratch)$
--
--     bind = SUPER,N,exec,/home/you/.local/bin/hypr-scratch
--     bind = ,mouse:272,exec,/home/you/.local/bin/hypr-scratch --outside-click,non_consuming
--     bind = ,mouse:273,exec,/home/you/.local/bin/hypr-scratch --outside-click,non_consuming
--
-- The `.*` on both ends of the class is load-bearing: Hyprland matches a rule
-- against the *whole* class, not a substring. A bare "HyprScratch" matches
-- nothing, and the symptom is not an error but a notepad that opens tiled.
--
-- `rounding = 10` here must equal the `border-radius` in data/style.css. The
-- compositor's `rounding` does not clip this window -- the arc is painted by GTK
-- -- so the two numbers have to agree by hand. `scripts/gates.sh` GATE 8 compares
-- them, which is the only thing standing between them.

hl.window_rule({
	name = "hypr-scratch-overlay",
	match = { class = ".*HyprScratch.*" },
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

-- Open it. Use an absolute path: binds run with a minimal environment, and
-- ~/.local/bin is not always on PATH.
bind("SUPER", "N", function()
	hl.exec("/home/you/.local/bin/hypr-scratch")
end)

-- Click-away dismissal, both buttons. `non_consuming` is the point of the whole
-- thing: without it the click is swallowed, so focusing whatever is underneath
-- and dismissing the notepad stop being one gesture. The app cannot do this from
-- inside itself -- GTK 4 removed the client-side pointer grab -- so the
-- compositor has to report the click, which is what this mode is for.
bind("", "mouse:272", function()
	hl.exec("/home/you/.local/bin/hypr-scratch --outside-click")
end, { non_consuming = true })

bind("", "mouse:273", function()
	hl.exec("/home/you/.local/bin/hypr-scratch --outside-click")
end, { non_consuming = true })
