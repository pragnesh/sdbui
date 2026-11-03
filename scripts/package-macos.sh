#!/bin/bash
# Build a native macOS .app and ZIP (run once per CPU architecture).
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $(uname -s) == Darwin ]] || { echo 'macOS packaging requires macOS and the Apple SDK.' >&2; exit 2; }
version=""
build=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) version=$2; shift 2 ;;
        --skip-build) build=0; shift ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done
version=${version:-$(git describe --tags --always --dirty | sed 's/^v//')}
[[ $version =~ ^[0-9][A-Za-z0-9.+~_-]*$ ]] || { echo 'Pass --version with a numeric release version.' >&2; exit 2; }
arch=$(uname -m)
case "$arch" in arm64|x86_64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 2 ;; esac
if [[ $build == 1 ]]; then swift build -c release --product sdbui; fi
bin_dir=$(swift build -c release --show-bin-path)
lipo -verify_arch "$arch" "$bin_dir/sdbui"
name="sdbui-$version-macos-$arch"
stage="$PWD/dist/$name"
app="$stage/SDB Query Browser.app"
rm -rf "$stage"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/sdbui" "$app/Contents/MacOS/sdbui"
bundle="$bin_dir/sdbui_ADBCKit.bundle"
[[ -d $bundle ]] || bundle="$bin_dir/sdbui_ADBCKit.resources"
[[ -d $bundle ]] || { echo 'Transfer resource bundle missing.' >&2; exit 1; }
cp -R "$bundle" "$app/Contents/Resources/"
# CLI SwiftPM resource accessors also search beside the executable.
ln -s "../Resources/$(basename "$bundle")" "$app/Contents/MacOS/$(basename "$bundle")"
cp scripts/setup-transfers.py "$app/Contents/Resources/"
cp README.md "$stage/README.md"
/usr/libexec/PlistBuddy -c 'Clear dict' "$app/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string dev.sdbui.QueryBrowser' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string sdbui' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleName string SDB Query Browser' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$app/Contents/Info.plist"
# CFBundle versions accept a numeric release, not git/build suffixes.
release_version=$(printf '%s' "$version" | sed -E 's/[^0-9.].*$//')
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $release_version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 1' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSMinimumSystemVersion string 14.0' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :NSHighResolutionCapable bool true' "$app/Contents/Info.plist"
# Official Swift toolchains may link newer Swift libraries than the OS ships.
# Embed the redistributable runtime instead of shipping a toolchain path dependency.
runtime_dir=$(swift -print-target-info | python3 -c 'import json,sys;print(json.load(sys.stdin)["paths"]["runtimeLibraryPaths"][0])')
xcrun swift-stdlib-tool --copy --scan-executable "$app/Contents/MacOS/sdbui" --destination "$app/Contents/Frameworks" --platform macosx --source-libraries "$runtime_dir"
# Remove build-machine/toolchain search paths and prefer the bundled Swift runtime.
otool -l "$app/Contents/MacOS/sdbui" | awk '/cmd LC_RPATH/{r=1;next} r && /path /{print $2;r=0}' | while IFS= read -r path; do
    case "$path" in @*) ;; *) install_name_tool -delete_rpath "$path" "$app/Contents/MacOS/sdbui" ;; esac
done
install_name_tool -add_rpath '@executable_path/../Frameworks' "$app/Contents/MacOS/sdbui"
# Sign nested libraries before the application. No certificate is needed for ad-hoc builds.
identity=${SDBUI_CODESIGN_IDENTITY:--}
if [[ -d $app/Contents/Frameworks ]]; then
    find "$app/Contents/Frameworks" -type f -name '*.dylib' -print0 | while IFS= read -r -d '' library; do
        codesign --force --sign "$identity" "$library"
    done
fi
codesign --force --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
ditto -c -k --sequesterRsrc --keepParent "$stage" "$PWD/dist/$name.zip"
(cd dist && shasum -a 256 "$name.zip" > "SHA256SUMS-macos-$arch")
echo "Created dist/$name.zip (ad-hoc signed unless SDBUI_CODESIGN_IDENTITY is set; not notarized)."
