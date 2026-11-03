#!/bin/sh
# Real GTK application checks under an isolated X display and accessibility bus.
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build/quality-ui
runtime_dir=$(mktemp -d /tmp/sdbui-quality-runtime.XXXXXX)
trap 'rm -rf "$runtime_dir" 2>/dev/null || true' EXIT
for mode in Light Dark; do
    env -u AT_SPI_BUS_ADDRESS XDG_RUNTIME_DIR="$runtime_dir" GDK_BACKEND=x11 GSK_RENDERER=cairo \
        GTK_USE_PORTAL=0 GIO_USE_VFS=local GSETTINGS_BACKEND=memory XDG_CURRENT_DESKTOP= \
        dbus-run-session -- xvfb-run -a -s '-screen 0 1600x1100x24' \
        sh -c '
            if ! dbus-send --session --print-reply --dest=org.a11y.Bus \
                /org/a11y/bus org.a11y.Bus.GetAddress; then
                echo "Accessibility bus unavailable. Install at-spi2-core, dbus-daemon and dbus-bin." >&2
                exit 1
            fi
            exec /usr/bin/python3 scripts/test-quality-ui.py "$@"
        ' sdbui-quality-ui --appearance "$mode"
done
