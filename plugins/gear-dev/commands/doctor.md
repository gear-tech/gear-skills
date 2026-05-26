---
description: Diagnose the gear-dev plugin's MCP server prerequisites and surface actionable fix commands.
argument-hint: (no arguments)
---

# /gear-dev:doctor

Run the gear-dev plugin's preflight diagnostic and show the result to the user verbatim. Use this when:

- The user reports that `serena` or `repomix` MCP failed in `/mcp`.
- The user wants to verify their machine is correctly set up for the plugin.
- After installing the plugin for the first time.

## What to do

1. Run the preflight script:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh"
   ```
   Where `${CLAUDE_PLUGIN_ROOT}` resolves to the gear-dev plugin's install path.

2. **Print the script's stdout to the user verbatim** inside a fenced code block — do not paraphrase or summarize. The user needs the exact ✓/✗/⚠/ℹ markers and install commands.

3. If any line starts with `✗` (missing prerequisite), additionally point the user to:
   - For missing `uvx`: explain that this is needed for Serena MCP; after installing, they must run `/reload-plugins` or restart Claude Code for Serena to start.
   - For missing `node`: explain that this is needed for repomix MCP; same reload step after install.

4. If everything is `✓`, confirm that the plugin should be fully operational and remind the user that `/mcp` shows live MCP server status.

## Notes

- The script always exits 0 — failures are surfaced via output, not exit codes.
- The script reads `${CLAUDE_PROJECT_DIR}` (falling back to `pwd`) to decide whether to show the rust-analyzer cache hint — that hint only appears inside Rust workspaces (detected via `Cargo.toml`).
- This command does not install anything itself; it only diagnoses.
