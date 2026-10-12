#!/bin/bash
set -Eeuo pipefail

RCON_PORT="${RCON_PORT:-27015}"

# If RCON is configured and listening, the server is ready.
if nc -z 127.0.0.1 "$RCON_PORT" >/dev/null 2>&1; then
    exit 0
fi

# Otherwise fall back to checking for the Java GameServer process.
pgrep -f 'zombie\.network\.GameServer' >/dev/null 2>&1
