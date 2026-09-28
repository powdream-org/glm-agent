# glm-agent

`glm-agent` is a small Bash wrapper for running persistent GLM coding workers
through Claude Code and Z.ai's Anthropic-compatible API.

It is designed for an orchestrator that needs compact control-plane output while
keeping each worker's prompts, durable reports, raw Claude responses, and stderr
on disk. A worker keeps the same Claude session, working directory, and model
across `start` and later `send` calls.

## Requirements

- Bash 3.2 or newer
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) available as
  `claude`
- `jq`
- A Z.ai API key
- macOS or a Unix-like environment

## Installation

### Claude Code plugin

Add this public repository as a marketplace and install the plugin:

```bash
claude plugin marketplace add powdream-org/glm-agent
claude plugin install glm-agent@glm-agent --scope user
```

The plugin exposes `glm-agent:explorer` for repository research and
`glm-agent:general-purpose` for implementation, testing, and debugging. The
bridge agents use native Claude Haiku only as a thin control plane; the actual
GLM logical model is selected separately for each new worker.

### Standalone CLI

Clone the repository and run the script from the checkout:

```bash
git clone https://github.com/powdream-org/glm-agent.git
/path/to/glm-agent/glm-agent --help
```

To install it elsewhere, copy `glm-agent`, `system-prompt.md`, and the complete
`prompts/` directory together. The common and role-specific prompts are
intentionally loaded from Markdown files next to the executable on every turn.

## Configure the API key

Use the hidden interactive prompt so the key is not recorded in shell history:

```bash
glm-agent api-key
```

The key is stored at `~/.glm/.env.auth` with mode `0600`. You can instead set
`ZAI_API_KEY` for the current process; the environment variable takes
precedence over the stored value.

Passing a key as an argument is supported for automation, but may expose it in
shell history or process listings:

```bash
glm-agent api-key "$ZAI_API_KEY"
```

## Quick start

Start a worker in a target repository:

```bash
glm-agent start --role general-purpose --model sonnet --cwd /path/to/project \
  "Implement the requested change and run the relevant tests."
```

Successful control-plane output has this shape:

```text
WORKER_ID=20260928T032843Z-15896-30630
TURN=1
MODEL=sonnet
ROLE=general-purpose
STATUS=DONE
RESULT=/Users/example/.glm/workers/20260928T032843Z-15896-30630/turns/0001/result.md
ERROR_KIND=
PROVIDER_CODE=
FALLBACK_RECOMMENDED=false
```

Inspect the reported file and the actual repository changes. If the worker
needs a correction, resume the same Claude session:

```bash
glm-agent send 20260928T032843Z-15896-30630 \
  "Fix the failing test, rerun the suite, and update the result."
```

When no more turns are needed, close the worker without deleting its history:

```bash
glm-agent close 20260928T032843Z-15896-30630
```

## Commands

| Command | Purpose |
| --- | --- |
| `api-key [key]` | Store a Z.ai API key, or prompt for it securely. |
| `run <prompt>` | Run a one-shot diagnostic session without creating a worker. |
| `start [--role <role>] [--model <alias>] [--cwd <dir>] <task>` | Create a persistent worker and execute turn 1. |
| `send <worker-id> <message>` | Resume the worker's original session, directory, role, and model. |
| `result <worker-id>` | Print the latest valid durable result path. |
| `status <worker-id>` | Print compact worker state without exposing the session ID. |
| `list` | List known workers. |
| `close <worker-id>` | Prevent further sends while preserving all worker files. |
| `--help` | Show the complete CLI and worker contract. |
| `--version` | Print the wrapper version. |

The default role is `general-purpose` and the default Claude alias is `sonnet`.
`start` accepts `explorer|general-purpose` via `--role` and
`opus|sonnet|haiku` logical aliases via `--model`; `send` always reuses the
values stored when the worker was created.

## Orchestrator routing

- `glm-agent:explorer` defaults to logical Haiku, mapped to
  `glm-5.3-flash[1m]`, for codebase search, dependency tracing, and evidence
  collection.
- `glm-agent:general-purpose` defaults to logical Sonnet for bounded
  implementation, refactoring, testing, and debugging.
- Either agent can start an Opus, Sonnet, or Haiku logical worker when the
  delegation prompt specifies `GLM_MODEL`.
- A `DONE` or `BLOCKED` turn does not close the worker. Continue it with the
  same bridge agent or its `WORKER_ID`; close it only by explicit request.

Prefer native Claude for connector/MCP work, design or safety rulings, and
changes to this provider wrapper itself. The GLM bridge does not inherit the
parent Claude Code session's connectors, authentication, or MCP tools.

Automatic native fallback is appropriate only when the control fields contain
both `ERROR_KIND=quota-exhausted` and `FALLBACK_RECOMMENDED=true`. Temporary
provider failures, authentication errors, unavailable models, and worker
protocol errors remain visible instead of being hidden by fallback.

## Durable result contract

Each worker turn receives an absolute `GLM_RESULT_FILE` path and the contents
of `system-prompt.md`. The worker must execute and verify the requested work,
write its complete report to that file, read it back, and make its final line
exactly one of:

```text
STATUS: DONE
STATUS: BLOCKED
```

Starting a background process is not completion. A failed Claude invocation,
invalid response, missing result, or malformed final status is classified as
`INVALID`. Raw output remains available for diagnosis.

The system prompt and selected role prompt are read directly from disk at the
start of every turn. Set `GLM_SYSTEM_PROMPT_FILE` or `GLM_ROLE_PROMPTS_DIR` to
use other readable, non-empty Markdown sources.

## Worker state

Worker history is stored under `~/.glm/workers/<worker-id>/`:

```text
meta
task.md
turns/
  0001/
    prompt.md
    response.json
    stderr.log
    result.md
  0002/
    ...
```

`close` only marks a worker closed. It does not remove this directory or any
turn data.

The wrapper stores the selected role and the latest provider classification in
`meta`. Raw response and stderr remain on disk; compact stdout never includes
the Claude session ID.

## Z.ai and Claude Code configuration

The wrapper preserves the verified Z.ai configuration:

- API endpoint: `https://api.z.ai/api/anthropic`
- `haiku`: `glm-5.3-flash[1m]`
- `sonnet`: `glm-5.3[1m]`
- `opus`: `glm-5.3[1m]`
- auto-compact window: `1000000`
- API timeout: `3000000` milliseconds
- nonessential Claude Code traffic disabled
- inherited `CLAUDECODE` removed before invocation

The endpoint and aliases can be overridden with `ZAI_BASE_URL`,
`ZAI_HAIKU_MODEL`, `ZAI_SONNET_MODEL`, `ZAI_OPUS_MODEL`, and `CLAUDE_MODEL`.
`GLM_AGENT_HOME` changes the state directory, which is useful for isolated
tests.

## Security

`start` and `send` invoke Claude Code with
`--dangerously-skip-permissions`. This is required for a headless worker to
edit files and run verification without an interactive approval prompt. Only
start workers in repositories you trust.

Both roles use this mode. Explorer non-modification is a behavioral prompt
contract, not a permission boundary; the parent orchestrator must verify the
working tree for unexpected changes.

The wrapper does not print the API key, and `status` does not expose the Claude
session ID. Avoid committing `~/.glm`, captured worker files, or shell output
that may contain private task data.

## Development

Run the complete test suite:

```bash
bash tests/test_glm_agent.sh
bash tests/test_plugin.sh
```

Run syntax and static checks when `shellcheck` is installed:

```bash
bash -n glm-agent tests/test_glm_agent.sh tests/test_plugin.sh scripts/bump-version.sh
shellcheck glm-agent tests/test_glm_agent.sh tests/test_plugin.sh scripts/bump-version.sh
claude plugin validate --strict .
```

See [AGENTS.md](AGENTS.md) for repository invariants and contribution rules.

## License

[MIT](LICENSE) © 2026 Heejoon Kang
