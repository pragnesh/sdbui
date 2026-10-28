#!/bin/sh
# Build a release of SDB Query Browser and package it for Linux.
#
#   scripts/package-linux.sh [--version X.Y.Z] [--skip-build] [--no-deb]
#
# Produces in dist/:
#   sdbui-<version>-linux-<arch>.tar.gz   portable archive with install.sh
#   sdbui_<version>_<debarch>.deb         Debian/Ubuntu package (needs dpkg-deb)
#   SHA256SUMS
#
# The Swift runtime is linked statically, so the only runtime dependency is
# GTK 4 (plus ADBC drivers installed with dbc to actually connect).
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

version=""
build=1
deb=1
while [ $# -gt 0 ]; do
    case "$1" in
        --version) version="$2"; shift 2 ;;
        --version=*) version="${1#--version=}"; shift ;;
        --skip-build) build=0; shift ;;
        --no-deb) deb=0; shift ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

# Default version: the latest vX.Y.Z tag, else 0.1.0; untagged or dirty
# builds get a +g<commit> suffix so they're distinguishable.
if [ -z "$version" ]; then
    tag=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)
    version=${tag#v}
    version=${version:-0.1.0}
    exact=$(git describe --tags --exact-match --match 'v[0-9]*' 2>/dev/null || true)
    if [ -z "$exact" ] || [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        version="$version+g$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
        [ -n "$(git status --porcelain 2>/dev/null)" ] && version="$version.dirty"
    fi
fi
case "$version" in
    [0-9]*) ;;
    *) echo "Version must start with a digit (got '$version')" >&2; exit 2 ;;
esac

case "$(uname -m)" in
    x86_64) arch=x86_64; debarch=amd64 ;;
    aarch64|arm64) arch=aarch64; debarch=arm64 ;;
    *) arch=$(uname -m); debarch=$arch ;;
esac

app_id=dev.sdbui.QueryBrowser
name="sdbui-$version-linux-$arch"
dist="$root/dist"
stage="$dist/$name"

if [ "$build" = 1 ]; then
    command -v swift >/dev/null 2>&1 || {
        echo "swift not found on PATH (with swiftly: . ~/.local/share/swiftly/env.sh)" >&2
        exit 1
    }
    echo "==> Building release ($version)"
    swift build -c release --product sdbui --static-swift-stdlib
fi
bin_dir=$(swift build -c release --show-bin-path 2>/dev/null || echo "$root/.build/release")
binary="$bin_dir/sdbui"
[ -x "$binary" ] || { echo "Release binary not found at $binary" >&2; exit 1; }

# Refuse to ship a binary that still needs the toolchain's Swift libraries.
if ldd "$binary" | grep -q 'libswiftCore\|libFoundation\.so'; then
    echo "error: $binary links the Swift runtime dynamically; rebuild without --skip-build" >&2
    exit 1
fi

echo "==> Staging $name"
rm -rf "$stage"
mkdir -p "$stage/bin" "$stage/share/applications" "$stage/share/icons/hicolor/scalable/apps"
cp "$binary" "$stage/bin/sdbui"
strip "$stage/bin/sdbui"
cp packaging/linux/$app_id.desktop "$stage/share/applications/"
cp packaging/linux/$app_id.svg "$stage/share/icons/hicolor/scalable/apps/"
cp packaging/linux/install.sh packaging/linux/uninstall.sh "$stage/"
chmod 755 "$stage/install.sh" "$stage/uninstall.sh"
cp README.md "$stage/"
echo "$version" > "$stage/VERSION"

echo "==> Creating $name.tar.gz"
tar -C "$dist" -czf "$dist/$name.tar.gz" "$name"
artifacts="$name.tar.gz"

if [ "$deb" = 1 ]; then
    if command -v dpkg-deb >/dev/null 2>&1; then
        deb_version=$(echo "$version" | tr -c 'A-Za-z0-9.+~\n' '.')
        deb_name="sdbui_${deb_version}_$debarch.deb"
        deb_root="$dist/deb-$debarch"
        echo "==> Creating $deb_name"
        rm -rf "$deb_root"
        mkdir -p "$deb_root/DEBIAN" "$deb_root/usr/bin" "$deb_root/usr/share/applications" \
            "$deb_root/usr/share/icons/hicolor/scalable/apps" "$deb_root/usr/share/doc/sdbui"
        cp "$stage/bin/sdbui" "$deb_root/usr/bin/"
        cp "$stage/share/applications/$app_id.desktop" "$deb_root/usr/share/applications/"
        cp "$stage/share/icons/hicolor/scalable/apps/$app_id.svg" \
            "$deb_root/usr/share/icons/hicolor/scalable/apps/"
        cp README.md "$deb_root/usr/share/doc/sdbui/"
        installed_size=$(du -sk "$deb_root/usr" | cut -f1)
        cat > "$deb_root/DEBIAN/control" <<EOF
Package: sdbui
Version: $deb_version
Architecture: $debarch
Maintainer: pragnesh <pg.radadia@gmail.com>
Installed-Size: $installed_size
Depends: libgtk-4-1
Section: database
Priority: optional
Homepage: https://github.com/columnar-tech/databow
Description: SDB Query Browser - native SQL browser over ADBC
 A GTK 4 desktop app (built with SwiftCrossUI) for browsing schemas and
 running SQL against any database with an ADBC driver. Drivers and
 connection profiles are shared with dbc/databow (~/.config/adbc).
EOF
        chmod -R u=rwX,go=rX "$deb_root"
        if command -v fakeroot >/dev/null 2>&1; then
            fakeroot dpkg-deb --build "$deb_root" "$dist/$deb_name" >/dev/null
        else
            dpkg-deb --root-owner-group --build "$deb_root" "$dist/$deb_name" >/dev/null
        fi
        rm -rf "$deb_root"
        artifacts="$artifacts $deb_name"
    else
        echo "==> dpkg-deb not found; skipping .deb"
    fi
fi

(cd "$dist" && sha256sum $artifacts > SHA256SUMS)
echo "==> Done:"
for artifact in $artifacts; do
    echo "    dist/$artifact ($(du -h "$dist/$artifact" | cut -f1))"
done
echo "    dist/SHA256SUMS"
