#!/bin/sh
set -eu

sdk_path=$(xcrun --sdk macosx --show-sdk-path)
sdk_version=$(xcrun --sdk macosx --show-sdk-version)
package_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

[ -d "$package_dir/vendor/FreeRDP.xcframework" ] || { echo "FreeRDP.xcframework missing; run ./scripts/build-freerdp-macos.sh from the repository root." >&2; exit 1; }

swift build --package-path "$package_dir" --sdk "$sdk_path" \
  -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$sdk_version" "$@"
