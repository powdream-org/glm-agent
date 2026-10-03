# glm-agent

`glm-agent` runs persistent GLM coding workers through Claude Code and Z.ai's
Anthropic-compatible API. It ships as a Bash CLI and as a Claude Code plugin.

A worker keeps one Claude session, working directory, and model across `start`
and later `send` calls. A headless turn runs synchronously, or as a detached
operation that the worker ID recovers. The CLI prints compact control-plane
output for an orchestrator. Prompts, durable reports, raw Claude responses, and
stderr stay on disk.

| Component | What it does |
| --- | --- |
| `glm-agent` | Creates, resumes, observes, cancels, and closes workers |
| `glm-dispatch` | Sends one task to a worker, waits, and prints a verdict |
| `glm-agent:dispatch` | Skill that tells the main session how to call `glm-dispatch` |
| `glm-agent:quota` | Skill that chooses a GLM worker or native Claude from the Z.ai quota |
| `glm-agent:explorer`, `glm-agent:general-purpose` | Bridge agents that route a task to a worker |

## Requirements

`glm-agent` runs with these tools and credentials:

- Bash 3.2 or newer
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) available as
  `claude`
- `jq`
- `curl` 7.55 or newer, for `glm-agent quota`
- A Z.ai API key
- macOS or a Unix-like environment

## Installation

Install the plugin from the marketplace, or run the CLI from a checkout.

### Claude Code plugin

Add this public repository as a marketplace and install the plugin:

```bash
claude plugin marketplace add powdream-org/glm-agent
claude plugin install glm-agent@glm-agent --scope user
```

The plugin provides the bridge agents `glm-agent:explorer` and
`glm-agent:general-purpose`, the skills `glm-agent:quota` and
`glm-agent:dispatch`, and the script `glm-dispatch`.

### Standalone CLI

Clone the repository and run the script from the checkout:

```bash
git clone https://github.com/powdream-org/glm-agent.git
/path/to/glm-agent/glm-agent --help
```

To install the CLI elsewhere, copy `glm-agent`, `system-prompt.md`, and the
complete `prompts/` directory together. The CLI loads the system prompt and the
role prompts from Markdown files next to the executable on every turn.

## Configure the API key

`glm-agent api-key` stores the Z.ai API key at `~/.glm/.env.auth` with mode
`0600`. Run it without an argument. A hidden interactive prompt keeps the key
out of shell history:

```bash
glm-agent api-key
```

This file is the only key source: `glm-agent` never reads the `ZAI_API_KEY`
environment variable.

Automation can pass the key as an argument. The argument may appear in shell
history or process listings:

```bash
glm-agent api-key "<key>"
```

## Quick start

`start` creates a worker and runs its first turn. Run it for a target
repository:

```bash
glm-agent start --role general-purpose --model sonnet --cwd /path/to/project \
  "Implement the requested change and run the relevant tests."
```

A successful turn prints control fields in this shape:

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

| Field | Value |
| --- | --- |
| `WORKER_ID` | The worker ID that later commands take |
| `TURN` | The turn number |
| `MODEL` | `opus`, `sonnet`, or `haiku` |
| `ROLE` | `explorer` or `general-purpose` |
| `STATUS` | `DONE`, `BLOCKED`, or `INVALID` |
| `RESULT` | The absolute path of the result file |
| `ERROR_KIND` | The failure classification, or empty |
| `PROVIDER_CODE` | The Z.ai error code, or empty |
| `FALLBACK_RECOMMENDED` | `true` or `false` |

`start` takes these options:

| Option | Values | Default |
| --- | --- | --- |
| `--role` | `explorer`, `general-purpose` | `general-purpose` |
| `--model` | `opus`, `sonnet`, `haiku` logical aliases | `sonnet` |
| `--cwd` | An existing directory | The current directory |

`send` always reuses the role, model, and directory that the worker stored at
creation.

Inspect the file that `RESULT` names and the actual repository changes. If the
worker needs a correction, resume the same Claude session:

```bash
glm-agent send 20260928T032843Z-15896-30630 \
  "Fix the failing test, rerun the suite, and update the result."
```

When no more turns are needed, close the worker. Its history stays on disk:

```bash
glm-agent close 20260928T032843Z-15896-30630
```

## Worker results

A worker reports through a result file, and the wrapper turns that file into a
`STATUS`.

| `STATUS` | Meaning |
| --- | --- |
| `DONE` | The worker produced a valid result that ends in `STATUS: DONE` |
| `BLOCKED` | The worker produced a valid result that ends in `STATUS: BLOCKED` |
| `INVALID` | Claude failed, returned malformed data, or violated the result protocol |
| `RUNNING` | A turn is executing, or an external event interrupted it |
| `NEW` | The worker exists and no turn has begun |

Each worker turn receives an absolute `GLM_RESULT_FILE` path and the contents
of `system-prompt.md`. The worker follows these steps:

1. Execute and verify the requested work.
2. Write the complete report to the result file.
3. Read the report back.
4. End the report with exactly one of these two lines:

   ```text
   STATUS: DONE
   STATUS: BLOCKED
   ```

- The system prompt asks for a report with the sections `# Summary`,
  `# Changes`, `# Verification`, and `# Remaining Issues`.
- Starting a background process is not completion.
- The wrapper classifies a failed Claude invocation, an invalid response, a
  missing result, and a malformed final status as `INVALID`.
  - Raw output stays on disk for diagnosis.
- The wrapper reads the system prompt and the selected role prompt from disk at
  the start of every turn.
  - Set `GLM_SYSTEM_PROMPT_FILE` or `GLM_ROLE_PROMPTS_DIR` to use other
    readable, non-empty Markdown sources.

## Run workers asynchronously

`start --async` and `send --async` return a `RUNNING` receipt before the
provider finishes. Launch a worker without holding the bridge agent open:

```bash
glm-agent start --async --role explorer --model haiku --cwd /path/to/project \
  "Trace the dependency path and write a verified report."
```

`STATUS=RUNNING` is a launch receipt, not task completion. Record the returned
`WORKER_ID`, then observe the worker with a bounded wait:

```bash
glm-agent wait --timeout 20 <worker-id>
glm-agent status <worker-id>
```

`--timeout` takes 0 to 300 seconds and defaults to 20. Resume the same session
asynchronously with:

```bash
glm-agent send --async <worker-id> "Apply the review feedback and rerun tests."
```

Stop an active asynchronous turn explicitly:

```bash
glm-agent cancel <worker-id>
```

Each command reports its outcome in one field:

| Field | Meaning | Next action |
| --- | --- | --- |
| `STATUS=RUNNING` | Launch receipt, not completion | Record `WORKER_ID`, then wait |
| `WAIT_RESULT=TIMEOUT` | The bounded wait ended and the worker keeps running | Wait again |
| `WAIT_RESULT=TERMINAL` | The turn reached a terminal status | Read `STATUS` |
| `STATUS=DONE` or `STATUS=BLOCKED` | Semantic completion | Inspect `RESULT` and the actual repository state |
| `CANCEL_RESULT=CANCELLED` or `ALREADY_TERMINAL` | The reported `STATUS` is final | Read `STATUS` |
| `CANCEL_RESULT=PENDING` | The worker has not settled; another party is finalizing it, or a replacement turn started | Retry `cancel`, or wait as for `TIMEOUT` |

Stopping the parent Claude Code turn does not cancel a detached GLM worker.
The parent or a later bridge agent uses the recorded worker ID to wait,
inspect, continue, or cancel it. Cancellation signals the managed provider
process group, preserves partial artifacts, and records `INVALID/interrupted`.

## Open a plain Claude Code session

`glm-agent tui` opens a plain interactive Z.ai-backed Claude Code session. The
session is your own main conversation:

```bash
glm-agent tui --model sonnet --cwd /path/to/project
```

The command prints the allocated `SESSION_ID` before the session starts.
Reopen that exact session later with:

```bash
glm-agent tui --resume <session-id>
```

`--resume` accepts the session ID that an earlier `tui` invocation printed, or
any Claude Code session ID. Claude Code has no session-name resume, so pass the
ID itself.

| Property | Worker (`start`, `send`) | `tui` session |
| --- | --- | --- |
| Worker created | Yes | No |
| Worker contract system prompt | Injected | None |
| Result files | Written | None |
| Resume with | `send <worker-id> <message>` | `tui --resume <session-id>` |

A worker session resumes through `send`, not through `tui`.

## Choose a provider

The orchestrator chooses the provider before it delegates work. Prefer native
Claude for connector/MCP work, design or safety rulings, and changes to this
provider wrapper itself. A GLM worker does not inherit the parent Claude Code
session's connectors, authentication, or MCP tools.

From the main session, `glm-dispatch` (skill `glm-agent:dispatch`)
is the recommended path to a GLM worker. The bridge agents are not recommended.
A bridge agent can read the brief and answer it itself without calling GLM.
A bridge report alone therefore does not prove that a GLM worker ran.
The plugin keeps both bridge agents. Use one only when Bash cannot run
`glm-dispatch`.

- Automatic native fallback is appropriate only when the control fields
  contain both `ERROR_KIND=quota-exhausted` and `FALLBACK_RECOMMENDED=true`.
- Temporary provider failures, authentication errors, unavailable models, and
  worker protocol errors stay visible to the orchestrator.

## Quota gate

`glm-agent quota` makes one read-only request to Z.ai's monitor API and prints
the credit quota per window. The lookup needs `curl` 7.55 or newer and `jq`.
It runs outside any worker and any Claude session.

### Output

A successful lookup prints one `LIMIT_<i>_` group per limit:

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

The CLI prints the server's numbers as reported, and the thresholds live in the
quota skill. `RESET_AT` is UTC. An empty value means the server did not report
it.

`WINDOW` derives from the server's `unit` and `number`:

| Server data | `WINDOW` |
| --- | --- |
| `unit` 3 | `<n>h` |
| `unit` 6 | `<n>w` |
| Any other `unit` | `u<unit>x<number>` |
| `unit` or `number` is not numeric | Empty |

The unit codes are inferred from observed responses. Z.ai does not document
them.

| Exit status | Meaning |
| --- | --- |
| 0 | The lookup succeeded, even when `REMAINING` is 0 |
| 1 | The lookup failed; the output holds only `QUOTA_STATUS=INVALID`, `SCOPE`, `RESPONSE`, `ERROR_KIND`, and `PROVIDER_CODE` |
| 2 | A usage or setup error |

`ERROR_KIND` is one of `authentication`, `quota-exhausted`,
`provider-transient`, `model-unavailable`, `provider-error`, or
`invalid-response`. `~/.glm/quota/response.json` and `~/.glm/quota/stderr.log`
keep the last call only.

### Team plan scope

`quota` queries the personal coding plan by default (`SCOPE=personal`). An
account on a GLM Team Plan saves the team's organization and project selectors
once:

```bash
glm-agent team-scope <organization> <project>
```

- `quota` then requests the team usage (`SCOPE=team`, `type=2` with Bigmodel
  selector headers).
- Copy the selectors from the request headers of `api/monitor/usage/quota/limit`
  on the team usage dashboard, in the browser's DevTools.
- `glm-agent team-scope` without arguments shows the saved scope, and
  `--clear` clears it.
- `ZAI_QUOTA_ORGANIZATION` and `ZAI_QUOTA_PROJECT` override the stored values
  one by one.
- Configuring exactly one selector is a setup error.

### Decision rows

The plugin ships the `glm-agent:quota` skill. An orchestrator runs it before
dispatching to `glm-agent:explorer` or `glm-agent:general-purpose`. The skill
reads the rows from the top and follows the first match:

| Row | Condition | Decision |
| --- | --- | --- |
| 1 | `ERROR_KIND=authentication`, a setup error (exit status 2), any exit status other than 0 or 1, or output with no `QUOTA_STATUS` line | Native Claude |
| 2 | `ERROR_KIND=quota-exhausted` | Native Claude; the reset time is unknown, so latch for the current orchestration session |
| 3 | Any other lookup failure | GLM (fail-open); the `quota-exhausted` fallback remains the safety net |
| 4 | A non-`TIME_LIMIT` limit has a `REMAINING` that is a number ≤ 0 (`REMAINING=0`, `0.0`, or `-1`) | Native Claude; latch until the latest `RESET_AT` of the exhausted limits, then query again. If an exhausted limit has an empty `RESET_AT`, latch for the current orchestration session |
| 5 | `USED_PERCENT>=90` on the 5-hour window, or `USED_PERCENT>=98` on the weekly window | Small, bounded, single-turn tasks on GLM; multi-turn work on native Claude |
| 6 | Anything else | GLM |

- Rows 1, 2, and 4 block GLM completely.
- To latch is to skip GLM and skip further lookups until the stated condition
  ends.
- The recognised windows are exactly `5h` and `1w`. Any other `WINDOW` value is
  judged by `REMAINING` alone and reported as new.
- `TIME_LIMIT` appears to be a separate MCP-usage limit (unverified). Row 4
  ignores it, and the CLI still prints it and counts it in `LIMIT_COUNT`.
- An empty `REMAINING` is never a number ≤ 0.

## Dispatch

`glm-dispatch` sends one task to a GLM worker and reports the outcome as fixed
lines. One process checks the quota, starts the worker with
`glm-agent start --async`, verifies the receipt, waits for the turn, and prints
the verdict. The skill `glm-agent:dispatch` tells the main session how to call
it.

- The script is `scripts/glm-dispatch`.
- It keeps one registry file per label under
  `$GLM_AGENT_HOME/dispatch/<session>/` (`~/.glm/dispatch/<session>/` by
  default).
- Only the CLI reads the key files.
- The environment variable `GLM_DISPATCH_CLI` replaces the CLI path. It exists
  for the tests.

### Run a task

Call `run` through Bash with `run_in_background: true` and `timeout: 7200000`:

```text
glm-dispatch run --label fx3-android --role general-purpose --model sonnet \
  --cwd /repo --task-file /tmp/brief.md --session <session-id> --wait
```

- `timeout: 7200000` is the 2-hour maximum of the Bash tool.
- Keep `--max-wait` under 7200 seconds. The script then ends before the Bash
  timeout.
- Without `--wait`, `run` prints `GLM_RECEIPT` and exits 0. `pending` shows the
  task later.
- The script starts the worker detached, so the worker keeps running when the
  background command ends. `attach` waits on it again.

### Options

| Option | Used by | Default | Effect |
| --- | --- | --- | --- |
| `--session <id>` | Every subcommand | Required | Names the orchestrator session: letters, digits, `.`, `_`, `-` |
| `--label <name>` | Every subcommand except `pending` | Required | Names the task, unique within the session: 1 to 64 characters, letters, digits, `.`, `_`, `-`, starting with a letter or digit. A repeated label exits 2 with `glm-dispatch: label already exists` |
| `--role <role>` | `run` | Required, no default | `explorer` for read-only investigation, `general-purpose` for implementation. A missing value exits 2 |
| `--model <alias>` | `run` | Required, no default | `haiku`, `sonnet`, or `opus`. A missing value exits 2 |
| `--cwd <dir>` | `run` | Required, no default | An existing directory where the worker runs. A missing value exits 2 |
| `--task-file <path>` | `run`, `send` | Required | The worker's instructions: a readable, non-empty file of at most 262144 bytes |
| `--wait` | `run`, `send` | Off | Waits for the turn and prints the verdict. `attach` always waits |
| `--max-wait <s>` | `run`, `send`, `attach` | 7000 | Wait ceiling in seconds, 1 or more. At the ceiling the script prints `GLM_STILL_RUNNING` and the worker keeps running |
| `--stall-timeout <s>` | `run`, `send`, `attach` | 300 | Seconds without a progress signal before `GLM_STALLED`. `0` turns detection off |
| `--poll-seconds <s>` | `run`, `send`, `attach` | 20 | Seconds between the script's internal status checks, 1 to 300 |
| `--small` | `run` | Off | Declares the task small and single-turn. Quota row 5 needs it |
| `--est-credits <n>` | `run` | None | Expected credit use, 1 or more. Quota row 7 compares it with the remaining quota |
| `--allow-path <glob>` | `run`, `send` | None | A repo-relative path pattern for expected changes. Repeatable |

### Subcommands

| Subcommand | What it does | Prints |
| --- | --- | --- |
| `run` | Starts a new worker. | `GLM_RECEIPT`; with `--wait`, the verdict lines follow |
| `send` | Sends a follow-up to the same worker, selected by label, and verifies the new receipt. | A new `GLM_RECEIPT`, or `GLM_NOT_REACHED`; with `--wait`, the verdict lines follow |
| `attach` | Waits again on the worker of a label, for example after the background process died. | `GLM_VERDICT`, `GLM_STALLED`, or `GLM_STILL_RUNNING` |
| `pending` | Lists dispatches of this session that are running or ended without an `ack`. | `GLM_PENDING label=<l> worker=<id> state=<running or terminal-unacked> status=<STATUS>` per task, or `GLM_PENDING none` |
| `ack` | Marks a label as confirmed. | `GLM_ACK label=<l>`; a worker that has not finished gets `GLM_ACK_REFUSED` and exit 1 |
| `status` | Calls the CLI `status` for the label. | `LABEL=<label>`, then the CLI output |
| `result` | Calls the CLI `result` for the label. | `LABEL=<label>`, then the CLI output |
| `cancel` | Calls the CLI `cancel` for the label. | `LABEL=<label>`, then the CLI output |
| `close` | Calls the CLI `close` for the label; a RUNNING worker is refused and `cancel` is the way to stop it. | The CLI output, or `GLM_CLOSE_REFUSED label=<l> reason=running` and exit 1 |

Every subcommand except `run` and `pending` selects the worker by label. A
label that does not exist exits 2. `send` repeats the quota gate and the git
snapshot before it starts the new turn. `status`, `result`, and `cancel` exit
with the CLI's exit code.

### Quota rows in dispatch

`run` and `send` apply the quota decision rows before they start a worker. A
blocked call prints `GLM_BLOCKED row=<n>`, exits 10, and starts no worker.

| Row | Condition | `reset_at` |
| --- | --- | --- |
| 1 | Authentication failure, any exit status other than 0 or 1, or output with no `QUOTA_STATUS` line | `session` |
| 2 | `ERROR_KIND=quota-exhausted` | `session` |
| 4 | A non-`TIME_LIMIT` limit has a numeric `REMAINING` of 0 or less | The latest `RESET_AT`, or `session` if any is empty |
| 5 | `USED_PERCENT>=90` on `5h` or `USED_PERCENT>=98` on `1w`, without `--small` | The latest `RESET_AT`, or `session` if any is empty |
| 7 | `--est-credits N` is given and the `REMAINING` of a `5h` or `1w` limit is below `2N` | The latest `RESET_AT` of those limits, or `session` if any is empty |

Row 7 is checked before row 5. Any other lookup failure (row 3) lets the call
go on, with `scope` and `quota_*_used` printed as `unknown`.

### Output lines

`glm-dispatch` prints one line per event, with space-free values. Read every
`GLM_` line and act on it:

| Line | Meaning | Next action |
| --- | --- | --- |
| `GLM_BLOCKED row=N reset_at=... scope=...` | The quota blocks GLM; the worker did not start. | Dispatch natively and keep GLM off until `reset_at`. |
| `GLM_NOT_REACHED reason=...` | Receipt verification failed. | Record that GLM was not reached; retry once or go native. |
| `GLM_RECEIPT label=<l> worker=<id> turn=<n> role=<r> model=<m> cwd=<dir> scope=<s> quota_5h_used=<n> quota_1w_used=<n>` | The worker started: its `meta` exists, role, model, and cwd match, and `STATUS=RUNNING`. | Quote the line in the work log. |
| `GLM_WARN explorer_modified files=...` | An explorer changed files. | Inspect the files and decide on rollback. |
| `GLM_WARN out_of_scope files=...` | Files outside every `--allow-path` glob changed. | Inspect the files and decide on rollback. |
| `GLM_VERDICT status=DONE` | The worker finished. | Check the result file and `files_changed`. |
| `GLM_VERDICT status=BLOCKED` | The worker declared itself blocked. | Read the result file and decide. |
| `GLM_VERDICT status=INVALID class=quota-exhausted` | The quota ran out during the turn (`fallback=true`). | Turn GLM off until the quota resets and go native; the working tree changes remain. |
| `GLM_VERDICT status=INVALID class=worker-protocol` | The result contract was violated; the work may be done, possibly in another repository. | Read the `--- Response ---` section and decide. Verify the result and the diff when the reply reports completion or `files_changed` is above 0. `files_changed=0` alone does not justify a retry; retry only when no response section prints. |
| `GLM_VERDICT status=INVALID class=<other>` | An authentication, model, or transient failure. | Record the class and ask the user. |
| `GLM_STALLED label=<l> worker=<id> idle_seconds=<n>` | No progress signal for `--stall-timeout` seconds. | `cancel`, then start again once with the same model under a new label. |
| `GLM_STILL_RUNNING label=<l> worker=<id> waited_seconds=<n>` | `--max-wait` was reached; the worker keeps running. | `attach` again or `cancel`. |

- The `GLM_RECEIPT` line is the proof that the worker started.
- `GLM_NOT_REACHED` carries one reason: `cli-failed`, `receipt-incomplete`,
  `meta-missing`, `meta-mismatch`, or `not-running`. A `GLM_NOT_REACHED` call
  leaves the registry unchanged.
- `GLM_WARN` prints right before `GLM_VERDICT` and leaves the exit code
  unchanged.

`GLM_VERDICT` carries these fields:

| Field | Value |
| --- | --- |
| `label`, `worker` | The label and the worker ID |
| `status` | `DONE`, `BLOCKED`, or `INVALID` |
| `class` | The worker's `ERROR_KIND`, or `-` when empty |
| `result` | The absolute path of the result file, or `-` |
| `files_changed` | The count of files changed since the start; `na` outside a git repository |
| `quota_1w_delta` | The change in the weekly `USED` value since the start (`+n`, `-n`, `0`, or `unknown`), including usage by other sessions on the same key |
| `fallback` | `true` when the CLI reports `FALLBACK_RECOMMENDED=true`, otherwise `false` |

Blocks follow `GLM_VERDICT`:

- `--- Summary ---` and `--- Remaining Issues ---` hold the `# Summary` and
  `# Remaining Issues` sections of the result file. Each block is cut at 20
  lines and ends with `... (truncated)` when cut.
- Both blocks are omitted when no result file exists.
- When a `worker-protocol` turn has no result file, a `--- Response ---` block
  follows `GLM_VERDICT`.
  - The block holds the first 20 lines of the worker reply and ends with
    `... (truncated)` when cut.
  - It prints only when `jq` is available and the turn's `response.json` has
    `is_error` false and a non-blank string `.result`.

| Exit code | Line |
| --- | --- |
| 0 | `GLM_RECEIPT` without `--wait`, `GLM_VERDICT status=DONE`, `pending`, or a successful `ack` |
| 1 | `GLM_VERDICT` with another status, `GLM_ACK_REFUSED`, `GLM_CLOSE_REFUSED` |
| 2 | Invalid arguments or an unknown label: one stderr line `glm-dispatch: <reason>`, no stdout |
| 10 | `GLM_BLOCKED` |
| 11 | `GLM_NOT_REACHED` |
| 12 | `GLM_STALLED` |
| 13 | `GLM_STILL_RUNNING` |

### Known limits

- A task file that starts with `-` is sent behind one newline byte. The CLI then
  reads the file as the task, not as an option.
- A task file larger than 262144 bytes exits 2 before any quota check.
- A `cwd` that contains spaces is written with each space as `%20` in
  `GLM_RECEIPT` and in the registry file.
- Stall detection compares the CPU time of the worker's process group. It runs
  only when that CPU time is readable. Otherwise the wait runs until
  `--max-wait` and ends with `GLM_STILL_RUNNING`.
- `files_changed` counts an untracked directory as one entry. It does not
  detect further edits to a file that was already modified when the worker
  started.

## Bridge agents

`glm-agent:explorer` and `glm-agent:general-purpose` are bridge agents. Each
one is a short routing interpreter on native Claude Sonnet. It passes `TASK`
unchanged through one `glm-agent` CLI call and returns the control fields as
routing evidence. The GLM logical model is selected separately for each new
worker.

| Agent | Default logical model | Use for |
| --- | --- | --- |
| `glm-agent:explorer` | Haiku, mapped to `glm-5.3-flash[1m]` | Codebase search, dependency tracing, and evidence collection |
| `glm-agent:general-purpose` | Sonnet | Bounded implementation, refactoring, testing, and debugging |

- Either agent starts an Opus, Sonnet, or Haiku logical worker when the
  delegation prompt specifies `GLM_MODEL`.
- The returned `WORKER_ID`, `TURN`, `STATUS`, and `RESULT` confirm a routed
  turn. `RUNNING` confirms routing; terminal `DONE|BLOCKED` and the durable
  result confirm semantic completion.
- A `DONE` or `BLOCKED` turn leaves the worker open. Continue it with the same
  bridge agent or its `WORKER_ID`. Close it only by explicit request.

A delegation prompt names an `ACTION`:

| `ACTION` | Required fields | CLI call |
| --- | --- | --- |
| `start` | `CWD`, `TASK` | `start --async --role <the agent's role> --model "$GLM_MODEL" --cwd "$CWD" "$TASK"` |
| `send` | `WORKER_ID`, `TASK` | `send --async "$WORKER_ID" "$TASK"` |
| `wait` | `WORKER_ID` | `wait --timeout 20 "$WORKER_ID"` |
| `status`, `result`, `cancel`, `close` | `WORKER_ID` | The CLI command of the same name |

`GLM_MODEL` accepts `opus`, `sonnet`, and `haiku`. When it is absent, `start`
uses `haiku` for `glm-agent:explorer` and `sonnet` for
`glm-agent:general-purpose`. A request with a missing field, an unsupported
`ACTION`, or another `GLM_MODEL` value returns `PROVIDER=glm`,
`BRIDGE_STATUS=INVALID_REQUEST`, and `DETAIL=<missing or invalid field>`.

## Command reference

| Command | What it does |
| --- | --- |
| `api-key [key]` | Store a Z.ai API key, or prompt for it securely. |
| `run <prompt>` | Run a one-shot diagnostic session without creating a worker. |
| `start [--role <role>] [--model <alias>] [--cwd <dir>] <task>` | Create a persistent worker and execute turn 1. |
| `start --async ... <task>` | Create a worker and return its RUNNING receipt before provider completion. |
| `send <worker-id> <message>` | Resume the worker's original session, directory, role, and model. |
| `send --async <worker-id> <message>` | Resume the same session in a detached turn. |
| `wait [--timeout <seconds>] <worker-id>` | Wait up to 0–300 seconds for terminal state; the default is 20. |
| `cancel <worker-id>` | Interrupt an active asynchronous headless turn. |
| `tui [--model <alias>] [--cwd <dir>] [--resume <id>]` | Open a plain interactive Claude Code session (no worker). |
| `result <worker-id>` | Print the latest valid durable result path. |
| `status <worker-id>` | Print compact worker state without exposing the session ID. |
| `list` | List known workers. |
| `close <worker-id>` | Prevent further sends while preserving all worker files. |
| `quota` | Print the Z.ai credit quota per window, outside any worker and any Claude session. |
| `team-scope [<organization> <project> \| --clear]` | Show, save, or clear the team-plan quota selectors used by `quota`. |
| `--help` | Show the complete CLI and worker contract. |
| `--version` | Print the wrapper version. |

| Exit status | Meaning |
| --- | --- |
| 0 | The command succeeded. `DONE` and `BLOCKED` are both successful turns |
| 1 | The Claude invocation or the worker result protocol failed (`STATUS=INVALID`) |
| 2 | Invalid CLI usage, configuration, dependency, or worker state |

## Worker state

Worker history lives under `~/.glm/workers/<worker-id>/`:

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

- The wrapper stores the selected role and the latest provider classification
  in `meta`.
- Raw response and stderr stay on disk. Compact stdout carries no Claude
  session ID.
- Asynchronous headless turns also contain `runner.log`.
- `close` only marks a worker closed. The directory and all turn data stay.

## Configuration

The wrapper preserves the verified Z.ai configuration:

| Setting | Value |
| --- | --- |
| API endpoint | `https://api.z.ai/api/anthropic` |
| `haiku` | `glm-5.3-flash[1m]` |
| `sonnet` | `glm-5.3[1m]` |
| `opus` | `glm-5.3[1m]` |
| Auto-compact window | `1000000` |
| API timeout | `3000000` milliseconds |
| Nonessential Claude Code traffic | Disabled |
| Inherited `CLAUDECODE` | Removed before invocation |

These environment variables change the defaults:

| Variable | Effect |
| --- | --- |
| `ZAI_BASE_URL` | Overrides the API endpoint |
| `ZAI_HAIKU_MODEL`, `ZAI_SONNET_MODEL`, `ZAI_OPUS_MODEL` | Override the model that each logical alias maps to |
| `CLAUDE_MODEL` | Sets the default logical alias for `run`, `start`, and `tui`; the default is `sonnet` |
| `GLM_AGENT_HOME` | Changes the state directory, which is useful for isolated tests |
| `GLM_SYSTEM_PROMPT_FILE` | Names the system prompt Markdown file; the default is `system-prompt.md` next to the executable |
| `GLM_ROLE_PROMPTS_DIR` | Names the directory with `explorer.md` and `general-purpose.md`; the default is `prompts/` next to the executable |
| `ZAI_QUOTA_ORGANIZATION`, `ZAI_QUOTA_PROJECT` | Override the stored team-scope selectors one by one |
| `GLM_DISPATCH_CLI` | Replaces the CLI path in `glm-dispatch`; it exists for the tests |

## Security

`start` and `send` invoke Claude Code with `--dangerously-skip-permissions`.
A headless worker needs this mode to edit files and run verification without
an interactive approval prompt. `tui` passes the same flag. Start workers only
in repositories you trust.

- Both roles run in this mode. The `explorer` read-only limit is a behavioral
  prompt contract, and the permission mode allows edits. The parent
  orchestrator must verify the working tree for unexpected changes.
- The wrapper never prints the API key, and `status` does not expose the Claude
  session ID.
- `~/.glm` has mode `0700` and `~/.glm/.env.auth` has mode `0600`.
- Keep `~/.glm`, captured worker files, and shell output that may contain
  private task data out of commits.
- `quota` passes the API key to `curl` as a header read from stdin
  (`curl -H @-`).
  - The key never appears in a process argument list.
  - Saved team-scope selectors travel in the same stdin header block.
- `~/.glm/quota/` stores only the response body and curl's stderr.

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
