---
name: quota
description: Use before dispatching work to glm-agent:explorer or glm-agent:general-purpose, and before returning to GLM after a quota-exhausted fallback, to read the remaining Z.ai GLM Coding Plan quota and choose between a GLM worker and native Claude.
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/glm-agent" quota)
---

# GLM quota gate

Choose whether the next unit of work goes to a GLM worker or stays on native
Claude. Run the lookup once per dispatch decision, before choosing the
provider. Do not poll, and do not open `~/.glm/quota/response.json` unless a
lookup failure needs debugging. Never print or search for the API key.

## Run the lookup

```bash
bash "${CLAUDE_PLUGIN_ROOT}/glm-agent" quota
```

The command makes one read-only request to Z.ai and prints `KEY=VALUE` lines:
`QUOTA_STATUS` (`OK` or `INVALID`), `SCOPE` (`personal` or `team`, depending
on whether a team scope was configured with `glm-agent team-scope`),
`PLAN_LEVEL`, `LIMIT_COUNT`, then for each
limit `n` the fields `LIMIT_n_TYPE`, `LIMIT_n_WINDOW`, `LIMIT_n_TOTAL`,
`LIMIT_n_USED`, `LIMIT_n_REMAINING`, `LIMIT_n_USED_PERCENT`, and
`LIMIT_n_RESET_AT` (UTC), and finally `RESPONSE`, `ERROR_KIND`, and
`PROVIDER_CODE`. The decision rules below apply unchanged in both scopes.
Exit status 0 means `QUOTA_STATUS=OK`, even when a window is
exhausted. Exit status 1 means `QUOTA_STATUS=INVALID`. Exit status 2 is a
usage or setup error with no `QUOTA_STATUS` line: report its stderr message to
the User and stay on native Claude, as in row 1 below. The same setup problem
(missing key, missing `jq`, malformed `ZAI_BASE_URL`) would also stop a GLM
worker. If the command exits with a status other than 0 or 1, or
prints no `QUOTA_STATUS` line, treat it like exit status 2.

## Decide

Read the rows from the top and follow the first one that matches.

| Row | Condition | Decision |
| --- | --- | --- |
| 1 | `QUOTA_STATUS=INVALID` and `ERROR_KIND=authentication` | Native Claude. Report the failure to the User. |
| 2 | `QUOTA_STATUS=INVALID` and `ERROR_KIND=quota-exhausted` | Native Claude. The reset time is unknown, so latch for the current orchestration session. |
| 3 | `QUOTA_STATUS=INVALID` with any other `ERROR_KIND` | GLM (fail-open). The post-failure fallback is the safety net. |
| 4 | A limit whose `LIMIT_n_TYPE` is not `TIME_LIMIT` has a `LIMIT_n_REMAINING` that is a number ≤ 0 (for example `REMAINING=0`, `0.0`, or `-1`) | Native Claude. Latch until the latest `RESET_AT` among the exhausted limits, then query again. If an exhausted limit has an empty `RESET_AT`, latch for the current orchestration session. |
| 5 | `WINDOW=5h` with `USED_PERCENT>=90`, or `WINDOW=1w` with `USED_PERCENT>=98` | Graded: send only a small, bounded, single-turn task to GLM; send multi-turn work to native Claude. |
| 6 | Anything else | GLM. |

- Only rows 1, 2, and 4 block GLM completely.
- To latch is to skip GLM and skip further lookups until the stated condition
  ends.
- Recognised windows are exactly `5h` and `1w`. Any other `WINDOW` value
  (empty, `u<unit>x<number>`, `1h`, `2w`, ...) is unrecognised. Only row 4
  applies to it; the row 5 thresholds do not. Whichever row matched, also
  report that the window is new.
- `TIME_LIMIT` appears to be a separate MCP-usage limit (unverified). Row 4
  ignores it, but it is still printed and counted in `LIMIT_COUNT`.
- An empty value means the server did not report it. An empty `REMAINING` is
  never a number ≤ 0.

## Report

State the decision in one short block: the matching row, and for each limit
that drove it `WINDOW`, `REMAINING`, and `RESET_AT` (plus `USED_PERCENT` for
row 5). For a failed lookup report `ERROR_KIND` and `PROVIDER_CODE`.

This skill only decides. Dispatch to `glm-agent:explorer` or
`glm-agent:general-purpose`, or stay on native Claude, as the decision says.
The bridge agents are unchanged: a GLM turn that later fails with
`ERROR_KIND=quota-exhausted` still returns `FALLBACK_RECOMMENDED=true`.
