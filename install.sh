#!/usr/bin/env sh
# install.sh — install compose-watcher on a standard Linux box
# Usage: curl -fsSL https://raw.githubusercontent.com/jackweinbender/compose-watcher/main/install.sh | sh
set -e

INSTALL_BIN="${INSTALL_BIN:-/usr/local/bin/compose-watcher}"
WATCH_DIR="${WATCH_DIR:-/etc/compose-stacks}"
UNIT_FILE="/etc/systemd/system/compose-watcher.service"
REPO="jackweinbender/compose-watcher"

# Use sudo only when not already root.
maybe_sudo() { [ "$(id -u)" -eq 0 ] && "$@" || sudo "$@"; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: $1 is required but not installed." >&2; exit 1; }; }

need curl
need docker
need flock
if ! command -v inotifywait >/dev/null 2>&1; then
    echo "ERROR: inotifywait not found. Install inotify-tools:" >&2
    echo "  apt-get install inotify-tools  OR  dnf install inotify-tools" >&2
    exit 1
fi

echo "==> Downloading compose-watcher..."
tmp=$(mktemp)
curl -fsSL "https://raw.githubusercontent.com/${REPO}/main/compose-watcher" -o "$tmp"
maybe_sudo install -m 755 "$tmp" "$INSTALL_BIN"
rm -f "$tmp"
echo "    Installed to $INSTALL_BIN"

echo "==> Creating watch directory $WATCH_DIR..."
maybe_sudo mkdir -p "$WATCH_DIR"

echo "==> Installing systemd unit..."
maybe_sudo sh -c "cat > '$UNIT_FILE'" <<EOF
[Unit]
Description=compose-watcher
After=docker.service
Requires=docker.service

[Service]
Environment=WATCH_DIR=$WATCH_DIR
ExecStart=$INSTALL_BIN
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

maybe_sudo systemctl daemon-reload
maybe_sudo systemctl enable compose-watcher
maybe_sudo systemctl restart compose-watcher

echo ""
echo "compose-watcher is running. Logs:"
echo "  journalctl -fu compose-watcher"
echo ""
echo "Deploy a stack by dropping a compose file into $WATCH_DIR/<repo>/<name>.yml"
