# AGENTS.md — glm-agent development guide

This file is the canonical repository instruction source. `CLAUDE.md` is a
symlink to `AGENTS.md` for Claude Code compatibility. Edit only `AGENTS.md`;
the symlink reflects changes automatically.

## Project scope

`glm-agent` is a Bash wrapper that runs persistent GLM coding workers through
Claude Code and Z.ai. Version 1 deliberately remains a local CLI and filesystem
protocol. Do not introduce MCP, a daemon, a database, or another implementation
language without an explicit design decision.

Keep stdout compact and control-plane oriented. Detailed worker reports, raw
Claude JSON, and stderr belong under the worker directory.

## Repository layout

- `glm-agent`: CLI implementation and embedded user-facing help.
- `system-prompt.md`: worker execution and durable-result contract, loaded
  directly at the start of every worker turn.
- `prompts/`: role-specific worker prompts, loaded directly on every turn.
- `.claude-plugin/`: Claude Code plugin and marketplace manifests.
- `agents/`: thin Claude Code bridges for explorer and general-purpose workers.
- `skills/`: Claude Code skills; `skills/quota/SKILL.md` is the quota gate that
  runs before work is dispatched to GLM or native Claude.
- `scripts/bump-version.sh`: synchronized CLI/plugin/marketplace version bump.
- `tests/test_glm_agent.sh`: hermetic CLI tests using fake `claude` and `curl`
  binaries.
- `tests/test_plugin.sh`: plugin schema, bridge contract, skill contract, and
  version tests.
- `README.md`: public installation, usage, behavior, and security documentation.
- `LICENSE`: MIT License terms for the project.
- `CLAUDE.md`: compatibility symlink; never replace it with an independent copy.

## Behavioral invariants

Preserve these unless the requested change explicitly revises the contract:

- `start` creates a worker and captures its Claude session ID.
- `send` resumes that exact session and reuses the original working directory
  and model.
- Each turn has `prompt.md`, `response.json`, `stderr.log`, and `result.md`.
- `GLM_RESULT_FILE` is an absolute path to the turn's canonical durable report.
- A valid report ends with exactly `STATUS: DONE` or `STATUS: BLOCKED`.
- Invocation failures and missing or malformed results become `INVALID`.
- Starting a background process alone is not completion.
- `close` preserves worker history and rejects later `send` calls.
- API keys and Claude session IDs must not appear in normal stdout.
- `quota` passes the API key to `curl` only as a stdin header (`-H @-`); it
  never appears in argv, stdout, stderr, or files.
- `system-prompt.md` is read directly on every turn; it is not duplicated in
  the Bash source.

## Verified Claude Code configuration

Keep these defaults intact unless there is an explicit, tested migration:

```text
ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic
ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-5.3-flash[1m]
ANTHROPIC_DEFAULT_SONNET_MODEL=glm-5.3[1m]
ANTHROPIC_DEFAULT_OPUS_MODEL=glm-5.3[1m]
CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
API_TIMEOUT_MS=3000000
```

Unset inherited `CLAUDECODE` before invoking Claude. The default Claude alias
is `sonnet`. Authentication is stored at `~/.glm/.env.auth`, unless
`GLM_AGENT_HOME` changes the state root, and the key must never be logged.

## Implementation rules

- Maintain compatibility with the Bash version shipped by macOS unless the
  documented minimum changes deliberately.
- Quote expansions and validate any value used in paths or metadata.
- Keep shared turn execution in `run_turn()`; do not duplicate it between
  `start` and `send`.
- Make state transitions explicit and retain raw failure artifacts.
- Treat worker directories as untrusted input when accepting a worker ID.
- Keep `--help`, `README.md`, tests, and implementation behavior synchronized.
- Prefer focused changes. Preserve unrelated user changes in a dirty worktree.

## Testing

For behavior changes, add or update a failing test before changing the
implementation. The fake Claude executable must not make network requests or
use a real API key.

Run before declaring work complete:

```bash
bash tests/test_glm_agent.sh
bash tests/test_plugin.sh
bash -n glm-agent tests/test_glm_agent.sh tests/test_plugin.sh scripts/bump-version.sh
shellcheck glm-agent tests/test_glm_agent.sh tests/test_plugin.sh scripts/bump-version.sh
claude plugin validate --strict .
```

If `shellcheck` is unavailable, report that fact rather than silently skipping
the check. For changes to live Z.ai integration, run a narrowly scoped real
smoke test only when credentials and authorization are already available, and
never print or inspect the key itself.

For releases, run `scripts/bump-version.sh <major.minor.patch>` rather than
editing version fields individually. The CLI, plugin manifest, and marketplace
entry must remain identical and the parity tests must pass. The bump script
does not commit, tag, or push.

Also inspect the final diff and confirm that documentation examples match the
current command output and exit-status behavior.

## Documentation and prompt changes

`system-prompt.md` is runtime behavior, not ordinary prose. Changes can alter
what every worker does, so cover its required clauses with tests and review it
like code.

Edit agent instructions only in `AGENTS.md`. Keep `CLAUDE.md` as a relative
symlink to `AGENTS.md` so clones remain portable.
