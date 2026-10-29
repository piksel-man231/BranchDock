#!/bin/zsh
set -eu
cd "${0:A:h}"
swift build -c release
if [[ -f Assets/BranchDock.png ]]; then ./build-icon.sh; fi
APP="$PWD/dist/BranchDock.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ -f Assets/BranchDock.icns ]]; then cp Assets/BranchDock.icns "$APP/Contents/Resources/BranchDock.icns"; fi
cp .build/release/BranchDock "$APP/Contents/MacOS/BranchDock.new"
mv -f "$APP/Contents/MacOS/BranchDock.new" "$APP/Contents/MacOS/BranchDock"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BranchDock</string>
<key>CFBundleIdentifier</key><string>local.branchdock.app</string>
<key>CFBundleName</key><string>BranchDock</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [[ -f "$APP/Contents/Resources/BranchDock.icns" ]]; then
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string BranchDock' "$APP/Contents/Info.plist"
fi
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
INSTALL_DIR=$(mktemp -d /Applications/.branchdock-install.XXXXXX)
trap 'rm -rf "$INSTALL_DIR"' EXIT
ditto "$APP" "$INSTALL_DIR/BranchDock.app"
codesign --verify --deep --strict "$INSTALL_DIR/BranchDock.app"
if [[ -e /Applications/BranchDock.app ]]; then
    mv /Applications/BranchDock.app "$INSTALL_DIR/Previous.app"
fi
if ! mv "$INSTALL_DIR/BranchDock.app" /Applications/BranchDock.app; then
    if [[ -e "$INSTALL_DIR/Previous.app" ]]; then
        mv "$INSTALL_DIR/Previous.app" /Applications/BranchDock.app
    fi
    exit 1
fi
echo "Готово: $APP"
echo "Установлено: /Applications/BranchDock.app"
