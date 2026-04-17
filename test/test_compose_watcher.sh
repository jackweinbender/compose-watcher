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

# --- log: JSON format ---
LOG_FORMAT=json
json_out=$(log INFO "compose up" "project=repo-a-pr-123" "file=/etc/stacks/a.yml")
assert_eq "json has level"   "1" "$(grep -c '"level":"INFO"'   <<< "$json_out")"
assert_eq "json has msg"     "1" "$(grep -c '"msg":"compose up"' <<< "$json_out")"
assert_eq "json has project" "1" "$(grep -c '"project":"repo-a-pr-123"' <<< "$json_out")"
assert_eq "json has file"    "1" "$(grep -c '"file":"/etc/stacks/a.yml"' <<< "$json_out")"

# --- log: text format ---
LOG_FORMAT=text
text_out=$(log WARN "something happened" "k=v")
assert_eq "text has level"   "1" "$(grep -c 'WARN'              <<< "$text_out")"
assert_eq "text has msg"     "1" "$(grep -c 'something happened' <<< "$text_out")"
assert_eq "text has kv"      "1" "$(grep -c 'k=v'               <<< "$text_out")"

# --- log: JSON escaping ---
LOG_FORMAT=json
escaped_out=$(log INFO 'say "hello"' 'path=a\b')
assert_eq "json escapes quotes"     "1" "$(grep -c '"msg":"say \\"hello\\""'  <<< "$escaped_out")"
assert_eq "json escapes backslash"  "1" "$(grep -c '"path":"a\\\\b"'          <<< "$escaped_out")"

echo ""; echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
