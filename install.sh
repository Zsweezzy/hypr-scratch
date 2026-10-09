#!/usr/bin/env bash
set -euo pipefail

PREFIX=${PREFIX:-$HOME/.local/bin}
DESTDIR=${DESTDIR:-}
ROOT=$(cd "$(dirname "$0")" && pwd)

if ! command -v cargo >/dev/null 2>&1; then
    echo "cargo is not installed. Install Rust from https://rustup.rs and re-run." >&2
    exit 1
fi

echo "Building hypr-scratch (release)..."
cargo build --release --manifest-path "$ROOT/Cargo.toml"

install -d "$DESTDIR$PREFIX"
install -m 755 "$ROOT/target/release/hypr-scratch" "$DESTDIR$PREFIX/hypr-scratch"
echo "Installed $DESTDIR$PREFIX/hypr-scratch"

STYLE_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/hypr-scratch
STYLE=$STYLE_DIR/style.css
if [ -e "$DESTDIR$STYLE" ]; then
    echo "Left your existing $DESTDIR$STYLE alone."
else
    install -d "$DESTDIR$STYLE_DIR"
    install -m 644 "$ROOT/data/style.css" "$DESTDIR$STYLE"
    echo "Wrote a starting $DESTDIR$STYLE -- edit it to change the colours."
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
