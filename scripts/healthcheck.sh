#!/bin/bash
set -euo pipefail

# RCON is the most useful readiness signal because it means the Java server has
# completed startup. Fall back to the process check during early initialization.
RCON_PORT="${RCON_PORT:-27015}"

if nc -z 127.0.0.1 "$RCON_PORT" 2>/dev/null; then
  exit 0
fi

pgrep -x ProjectZomboid64 >/dev/null 2>&1
