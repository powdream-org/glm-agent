# glm-agent

`glm-agent` is a small Bash wrapper for running persistent GLM coding workers
through Claude Code and Z.ai's Anthropic-compatible API.

It is designed for an orchestrator that needs compact control-plane output while
keeping each worker's prompts, durable reports, raw Claude responses, and stderr
on disk. A worker keeps the same Claude session, working directory, and model
across `start`, later `send` calls, and managed native Claude Code TUI
attachments. Headless turns may run synchronously or as detached operations
that remain recoverable by worker ID.

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
bridge agents use native Claude Sonnet as short routing interpreters; the
actual GLM logical model is selected separately for each new worker. Each
interpreter passes `TASK` unchanged through one `glm-agent` CLI call and
returns its control fields as routing evidence.

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

The key is stored at `~/.glm/.env.auth` with mode `0600`. glm-agent reads the
key only from this file; the `ZAI_API_KEY` environment variable is never read.

Passing a key as an argument is supported for automation, but may expose it in
shell history or process listings:

```bash
glm-agent api-key "<key>"
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

## Asynchronous orchestration

Launch a worker without holding the bridge agent open:

```bash
glm-agent start --async --role explorer --model haiku --cwd /path/to/project \
  "Trace the dependency path and write a verified report."
```

`STATUS=RUNNING` is a launch receipt, not task completion. Record the returned
`WORKER_ID`, then observe it with a bounded wait:

```bash
glm-agent wait --timeout 20 <worker-id>
glm-agent status <worker-id>
```

`WAIT_RESULT=TIMEOUT` leaves the worker running. `DONE` or `BLOCKED` is semantic
completion and requires inspecting `RESULT` plus the actual repository state.
Resume the same session asynchronously with:

```bash
glm-agent send --async <worker-id> "Apply the review feedback and rerun tests."
```

Stop an active asynchronous turn explicitly:

```bash
glm-agent cancel <worker-id>
```

Stopping the parent Claude Code turn does not cancel a detached GLM worker.
The parent or a later bridge uses the recorded worker ID to wait, inspect,
continue, or cancel it. Cancellation signals the managed provider process group,
preserves partial artifacts, and records `INVALID/interrupted`.

## Plain Claude Code TUI

Open a plain interactive Z.ai-backed Claude Code session. The session is your
own main conversation: glm-agent creates no worker, injects no worker contract
system prompt, and writes no result files.

```bash
glm-agent tui --model sonnet --cwd /path/to/project
```

The command prints the allocated `SESSION_ID` before the session starts;
reopen that exact session later with:

```bash
glm-agent tui --resume <session-id>
```

`--resume` accepts the session id printed by an earlier `tui` invocation (or
any Claude Code session id). Claude Code has no session-name resume, so pass
the id itself. Worker sessions managed by `start`/`send` are not attachable
through `tui`; use `send` for those.

## Commands

| Command | Purpose |
| --- | --- |
| `api-key [key]` | Store a Z.ai API key, or prompt for it securely. |
| `run <prompt>` | Run a one-shot diagnostic session without creating a worker. |
| `start [--role <role>] [--model <alias>] [--cwd <dir>] <task>` | Create a persistent worker and execute turn 1. |
| `start --async ... <task>` | Create a worker and return its RUNNING receipt before provider completion. |
| `send <worker-id> <message>` | Resume the worker's original session, directory, role, and model. |
| `send --async <worker-id> <message>` | Resume the same session in a detached turn. |
| `wait [--timeout <seconds>] <worker-id>` | Wait up to 0–300 seconds for terminal state. |
| `cancel <worker-id>` | Interrupt an active asynchronous headless turn. |
| `tui [--model <alias>] [--cwd <dir>] [--resume <id>]` | Open a plain interactive Claude Code session (no worker). |
| `result <worker-id>` | Print the latest valid durable result path. |
| `status <worker-id>` | Print compact worker state without exposing the session ID. |
| `list` | List known workers. |
| `close <worker-id>` | Prevent further sends while preserving all worker files. |
| `quota` | Print the Z.ai credit quota per window; creates no worker and starts no Claude session. |
| `team-scope [<organization> <project> \| --clear]` | Show, save, or clear the team-plan quota selectors used by `quota`. |
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
- A routed turn is confirmed by its returned `WORKER_ID`, `TURN`, `STATUS`, and
  `RESULT`. `RUNNING` confirms routing; terminal `DONE|BLOCKED` and the durable
  result confirm semantic completion.
- A `DONE` or `BLOCKED` turn does not close the worker. Continue it with the
  same bridge agent or its `WORKER_ID`; close it only by explicit request.

From the main session, `glm-dispatch` (skill `glm-agent:dispatch`)
is the recommended path to a GLM worker. The bridge agents are not recommended.

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
    mode
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

Asynchronous headless turns also contain `runner.log`. TUI batches contain
`exit.meta` and omit the headless-only `response.json`.

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

## Quota gate

`glm-agent quota` makes one read-only request to Z.ai's monitor API and prints
the credit quota per window. It needs `curl` 7.55 or newer and `jq`, creates no
worker, and starts no Claude session.

```text
QUOTA_STATUS=OK
SCOPE=personal
PLAN_LEVEL=lite
LIMIT_COUNT=2
LIMIT_1_TYPE=CREDIT_LIMIT
LIMIT_1_WINDOW=5h
LIMIT_1_TOTAL=2000
LIMIT_1_USED=1450
LIMIT_1_REMAINING=549
LIMIT_1_USED_PERCENT=72
LIMIT_1_RESET_AT=2026-09-30T18:03:15Z
LIMIT_2_TYPE=CREDIT_LIMIT
LIMIT_2_WINDOW=1w
LIMIT_2_TOTAL=10000
LIMIT_2_USED=7974
LIMIT_2_REMAINING=2025
LIMIT_2_USED_PERCENT=79
LIMIT_2_RESET_AT=2026-10-05T01:12:44Z
RESPONSE=/home/you/.glm/quota/response.json
ERROR_KIND=
PROVIDER_CODE=
```

- The numbers are the server's own; the CLI computes no thresholds.
  `RESET_AT` is UTC, and an empty value means the server did not report it.
- `WINDOW` is `<n>h` for unit 3 and `<n>w` for unit 6. Any other unit prints
  as `u<unit>x<number>`, and `WINDOW` is empty when `unit` or `number`
  is not numeric. The unit codes are inferred from observed responses; Z.ai
  does not document them.
- Exit status 0 means the lookup succeeded, even when `REMAINING` is 0. Exit
  status 1 prints only `QUOTA_STATUS=INVALID`, `SCOPE`, `RESPONSE`,
  `ERROR_KIND` (`authentication`, `quota-exhausted`, `provider-transient`,
  `model-unavailable`, `provider-error`, or `invalid-response`), and
  `PROVIDER_CODE`. Exit status 2 is a usage or setup error.
- `~/.glm/quota/response.json` and `~/.glm/quota/stderr.log` keep the last
  call only.
- The lookup queries the personal coding plan by default (`SCOPE=personal`).
  An account using a GLM Team Plan instead of a personal subscription can
  save the team's organization and project selectors once with
  `glm-agent team-scope <organization> <project>`; `quota` then requests the
  team usage (`SCOPE=team`, `type=2` with Bigmodel selector headers). The
  selectors are copied from the team usage dashboard's
  `api/monitor/usage/quota/limit` request headers in the browser's DevTools.
  The `ZAI_QUOTA_ORGANIZATION` and `ZAI_QUOTA_PROJECT` environment variables
  override the stored values one by one; configuring exactly one selector is
  a setup error.

The plugin ships the `glm-agent:quota` skill. An orchestrator runs it before
dispatching to `glm-agent:explorer` or `glm-agent:general-purpose`:

- Setup errors (exit status 2), any exit status other than 0 or 1, output with
  no `QUOTA_STATUS` line, `authentication` and `quota-exhausted` failures, and
  any non-`TIME_LIMIT` limit whose `REMAINING` is a number ≤ 0 (`REMAINING=0`,
  `0.0`, or `-1`) send the work to native Claude. An exhausted limit with an
  empty `RESET_AT` latches for the current orchestration session.
- `USED_PERCENT>=90` on the 5-hour window or `USED_PERCENT>=98` on the weekly
  window allows only small, bounded, single-turn tasks on GLM. The recognised
  windows are exactly `5h` and `1w`; any other `WINDOW` value is judged by
  `REMAINING` alone and reported as new.
- Any other lookup failure proceeds with GLM (fail-open); the existing
  `quota-exhausted` fallback remains the safety net.

The thresholds live in the skill, not in the CLI.

## Dispatch

`scripts/glm-dispatch` sends one seat to a GLM worker and reports the outcome
as fixed lines. One process checks the quota, starts the worker with
`glm-agent start --async`, verifies the receipt, waits for the turn, and prints
the verdict. The skill `glm-agent:dispatch` tells the main session how to call
it. The script keeps one registry file per label under
`$GLM_AGENT_HOME/dispatch/<session>/` (`~/.glm/dispatch/<session>/` by default)
and never reads the key files; only the CLI does. The environment variable
`GLM_DISPATCH_CLI` replaces the CLI path and exists for the tests.

Call it through Bash with `run_in_background: true` and `timeout: 7200000`:

```text
glm-dispatch run --label fx3-android --role general-purpose --model sonnet \
  --cwd /repo --task-file /tmp/brief.md --session <session-id> --wait
```

| Subcommand | Role |
| --- | --- |
| `run` | Starts a new worker. |
| `send` | Sends a follow-up to the same worker, selected by label, and verifies the new receipt. |
| `attach` | Waits again on the worker of a label, for example after the background process died. |
| `pending` | Lists dispatches of this session that are running or ended without an `ack`. |
| `ack` | Marks a label as confirmed. |
| `status` | Calls the CLI `status` for the label. |
| `result` | Calls the CLI `result` for the label. |
| `cancel` | Calls the CLI `cancel` for the label. |
| `close` | Calls the CLI `close` for the label; a RUNNING worker is refused and `cancel` is the way to stop it. |

`--session` is required. `--label` is required for every subcommand except
`pending`. `run` takes `--role`, `--model`, `--cwd`, `--task-file`, `--wait`,
`--max-wait` (default 7000 seconds), `--stall-timeout` (default 300 seconds,
`0` turns it off), `--poll-seconds` (default 20), `--small`,
`--est-credits <n>`, and a repeatable `--allow-path <glob>`. `send` takes
`--task-file` and the wait options; `attach` takes only the wait options.

| Line | Meaning | Next action |
| --- | --- | --- |
| `GLM_BLOCKED row=N reset_at=... scope=...` | The quota blocks GLM. | Dispatch natively and keep GLM off until `reset_at`. |
| `GLM_NOT_REACHED reason=...` | Receipt verification failed. | Record that GLM was not reached; retry once or go native. |
| `GLM_RECEIPT ...` | The seat reached GLM. | Quote the line in the ledger. |
| `GLM_VERDICT status=DONE` | The worker finished. | Check the result file and `files_changed`. |
| `GLM_VERDICT status=BLOCKED` | The worker declared itself blocked. | Read the result file and decide. |
| `GLM_VERDICT status=INVALID class=quota-exhausted` | The quota ran out during the turn. | Go native after `reset_at`; the working tree changes remain. |
| `GLM_VERDICT status=INVALID class=worker-protocol` | The result contract was violated; the work may be done. | Verify the result and the diff when `files_changed` is above 0; otherwise retry. |
| `GLM_VERDICT status=INVALID class=<other>` | An authentication, model, or transient failure. | Record the class and ask the User. |
| `GLM_WARN explorer_modified files=...` | An explorer changed files. | Inspect the files and decide on rollback. |
| `GLM_WARN out_of_scope files=...` | Files outside every `--allow-path` glob changed. | Inspect the files and decide on rollback. |
| `GLM_STALLED ...` | No progress signal for `--stall-timeout` seconds. | `cancel` and restart once with the same model. |
| `GLM_STILL_RUNNING ...` | `--max-wait` was reached; the worker keeps running. | `attach` again or `cancel`. |

`GLM_VERDICT` is followed by the `# Summary` and `# Remaining Issues` sections
of the result file, each cut at 20 lines.

| Exit code | Line |
| --- | --- |
| 0 | `GLM_RECEIPT` without `--wait`, or `GLM_VERDICT status=DONE` |
| 1 | `GLM_VERDICT` with another status, `GLM_ACK_REFUSED`, `GLM_CLOSE_REFUSED` |
| 2 | Invalid arguments or an unknown label |
| 10 | `GLM_BLOCKED` |
| 11 | `GLM_NOT_REACHED` |
| 12 | `GLM_STALLED` |
| 13 | `GLM_STILL_RUNNING` |

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

`quota` passes the API key to `curl` as a header read from stdin
(`curl -H @-`), so the key never appears in a process argument list. Saved
team-scope selectors travel in the same stdin header block.
`~/.glm/quota/` stores only the response body and curl's stderr.

## Development

Run the complete test suite:

```bash
bash tests/test_glm_agent.sh
bash tests/test_plugin.sh
bash tests/test_dispatch.sh
```

Run syntax and static checks when `shellcheck` is installed:

```bash
bash -n glm-agent scripts/glm-dispatch scripts/lib/dispatch-*.sh tests/*.sh tests/dispatch/*.sh scripts/bump-version.sh
shellcheck --external-sources --source-path=SCRIPTDIR glm-agent scripts/glm-dispatch scripts/lib/dispatch-*.sh tests/*.sh tests/dispatch/*.sh scripts/bump-version.sh
claude plugin validate --strict .
```

See [AGENTS.md](AGENTS.md) for repository invariants and contribution rules.

## License

[MIT](LICENSE) © 2026 Heejoon Kang
