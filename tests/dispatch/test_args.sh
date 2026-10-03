#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

make_brief brief.md $'brief line\nsecond line\n'
EMPTY_BRIEF="$TEST_ROOT/empty.md"
: >"$EMPTY_BRIEF"
MISSING_BRIEF="$TEST_ROOT/missing.md"
UNREADABLE_BRIEF="$TEST_ROOT/unreadable.md"
printf 'x\n' >"$UNREADABLE_BRIEF"
chmod 000 "$UNREADABLE_BRIEF"
LONG_LABEL="a$(printf 'b%.0s' {1..64})"

expect_usage_error() {
  local name="$1"
  shift
  dispatch "$@"
  if [[ "$RC" == 2 && -z "$OUTPUT" && "$STDERR" == 'glm-dispatch: '* &&
        "$STDERR" != *$'\n'* ]]; then
    pass "$name"
  else
    fail "$name" "rc=$RC stdout=[$OUTPUT] stderr=[$STDERR]"
  fi
}

expect_usage_text() {
  local name="$1"
  shift
  dispatch "$@"
  if [[ "$RC" == 2 && -z "$OUTPUT" && "$STDERR" == *'usage: glm-dispatch'* ]]; then
    pass "$name"
  else
    fail "$name" "rc=$RC stdout=[$OUTPUT] stderr=[$STDERR]"
  fi
}

expect_usage_text 'no arguments print usage and exit 2'
expect_usage_text 'unknown subcommand prints usage and exits 2' frobnicate
expect_usage_text '--help prints usage on stderr and exits 2' --help

expect_usage_error 'run without --session is rejected' \
  run --label l1 --task-file "$BRIEF"
expect_usage_error 'run without --label is rejected' \
  run --session s1 --task-file "$BRIEF"
expect_usage_error 'run without --task-file is rejected' \
  run --session s1 --label l1 --role general-purpose --model sonnet --cwd "$PROJECT"
expect_usage_error 'session with a space is rejected' \
  run --session 'bad session' --label l1 --role general-purpose --model sonnet --cwd "$PROJECT" --task-file "$BRIEF"
expect_usage_error 'session with a slash is rejected' \
  run --session 'a/b' --label l1 --role general-purpose --model sonnet --cwd "$PROJECT" --task-file "$BRIEF"
expect_usage_error 'session dot-dot is rejected' \
  run --session .. --label l1 --role general-purpose --model sonnet --cwd "$PROJECT" --task-file "$BRIEF"
expect_usage_error 'label starting with a dash is rejected' \
  run --session s1 --label -bad --role general-purpose --model sonnet --cwd "$PROJECT" --task-file "$BRIEF"
expect_usage_error 'label with a slash is rejected' \
  run --session s1 --label a/b --role general-purpose --model sonnet --cwd "$PROJECT" --task-file "$BRIEF"
expect_usage_error 'label longer than 64 characters is rejected' \
  run --session s1 --label "$LONG_LABEL" --role general-purpose --model sonnet --cwd "$PROJECT" --task-file "$BRIEF"
expect_usage_error 'role outside the allowed set is rejected' \
  run --session s1 --label l1 --model sonnet --cwd "$PROJECT" --role planner --task-file "$BRIEF"
expect_usage_error 'model outside the allowed set is rejected' \
  run --session s1 --label l1 --role general-purpose --cwd "$PROJECT" --model gpt --task-file "$BRIEF"
expect_usage_error 'cwd that is not a directory is rejected' \
  run --session s1 --label l1 --role general-purpose --model sonnet --cwd "$TEST_ROOT/nope" --task-file "$BRIEF"
expect_usage_error 'missing task file is rejected' \
  run --session s1 --label l1 --role general-purpose --model sonnet --cwd "$PROJECT" --task-file "$MISSING_BRIEF"
expect_usage_error 'empty task file is rejected' \
  run --session s1 --label l1 --role general-purpose --model sonnet --cwd "$PROJECT" --task-file "$EMPTY_BRIEF"
if [[ "$(id -u)" != 0 ]]; then
  expect_usage_error 'unreadable task file is rejected' \
    run --session s1 --label l1 --role general-purpose --model sonnet --cwd "$PROJECT" --task-file "$UNREADABLE_BRIEF"
fi
expect_usage_error 'max-wait zero is rejected' \
  run --session s1 --label l1 --role general-purpose --model sonnet --cwd "$PROJECT" --task-file "$BRIEF" --max-wait 0
expect_usage_error 'max-wait that is not a number is rejected' \
  run --session s1 --label l1 --role general-purpose --model sonnet --cwd "$PROJECT" --task-file "$BRIEF" --max-wait abc
expect_usage_error 'negative max-wait is rejected' \
  run --session s1 --label l1 --role general-purpose --model sonnet --cwd "$PROJECT" --task-file "$BRIEF" --max-wait -5
expect_usage_error 'fractional max-wait is rejected' \
  run --session s1 --label l1 --role general-purpose --model sonnet --cwd "$PROJECT" --task-file "$BRIEF" --max-wait 1.5
expect_usage_error 'poll-seconds zero is rejected' \
  run --session s1 --label l1 --role general-purpose --model sonnet --cwd "$PROJECT" --task-file "$BRIEF" --poll-seconds 0
expect_usage_error 'poll-seconds above 300 is rejected' \
  run --session s1 --label l1 --role general-purpose --model sonnet --cwd "$PROJECT" --task-file "$BRIEF" --poll-seconds 301
expect_usage_error 'negative stall-timeout is rejected' \
  run --session s1 --label l1 --role general-purpose --model sonnet --cwd "$PROJECT" --task-file "$BRIEF" --stall-timeout -1
expect_usage_error 'stall-timeout that is not a number is rejected' \
  run --session s1 --label l1 --role general-purpose --model sonnet --cwd "$PROJECT" --task-file "$BRIEF" --stall-timeout abc
expect_usage_error 'est-credits zero is rejected' \
  run --session s1 --label l1 --role general-purpose --model sonnet --cwd "$PROJECT" --task-file "$BRIEF" --est-credits 0
expect_usage_error 'unknown option is rejected' \
  run --session s1 --label l1 --role general-purpose --model sonnet --cwd "$PROJECT" --task-file "$BRIEF" --bogus
expect_usage_error 'option without a value is rejected' \
  run --session s1 --label l1 --model sonnet --cwd "$PROJECT" --task-file "$BRIEF" --role
expect_usage_error 'positional argument is rejected' \
  run --session s1 --label l1 --role general-purpose --model sonnet --cwd "$PROJECT" --task-file "$BRIEF" extra

expect_usage_error 'send without --task-file is rejected' \
  send --session s1 --label l1
expect_usage_error 'send rejects --small' \
  send --session s1 --label l1 --task-file "$BRIEF" --small
expect_usage_error 'send rejects --role' \
  send --session s1 --label l1 --task-file "$BRIEF" --role explorer
expect_usage_error 'attach rejects --wait' \
  attach --session s1 --label l1 --wait
expect_usage_error 'attach rejects --task-file' \
  attach --session s1 --label l1 --task-file "$BRIEF"
expect_usage_error 'attach without --label is rejected' \
  attach --session s1
expect_usage_error 'pending rejects --label' \
  pending --session s1 --label l1
expect_usage_error 'pending without --session is rejected' pending
expect_usage_error 'ack without --label is rejected' ack --session s1
expect_usage_error 'status without --label is rejected' status --session s1
expect_usage_error 'result without --session is rejected' result --label l1
expect_usage_error 'cancel with an invalid label is rejected' \
  cancel --session s1 --label 'a b'
expect_usage_error 'close with an invalid session is rejected' \
  close --session 'x y' --label l1

finish
