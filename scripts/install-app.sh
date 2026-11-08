#!/bin/zsh
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_SOURCE="$TASK_ROOT/dist/KeyDock.zip"
TASK_DESTINATION="$HOME/Applications/KeyDock.app"
[[ -f "$TASK_SOURCE" ]] || { print '请先运行 zsh scripts/build-app.sh'; exit 1; }
mkdir -p "$HOME/Applications"
TASK_STAGE="$(mktemp -d "$HOME/Applications/.KeyDock-install.XXXXXX")"
trap 'if [[ ! -e "$TASK_STAGE/previous.app" || -d "$TASK_DESTINATION" ]]; then rm -rf "$TASK_STAGE"; fi' EXIT
ditto -x -k "$TASK_SOURCE" "$TASK_STAGE"
codesign --verify --deep --strict "$TASK_STAGE/KeyDock.app"
python3 - "$TASK_STAGE/KeyDock.app" "$TASK_DESTINATION" "$TASK_STAGE/previous.app" <<'PY'
import os, plistlib, sys
from pathlib import Path
stage,target,previous=map(Path,sys.argv[1:])
for candidate in (stage,target):
    if not candidate.exists(): continue
    with (candidate/'Contents/Info.plist').open('rb') as file:
        if plistlib.load(file).get('CFBundleIdentifier')!='local.keydock.app':
            raise SystemExit('目标不是 KeyDock，未覆盖。')
if target.exists():
    os.rename(target,previous)
try:
    os.rename(stage,target)
except BaseException:
    if previous.exists() and not target.exists(): os.rename(previous,target)
    raise
print('已安装：'+str(target))
print('若旧版仍在运行，请从菜单栏退出后重新打开。')
PY
"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister" -f "$TASK_DESTINATION" >/dev/null 2>&1 || true
mdimport -i "$TASK_DESTINATION" >/dev/null 2>&1 || true
