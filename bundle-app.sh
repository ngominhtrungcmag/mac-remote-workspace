#!/bin/sh
set -eu

package_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$package_dir

version=${MRW_VERSION:-$(git -C "$repo_root" describe --tags --abbrev=0 2>/dev/null || printf 1.0.0)}
version=${version#v}
build_number=$(git -C "$repo_root" rev-list --count HEAD)

echo "==> Building native MacRemoteWorkspace (Release)..."
# Universal by default; MRW_ARCHS="arm64" builds a single architecture.
arch_flags=""
for a in ${MRW_ARCHS:-arm64 x86_64}; do arch_flags="$arch_flags --arch $a"; done
# shellcheck disable=SC2086
"$package_dir/build-native.sh" -c release $arch_flags
# shellcheck disable=SC2086
bin_dir=$(swift build --package-path "$package_dir" -c release $arch_flags --show-bin-path)

target_app_dir="$package_dir/.build/NativeApp"
mkdir -p "$target_app_dir"
app_bundle="$target_app_dir/Mac Remote Workspace.app"

rm -rf "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS"
mkdir -p "$app_bundle/Contents/Resources"

cp "$bin_dir/MacRemoteWorkspace" "$app_bundle/Contents/MacOS/MacRemoteWorkspace"
cp "$bin_dir/RdpSessionHelper" "$app_bundle/Contents/MacOS/RdpSessionHelper"
cp -R "$bin_dir/MacRemoteWorkspace_AppCore.bundle" "$app_bundle/Contents/Resources/"
cp -R "$bin_dir/MacRemoteWorkspace_MacRemoteWorkspace.bundle" "$app_bundle/Contents/Resources/"

cp "$repo_root/LICENSE" "$repo_root/THIRD_PARTY_NOTICES.md" "$app_bundle/Contents/Resources/"

# Regenerate with: swift scripts/make-app-icon.swift <dir>/AppIcon.iconset && iconutil -c icns ...
cp "$package_dir/Resources/AppIcon.icns" "$app_bundle/Contents/Resources/icon.icns"

cat << EOF > "$app_bundle/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDisplayName</key>
	<string>Mac Remote Workspace</string>
	<key>CFBundleExecutable</key>
	<string>MacRemoteWorkspace</string>
	<key>CFBundleIconFile</key>
	<string>icon.icns</string>
	<key>CFBundleIdentifier</key>
	<string>org.macremoteworkspace.desktop</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Mac Remote Workspace</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$version</string>
	<key>CFBundleVersion</key>
	<string>$build_number</string>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleLocalizations</key>
	<array><string>en</string><string>vi</string></array>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
EOF

codesign --force -s - "$app_bundle/Contents/MacOS/RdpSessionHelper"
codesign --force -s - "$app_bundle"
echo "==> Application bundle successfully built at: $app_bundle"

if [ "${1:-}" = "--install" ] || [ "${1:-}" = "-i" ]; then
  dest="/Applications/Mac Remote Workspace.app"
  if [ -d "$dest" ]; then
    backup="/Applications/Mac Remote Workspace.app.backup-$(date +%Y%m%d%H%M%S)"
    echo "==> Backing up existing $dest to $backup..."
    mv "$dest" "$backup"
  fi
  echo "==> Installing to $dest..."
  cp -R "$app_bundle" "$dest"
  echo "==> Installed successfully to $dest"
fi
