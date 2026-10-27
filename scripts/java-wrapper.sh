#!/bin/sh
set -eu

SERVER_DIR="${PZ_SERVER_DIR:-/opt/zomboid}"
if [ "${JAVA_RUNTIME:-bundled}" = "zulu" ]; then
    JAVA_BIN="/opt/zulu-jre/bin/java"
else
    JAVA_BIN="${SERVER_DIR}/jre64/bin/java"
fi

if [ ! -x "$JAVA_BIN" ]; then
    echo "ERROR: selected Java runtime not found at $JAVA_BIN" >&2
    exit 1
fi

exec /usr/local/bin/box64 "$JAVA_BIN" "$@"
