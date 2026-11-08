#!/bin/sh
set -eu
cd "$SRCROOT"
if [ "${1:-}" = prepare ]; then
  mkdir -p "$DERIVED_FILE_DIR"
  cp scripts/XcodeInfo.plist "$DERIVED_FILE_DIR/MacRemoteWorkspace-Info.plist"
  version=${MRW_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || printf 1.0.0)}
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${version#v}" "$DERIVED_FILE_DIR/MacRemoteWorkspace-Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD)" "$DERIVED_FILE_DIR/MacRemoteWorkspace-Info.plist"
  exit 0
fi
configuration=$(printf '%s' "$CONFIGURATION" | tr '[:upper:]' '[:lower:]')
scratch="$PROJECT_TEMP_DIR/swiftpm"
arch_flags=""
for arch in $ARCHS; do arch_flags="$arch_flags --arch $arch"; done
# SwiftPM receives the same architectures as the Xcode app target.
# shellcheck disable=SC2086
swift build --scratch-path "$scratch" -c "$configuration" $arch_flags --product RdpSessionHelper
# shellcheck disable=SC2086
bin_dir=$(swift build --scratch-path "$scratch" -c "$configuration" $arch_flags --show-bin-path)
mkdir -p "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/MacOS" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
cp "$bin_dir/RdpSessionHelper" "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/MacOS/"
cp -R Sources/MacRemoteWorkspace/Resources/*.lproj "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/"
cp Resources/AppIcon.icns "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/icon.icns"
cp LICENSE THIRD_PARTY_NOTICES.md "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/"
