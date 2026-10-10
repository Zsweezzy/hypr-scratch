# AGENTS.md

Project instructions for this repository, read automatically by OpenCode.

## Where the commentary lives

The shell scripts under `scripts/` carry **no comments on purpose**. The notes
that used to sit inline beside them were moved here, grouped by file, in the
order they appeared. When you change one of those scripts, update the matching
note here rather than re-adding a comment.

`install.sh` has no comments and needs none.

## ShellCheck

Keep `scripts/*.sh` ShellCheck-clean:

    shellcheck scripts/*.sh

`.shellcheckrc` sets `external-sources=true` and `source-path=SCRIPTDIR` so that
`. "$HERE/lib.sh"` is followed and the variables it defines across files
(`SINK_CLASS`, `SINK_BIN`) are known. Do not reintroduce inline `# shellcheck`
directives, or any other comments, in the scripts.

## scripts/gates.sh
- Filled in by sink_up from the window's real geometry; left empty so a stray click_sink clicks nothing.
- `note_says() {` — $1 = the marker to look for
- `check_note() {` — $1 = label, $2 = marker
- `wait_state() {` — $1 = want, $2 = timeout in tenths of a second
- `type_into() {` — $1 = the class that must have the focus, $2.. = wtype arguments
- The suite may take focus back from its own sink, but nothing else; a browser or empty desktop aborts.
- The focused window's class, sampled until two reads agree, because focus release is asynchronous.
- `stable_focus() {` — $1 = timeout in tenths of a second
- The sink window: a floated, pinned target the suite owns and places, built from src/bin/sink.rs.
- Crop box in physical px; trims the reserved top strip so the bar's repaint is not read as the sink changing.
- Click point on the sink's largest notepad-free area; fails if none is at least 8px wide.
- Set float/pin rather than toggling: the notepad rule's .*HyprScratch.* match already pins the sink.
- `sink_set_state() {` — $1 = want float, $2 = want pin
- A selector matching two windows acts on nothing yet reports ok: assert exactly one sink.
- class = "..." syntax, not class:foo -- a Lua syntax error there no-ops the dispatch while printing ok.
- Set the state rather than dispatching the toggles blindly; see sink_set_state.
- Post-condition: confirm the sink really landed in the usable area, not merely that we asked.
- Kill by PID, not a selector: one matching nothing falls back to the focused window.
- Wait for the window, not just the process: one on its way out still matches the class.
- `monitor_at() {` — $1 = logical x -> the monitor's name
- `click_at() {` — $1 = logical x, $2 = logical y
- `centre() {` — the middle of the notepad, as the compositor reports it
- Checked: a sink that did not come up would make the failure name the notepad, not the missing window.
- Crop to the sink's own rect, not the whole monitor: a monitor-wide diff can pass on a window it is not testing.
- CSS paints the corners, nothing else ties them to decoration.rounding; the number is read from data/style.css.
- The rule's own rounding: an empty result is not a pass, since a rule that restates nothing leaves it to chance.
- Address, not a class selector: a class that matches nothing falls back to the focused window.
- `bind_count() {` — $1 = description

## scripts/lib.sh
- The notepad's window class, matched by equality; a substring match would land on the test sink.
- `physical_geom_of() {` — $1 = window class -> "name px py pw ph", or exits
- `reserved_top_px() {` — $1 = monitor name
- Builds the test-only sink if missing; its class must stay short (comm truncates at 15 chars) or pkill -x misses it.
- The user's Hyprland config for the blur and `rounding` checks; neither is derivable from the session.
- The corner radius in the notepad's window rule, in either dialect; the class must appear in the same rule.
- Every way a class can be written across the two dialects and quoting styles.
- Ask the regex, not substring containment: the test sink's class contains the notepad's.

## scripts/stress.sh
- `wait_for() {` — $1 = want, $2 = timeout in tenths
- `toggle() {` — $1 = want, $2 = timeout in tenths

## scripts/visual.sh
- `set_blur() {` — $1 = true (blur on) | false (blur off)
- `want = not on` — no_blur is the negation of "blur on"
- Which rule is the notepad's; backslashes stripped, and the trailing (?!\w) keeps the test sink out.
- `shoot() {` — $1 = output name
