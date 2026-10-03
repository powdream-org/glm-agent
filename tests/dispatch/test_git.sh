#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

make_brief idle.md $'# Task\nno edits\n'
make_brief touch.md $'# Task\nTOUCH_TRACKED\n'
make_brief create.md $'# Task\nCREATE_FILE\n'
make_brief commit.md $'# Task\nCOMMIT_CHANGE\n'
make_brief all.md $'# Task\nTOUCH_TRACKED CREATE_FILE COMMIT_CHANGE\n'

use_real_cli

fresh_git() {
  GIT_PROJECT="$TEST_ROOT/$1"
  make_git_project "$GIT_PROJECT"
}

git_run() {
  local label="$1" role="$2" brief="$3" cwd="$4"
  shift 4
  next_session
  dispatch run --session "$SESSION" --label "$label" --model sonnet --role "$role" --cwd "$cwd" \
    --task-file "$TEST_ROOT/$brief" --wait --poll-seconds 1 "$@"
  VERDICT="$(grep '^GLM_VERDICT' <<<"$OUTPUT" || true)"
  WARNS="$(grep '^GLM_WARN' <<<"$OUTPUT" || true)"
  CHANGED="$(sed -n 's/.* files_changed=\([^ ]*\) .*/\1/p' <<<"$VERDICT")"
  REGISTRY_ENV="$GLM_AGENT_HOME/dispatch/$SESSION/$label.env"
}

fresh_git g-none
git_run none explorer idle.md "$GIT_PROJECT"
assert_eq 'a run without edits reports files_changed=0 and no warning' "0||0" "$CHANGED|$WARNS|$RC"
assert_eq 'registry git_head is the HEAD at start' "$(git -C "$GIT_PROJECT" rev-parse HEAD)" \
  "$(kv_file_get "$REGISTRY_ENV" git_head)"
assert_file 'run writes the porcelain snapshot file' "$GLM_AGENT_HOME/dispatch/$SESSION/none.status"
assert_eq 'registry git_status_hash is the cksum of the snapshot file' \
  "$(cksum <"$GLM_AGENT_HOME/dispatch/$SESSION/none.status" | cut -d' ' -f1)" \
  "$(kv_file_get "$REGISTRY_ENV" git_status_hash)"
assert_eq 'the snapshot file mode is 600' 600 "$(file_mode "$GLM_AGENT_HOME/dispatch/$SESSION/none.status")"

fresh_git g-touch
git_run touch explorer touch.md "$GIT_PROJECT"
assert_eq 'an explorer that edits a tracked file counts one change' 1 "$CHANGED"
assert_eq 'an explorer edit warns with the changed file' \
  'GLM_WARN explorer_modified files=tracked.txt' "$WARNS"
assert_eq 'the warning line comes right before the verdict' 'GLM_WARN explorer_modified files=tracked.txt' \
  "$(grep -B1 '^GLM_VERDICT' <<<"$OUTPUT" | head -n 1)"
assert_eq 'warnings leave the exit code at 0 for a DONE worker' 0 "$RC"

fresh_git g-touch-gp
git_run touch-gp general-purpose touch.md "$GIT_PROJECT"
assert_eq 'a general-purpose edit counts the change without a warning' "1|" "$CHANGED|$WARNS"

fresh_git g-create
git_run create explorer create.md "$GIT_PROJECT"
assert_eq 'a new untracked file counts as a change' "1|GLM_WARN explorer_modified files=created.txt" \
  "$CHANGED|$WARNS"

fresh_git g-commit
git_run commit explorer commit.md "$GIT_PROJECT"
assert_eq 'a commit made by the worker counts its files' \
  "1|GLM_WARN explorer_modified files=committed.txt" "$CHANGED|$WARNS"
assert_eq 'the worker commit leaves the tree clean' '' "$(git -C "$GIT_PROJECT" status --porcelain)"

fresh_git g-all
git_run all explorer all.md "$GIT_PROJECT"
assert_eq 'edits, new files, and commits are combined and sorted' \
  "3|GLM_WARN explorer_modified files=committed.txt,created.txt,tracked.txt" "$CHANGED|$WARNS"

fresh_git g-dirty
printf 'pre\n' >"$GIT_PROJECT/pre.txt"
git_run dirty explorer idle.md "$GIT_PROJECT"
assert_eq 'an untracked file present at start is not counted' "0|" "$CHANGED|$WARNS"
assert_eq 'the snapshot file keeps the porcelain text' '?? pre.txt' \
  "$(cat "$GLM_AGENT_HOME/dispatch/$SESSION/dirty.status")"
assert_eq 'registry git_status_hash covers the dirty list' \
  "$(printf '?? pre.txt\n' | cksum | cut -d' ' -f1)" "$(kv_file_get "$REGISTRY_ENV" git_status_hash)"
git_run dirty-new explorer create.md "$GIT_PROJECT"
assert_eq 'a start-time untracked file stays out of the list when a new one appears' \
  "1|GLM_WARN explorer_modified files=created.txt" "$CHANGED|$WARNS"

fresh_git g-scope
git_run scope general-purpose create.md "$GIT_PROJECT" --allow-path 'src/*'
assert_eq 'a change outside every allowed glob warns out_of_scope' \
  "1|GLM_WARN out_of_scope files=created.txt" "$CHANGED|$WARNS"
assert_eq 'allow-path globs are stored one per line' $'src/*' \
  "$(cat "$GLM_AGENT_HOME/dispatch/$SESSION/scope.allow")"
fresh_git g-scope-ok
git_run scope-ok general-purpose create.md "$GIT_PROJECT" --allow-path 'src/*' --allow-path '*.txt'
assert_eq 'a change matching one of several globs is in scope' "1|" "$CHANGED|$WARNS"
assert_eq 'repeated allow-path globs are all stored' $'src/*\n*.txt' \
  "$(cat "$GLM_AGENT_HOME/dispatch/$SESSION/scope-ok.allow")"
fresh_git g-scope-both
git_run scope-both explorer all.md "$GIT_PROJECT" --allow-path 'docs/*'
assert_eq 'explorer_modified comes before out_of_scope' \
  $'GLM_WARN explorer_modified files=committed.txt,created.txt,tracked.txt\nGLM_WARN out_of_scope files=committed.txt,created.txt,tracked.txt' \
  "$WARNS"
fresh_git g-noallow
git_run noallow general-purpose create.md "$GIT_PROJECT"
assert_no_file 'a run without allow-path writes no allow file' "$GLM_AGENT_HOME/dispatch/$SESSION/noallow.allow"

mkdir -p "$TEST_ROOT/plain-dir"
git_run nongit explorer create.md "$TEST_ROOT/plain-dir"
assert_eq 'a non-git cwd reports files_changed=na and no warning' "na|" "$CHANGED|$WARNS"
assert_eq 'a non-git cwd records git_head=none' none "$(kv_file_get "$REGISTRY_ENV" git_head)"
assert_no_file 'a non-git cwd writes no snapshot file' "$GLM_AGENT_HOME/dispatch/$SESSION/nongit.status"
assert_eq 'a non-git cwd still exits 0 for a DONE worker' 0 "$RC"

GIT_PROBE="$TEST_ROOT/git-probe.sh"
cat >"$GIT_PROBE" <<'PROBE'
set -Eeuo pipefail
source "$1/scripts/lib/dispatch-common.sh"
source "$1/scripts/lib/dispatch-git.sh"
for pair in 'src/a/b.txt|src/*' 'docs/x|src/*' 'a.txt|*.txt' 'a.txt|a.t?t' 'src/a.txt|src/[ab].txt' 'src/c.txt|src/[ab].txt'; do
  if dd_glob_matches "${pair%%|*}" "${pair#*|}"; then
    printf 'match %s\n' "$pair"
  else
    printf 'miss %s\n' "$pair"
  fi
done
printf ' M a.txt\nR  old.txt -> new.txt\n?? "sp ace.txt"\n?? dir/\n' | dd_porcelain_paths
PROBE
capture "$BASH" "$GIT_PROBE" "$REPO_DIR"
assert_eq 'glob matching follows bash case patterns and porcelain paths are normalised' \
  $'match src/a/b.txt|src/*\nmiss docs/x|src/*\nmatch a.txt|*.txt\nmatch a.txt|a.t?t\nmatch src/a.txt|src/[ab].txt\nmiss src/c.txt|src/[ab].txt\na.txt\nnew.txt\nsp ace.txt\ndir/' \
  "$OUTPUT"

finish
