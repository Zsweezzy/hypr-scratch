-- hypr-scratch: window rule and binds for a Hyprland *Lua* config.
--
-- For a plain `.conf`, the same thing in Hyprland's own syntax:
--
--     windowrulev2 = float, class:^(dev\.Zsweezzy\.HyprScratch)$, match:^(hypr-scratch)$
--     windowrulev2 = center, class:^(dev\.Zsweezzy\.HyprScratch)$, match:^(hypr-scratch)$
--     windowrulev2 = pin, class:^(dev\.Zsweezzy\.HyprScratch)$, match:^(hypr-scratch)$
--     windowrulev2 = border_size 0, class:^(dev\.Zsweezzy\.HyprScratch)$, match:^(hypr-scratch)$
--     windowrulev2 = no_shadow, class:^(dev\.Zsweezzy\.HyprScratch)$, match:^(hypr-scratch)$
--     windowrulev2 = no_anim, class:^(dev\.Zsweezzy\.HyprScratch)$, match:^(hypr-scratch)$
--     windowrulev2 = no_blur, class:^(dev\.Zsweezzy\.HyprScratch)$, match:^(hypr-scratch)$
--     windowrulev2 = rounding 10, class:^(dev\.Zsweezzy\.HyprScratch)$, match:^(hypr-scratch)$
--     windowrulev2 = suppress_event maximize fullscreen, class:^(dev\.Zsweezzy\.HyprScratch)$, match:^(hypr-scratch)$
--
--     bind = SUPER,N,exec,$HOME/.local/bin/hypr-scratch
--     bind = ,mouse:272,exec,$HOME/.local/bin/hypr-scratch --outside-click,non_consuming
--     bind = ,mouse:273,exec,$HOME/.local/bin/hypr-scratch --outside-click,non_consuming
--
-- The class is anchored at both ends, and that is the whole point of the line.
--
-- Hyprland matches a rule against the *whole* class, not a substring, so a bare
-- "HyprScratch" matches nothing at all and the symptom is not an error: it is a
-- notepad that opens tiled. That is why the `.*` is needed on a loose match.
--
-- But `.*HyprScratch.*` is anchored at neither end, and it is the more tempting
-- thing to write, so it is worth being precise. This repository's own test sink
-- is called `dev.Zsweezzy.HyprScratchSink` -- the notepad's class with "Sink" on the
-- end -- and an unanchored match floats, centres and pins it too. It did exactly
-- that here: the sink came up already pinned, the suite's own `pin` toggle then
-- unpinned it, it fell under a fullscreen browser, and every click meant for it
-- landed on the browser instead. Two unrelated-looking failures, one unanchored
-- regex. If you install a second window whose class contains "HyprScratch", the
-- loose form will float and pin that one as well.
--
-- The `[[...]]` is not decoration. A backslash before a dot is an invalid escape
-- sequence in a Lua string, quoted either way, and `luac -p` rejects the file
-- outright; the long-bracket form is literal, so the regex can be written here
-- exactly as it reads. (`'\\.'` works too, if you prefer to double it.)
--
-- `rounding = 10` here must equal the `border-radius` in data/style.css. The
-- compositor's `rounding` does not clip this window -- the arc is painted by GTK
-- -- so the two numbers have to agree by hand. `scripts/gates.sh` GATE 8 compares
-- them, which is the only thing standing between them.

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

-- Open it. Use an absolute path: binds run with a minimal environment, and
-- ~/.local/bin is not always on PATH.
bind("SUPER", "N", function()
	hl.exec(os.getenv("HOME") .. "/.local/bin/hypr-scratch")
end)

-- Click-away dismissal, both buttons. `non_consuming` is the point of the whole
-- thing: without it the click is swallowed, so focusing whatever is underneath
-- and dismissing the notepad stop being one gesture. The app cannot do this from
-- inside itself -- GTK 4 removed the client-side pointer grab -- so the
-- compositor has to report the click, which is what this mode is for.
bind("", "mouse:272", function()
	hl.exec(os.getenv("HOME") .. "/.local/bin/hypr-scratch --outside-click")
end, { non_consuming = true })

bind("", "mouse:273", function()
	hl.exec(os.getenv("HOME") .. "/.local/bin/hypr-scratch --outside-click")
end, { non_consuming = true })
