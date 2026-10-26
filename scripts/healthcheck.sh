#!/bin/bash
set -euo pipefail

RCON_PORT="${RCON_PORT:-27015}"
SERVER_PID_FILE="${PZ_CONFIG_DIR:-/config}/.pz-server.pid"

if nc -z 127.0.0.1 "$RCON_PORT" >/dev/null 2>&1; then
    exit 0
fi

# The entrypoint records its PID immediately before exec'ing Box64/Java. The
# exec preserves that PID, so this works even when Box64 rewrites argv and
# pgrep cannot see the emulated Java main-class name.
if [[ -r "$SERVER_PID_FILE" ]]; then
    server_pid=""
    if IFS= read -r server_pid < "$SERVER_PID_FILE" \
        && [[ "$server_pid" =~ ^[0-9]+$ ]] \
        && kill -0 "$server_pid" 2>/dev/null; then
        exit 0
    fi
fi

# Keep compatibility with manual runs that don't use the container entrypoint.
if command -v pgrep >/dev/null 2>&1 \
    && pgrep -f "zombie.network.GameServer" >/dev/null 2>&1; then
    exit 0
fi

echo "No RCON listener or live Project Zomboid server process found" >&2
exit 1
