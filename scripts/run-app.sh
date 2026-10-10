#!/bin/zsh
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$root_dir/.build/arm64-apple-macosx/debug"
app_bundle="$root_dir/.build/AgentOSDesktop.app"

cd "$root_dir"
swift build

mkdir -p "$app_bundle/Contents/MacOS"
cp "$root_dir/App/Info.plist" "$app_bundle/Contents/Info.plist"
cp "$build_dir/AgentOSDesktop" "$app_bundle/Contents/MacOS/AgentOSDesktop"

open "$app_bundle"
