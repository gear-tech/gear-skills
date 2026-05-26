#!/usr/bin/env bash
# gear-dev plugin — SessionStart preflight check.
#
# Verifies the runtime prerequisites for the bundled MCP servers (Serena via
# uvx, repomix via npx) and surfaces actionable fix commands when something is
# missing. Also gives a heads-up about rust-analyzer cold-start cost in Rust
# workspaces. Never blocks session start — always exits 0.

set -u

echo
echo "[gear-dev preflight]"

# ---------- Serena prereq: uvx ----------
if command -v uvx >/dev/null 2>&1; then
  UVX_VER=$(uvx --version 2>&1 | head -1)
  echo "  ✓ $UVX_VER (Serena MCP ready)"
else
  echo "  ✗ uvx not found — Serena MCP will not start"
  echo "    Install: curl -LsSf https://astral.sh/uv/install.sh | sh"
fi

# ---------- repomix prereq: node 18+ ----------
if command -v node >/dev/null 2>&1; then
  NODE_VER=$(node --version 2>&1)                  # e.g. v20.10.0
  NODE_MAJOR=${NODE_VER#v}                         # strip leading 'v'
  NODE_MAJOR=${NODE_MAJOR%%.*}                     # take major version
  if [ "${NODE_MAJOR:-0}" -ge 18 ] 2>/dev/null; then
    echo "  ✓ node $NODE_VER (repomix MCP ready)"
  else
    echo "  ⚠ node $NODE_VER — repomix needs Node 18+"
    echo "    Upgrade via https://nodejs.org or your package manager"
  fi
else
  echo "  ✗ node not found — repomix MCP will not start"
  echo "    Install Node 18+ from https://nodejs.org"
fi

# ---------- rust-analyzer warmth hint (only inside a Rust workspace) ----------
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
if [ -f "$PROJECT_DIR/Cargo.toml" ]; then
  if [ -d "$PROJECT_DIR/target/rust-analyzer" ]; then
    echo "  ✓ rust-analyzer cache present (Serena warm-start)"
  else
    echo "  ℹ first run in this workspace — rust-analyzer will index ~30–90s (Serena cold-start)"
  fi
fi

echo
exit 0
