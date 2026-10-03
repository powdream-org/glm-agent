---
name: dispatch
description: Use when sending a task to a GLM worker, handing a follow-up to the same worker, or collecting its result, after the provider is already chosen as GLM.
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/glm-dispatch" *)
---

# GLM dispatch

`glm-dispatch` is a script that sends one task to a GLM worker, waits for it, and prints a verdict line.
One call runs the quota gate, starts the worker, verifies the receipt, waits, and reports.
The `GLM_RECEIPT` line it prints is the proof that the worker started.

## When to use

Use this skill after the provider is chosen as GLM. Provider selection happens before it.

- Run `glm-dispatch` instead of the `glm-agent:*` bridge agents.
- Use a bridge agent as the fallback when Bash cannot run the script.
- "Native" below means Claude does the task instead of a GLM worker.

Every subcommand runs as `bash "${CLAUDE_PLUGIN_ROOT}/scripts/glm-dispatch" <subcommand> ...`.
Claude Code substitutes `${CLAUDE_PLUGIN_ROOT}` and `${CLAUDE_SESSION_ID}` in this skill before you read it.

## Prepare

The call needs these inputs.

| Input | Rule |
| --- | --- |
| Brief file | The worker's instructions. The caller writes it. It must be readable, non-empty, and at most 262144 bytes |
| Label | A task name, unique within the session. 1 to 64 characters: letters, digits, `.`, `_`, `-`, starting with a letter or digit |
| Role | `explorer` for read-only investigation, `general-purpose` for implementation |
| Model | `haiku`, `sonnet`, or `opus` |
| Cwd | An existing directory where the worker runs |

- The script passes the whole brief file, line breaks included, as one argument.
  - A brief that starts with `-` works like any other brief.
  - A file over 262144 bytes exits 2 with `glm-dispatch: task-file too large (max 262144 bytes)`.
  - That size check runs before the quota check and before the worker starts.
- A repeated label exits 2 with `glm-dispatch: label already exists`.
- The `explorer` read-only limit is an instruction in the worker's prompt. The script reports violations with `GLM_WARN explorer_modified`.
- `run` takes `--role`, `--model`, and `--cwd` as required flags with no defaults.
  - A missing flag exits 2 with `glm-dispatch: --role is required`. `--model` and `--cwd` use the same form.
  - The role is explicit because the `explorer` limit is only a prompt instruction.

## Run

Start `run` with `--wait` in the background.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/glm-dispatch" run --label <label> --role <role> --model <model> --cwd <dir> --task-file <brief> --session ${CLAUDE_SESSION_ID} --wait
```

- Set the Bash tool to `run_in_background: true` and `timeout: 7200000`.
  - `timeout: 7200000` is the 2-hour Bash maximum. The default is 30 minutes.
  - Measured worker runs took 4.5 to 33 minutes.
- Claude Code notifies you when the command ends. Read the output then.
- The wait always ends: at the worker's end, at `--max-wait`, or at a stall.
- Keep `--max-wait` under 7200 so the script ends before the Bash timeout.
- When the expected duration exceeds 10 minutes, also set a one-shot `CronCreate` timer as a backstop.
  - The timer is a channel separate from the notification.
  - Set it to fire after the expected duration.
  - When it fires before the notification, run `pending`.
- A `run` without `--wait` prints `GLM_RECEIPT` and exits 0. Check it later with `pending`.
- The worker keeps running if the background command dies, because the script starts it detached. Re-arm the wait with `attach`.

Optional flags:

| Flag | Default | Effect |
| --- | --- | --- |
| `--max-wait <s>` | 7000 | Wait ceiling in seconds. At the ceiling the script prints `GLM_STILL_RUNNING`; the worker keeps running |
| `--stall-timeout <s>` | 300 | Seconds without a progress signal before `GLM_STALLED`. 0 turns detection off |
| `--poll-seconds <s>` | 20 | Seconds between the script's internal status checks |
| `--small` | off | Declares the task small and single-turn. Quota row 5 needs it |
| `--est-credits <N>` | none | Expected credit use. Quota row 7 compares it with the remaining quota |
| `--allow-path <glob>` | none | Repo-relative path pattern for expected changes. Repeatable |

Numeric flags take positive integers.

## Read the output

Each event is one stdout line with space-free values. Read every `GLM_` line, then act on it.

| Line | Meaning | Next action |
| --- | --- | --- |
| `GLM_BLOCKED row=<n> reset_at=<UTC or session> scope=<scope>` | The quota gate stopped the run before the worker started | Dispatch to native. Log that GLM is off for this work until `reset_at` |
| `GLM_NOT_REACHED reason=<reason>` | The receipt check failed | Log that GLM was not reached. Read `reason`, then retry once or go native |
| `GLM_RECEIPT label=<l> worker=<id> turn=<n> role=<r> model=<m> cwd=<dir> scope=<s> quota_5h_used=<n> quota_1w_used=<n>` | The worker started. Its `meta` exists, role, model, and cwd match, and `STATUS=RUNNING` | Quote the line verbatim in the work log |
| `GLM_VERDICT ... status=DONE` | The worker finished | Read the result file and check `files_changed` |
| `GLM_VERDICT ... status=BLOCKED` | The worker declared itself blocked | Read the result file and judge |
| `GLM_VERDICT ... status=INVALID class=quota-exhausted` | The quota ran out (`fallback=true`) | Turn GLM off until the quota resets. Native takes over. The worktree changes remain |
| `GLM_VERDICT ... status=INVALID class=worker-protocol` | The turn ended without a valid result file. The work may be done | Read the `--- Response ---` section and judge from it. If the reply says the work is done, or `files_changed` is above 0, verify the result and the diff yourself. The worker may have worked outside `cwd`, in another repository for example, so retry only when no Response section is printed |
| `GLM_VERDICT ... status=INVALID class=<any other>` | Authentication, model, or transient failure | Log the class and ask the user |
| `GLM_STALLED label=<l> worker=<id> idle_seconds=<n>` | No progress signal for `--stall-timeout` seconds | `cancel`, then start again once with the same `--model` under a new label. If it stalls again, report a fault to the user |
| `GLM_STILL_RUNNING label=<l> worker=<id> waited_seconds=<n>` | `--max-wait` was reached and the worker keeps running | Wait again with `attach`, or `cancel` |
| `GLM_WARN explorer_modified files=<list>` | An `explorer` worker changed files | Inspect the listed files. Decide on rollback yourself |
| `GLM_WARN out_of_scope files=<list>` | A changed file matches no `--allow-path` pattern | Inspect the listed files. Decide on rollback yourself |

`GLM_NOT_REACHED` carries one of these reasons: `cli-failed`, `receipt-incomplete`, `meta-missing`, `meta-mismatch`, `not-running`.
A `GLM_NOT_REACHED` run leaves the registry unchanged.

- `GLM_WARN` prints right before `GLM_VERDICT` and leaves the exit code unchanged.
- `GLM_VERDICT` carries `status`, `class`, `result`, `files_changed`, `quota_1w_delta`, and `fallback`.
  - `class` is the worker's `ERROR_KIND`, or `-` when empty.
  - `result` is the absolute path of the result file, or `-`.
  - `files_changed` counts files changed since the start. It is `na` outside a git repository.
  - `quota_1w_delta` includes usage by other sessions on the same key.
- `--- Summary ---` and `--- Remaining Issues ---` blocks follow `GLM_VERDICT`.
  - Each block holds the result file's section, cut to 20 lines with a closing `... (truncated)`.
  - Both blocks are omitted when no result file exists.
  - A `worker-protocol` turn without a result file prints a `--- Response ---` block right after `GLM_VERDICT` instead.
  - That block holds the first 20 lines of the worker's reply, closed by `... (truncated)` when the reply is longer.
  - It prints only when the turn reported no error and the reply is non-empty. `DONE`, `BLOCKED`, and other `INVALID` classes never print it.
- A turn can end `INVALID` with `worker-protocol` after the work is finished. Read the Response section and `files_changed` before you call it a failure.
- `GLM_STALLED` needs the worker's CPU time to be readable. When it cannot be read, the wait runs until `--max-wait` and ends with `GLM_STILL_RUNNING`.
- In `GLM_RECEIPT` and in the registry, each space in `cwd` is written as `%20`.

Exit codes:

| Code | Event |
| --- | --- |
| 0 | `GLM_VERDICT status=DONE`; a `run` or `send` without `--wait` that printed `GLM_RECEIPT`; `pending` |
| 1 | `GLM_VERDICT` with `BLOCKED` or `INVALID`; a refused `ack` or `close` |
| 2 | Argument check failure or usage error: one stderr line `glm-dispatch: <reason>`, no stdout |
| 10 | `GLM_BLOCKED` |
| 11 | `GLM_NOT_REACHED` |
| 12 | `GLM_STALLED` |
| 13 | `GLM_STILL_RUNNING` |

## Follow up

Every subcommand takes `--session ${CLAUDE_SESSION_ID}`. All but `pending` also take `--label <label>`.

| Subcommand | Use | Prints |
| --- | --- | --- |
| `send` | Hand a follow-up to the same worker. Needs `--task-file`; takes `--wait`, `--max-wait`, `--stall-timeout`, `--poll-seconds`, `--allow-path` | A new `GLM_RECEIPT`, or `GLM_NOT_REACHED`. A label that does not exist exits 2 |
| `attach` | Re-arm the wait on a worker. Always waits; takes `--max-wait`, `--stall-timeout`, `--poll-seconds` | The same lines as `run --wait` |
| `pending` | List tasks that are running or finished but not acknowledged | `GLM_PENDING label=<l> worker=<id> state=<running or terminal-unacked> status=<STATUS>`, or `GLM_PENDING none` |
| `ack` | Mark a finished task as read | `GLM_ACK label=<l>`. A running worker gets `GLM_ACK_REFUSED label=<l> reason=running` and exit 1 |
| `status`, `result` | Read the worker's status or result | `LABEL=<label>`, then the CLI output. The exit code is the CLI's |
| `cancel` | Stop a running worker | `LABEL=<label>`, then the CLI output. The exit code is the CLI's |
| `close` | Close a finished worker | A running worker gets `GLM_CLOSE_REFUSED label=<l> reason=running` and exit 1. `cancel` it first |

- `send` repeats the quota gate and the git snapshot, then verifies the receipt for the new turn.
- Start `send --wait` and `attach` with the same Bash settings as `run --wait`. The other subcommands finish quickly; run them in the foreground.
- Run `ack` after you act on a verdict, so `pending` stops listing the task.

## Quota gate

The script applies the `glm-agent:quota` decision table, plus row 7, before it starts a worker.
It reads `glm-agent quota` on every `run` and `send`.
A blocked run prints `GLM_BLOCKED row=<n>` and exits 10. No worker starts.

| Row | Condition | Core output | Your action |
| --- | --- | --- | --- |
| 1 | `QUOTA_STATUS=INVALID` with `ERROR_KIND=authentication`; or the quota command exits with a status other than 0 or 1; or it prints no `QUOTA_STATUS` line | `GLM_BLOCKED row=1` | Go native. Report the failure to the user |
| 2 | `QUOTA_STATUS=INVALID` with `ERROR_KIND=quota-exhausted` | `GLM_BLOCKED row=2 reset_at=session` | Go native. Keep GLM off for the current session |
| 3 | `QUOTA_STATUS=INVALID` with any other `ERROR_KIND` | None. The run goes on (fail-open). `scope` and `quota_*_used` print as `unknown` | None |
| 4 | A limit whose type is not `TIME_LIMIT` has a numeric `REMAINING` of 0 or less | `GLM_BLOCKED row=4 reset_at=<latest RESET_AT, or session if any is empty>` | Go native until `reset_at` |
| 5 | `WINDOW=5h` with `USED_PERCENT>=90`, or `WINDOW=1w` with `USED_PERCENT>=98` | `GLM_BLOCKED row=5` without `--small`. None with `--small` | Pass `--small` for a small, single-turn task. Send multi-turn work to native |
| 6 | Anything else | None. The run goes on | None |
| 7 | `--est-credits N` is given and the `REMAINING` of a `5h` or `1w` limit is below `2N` | `GLM_BLOCKED row=7 reset_at=<that limit's RESET_AT, or session>` | Go native until `reset_at` |

The core checks row 7 before row 5.

## Record

Log every dispatch in the work log (the ledger).

| Event | What you write |
| --- | --- |
| `GLM_RECEIPT` printed | The `GLM_RECEIPT` line, quoted verbatim |
| `GLM_NOT_REACHED` printed | That the task did not reach GLM. Record the native result as native, not as a GLM result |
| `GLM_BLOCKED` printed | That GLM is off for this work until `reset_at` |
| A bridge agent ran the task | The result as GLM work only if the report carries `WORKER_ID`, `TURN`, and `STATUS` receipt fields |

## Do not

- Do not retype the brief into the command. Pass the file with `--task-file`.
- Do not wait with `sleep`, `while` or `until` loops, or file watching. Use `--wait` or `pending`.
- Do not open or print `~/.glm/.env.auth` or `~/.glm/.env.team-scope`. Only the CLI reads them.
- Do not record a worker result as GLM work without its `GLM_RECEIPT` line. Quote the line next to the result.
- Do not `close` a running worker. `cancel` it first.
