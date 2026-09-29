# glm-agent TUI and asynchronous worker supervision design

Date: 2026-09-29
Status: Proposed for user review
Target release: 0.4.0

## 1. Intent

`glm-agent` will support two additional operating styles while preserving one
Claude session per worker:

1. A person can start a new Z.ai-backed Claude Code TUI or enter an existing
   worker's exact session.
2. Claude Code orchestrators can launch a headless turn asynchronously, receive
   its worker identity immediately, and recover the terminal result even when
   the short-lived bridge agent disappears.

The TUI and headless paths share authentication, model aliases, role prompts,
working-directory ownership, session persistence, and worker state. They differ
only in presentation and turn artifacts.

## 2. Observed failure and root cause

The current plugin bridge calls synchronous `glm-agent start` or `send` and
returns only after the nested GLM Claude process exits. `start` creates the
worker directory before invoking Claude, but prints `WORKER_ID` only after the
turn reaches a terminal state.

This creates a blind interval:

```text
bridge starts
  -> worker exists on disk
  -> nested provider call blocks or retries
  -> bridge has not returned WORKER_ID
  -> bridge is terminated
  -> parent has no worker identity to query
```

A diagnostic call remained open for more than two minutes without a terminal
provider response. The configured `API_TIMEOUT_MS=3000000` permits a provider
request to remain open for up to 50 minutes, longer than a bridge-agent seat may
survive. The wrapper also currently classifies provider codes only on non-zero
Claude process exits; a zero exit containing `is_error=true` falls through to a
generic worker-protocol error.

The root problem is therefore synchronous identity delivery combined with
incomplete normalization of provider error shapes. Prompt wording alone cannot
make a terminated bridge deliver a final message.

## 3. Goals

- Start a full Claude Code TUI through the verified Z.ai environment.
- Resume an existing worker TUI in its stored cwd, role, model, and Claude
  session.
- Make every new TUI session a managed worker so it can later be resumed from
  either the TUI or headless `send` path.
- Return a durable worker receipt before an asynchronous provider call can
  block.
- Preserve the distinction between `RUNNING` and semantic completion.
- Allow any later bridge invocation to recover status by `WORKER_ID`.
- Normalize quota and provider errors from both process failures and successful
  process exits carrying error JSON.
- Preserve raw headless artifacts and a durable report for each TUI attachment.
- Keep implementation in the existing Bash CLI and filesystem protocol.

## 4. Non-goals

- No MCP server, daemon, database, or remote coordinator.
- No push-notification service from the wrapper to Claude Code.
- No emulation of the Claude Code TUI inside Bash.
- No dependency on Claude Code's private transcript-file layout.
- No automatic deletion of workers or history.
- No automatic native-provider fallback inside the CLI. Provider selection and
  fallback remain orchestrator responsibilities.

## 5. Command surface

### 5.1 Managed TUI

```text
glm-agent tui [--role <role>] [--model <alias>] [--cwd <directory>]
glm-agent tui <worker-id>
```

With no worker ID, `tui` creates a managed worker, allocates a Claude session
ID, prints a compact pre-launch receipt, and opens the native Claude Code TUI.
Defaults remain role `general-purpose`, model `sonnet`, and the current
directory.

With a worker ID, `tui` reads the stored cwd, role, model, and Claude session.
The caller's cwd has no effect. `--cwd`, `--role`, and `--model` are creation
options and are invalid when attaching to an existing worker. A missing stored
cwd is an explicit CLI error; the wrapper does not substitute the caller's
directory.

The wrapper launches the TUI in a subshell, so the user's shell returns to its
original cwd after the TUI exits.

```text
caller cwd=/tmp
worker cwd=/project/worktree-a

glm-agent tui <worker-id>
  -> child process cwd=/project/worktree-a
  -> stored model, role, and session are resumed
  -> caller remains in /tmp after exit
```

The TUI uses the same Z.ai endpoint, aliases, API timeout, compact window,
nonessential-traffic setting, `CLAUDECODE` removal, and dangerous permission
mode as headless workers.

### 5.2 Asynchronous headless turns

```text
glm-agent start --async [--role <role>] [--model <alias>]
  [--cwd <directory>] <task>
glm-agent send --async <worker-id> <message>
glm-agent wait [--timeout <seconds>] <worker-id>
glm-agent cancel <worker-id>
```

Synchronous `start` and `send` remain available for scripts and backward
compatibility. `--async` changes only process supervision and the timing of the
first response; it uses the same turn execution and validation code.

An asynchronous launch returns after the detached per-turn runner has been
created:

```text
WORKER_ID=<id>
TURN=<number>
MODEL=opus|sonnet|haiku
ROLE=explorer|general-purpose
STATUS=RUNNING
RESULT=<expected-absolute-result-path>
ERROR_KIND=
PROVIDER_CODE=
FALLBACK_RECOMMENDED=false
```

`STATUS=RUNNING` is a launch receipt, not task completion. The existing rule
that background-process startup is not completion remains unchanged.

`wait` observes the worker's filesystem state. It returns terminal control
fields as soon as the active turn reaches `DONE`, `BLOCKED`, or `INVALID`.
The default timeout is 20 seconds; explicit values are integer seconds from 0
through 300. A wait timeout returns the current `STATUS=RUNNING` fields and
`WAIT_RESULT=TIMEOUT`; the worker continues. Plugin bridge agents use the
20-second default. `status` remains an immediate, non-waiting snapshot.

`cancel` is an explicit operator action for an active asynchronous headless
turn. It signals the detached runner, waits a bounded interval for artifact
finalization, and records `STATUS=INVALID` with `ERROR_KIND=interrupted` when
the turn does not already have a terminal state. TUI sessions are exited from
their owning terminal rather than through `cancel`.

## 6. Custom-agent protocol

`glm-agent:explorer` and `glm-agent:general-purpose` use asynchronous headless
commands for `start` and `send`:

```text
ACTION=start -> glm-agent start --async ... -> return routing receipt
ACTION=send  -> glm-agent send --async ...  -> return routing receipt
ACTION=wait  -> glm-agent wait --timeout 20 <worker-id>
ACTION=status/result/cancel/close -> matching CLI command
```

The routing interpreter completes `start` and `send` when it has returned a
valid `WORKER_ID`, `TURN`, and `STATUS=RUNNING` receipt. The parent
orchestrator records the ID before monitoring. Completion is accepted only
after `wait` or `status` returns `DONE` or `BLOCKED` and the parent verifies the
durable result.

If a bridge invocation ends during a later `wait`, the parent already owns the
worker ID and can issue `wait` or `status` through a fresh bridge. Bridge-agent
identity is optional; worker identity is authoritative.

`my-superpowers` will use this lifecycle:

1. Dispatch one Sonnet routing interpreter with `ACTION=start` or `send`.
2. Record the returned worker ID, turn, cwd, role, and logical model.
3. Monitor with bounded `ACTION=wait` calls or status snapshots.
4. On terminal success, verify `RESULT` and repository state.
5. On `quota-exhausted`, latch Z.ai unavailability for the current
   orchestration and redispatch the same logical model tier to native Claude.

## 7. Worker concurrency and ownership

One worker may have at most one active headless turn or TUI attachment. An
atomic directory lock under the worker directory records active mode, turn,
runner PID, and start time. `mkdir` provides the portable exclusion primitive
for macOS Bash 3.2.

- `send`, `send --async`, and `tui <worker-id>` reject a live lock.
- `close` rejects a live lock and preserves all files.
- `cancel` applies to an asynchronous headless lock and preserves its partial
  artifacts.
- `status` reports `ACTIVE_MODE=headless|tui` and `ACTIVE_TURN` while running.
- The per-turn runner removes its lock through an exit trap.
- A lock whose recorded process is gone is finalized as `STATUS=INVALID` with
  `ERROR_KIND=interrupted`; its artifacts remain and the worker becomes
  available for a later turn.

The CLI, rather than the bridge custom agent, owns process detachment. After
preparing the turn, `start --async` and `send --async` launch an internal
one-turn runner with the equivalent of:

```sh
nohup glm-agent _execute-turn WORKER_ID TURN \
  </dev/null >TURN_DIR/runner.log 2>&1 &
```

The wrapper records the returned PID before emitting the control-plane
receipt. All three standard streams are disconnected from the invoking Bash
tool, and `nohup` protects the runner from the normal hangup caused when that
tool or its parent `claude -p` exits. The custom agent therefore invokes only
`glm-agent start --async` or `glm-agent send --async`; it does not background a
foreground `glm-agent` or `claude -p` command itself.

The detached runner receives only worker ID and turn number on its command
line. The task body is read from the already-private `prompt.md`, keeping long
or sensitive prompts out of process listings. The operating system may adopt
the process after its parent exits. The runner redirects its own control output
to the turn directory and exits after one turn; it is not a daemon and no
bridge process remains open merely to keep it alive.

## 8. Turn preparation and execution

The existing `run_turn()` mixes allocation, execution, and finalization. It
will be split into shared stages used by synchronous and asynchronous paths:

```text
prepare_turn(worker, prompt, mode)
  -> validate state and acquire lock
  -> allocate turn number and directory
  -> write prompt and RUNNING metadata
  -> return turn paths

execute_headless_turn(worker, turn)
  -> read prepared prompt and stored worker configuration
  -> invoke Claude
  -> preserve response and stderr
  -> normalize provider result
  -> validate result.md
  -> finalize metadata and release lock

launch_async_turn(worker, turn)
  -> detach execute_headless_turn
  -> store runner identity
  -> return RUNNING receipt
```

The synchronous path calls preparation and execution in the foreground. The
asynchronous path calls the same preparation function, launches exactly the
same executor, and returns the receipt.

## 9. TUI lifecycle and durable interactive batches

Every TUI open/close interval is one interactive batch associated with the
worker's next sequence number. It may contain multiple human messages and
assistant responses in the native Claude Code UI.

### 9.1 New TUI worker

The wrapper:

1. validates dependencies, credentials, role, model, and cwd;
2. creates the worker and allocates a UUID-format Claude session ID;
3. stores the session ID privately in metadata;
4. allocates the interactive batch and `GLM_RESULT_FILE`;
5. prints `WORKER_ID`, model, role, cwd, and `STATUS=RUNNING` before entering
   the TUI;
6. launches native Claude with `--session-id` in the selected cwd;
7. validates the latest durable report when the TUI exits.

### 9.2 Existing worker TUI

The wrapper validates that the worker is open, idle, has a stored Claude
session ID, and still has its original cwd. It acquires the worker lock and
launches native Claude with `--resume <stored-session-id>` inside the stored
cwd. It uses the stored model and role without accepting replacements.

### 9.3 Interactive artifacts

Headless turns retain the existing files:

```text
turns/NNNN/
  mode                 # headless
  prompt.md
  response.json
  stderr.log
  result.md
```

Interactive batches use mode-specific artifacts:

```text
turns/NNNN/
  mode                 # tui
  prompt.md             # launch context, not the human transcript
  stderr.log
  result.md
  exit.meta             # start/end time and Claude exit status
```

The native Claude session remains the authoritative conversational transcript
and is resumed by its private session ID. Version 0.4.0 does not copy Claude
Code's private transcript files or wrap the TUI in a pseudo-terminal recorder.
The durable `result.md` is the wrapper-owned summary and handoff artifact.

The appended system prompt gives the interactive batch one absolute
`GLM_RESULT_FILE` and asks the worker to refresh it after each completed user
request. On TUI exit, a valid final marker yields `DONE` or `BLOCKED`. A missing
or malformed report yields `INVALID` while retaining the previous canonical
valid result path.

## 10. Provider and quota error normalization

All Claude invocations are normalized before session or result validation:

1. inspect process exit status;
2. parse JSON when output is JSON;
3. inspect `is_error`, subtype, result text, response error objects, and
   stderr;
4. extract the Z.ai provider code from every available error surface;
5. classify the error and persist it in worker metadata;
6. finalize the active turn and release its lock.

This order handles both non-zero exits and exit-zero responses containing
`is_error=true`. Known Z.ai quota codes continue to produce:

```text
STATUS=INVALID
ERROR_KIND=quota-exhausted
PROVIDER_CODE=<code>
FALLBACK_RECOMMENDED=true
```

Unknown provider errors remain visible as provider errors and retain raw
artifacts. New Lite-plan quota codes are added only after capture from a real
response or authoritative Z.ai documentation; generic HTTP 429 remains
insufficient evidence for automatic fallback.

## 11. Failure and recovery semantics

- A normally exiting routing interpreter, Bash tool, or parent `claude -p`
  does not terminate a successfully detached GLM turn.
- Detachment is not a guarantee against an explicit process-tree kill, host
  shutdown, or reboot. Those cases leave a detectable stale lock and are
  recovered as interrupted work.
- A terminated bounded `wait` loses no worker identity or state.
- A runner that reaches a provider error persists terminal metadata before
  exiting.
- A runner killed before finalization leaves a detectable stale lock and
  `RUNNING` turn; the next `status` or `wait` finalizes it as interrupted rather
  than claiming completion.
- `cancel` provides explicit recovery for a live asynchronous runner that is
  stuck or no longer useful.
- `result` continues to return only the latest valid durable report.
- A failed turn or TUI batch does not erase an earlier valid result.
- `close` remains explicit and history-preserving.

## 12. Security

- API keys and Claude session IDs remain absent from normal stdout.
- Worker and turn files retain private directory and file modes.
- Prompts are stored in private files and omitted from detached-runner argv.
- TUI mode runs only in a user-selected new cwd or a validated stored worker
  cwd.
- Existing dangerous permission behavior is clearly displayed in help before
  launching a TUI.
- Raw provider responses and stderr remain on disk instead of being relayed by
  bridge agents.

## 13. Testing strategy

Hermetic fake-Claude tests cover:

- new TUI creation with an assigned session ID and selected cwd/model/role;
- existing TUI resume from a different caller cwd;
- rejection of attach-time cwd/model/role overrides;
- missing stored cwd and missing session handling;
- TUI batch result validation and lock release;
- async start returning `RUNNING` before fake Claude completes;
- async send preserving the original session, cwd, role, and model;
- detached runner survival after its launching shell and parent bridge exit,
  with stdin closed and every output stream redirected;
- regression rejection of an implementation that merely appends `&` while
  leaving inherited bridge pipes open;
- one-active-operation lock enforcement and stale-lock recovery;
- bounded wait terminal and timeout responses;
- cancellation and stale-runner interruption finalization;
- close rejection while active and history preservation afterward;
- quota classification for non-zero exits and exit-zero error JSON;
- API key and session ID non-disclosure in every control response;
- synchronous start/send regression coverage.

Plugin tests cover the positive custom-agent state machine for asynchronous
start/send and bounded wait. A live release smoke test creates one asynchronous
explorer worker, receives its ID immediately, observes terminal completion,
opens and exits its TUI from a different caller cwd, then resumes one headless
turn in the same session. The test records no API key or Claude session ID.

## 14. Alternatives considered

### A. Raw unmanaged TUI

Directly executing Z.ai-backed Claude is small, but creates no worker identity,
cannot be attached through the existing lifecycle, and provides no durable
result for recovery. Rejected.

### B. TUI-only session with no wrapper artifacts

This preserves Claude's transcript but leaves `status` and `result` unaware of
interactive work. A later headless `send` would resume context that the worker
ledger does not describe. Rejected.

### C. Synchronous custom-agent bridge with stronger prompt wording

A terminated process cannot return a final message regardless of prompt
quality. It also leaves the parent without a worker ID during the longest and
least reliable interval. Rejected.

### D. Managed TUI plus asynchronous receipts and bounded monitoring

This preserves a single session across human and orchestrated use, gives the
parent a durable recovery key before provider work, and keeps completion
evidence separate from launch evidence. Selected.

## 15. Acceptance criteria

- `glm-agent tui` opens the native Claude Code TUI as a new managed worker.
- `glm-agent tui <worker-id>` opens the same Claude session in the worker's
  stored cwd, independent of the caller's cwd.
- TUI exit leaves a durable interactive batch and terminal worker status.
- `start --async` and `send --async` return a worker receipt before provider
  completion.
- Their detached runner continues after the invoking Bash tool and parent
  `claude -p` exit normally; no bridge process is kept alive for supervision.
- The plugin custom agents use asynchronous start/send and return the receipt
  immediately.
- A later bridge can recover any launched worker using only `WORKER_ID`.
- `wait` is bounded and distinguishes timeout from semantic completion.
- `cancel` preserves partial artifacts and returns the worker to an idle,
  terminally classified state.
- Provider quota errors are classified from all supported Claude error shapes.
- The parent orchestrator can fall back to the same native logical tier after
  receiving a persisted quota-exhausted result.
- Existing synchronous workflows, worker history, security properties, and
  version parity continue to pass their tests.
