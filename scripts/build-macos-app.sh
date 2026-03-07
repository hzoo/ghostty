#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Build the local macOS app bundle in one command.

Usage:
  ./scripts/build-macos-app.sh [--debug] [--install]

Options:
  --debug     Build the Debug configuration instead of Release.
  --install   Copy the built app into /Applications after building.
  --help      Show this help text.

Environment overrides:
  APP_NAME           Default: Glossolalia
  BUNDLE_ID          Default: dev.glossolalia.app
  EXECUTABLE_NAME    Default: glossolalia
  ICON_NAME          Default: Ghostty
  INSTALL_DIR        Default: /Applications
EOF
}

configuration="Release"
optimize="ReleaseFast"
install_app=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)
      configuration="Debug"
      optimize="Debug"
      shift
      ;;
    --install)
      install_app=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      echo
      usage >&2
      exit 1
      ;;
  esac
done

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_name="${APP_NAME:-Glossolalia}"
bundle_id="${BUNDLE_ID:-dev.glossolalia.app}"
executable_name="${EXECUTABLE_NAME:-glossolalia}"
icon_name="${ICON_NAME:-Ghostty}"
install_dir="${INSTALL_DIR:-/Applications}"

echo "building GhosttyKit with Zig..."
(
  cd "$root_dir"
  zig build \
    -Demit-macos-app=false \
    -Doptimize="$optimize"
)

echo "building ${app_name}.app with Xcode..."
(
  cd "$root_dir/macos"
  xcodebuild \
    -project Ghostty.xcodeproj \
    -target Ghostty \
    -configuration "$configuration" \
    CODE_SIGNING_ALLOWED=NO \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
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
    build
)

app_path="$root_dir/macos/build/${configuration}/${app_name}.app"

if [[ ! -d "$app_path" ]]; then
  echo "expected app bundle not found: $app_path" >&2
  exit 1
fi

echo "built app: $app_path"

if [[ "$install_app" -eq 1 ]]; then
  echo "installing to ${install_dir}/${app_name}.app..."
  rm -rf "${install_dir}/${app_name}.app"
  ditto "$app_path" "${install_dir}/${app_name}.app"
  echo "installed app: ${install_dir}/${app_name}.app"
fi
