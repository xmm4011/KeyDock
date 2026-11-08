#!/bin/zsh
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_APP="$1"
TASK_NODE="$(node -p 'process.execPath')"
node -e 'const [major,minor]=process.versions.node.split(".").map(Number); if(major<22 || (major===22 && minor<19)) { console.error("构建 Agent 需要 Node 22.19 或更新版本"); process.exit(1); }'
if ! npm ls --prefix "$TASK_ROOT/AgentRuntime" --omit=dev --all >/dev/null 2>&1; then
  npm ci --prefix "$TASK_ROOT/AgentRuntime" --omit=dev --ignore-scripts --no-audit --no-fund
fi
TASK_AGENT_BUNDLE="$TASK_APP/Contents/Resources/AgentRuntime"
mkdir -p "$TASK_AGENT_BUNDLE"
ditto "$TASK_ROOT/AgentRuntime/node_modules" "$TASK_AGENT_BUNDLE/node_modules"
cp "$TASK_ROOT/AgentRuntime/bridge.mjs" "$TASK_ROOT/AgentRuntime/sandbox.sb" "$TASK_ROOT/AgentRuntime/package.json" "$TASK_ROOT/AgentRuntime/package-lock.json" "$TASK_AGENT_BUNDLE/"
cp "$TASK_NODE" "$TASK_AGENT_BUNDLE/node"
chmod 755 "$TASK_AGENT_BUNDLE/node"
TASK_NODE_LICENSE="${TASK_NODE:h:h}/LICENSE"
[[ -f "$TASK_NODE_LICENSE" ]] || { print '未找到 Node 运行时许可证，请使用官方 Node 安装包构建。'; exit 1; }
cp "$TASK_NODE_LICENSE" "$TASK_AGENT_BUNDLE/NODE-LICENSE"
"$TASK_AGENT_BUNDLE/node" --check "$TASK_AGENT_BUNDLE/bridge.mjs"
