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

assert_eq "script is sourceable" "ok" "ok"

# --- log ---
out=$(log INFO "something happened" "k=v")
assert_eq "log has level"   "1" "$(grep -c 'INFO'              <<< "$out")"
assert_eq "log has msg"     "1" "$(grep -c 'something happened' <<< "$out")"
assert_eq "log has kv"      "1" "$(grep -c 'k=v'               <<< "$out")"

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

echo ""; echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
