#!/usr/bin/env bash
# Build and install hypr-scratch.
#
# `cargo install --path .` would do, and is the better choice if you want the
# binary managed by cargo. This exists for the case where you do not want a
# toolchain permanently on the machine that runs the notepad -- the notepad
# autostarts on every login, so it is worth being able to build it once and
# leave Rust behind.
set -euo pipefail

PREFIX=${PREFIX:-$HOME/.local/bin}
ROOT=$(cd "$(dirname "$0")" && pwd)

if ! command -v cargo >/dev/null 2>&1; then
    echo "cargo is not installed. Install Rust from https://rustup.rs and re-run." >&2
    exit 1
fi

echo "Building hypr-scratch (release)..."
cargo build --release --manifest-path "$ROOT/Cargo.toml"

install -d "$PREFIX"
install -m 755 "$ROOT/target/release/hypr-scratch" "$PREFIX/hypr-scratch"
echo "Installed $PREFIX/hypr-scratch"

# Offer the stylesheet, but never overwrite one that is already there. The
# built-in default is compiled in, so the notepad works without this file; it is
# only here so there is something to edit.
STYLE_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/hypr-scratch
STYLE=$STYLE_DIR/style.css
if [ -e "$STYLE" ]; then
    echo "Left your existing $STYLE alone."
else
    # No existence test on the source, and deliberately so. `cargo build` above
    # has already run under `set -e`, and it can only succeed if
    # `include_str!("../data/style.css")` resolved, so the file is known to be
    # there. This used to carry a third case for a missing data/style.css,
    # promising that the built-in stylesheet would be used instead -- but the
    # build fails long before this point, with a clear `couldn't read` error
    # naming src/ui.rs, so the fallback was unreachable and the message described
    # a recovery that cannot happen. A branch that says something untrue is
    # worse than no branch.
    install -d "$STYLE_DIR"
    install -m 644 "$ROOT/data/style.css" "$STYLE"
    echo "Wrote a starting $STYLE -- edit it to change the colours."
fi

cat <<EOF

Next, in your Hyprland config. See the README for the full snippet; the minimum
is a bind to open it:

    bind = SUPER,N,exec, $PREFIX/hypr-scratch

and, for click-away dismissal, two binds that the compositor owns:

    bind = ,mouse:272,exec, $PREFIX/hypr-scratch --outside-click, non_consuming
    bind = ,mouse:273,exec, $PREFIX/hypr-scratch --outside-click, non_consuming

then reload with \`hyprctl reload\`.
EOF
