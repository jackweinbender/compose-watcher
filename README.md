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
{"time":"2026-04-16T12:01:00Z","level":"INFO","msg":"event","event":"DELETE","path":"/etc/compose-stacks/repo-a/pr-123.yml","project":"repo-a-pr-123"}
```

## Adding a new repo

Create the subdirectory before or after starting the daemon. If added while the daemon is running, it will detect the new directory (via `inotifywait CREATE,ISDIR`) and restart its watches automatically. No daemon restart needed.
