#!/bin/sh
# Install SDB Query Browser from this release archive.
#
#   ./install.sh                     # per-user, into ~/.local (no sudo)
#   sudo ./install.sh --prefix /usr/local
#
# The list of installed files is written to <prefix>/share/sdbui/installed-files
# so uninstall.sh can remove exactly those.
set -eu

prefix="${HOME}/.local"
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) prefix="$2"; shift 2 ;;
        --prefix=*) prefix="${1#--prefix=}"; shift ;;
        -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

here=$(cd "$(dirname "$0")" && pwd)
app_id=dev.sdbui.QueryBrowser
manifest_dir="$prefix/share/sdbui"
manifest="$manifest_dir/installed-files"

install_file() { # <mode> <source> <destination>
    mkdir -p "$(dirname "$3")"
    cp "$2" "$3"
    chmod "$1" "$3"
    echo "$3" >> "$manifest.tmp"
    echo "  $3"
}

mkdir -p "$manifest_dir"
: > "$manifest.tmp"
echo "Installing to $prefix"
install_file 755 "$here/bin/sdbui" "$prefix/bin/sdbui"
install_file 644 "$here/share/applications/$app_id.desktop" "$prefix/share/applications/$app_id.desktop"
install_file 644 "$here/share/icons/hicolor/scalable/apps/$app_id.svg" \
    "$prefix/share/icons/hicolor/scalable/apps/$app_id.svg"
install_file 755 "$here/uninstall.sh" "$manifest_dir/uninstall.sh"
echo "$manifest" >> "$manifest.tmp"
mv "$manifest.tmp" "$manifest"

# Refresh desktop caches when the tools are available (they're optional).
command -v update-desktop-database >/dev/null 2>&1 \
    && update-desktop-database -q "$prefix/share/applications" 2>/dev/null || true
# Only refresh an existing icon cache: creating one (e.g. in ~/.local) would
# hide icons that other apps add later without updating it.
if [ -f "$prefix/share/icons/hicolor/icon-theme.cache" ] \
    && command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -t "$prefix/share/icons/hicolor" 2>/dev/null || true
fi

# Runtime checks: GTK 4 is required; ADBC drivers are needed to connect.
if ! (ldconfig -p 2>/dev/null | grep -q 'libgtk-4\.so\.1'); then
    echo
    echo "warning: GTK 4 was not found. Install it, e.g. 'sudo apt install libgtk-4-1'."
fi
if ! ls "${XDG_CONFIG_HOME:-$HOME/.config}"/adbc/drivers/*.toml >/dev/null 2>&1 \
    && ! ls /etc/adbc/drivers/*.toml >/dev/null 2>&1; then
    echo
    echo "note: no ADBC drivers found. Install some with dbc (https://docs.columnar.tech/dbc/),"
    echo "      e.g. 'dbc install postgresql' or 'dbc install mysql'."
fi

case ":$PATH:" in
    *":$prefix/bin:"*) ;;
    *) echo; echo "note: $prefix/bin is not on your PATH; add it or launch from the app menu." ;;
esac

echo
echo "Done. Run 'sdbui' or open 'SDB Query Browser' from the app menu."
echo "To uninstall: $manifest_dir/uninstall.sh"
