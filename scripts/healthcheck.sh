#!/bin/bash
set -euo pipefail

RCON_PORT="${RCON_PORT:-27015}"

if nc -z 127.0.0.1 "$RCON_PORT" >/dev/null 2>&1; then
    exit 0
fi

pgrep -x ProjectZomboid64 >/dev/null 2>&1
