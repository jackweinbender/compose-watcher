#!/usr/bin/env bash
set -euo pipefail

PASS=0; FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "PASS: $desc"; PASS=$(( PASS + 1 ))
    else
        echo "FAIL: $desc"; echo "  expected: $expected"; echo "  actual:   $actual"; FAIL=$(( FAIL + 1 ))
    fi
}

source "$(dirname "$0")/../compose-watcher"

# --- project_name ---

assert_eq "subdir/file.yml" \
    "repo-a-pr-123" \
    "$(project_name /etc/compose-stacks /etc/compose-stacks/repo-a/pr-123.yml)"

assert_eq "subdir/file.yaml" \
    "repo-b-pr-456" \
    "$(project_name /etc/compose-stacks /etc/compose-stacks/repo-b/pr-456.yaml)"

assert_eq "underscore prefix" \
    "repo-a-_traefik" \
    "$(project_name /etc/compose-stacks /etc/compose-stacks/repo-a/_traefik.yml)"

assert_eq "file directly in watch root" \
    "standalone" \
    "$(project_name /etc/compose-stacks /etc/compose-stacks/standalone.yml)"

assert_eq "multi-dot stem" \
    "repo-a-multi.service" \
    "$(project_name /etc/compose-stacks /etc/compose-stacks/repo-a/multi.service.yml)"

# --- startup_scan ---

_SAVED_WATCH_DIR="$WATCH_DIR"
WATCH_DIR=$(mktemp -d)
mkdir -p "$WATCH_DIR/repo-a"
touch "$WATCH_DIR/repo-a/pr-123.yml"
touch "$WATCH_DIR/repo-a/pr-456.yaml"
touch "$WATCH_DIR/repo-a/README.md"   # not a compose file — should be ignored
touch "$WATCH_DIR/standalone.yml"

_CALLS=$(mktemp)
compose_up()   { echo "up|$1|$2"  >> "$_CALLS"; }
compose_down() { echo "down|$1"   >> "$_CALLS"; }

startup_scan

assert_eq "startup_scan: upserts .yml" \
    "1" "$(grep -c "^up|repo-a-pr-123|$WATCH_DIR/repo-a/pr-123.yml" "$_CALLS")"
assert_eq "startup_scan: upserts .yaml" \
    "1" "$(grep -c "^up|repo-a-pr-456|$WATCH_DIR/repo-a/pr-456.yaml" "$_CALLS")"
assert_eq "startup_scan: upserts root-level file" \
    "1" "$(grep -c "^up|standalone|$WATCH_DIR/standalone.yml" "$_CALLS")"
assert_eq "startup_scan: ignores non-compose files" \
    "0" "$(grep -c "README" "$_CALLS")"

rm -rf "$WATCH_DIR" "$_CALLS"
WATCH_DIR="$_SAVED_WATCH_DIR"

# --- event_loop dispatch ---

WATCH_DIR="/etc/compose-stacks"

_CALLS=$(mktemp)
compose_up()   { echo "up|$1|$2"  >> "$_CALLS"; }
compose_down() { echo "down|$1"   >> "$_CALLS"; }

# Override inotifywait to emit a fixed sequence of synthetic events.
inotifywait() {
    printf '%s\n' \
        "/etc/compose-stacks/repo-a/pr-123.yml CLOSE_WRITE,CLOSE" \
        "/etc/compose-stacks/repo-a/pr-456.yml MOVED_TO"           \
        "/etc/compose-stacks/repo-a/pr-789.yml DELETE"             \
        "/etc/compose-stacks/repo-a/notes.txt CLOSE_WRITE,CLOSE"   \
        "/etc/compose-stacks/repo-a/ CREATE,ISDIR"                 \
        "/etc/compose-stacks/repo-a/after.yml CLOSE_WRITE,CLOSE"   # must not be dispatched
}

event_loop

assert_eq "event_loop: CLOSE_WRITE → compose_up" \
    "1" "$(grep -c "^up|repo-a-pr-123|" "$_CALLS")"
assert_eq "event_loop: MOVED_TO → compose_up" \
    "1" "$(grep -c "^up|repo-a-pr-456|" "$_CALLS")"
assert_eq "event_loop: DELETE → compose_down" \
    "1" "$(grep -c "^down|repo-a-pr-789$" "$_CALLS")"
assert_eq "event_loop: non-yml files ignored" \
    "0" "$(grep -c "notes" "$_CALLS")"
assert_eq "event_loop: ISDIR breaks loop (no events after)" \
    "0" "$(grep -c "after" "$_CALLS")"
assert_eq "event_loop: exactly 3 dispatches before ISDIR" \
    "3" "$(wc -l < "$_CALLS" | tr -d ' ')"

rm -f "$_CALLS"

echo ""; echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
