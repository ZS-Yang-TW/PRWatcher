#!/bin/bash
# Usage: ./build.sh          → 產生 build/PRWatcher.app
#        ./build.sh install  → 另外安裝到 ~/Applications 並啟動
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=build/PRWatcher.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/PRWatcher "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
    pkill -x PRWatcher || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/PRWatcher.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/PRWatcher.app
    echo "Installed to ~/Applications/PRWatcher.app"
fi
