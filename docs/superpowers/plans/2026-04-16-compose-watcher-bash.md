# compose-watcher (bash) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a bash script daemon that watches a directory with `inotifywait` and runs `docker compose up/down` in response to file changes, using per-project lock files to prevent concurrent operations.

**Architecture:** A single bash script with a `main()` guard so it can be sourced in tests. Pure helper functions (`project_name`, `log`) are unit-tested by sourcing the script. Compose operations run as background subshells acquiring a per-project `flock` lock — if the lock is held the event is skipped. `inotifywait` runs in a restart loop; breaking out of the read loop (on new-directory events) causes a clean restart with updated watches.

**Tech Stack:** bash, `inotifywait` (inotify-tools package), `docker compose` (Compose V2), `flock` (util-linux, standard on Linux).

---

## File Map

| File | Responsibility |
|---|---|
| `compose-watcher` | Executable bash script — all logic |
| `test/test_compose_watcher.sh` | Unit tests for `project_name` and `log` (sources the script) |
| `README.md` | Build, install, systemd, config, GitHub Actions integration |

> **Supersedes:** `docs/superpowers/plans/2026-04-16-compose-watcher.md` (Go implementation — abandoned in favour of this bash redesign).

---

### Task 1: Script skeleton with testable guard

**Files:**
- Create: `compose-watcher`
- Create: `test/test_compose_watcher.sh`

The script must be sourceable (for unit tests) without executing `main`. The standard bash pattern is `[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"`.

- [ ] **Step 1: Write failing test that sources the script**

`test/test_compose_watcher.sh`:
```bash
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

echo ""; echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
```

- [ ] **Step 2: Run test to verify it fails**

```bash
bash test/test_compose_watcher.sh
```

Expected: error — `compose-watcher: No such file or directory`

- [ ] **Step 3: Create the script skeleton**

`compose-watcher`:
```bash
#!/usr/bin/env bash
set -euo pipefail

WATCH_DIR="${WATCH_DIR:-/etc/compose-stacks}"
LOG_FORMAT="${LOG_FORMAT:-json}"
LOCK_DIR="${LOCK_DIR:-/run/compose-watcher}"

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --watch-dir)   WATCH_DIR="$2";   shift 2 ;;
            --log-format)  LOG_FORMAT="$2";  shift 2 ;;
            -h|--help)     usage; exit 0 ;;
            *) printf 'Unknown flag: %s\n' "$1" >&2; usage >&2; exit 1 ;;
        esac
    done
    printf 'compose-watcher starting\n'
}

usage() {
    cat <<'EOF'
Usage: compose-watcher [OPTIONS]

Options:
  --watch-dir DIR    Root directory to watch recursively (default: /etc/compose-stacks)
                     Also configurable via WATCH_DIR env var.
  --log-format FMT   Log format: json or text (default: json)
                     Also configurable via LOG_FORMAT env var.
  -h, --help         Show this help
EOF
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
```

- [ ] **Step 4: Make the script executable**

```bash
chmod +x compose-watcher
```

- [ ] **Step 5: Run test to verify it passes**

```bash
bash test/test_compose_watcher.sh
```

Expected:
```
PASS: script is sourceable

Results: 1 passed, 0 failed
```

- [ ] **Step 6: Commit**

```bash
git add compose-watcher test/test_compose_watcher.sh
git commit -m "feat: add script skeleton with testable source guard"
```

---

### Task 2: Logging

**Files:**
- Modify: `compose-watcher`
- Modify: `test/test_compose_watcher.sh`

- [ ] **Step 1: Add failing tests for `log`**

Append to the test assertions section in `test/test_compose_watcher.sh` (before the final `echo/exit`):

```bash
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
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
bash test/test_compose_watcher.sh
```

Expected: FAILs for all `log` assertions — `log: command not found`

- [ ] **Step 3: Add `_json_esc` and `log` to `compose-watcher`** (insert before `main`):

```bash
# Escape backslashes and double quotes for use inside a JSON string.
_json_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# log LEVEL MESSAGE [key=value ...]
# Writes a structured log line to stdout.
log() {
    local level="$1" msg="$2"; shift 2
    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if [[ "$LOG_FORMAT" == "json" ]]; then
        local j="{\"time\":\"$ts\",\"level\":\"$level\",\"msg\":\"$(_json_esc "$msg")\""
        while [[ $# -gt 0 ]]; do
            j+=",\"${1%%=*}\":\"$(_json_esc "${1#*=}")\""
            shift
        done
        printf '%s\n' "${j}}"
    else
        local kv=""
        while [[ $# -gt 0 ]]; do kv+=" $1"; shift; done
        printf '%s  %-5s  %s%s\n' "$ts" "$level" "$msg" "$kv"
    fi
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
bash test/test_compose_watcher.sh
```

Expected: all log assertions PASS

- [ ] **Step 5: Commit**

```bash
git add compose-watcher test/test_compose_watcher.sh
git commit -m "feat: add structured logging (json/text)"
```

---

### Task 3: Project name derivation

**Files:**
- Modify: `compose-watcher`
- Modify: `test/test_compose_watcher.sh`

- [ ] **Step 1: Add failing tests for `project_name`**

Append to test assertions in `test/test_compose_watcher.sh`:

```bash
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
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
bash test/test_compose_watcher.sh
```

Expected: FAILs for all `project_name` assertions — `project_name: command not found`

- [ ] **Step 3: Add `project_name` to `compose-watcher`** (insert before `main`):

```bash
# Derive a unique Docker Compose project name from a file path.
# Example: /etc/compose-stacks/repo-a/pr-123.yml → repo-a-pr-123
project_name() {
    local watch_root="$1" file="$2"
    local rel="${file#${watch_root}/}"
    local dir; dir=$(dirname "$rel")
    local base; base=$(basename "$rel")
    local stem="${base%.*}"
    if [[ "$dir" == "." ]]; then
        printf '%s' "$stem"
    else
        printf '%s' "${dir}-${stem}"
    fi
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
bash test/test_compose_watcher.sh
```

Expected: all `project_name` assertions PASS

- [ ] **Step 5: Commit**

```bash
git add compose-watcher test/test_compose_watcher.sh
git commit -m "feat: add project name derivation"
```

---

### Task 4: Docker compose operations

**Files:**
- Modify: `compose-watcher`

No unit tests here — the functions shell out to docker. Correctness is verified manually in Task 7. The important invariants (lock acquired, correct CLI args) are verified by reading the code.

- [ ] **Step 1: Add `compose_upsert` to `compose-watcher`** (insert before `main`):

```bash
# Run `docker compose up -d --remove-orphans` in a background subshell.
# Acquires a per-project flock lock; skips if the lock is already held.
# This prevents two simultaneous deploys for the same project.
compose_upsert() {
    local project="$1" file="$2"
    local lock="${LOCK_DIR}/${project}.lock"
    mkdir -p "$LOCK_DIR"
    (
        exec 9>"$lock"
        if ! flock -n 9; then
            log INFO "compose up skipped: operation already in progress" "project=$project"
            exit 0
        fi
        log INFO "compose up starting" "project=$project" "file=$file"
        local output rc
        output=$(docker compose -p "$project" -f "$file" up -d --remove-orphans 2>&1) && rc=0 || rc=$?
        while IFS= read -r line; do
            [[ -n "$line" ]] && log INFO "$line" "project=$project"
        done <<< "$output"
        if [[ $rc -eq 0 ]]; then
            log INFO "compose up complete" "project=$project"
        else
            log ERROR "compose up failed" "project=$project" "exit_code=$rc"
        fi
    ) &
}
```

- [ ] **Step 2: Add `compose_cleanup` to `compose-watcher`** (insert after `compose_upsert`):

```bash
# Run `docker compose down -v` then prune dangling resources, in a background subshell.
# Acquires a per-project flock lock; skips if the lock is already held.
compose_cleanup() {
    local project="$1"
    local lock="${LOCK_DIR}/${project}.lock"
    mkdir -p "$LOCK_DIR"
    (
        exec 9>"$lock"
        if ! flock -n 9; then
            log INFO "compose down skipped: operation already in progress" "project=$project"
            exit 0
        fi
        log INFO "compose down starting" "project=$project"
        local output rc
        output=$(docker compose -p "$project" down -v 2>&1) && rc=0 || rc=$?
        while IFS= read -r line; do
            [[ -n "$line" ]] && log INFO "$line" "project=$project"
        done <<< "$output"
        if [[ $rc -eq 0 ]]; then
            log INFO "compose down complete" "project=$project"
        else
            log ERROR "compose down failed" "project=$project" "exit_code=$rc"
        fi
        log INFO "pruning dangling resources" "project=$project"
        for resource in image container volume; do
            local prune_out
            prune_out=$(docker "$resource" prune -f 2>&1) || true
            while IFS= read -r line; do
                [[ -n "$line" ]] && log INFO "$line" "resource=$resource"
            done <<< "$prune_out"
        done
        log INFO "prune complete" "project=$project"
    ) &
}
```

- [ ] **Step 3: Verify script still sources cleanly**

```bash
bash test/test_compose_watcher.sh
```

Expected: all tests still PASS (new functions don't break sourcing)

- [ ] **Step 4: Commit**

```bash
git add compose-watcher
git commit -m "feat: add compose upsert and cleanup operations with flock locking"
```

---

### Task 5: Startup scan

**Files:**
- Modify: `compose-watcher`

- [ ] **Step 1: Add `startup_scan` to `compose-watcher`** (insert before `main`):

```bash
# Find all .yml/.yaml files under WATCH_DIR and run compose_upsert on each.
# Runs at daemon startup to bring up any stacks that existed before the daemon started.
startup_scan() {
    log INFO "startup scan starting" "dir=$WATCH_DIR"
    while IFS= read -r -d '' file; do
        local project
        project=$(project_name "$WATCH_DIR" "$file")
        log INFO "startup: upserting stack" "project=$project" "file=$file"
        compose_upsert "$project" "$file"
    done < <(find "$WATCH_DIR" \( -name '*.yml' -o -name '*.yaml' \) -print0 2>/dev/null)
    log INFO "startup scan complete" "dir=$WATCH_DIR"
}
```

- [ ] **Step 2: Wire `startup_scan` into `main`** — replace the stub `printf` line with:

```bash
main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --watch-dir)   WATCH_DIR="$2";   shift 2 ;;
            --log-format)  LOG_FORMAT="$2";  shift 2 ;;
            -h|--help)     usage; exit 0 ;;
            *) printf 'Unknown flag: %s\n' "$1" >&2; usage >&2; exit 1 ;;
        esac
    done

    mkdir -p "$LOCK_DIR"
    log INFO "starting compose-watcher" "watch_dir=$WATCH_DIR" "log_format=$LOG_FORMAT"
    startup_scan
}
```

- [ ] **Step 3: Verify tests still pass**

```bash
bash test/test_compose_watcher.sh
```

Expected: all tests PASS

- [ ] **Step 4: Commit**

```bash
git add compose-watcher
git commit -m "feat: add startup scan to upsert existing stacks on boot"
```

---

### Task 6: inotifywait event loop

**Files:**
- Modify: `compose-watcher`

Events watched:
- `close_write` — file fully written (fires when scp finishes)
- `moved_to` — atomic rename (alternative write method)
- `delete` — file removed (triggers cleanup)
- `create` — watched only to detect new subdirectories; triggers a watcher restart

New directories (`CREATE,ISDIR`) are handled by `break`ing out of the `while read` loop. This closes the read end of the pipe, sending SIGPIPE to `inotifywait` and killing it. The outer `while true` loop then restarts `inotifywait` with the updated directory structure.

- [ ] **Step 1: Add `event_loop` to `compose-watcher`** (insert before `main`):

```bash
# Run inotifywait in monitor mode and dispatch events.
# Returns when a new subdirectory is detected so the caller can restart with updated watches.
event_loop() {
    inotifywait -m -r \
        --format '%w%f %e' \
        -e close_write \
        -e moved_to \
        -e delete \
        -e create \
        "$WATCH_DIR" 2>/dev/null |
    while IFS=' ' read -r filepath event; do
        # New directory — signal caller to restart inotifywait with updated watches
        if [[ "$event" == *ISDIR* ]]; then
            log INFO "new directory, reinitializing watcher" "path=$filepath"
            break
        fi

        # Only act on .yml and .yaml files
        case "$filepath" in
            *.yml|*.yaml) ;;
            *) continue ;;
        esac

        local project
        project=$(project_name "$WATCH_DIR" "$filepath")

        log INFO "event" "event=$event" "path=$filepath" "project=$project"

        case "$event" in
            CLOSE_WRITE*|MOVED_TO*)
                compose_upsert "$project" "$filepath"
                ;;
            DELETE*)
                compose_cleanup "$project"
                ;;
        esac
    done
}
```

- [ ] **Step 2: Wire `event_loop` into `main`** — append the watch loop after `startup_scan`:

```bash
main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --watch-dir)   WATCH_DIR="$2";   shift 2 ;;
            --log-format)  LOG_FORMAT="$2";  shift 2 ;;
            -h|--help)     usage; exit 0 ;;
            *) printf 'Unknown flag: %s\n' "$1" >&2; usage >&2; exit 1 ;;
        esac
    done

    mkdir -p "$LOCK_DIR"
    log INFO "starting compose-watcher" "watch_dir=$WATCH_DIR" "log_format=$LOG_FORMAT"
    startup_scan

    log INFO "watching for changes" "dir=$WATCH_DIR"
    while true; do
        event_loop
        log INFO "restarting watcher" "dir=$WATCH_DIR"
        sleep 1
    done
}
```

- [ ] **Step 3: Verify tests still pass**

```bash
bash test/test_compose_watcher.sh
```

Expected: all tests PASS

- [ ] **Step 4: Check script for syntax errors**

```bash
bash -n compose-watcher
```

Expected: no output, exit 0.

- [ ] **Step 5: Commit**

```bash
git add compose-watcher
git commit -m "feat: add inotifywait event loop with directory-change restart"
```

---

### Task 7: README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Write README**

`README.md`:
```markdown
# compose-watcher

A lightweight Linux daemon that manages Docker Compose stacks by watching a directory for file changes. Designed for PR preview environments: drop a compose file on the server to spin up a stack, remove it to tear it down.

## How it works

- **File created or modified** → `docker compose up -d --remove-orphans`
- **File deleted** → `docker compose down -v` → prune dangling images, containers, and volumes

The daemon watches a directory tree recursively using `inotifywait`. File writes are detected via `close_write` (triggered when scp finishes writing). Each active compose operation holds a per-project lock file (`flock`); if a second event arrives while an operation is still running, it is skipped. On startup the daemon scans the watch root and runs `compose up` on all existing `.yml`/`.yaml` files, making daemon restarts idempotent.

## Directory structure

```
/etc/compose-stacks/
├── repo-a/
│   ├── _traefik.yml       ← stable infra (underscore prefix is a convention only)
│   └── pr-123.yml         ← ephemeral PR preview
└── repo-b/
    ├── _traefik.yml
    └── pr-456.yml
```

Project names are derived from the subdirectory and filename stem:

```
/etc/compose-stacks/repo-a/pr-123.yml  →  project: repo-a-pr-123
```

## Requirements

- Linux
- `inotify-tools` package (`inotifywait`)
- Docker with Compose V2 (`docker compose` subcommand)
- `flock` (part of `util-linux`, standard on all Linux distributions)

Install inotify-tools if not present:

```bash
# Debian / Ubuntu
sudo apt-get install inotify-tools

# RHEL / Fedora / Rocky
sudo dnf install inotify-tools
```

## Install

Copy the script to a location on `$PATH`:

```bash
sudo install -m 755 compose-watcher /usr/local/bin/compose-watcher
```

## Configuration

| Flag | Environment variable | Default | Description |
|---|---|---|---|
| `--watch-dir` | `WATCH_DIR` | `/etc/compose-stacks` | Root directory to watch recursively |
| `--log-format` | `LOG_FORMAT` | `json` | `json` or `text` |

Lock files are written to `/run/compose-watcher/` by default. This directory is on tmpfs and is cleared on reboot, so stale locks from crashed processes are automatically removed. Override with the `LOCK_DIR` environment variable.

## systemd setup

Create the watch directory:

```bash
sudo mkdir -p /etc/compose-stacks
```

Create the unit file at `/etc/systemd/system/compose-watcher.service`:

```ini
[Unit]
Description=compose-watcher
After=docker.service
Requires=docker.service

[Service]
ExecStart=/usr/local/bin/compose-watcher --watch-dir=/etc/compose-stacks
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

Enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now compose-watcher
sudo journalctl -fu compose-watcher
```

## GitHub Actions integration

### Deploy preview (PR opened / pushed)

```yaml
- name: Deploy preview
  run: |
    envsubst < deploy/preview.yml.tmpl > pr-${{ github.event.pull_request.number }}.yml
    scp pr-${{ github.event.pull_request.number }}.yml \
        user@server:/etc/compose-stacks/${{ github.event.repository.name }}/
```

### Tear down preview (PR closed / merged)

```yaml
- name: Tear down preview
  run: |
    ssh user@server \
        rm /etc/compose-stacks/${{ github.event.repository.name }}/pr-${{ github.event.pull_request.number }}.yml
```

## Logging

JSON by default (`--log-format=text` for development). All Docker CLI output is captured and emitted as individual log lines. Example:

```json
{"time":"2026-04-16T12:00:00Z","level":"INFO","msg":"compose up complete","project":"repo-a-pr-123"}
{"time":"2026-04-16T12:01:00Z","level":"INFO","msg":"file deleted","event":"DELETE","path":"/etc/compose-stacks/repo-a/pr-123.yml","project":"repo-a-pr-123"}
```

## Adding a new repo

Create the subdirectory before or after starting the daemon. If added while the daemon is running, it will detect the new directory (via `inotifywait CREATE,ISDIR`) and restart its watches automatically. No daemon restart needed.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add installation and systemd setup guide"
```

---

### Task 8: Smoke test

Verify the script works end-to-end before calling it done.

- [ ] **Step 1: Run unit tests one final time**

```bash
bash test/test_compose_watcher.sh
```

Expected:
```
PASS: script is sourceable
PASS: json has level
PASS: json has msg
PASS: json has project
PASS: json has file
PASS: text has level
PASS: text has msg
PASS: text has kv
PASS: json escapes quotes
PASS: json escapes backslash
PASS: subdir/file.yml
PASS: subdir/file.yaml
PASS: underscore prefix
PASS: file directly in watch root
PASS: multi-dot stem

Results: 15 passed, 0 failed
```

- [ ] **Step 2: Syntax check**

```bash
bash -n compose-watcher
```

Expected: no output, exit 0.

- [ ] **Step 3: Test help flag**

```bash
./compose-watcher --help
```

Expected: usage text printed, exit 0.

- [ ] **Step 4: Test unknown flag**

```bash
./compose-watcher --unknown 2>&1 || true
```

Expected: `Unknown flag: --unknown` on stderr, exit 1.

- [ ] **Step 5: Commit**

```bash
git add .
git commit -m "chore: verify script correctness"
```
