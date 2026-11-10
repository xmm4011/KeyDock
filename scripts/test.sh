#!/bin/zsh
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
mkdir -p .build/checks
TASK_FLAGS=(-parse-as-library -swift-version 5 -whole-module-optimization -D KEYDOCK_CHECKS)
TASK_CHECK_BINARY=.build/checks/KeyDockChecks
if [[ "${KEYDOCK_SANITIZE_ADDRESS:-0}" == 1 ]]; then
  TASK_FLAGS+=(-sanitize=address)
  TASK_CHECK_BINARY=.build/checks/KeyDockChecksASan
fi
TASK_SOURCES=(Sources/KeyDock/*.swift)
TASK_SOURCES=(${TASK_SOURCES:#Sources/KeyDock/App.swift})
swiftc "${TASK_FLAGS[@]}" -o "$TASK_CHECK_BINARY" \
  "${TASK_SOURCES[@]}" Tests/*.swift Tests/KeyDockTests/CoreTests.swift
if [[ "${KEYDOCK_BUILD_CHECKS_ONLY:-0}" == 1 ]]; then exit 0; fi
case "${1:-}" in
  --sdk-fixture|--instance-lock-hold|--preset-reference-json|--live-deepseek|--live-http-gateway)
    exec "$TASK_CHECK_BINARY" "$@" ;;
esac
TASK_REPORT="$(mktemp "$TASK_ROOT/.build/checks/completion.XXXXXX")"
trap 'rm -f "$TASK_REPORT"' EXIT
"$TASK_CHECK_BINARY" "$@" | tee "$TASK_REPORT"
if ! /usr/bin/grep -Eq '^ALL .*CHECKS PASSED \([0-9]+ scenarios\)$' "$TASK_REPORT"; then
  print -u2 '检查程序提前结束，未产生完整通过标记。'
  exit 1
fi
