#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Build, sign, notarize, tag, and publish a macOS release from the local machine.

Usage:
  ./scripts/release-macos-local.sh <version>

Example:
  CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  NOTARY_PROFILE="glossolalia-notary" \
  ./scripts/release-macos-local.sh 0.1.0

Requirements:
  - clean git worktree
  - current branch is `glossolalia`
  - `gh` is authenticated for this repo
  - Apple signing identity is installed in the local keychain
  - `xcrun notarytool store-credentials` already created the notary profile

Environment overrides:
  APP_NAME            Default: Glossolalia
  PRODUCT_SLUG        Default: glossolalia
  BUNDLE_ID           Default: com.henryzoo.glossolalia
  EXECUTABLE_NAME     Default: glossolalia
  ICON_NAME           Default: AppIconImage
  MINIMUM_SYSTEM_VERSION Default: 13.0.0
  CODESIGN_IDENTITY   Required
  NOTARY_PROFILE      Required
EOF
}

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 1
fi

version="$1"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "version must follow X.Y.Z" >&2
  exit 1
fi

for tool in git gh zig xcodebuild xcrun codesign hdiutil ditto zip; do
  command -v "$tool" >/dev/null || {
    echo "missing required tool: $tool" >&2
    exit 1
  }
done

: "${CODESIGN_IDENTITY:?set CODESIGN_IDENTITY to your local Developer ID Application identity}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to your stored notarytool profile name}"

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root_dir"

if [[ -n "$(git status --short)" ]]; then
  echo "worktree must be clean" >&2
  exit 1
fi

branch="$(git branch --show-current)"
if [[ "$branch" != "glossolalia" ]]; then
  echo "release must run from glossolalia; current branch: $branch" >&2
  exit 1
fi

app_name="${APP_NAME:-Glossolalia}"
product_slug="${PRODUCT_SLUG:-glossolalia}"
bundle_id="${BUNDLE_ID:-com.henryzoo.glossolalia}"
executable_name="${EXECUTABLE_NAME:-glossolalia}"
icon_name="${ICON_NAME:-AppIconImage}"
minimum_system_version="${MINIMUM_SYSTEM_VERSION:-13.0.0}"

tag="v${version}"
release_title="${app_name} v${version}"
build="$(git rev-list --count HEAD)"
commit="$(git rev-parse --short HEAD)"
commit_long="$(git rev-parse HEAD)"
release_notes_url="https://github.com/hzoo/glossolalia/releases/tag/${tag}"
compare_url_template="https://github.com/hzoo/glossolalia/compare/{current}...{new}"
commit_url_template="https://github.com/hzoo/glossolalia/commit/{new}"

if git rev-parse "$tag" >/dev/null 2>&1; then
  echo "tag already exists locally: $tag" >&2
  exit 1
fi

if gh release view "$tag" >/dev/null 2>&1; then
  echo "GitHub release already exists: $tag" >&2
  exit 1
fi

release_dir="$(mktemp -d "/tmp/${product_slug}-${version}.XXXXXX")"
app_path="$root_dir/macos/build/Release/${app_name}.app"
dmg_path="$release_dir/${app_name}.dmg"
zip_path="$release_dir/${product_slug}-macos-universal.zip"
dsym_path="$release_dir/${product_slug}-macos-universal-dsym.zip"

echo "release dir: $release_dir"
echo "building GhosttyKit..."
zig build \
  -Doptimize=ReleaseFast \
  -Demit-macos-app=false \
  -Dversion-string="$version"

echo "building ${app_name}.app..."
(
  cd "$root_dir/macos"
  xcodebuild \
    -project Ghostty.xcodeproj \
    -target Ghostty \
    -configuration Release \
    GLOSSOLALIA_APP_PRODUCT_NAME="$app_name" \
    GLOSSOLALIA_APP_DISPLAY_NAME="$app_name" \
    GLOSSOLALIA_DEBUG_APP_DISPLAY_NAME="${app_name}[DEBUG]" \
    GLOSSOLALIA_APP_ICON_NAME="$icon_name" \
    GLOSSOLALIA_EXECUTABLE_NAME="$executable_name" \
    GLOSSOLALIA_BUNDLE_ID="$bundle_id" \
    GLOSSOLALIA_DEBUG_BUNDLE_ID="${bundle_id}.debug" \
    GLOSSOLALIA_DOCK_TILE_PRODUCT_NAME="DockTilePlugin" \
    GLOSSOLALIA_DOCK_TILE_DISPLAY_NAME="${app_name} Dock Tile Plugin" \
    GLOSSOLALIA_DOCK_TILE_BUNDLE_ID="${bundle_id}-dock-tile" \
    GLOSSOLALIA_NOTIFICATION_NAMESPACE="$bundle_id" \
    GLOSSOLALIA_DEFAULTS_SUITE_NAME="$bundle_id" \
    GLOSSOLALIA_SURFACE_UTI="${bundle_id}.surface-id" \
    GLOSSOLALIA_RELEASE_NOTES_URL_TEMPLATE="$release_notes_url" \
    GLOSSOLALIA_COMPARE_URL_TEMPLATE="$compare_url_template" \
    GLOSSOLALIA_COMMIT_URL_TEMPLATE="$commit_url_template" \
    GLOSSOLALIA_UPDATE_STABLE_FEED_URL="" \
    GLOSSOLALIA_UPDATE_TIP_FEED_URL="" \
    COMPILATION_CACHE_KEEP_CAS_DIRECTORY=YES \
    build
)

if [[ ! -d "$app_path" ]]; then
  echo "expected app bundle not found: $app_path" >&2
  exit 1
fi

echo "patching Info.plist..."
/usr/libexec/PlistBuddy -c "Set :GhosttyCommit $commit" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :SUEnableAutomaticChecks" "$app_path/Contents/Info.plist" || true
/usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$app_path/Contents/Info.plist" || true

echo "codesigning app bundle..."
codesign --verbose -f -s "$CODESIGN_IDENTITY" -o runtime "$app_path/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
codesign --verbose -f -s "$CODESIGN_IDENTITY" -o runtime "$app_path/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"
codesign --verbose -f -s "$CODESIGN_IDENTITY" -o runtime "$app_path/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
codesign --verbose -f -s "$CODESIGN_IDENTITY" -o runtime "$app_path/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
codesign --verbose -f -s "$CODESIGN_IDENTITY" -o runtime "$app_path/Contents/Frameworks/Sparkle.framework"
codesign --verbose -f -s "$CODESIGN_IDENTITY" -o runtime "$app_path/Contents/PlugIns/DockTilePlugin.plugin"
codesign --verbose -f -s "$CODESIGN_IDENTITY" -o runtime --entitlements "$root_dir/macos/Ghostty.entitlements" "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
spctl --assess --type execute --verbose "$app_path"

echo "creating DMG..."
hdiutil create \
  -volname "$app_name" \
  -srcfolder "$app_path" \
  -format UDZO \
  "$dmg_path"

echo "notarizing DMG..."
xcrun notarytool submit "$dmg_path" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$dmg_path"
xcrun stapler staple "$app_path"

echo "zipping app bundle and dSYM..."
(
  cd "$root_dir/macos/build/Release"
  zip -9 -r --symlinks "$zip_path" "${app_name}.app"
  zip -9 -r --symlinks "$dsym_path" "${app_name}.app.dSYM"
)

echo "creating tag $tag..."
git tag -a "$tag" -m "$release_title"

echo "pushing branch and tag..."
git push origin glossolalia
git push origin "$tag"

echo "creating GitHub release..."
gh release create "$tag" \
  "$dmg_path" \
  "$zip_path" \
  "$dsym_path" \
  --verify-tag \
  --title "$release_title"

cat <<EOF
release complete
tag: $tag
commit: $commit_long
dmg: $dmg_path
zip: $zip_path
dsym: $dsym_path
EOF
