#!/bin/bash
set -euo pipefail

RCON_PORT="${RCON_PORT:-27015}"

if nc -z 127.0.0.1 "$RCON_PORT" >/dev/null 2>&1; then
    exit 0
fi

# The server is launched as the bundled x86_64 Java process under Box64,
# so match on the GameServer main class rather than ProjectZomboid64.
pgrep -f "zombie.network.GameServer" >/dev/null 2>&1
