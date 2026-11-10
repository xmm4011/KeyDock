#!/bin/zsh
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
swift build -c release
TASK_BIN="$(swift build -c release --show-bin-path)"
TASK_PACKAGE="$(mktemp -d "$TASK_ROOT/.build/package.XXXXXX")"
trap 'rm -rf "$TASK_PACKAGE"' EXIT
TASK_APP="$TASK_PACKAGE/KeyDock.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources"
cp "$TASK_BIN/KeyDock" "$TASK_APP/Contents/MacOS/KeyDock"
# NSAllowsLocalNetworking would override NSAllowsArbitraryLoads on current
# macOS, blocking user-supplied HTTP gateways with NSURLErrorDomain -1022.
cat > "$TASK_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>KeyDock</string>
  <key>CFBundleDisplayName</key><string>KeyDock</string>
  <key>CFBundleIdentifier</key><string>local.keydock.app</string>
  <key>CFBundleExecutable</key><string>KeyDock</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>31</string>
  <key>CFBundleShortVersionString</key><string>1.3.24</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <key>NSHumanReadableCopyright</key><string>KeyDock · 本地密钥管理</string>
</dict></plist>
PLIST
TASK_ICONSET="$TASK_ROOT/.build/AppIcon.iconset"
mkdir -p "$TASK_ICONSET"
swift scripts/icon.swift "$TASK_ROOT/.build/icon-1024.png"
for TASK_SIZE in 16 32 128 256 512; do
  sips -z "$TASK_SIZE" "$TASK_SIZE" "$TASK_ROOT/.build/icon-1024.png" --out "$TASK_ICONSET/icon_${TASK_SIZE}x${TASK_SIZE}.png" >/dev/null
  TASK_DOUBLE=$((TASK_SIZE * 2))
  sips -z "$TASK_DOUBLE" "$TASK_DOUBLE" "$TASK_ROOT/.build/icon-1024.png" --out "$TASK_ICONSET/icon_${TASK_SIZE}x${TASK_SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$TASK_ICONSET" -o "$TASK_APP/Contents/Resources/AppIcon.icns"
zsh "$TASK_ROOT/scripts/prepare-agent.sh" "$TASK_APP"
codesign --force --sign - --identifier local.keydock.app "$TASK_APP"
codesign --verify --deep --strict "$TASK_APP"
ditto -c -k --sequesterRsrc --keepParent "$TASK_APP" "$TASK_PACKAGE/KeyDock.zip"
python3 - "$TASK_PACKAGE/KeyDock.zip" "$TASK_ROOT/dist" <<'PY'
import os,plistlib,shutil,subprocess,sys
from pathlib import Path
stage,directory=map(Path,sys.argv[1:])
legacy=directory/'KeyDock.app'
if legacy.exists():
    with (legacy/'Contents/Info.plist').open('rb') as file:
        if plistlib.load(file).get('CFBundleIdentifier')!='local.keydock.app':
            raise SystemExit('dist 中的应用不是 KeyDock，未覆盖或移除。')
directory.mkdir(parents=True,exist_ok=True)
target=directory/'KeyDock.zip'
os.replace(stage,target)
if legacy.exists():
    register='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
    subprocess.run([register,'-u',str(legacy)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    shutil.rmtree(legacy)
print('已生成安装包：'+str(target))
PY
