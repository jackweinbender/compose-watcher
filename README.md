# compose-watcher

A lightweight Linux daemon that manages Docker Compose stacks by watching a directory for file changes. Designed for PR preview environments: drop a compose file on the server to spin up a stack, remove it to tear it down.

## How it works

- **File created or modified** → `docker compose up -d --remove-orphans`
- **File deleted** → `docker compose down -v --rmi local`

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

### YOLO

```sh
curl -fsSL https://raw.githubusercontent.com/jackweinbender/compose-watcher/main/install.sh | sh
```

Downloads the script, installs it to `/usr/local/bin`, creates `/etc/compose-stacks`, and enables the systemd service. Requires `inotify-tools`, `docker`, and `flock`.

### Manual

Copy the script to a location on `$PATH`:

```bash
sudo install -m 755 compose-watcher /usr/local/bin/compose-watcher
```

## Configuration

All configuration is via environment variables.

| Variable | Default | Description |
|---|---|---|
| `WATCH_DIR` | `/etc/compose-stacks` | Root directory to watch recursively |
| `LOCK_DIR` | `/run/compose-watcher` | Per-project lock files (on tmpfs; stale locks clear on reboot) |

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
Environment=WATCH_DIR=/etc/compose-stacks
ExecStart=/usr/local/bin/compose-watcher
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

Plain-text log lines written to stdout. journald captures these and adds its own timestamps. Format is `LEVEL message key=value ...`:

```
INFO starting watch_dir=/etc/compose-stacks
INFO up starting project=repo-a-pr-123 file=/etc/compose-stacks/repo-a/pr-123.yml
INFO up complete project=repo-a-pr-123
INFO event=DELETE path=/etc/compose-stacks/repo-a/pr-123.yml project=repo-a-pr-123
INFO down starting project=repo-a-pr-123
INFO down complete project=repo-a-pr-123
```

Docker's own output is suppressed; operators can run `docker compose -p <project> logs` or `docker compose -p <project> up -d` manually to see stack-level detail.

For cleanup of dangling images accumulated during rebuilds, schedule a periodic `docker system prune -f` via cron or a systemd timer — this is deliberately not done by the daemon so its cleanup is strictly project-scoped.

## Adding a new repo

Create the subdirectory before or after starting the daemon. If added while the daemon is running, it will detect the new directory (via `inotifywait CREATE,ISDIR`) and restart its watches automatically. No daemon restart needed.
