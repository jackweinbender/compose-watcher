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

assert_eq "subdir/file.yml → subdir name" \
    "repo-a" \
    "$(project_name /etc/compose-stacks /etc/compose-stacks/repo-a/pr-123.yml)"

assert_eq "subdir path (no file) → subdir name" \
    "repo-b" \
    "$(project_name /etc/compose-stacks /etc/compose-stacks/repo-b)"

assert_eq "nested path → still first component" \
    "repo-c" \
    "$(project_name /etc/compose-stacks /etc/compose-stacks/repo-c/nested/compose.yml)"

# --- startup_scan ---

_SAVED_WATCH_DIR="$WATCH_DIR"
WATCH_DIR=$(mktemp -d)
mkdir -p "$WATCH_DIR/repo-a"
mkdir -p "$WATCH_DIR/repo-b"
touch "$WATCH_DIR/repo-a/compose.yml"
touch "$WATCH_DIR/repo-b/docker-compose.yaml"
touch "$WATCH_DIR/repo-a/README.md"       # not a compose file — should be ignored
touch "$WATCH_DIR/stray.yml"              # root-level file — should be ignored

_CALLS=$(mktemp)
compose_up()   { echo "up|$1|$2"  >> "$_CALLS"; }
compose_down() { echo "down|$1"   >> "$_CALLS"; }

startup_scan

assert_eq "startup_scan: upserts subdir .yml" \
    "1" "$(grep -c "^up|repo-a|$WATCH_DIR/repo-a/compose.yml" "$_CALLS")"
assert_eq "startup_scan: upserts subdir .yaml" \
    "1" "$(grep -c "^up|repo-b|$WATCH_DIR/repo-b/docker-compose.yaml" "$_CALLS")"
assert_eq "startup_scan: ignores non-compose files" \
    "0" "$(grep -c "README" "$_CALLS")"
assert_eq "startup_scan: ignores root-level files" \
    "0" "$(grep -c "stray" "$_CALLS")"

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
        "/etc/compose-stacks/repo-a/compose.yml CLOSE_WRITE,CLOSE" \
        "/etc/compose-stacks/repo-b/compose.yml MOVED_TO"          \
        "/etc/compose-stacks/repo-c/compose.yml DELETE"            \
        "/etc/compose-stacks/repo-a/notes.txt CLOSE_WRITE,CLOSE"   \
        "/etc/compose-stacks/stray.yml CLOSE_WRITE,CLOSE"          \
        "/etc/compose-stacks/repo-d/ DELETE,ISDIR"                 \
        "/etc/compose-stacks/repo-e/ CREATE,ISDIR"                 \
        "/etc/compose-stacks/repo-a/after.yml CLOSE_WRITE,CLOSE"   # must not be dispatched
}

event_loop

assert_eq "event_loop: CLOSE_WRITE → compose_up" \
    "1" "$(grep -c "^up|repo-a|" "$_CALLS")"
assert_eq "event_loop: MOVED_TO → compose_up" \
    "1" "$(grep -c "^up|repo-b|" "$_CALLS")"
assert_eq "event_loop: DELETE → compose_down" \
    "1" "$(grep -c "^down|repo-c$" "$_CALLS")"
assert_eq "event_loop: DELETE,ISDIR → compose_down" \
    "1" "$(grep -c "^down|repo-d$" "$_CALLS")"
assert_eq "event_loop: non-yml files ignored" \
    "0" "$(grep -c "notes" "$_CALLS")"
assert_eq "event_loop: root-level yml ignored" \
    "0" "$(grep -c "stray" "$_CALLS")"
assert_eq "event_loop: CREATE,ISDIR breaks loop (no events after)" \
    "0" "$(grep -c "after" "$_CALLS")"
assert_eq "event_loop: exactly 4 dispatches before CREATE,ISDIR" \
    "4" "$(wc -l < "$_CALLS" | tr -d ' ')"

rm -f "$_CALLS"

# --- main block: exits when event_loop returns (systemd restarts us) ---

_BIN_DIR=$(mktemp -d)
cat > "$_BIN_DIR/inotifywait" <<'EOF'
#!/usr/bin/env bash
# Fake inotifywait: emit a single CREATE,ISDIR event and exit.
echo "/fake/new-dir/ CREATE,ISDIR"
EOF
chmod +x "$_BIN_DIR/inotifywait"

_TMP=$(mktemp -d)
_SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/compose-watcher"

# If the main block still wrapped event_loop in `while true`, the fake inotifywait
# would be re-invoked forever and `timeout` would fire (exit 124).
set +e
PATH="$_BIN_DIR:$PATH" WATCH_DIR="$_TMP/watch" LOCK_DIR="$_TMP/locks" \
    timeout 5 "$_SCRIPT" >/dev/null 2>&1
_EXIT=$?
set -e

assert_eq "main block: exits after event_loop returns (no internal loop)" \
    "0" "$([[ $_EXIT -eq 124 ]] && echo 1 || echo 0)"

rm -rf "$_BIN_DIR" "$_TMP"

echo ""; echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
