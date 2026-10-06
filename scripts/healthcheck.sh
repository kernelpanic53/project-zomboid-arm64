#!/bin/bash
set -euo pipefail

RCON_PORT="${RCON_PORT:-27015}"

# Check whether the RCON TCP port is accepting connections.
if nc -z 127.0.0.1 "$RCON_PORT" >/dev/null 2>&1; then
    exit 0
fi

# During startup, RCON may not be listening yet.
# Consider the container healthy if the Project Zomboid process is still alive.
pgrep -x ProjectZomboid64 >/dev/null 2>&1
