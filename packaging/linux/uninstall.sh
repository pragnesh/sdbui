#!/bin/sh
# Remove an installation made by install.sh, using its list of installed files.
#
#   ~/.local/share/sdbui/uninstall.sh
#   sudo /usr/local/share/sdbui/uninstall.sh
set -eu

manifest_dir=$(cd "$(dirname "$0")" && pwd)
manifest="$manifest_dir/installed-files"
if [ ! -f "$manifest" ]; then
    echo "No installation manifest at $manifest" >&2
    exit 1
fi

prefix=$(dirname "$(dirname "$manifest_dir")")
echo "Removing SDB Query Browser from $prefix"
while IFS= read -r file; do
    [ "$file" = "$manifest" ] && continue
    case "$file" in
        "$prefix"/*) rm -f "$file" && echo "  $file" ;;
        *) echo "  skipped (outside $prefix): $file" >&2 ;;
    esac
done < "$manifest"
rm -f "$manifest"
rmdir "$manifest_dir" 2>/dev/null || true

command -v update-desktop-database >/dev/null 2>&1 \
    && update-desktop-database -q "$prefix/share/applications" 2>/dev/null || true
# Only refresh an existing icon cache: creating one (e.g. in ~/.local) would
# hide icons that other apps add later without updating it.
if [ -f "$prefix/share/icons/hicolor/icon-theme.cache" ] \
    && command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -t "$prefix/share/icons/hicolor" 2>/dev/null || true
fi
echo "Done."
