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

Clone the repository and run the script from the checkout:

```bash
git clone https://github.com/powdream-org/glm-agent.git
/path/to/glm-agent/glm-agent --help
```

To install it elsewhere, copy both `glm-agent` and `system-prompt.md` into the
same directory. The worker prompt is intentionally loaded from the Markdown
file next to the executable on every turn.

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
glm-agent start --cwd /path/to/project \
  "Implement the requested change and run the relevant tests."
```

Successful control-plane output has this shape:

```text
WORKER_ID=20260928T032843Z-15896-30630
TURN=1
STATUS=DONE
RESULT=/Users/example/.glm/workers/20260928T032843Z-15896-30630/turns/0001/result.md
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
| `start [--model <alias>] [--cwd <dir>] <task>` | Create a persistent worker and execute turn 1. |
| `send <worker-id> <message>` | Resume the worker's original session, directory, and model. |
| `result <worker-id>` | Print the latest valid durable result path. |
| `status <worker-id>` | Print compact worker state without exposing the session ID. |
| `list` | List known workers. |
| `close <worker-id>` | Prevent further sends while preserving all worker files. |
| `--help` | Show the complete CLI and worker contract. |
| `--version` | Print the wrapper version. |

The default Claude alias is `sonnet`. `start` accepts another Claude alias via
`--model`; `send` always reuses the value stored when the worker was created.

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

The system prompt is read directly from disk at the start of every turn. Set
`GLM_SYSTEM_PROMPT_FILE` to use another readable, non-empty Markdown file.

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

The wrapper does not print the API key, and `status` does not expose the Claude
session ID. Avoid committing `~/.glm`, captured worker files, or shell output
that may contain private task data.

## Development

Run the complete test suite:

```bash
bash tests/test_glm_agent.sh
```

Run syntax and static checks when `shellcheck` is installed:

```bash
bash -n glm-agent tests/test_glm_agent.sh
shellcheck glm-agent tests/test_glm_agent.sh
```

See [AGENTS.md](AGENTS.md) for repository invariants and contribution rules.

## License

[MIT](LICENSE) © 2026 Heejoon Kang
