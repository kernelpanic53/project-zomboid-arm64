#!/bin/bash
set -euo pipefail

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

SERVER_DIR="${PZ_SERVER_DIR:-/opt/zomboid}"
CONFIG_DIR="${PZ_CONFIG_DIR:-/config}"
DD="${DEPOTDOWNLOADER_DIR:-/opt/depotdownloader}/DepotDownloader"

BRANCH="${SERVER_BRANCH:-public}"
SERVER_NAME="${SERVER_NAME:-servertest}"
SERVER_PORT="${SERVER_PORT:-16261}"
UDP_PORT="${SERVER_UDP_PORT:-16262}"
STEAM_PORT_1="${STEAM_PORT_1:-8766}"
STEAM_PORT_2="${STEAM_PORT_2:-8767}"
RCON_PORT="${RCON_PORT:-27015}"
MEMORY="${MEMORY:-4G}"

mkdir -p "$SERVER_DIR" "$CONFIG_DIR"

# -----------------------------------------------------------------------------
# Verify required tools.
# -----------------------------------------------------------------------------

if [[ ! -x "$DD" ]]; then
    log "ERROR: DepotDownloader not found at $DD"
    exit 1
fi

if ! command -v box64 >/dev/null 2>&1; then
    log "ERROR: Box64 was not found"
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    log "ERROR: jq was not found"
    exit 1
fi

# -----------------------------------------------------------------------------
# Install/update Project Zomboid.
# -----------------------------------------------------------------------------

install_server() {
    local args=(
        -app 380870
        -os linux
        -osarch 64
        -dir "$SERVER_DIR"
        -validate
    )

    if [[ -n "$BRANCH" && "${BRANCH,,}" != "public" ]]; then
        args+=(
            -branch "$BRANCH"
        )
    fi

    log "Installing/updating Project Zomboid AppID 380870 (branch: ${BRANCH})"

    "$DD" "${args[@]}"

    # DepotDownloader does not necessarily preserve executable bits from
    # the depot. Only mark known executable files as executable.
    if [[ -f "$SERVER_DIR/ProjectZomboid64" ]]; then
        chmod 0755 "$SERVER_DIR/ProjectZomboid64"
    fi

    if [[ -f "$SERVER_DIR/start-server.sh" ]]; then
        chmod 0755 "$SERVER_DIR/start-server.sh"
    fi

    if [[ -f "$SERVER_DIR/jre64/bin/java" ]]; then
        chmod 0755 "$SERVER_DIR/jre64/bin/java"
    fi

    if [[ ! -x "$SERVER_DIR/ProjectZomboid64" ]]; then
        log "ERROR: ProjectZomboid64 was not installed"
        exit 1
    fi
}

UPDATE_ON_START="${UPDATE_ON_START:-true}"

if [[ "${UPDATE_ON_START,,}" == "true" || ! -x "$SERVER_DIR/ProjectZomboid64" ]]; then
    install_server
else
    log "UPDATE_ON_START=false and server files already exist; skipping update"
fi

# -----------------------------------------------------------------------------
# Persistent Project Zomboid configuration.
# -----------------------------------------------------------------------------

# Project Zomboid stores persistent server/world configuration under ~/Zomboid.
# Keep it outside the game-install PVC so image updates do not touch it.

mkdir -p \
    "$CONFIG_DIR/Server" \
    "$CONFIG_DIR/Saves"

SERVER_INI="$CONFIG_DIR/Server/${SERVER_NAME}.ini"

FIRST_BOOT=false

if [[ ! -f "$SERVER_INI" ]]; then
    FIRST_BOOT=true
fi

touch "$SERVER_INI"

set_ini() {
    local key="$1"
    local value="$2"

    if grep -q "^${key}=" "$SERVER_INI"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$SERVER_INI"
    else
        printf '%s=%s\n' "$key" "$value" >> "$SERVER_INI"
    fi
}

# -----------------------------------------------------------------------------
# Server configuration.
# -----------------------------------------------------------------------------

set_ini "Public" "${SERVER_PUBLIC:-false}"

if [[ -n "${SERVER_DISPLAY_NAME:-}" ]]; then
    set_ini "PublicName" "${SERVER_DISPLAY_NAME}"
fi

if [[ -n "${SERVER_PASSWORD:-}" ]]; then
    set_ini "Password" "${SERVER_PASSWORD}"
fi

if [[ -n "${RCON_PASSWORD:-}" ]]; then
    set_ini "RCONPassword" "${RCON_PASSWORD}"
fi

set_ini "RCONPort" "$RCON_PORT"
set_ini "UDPPort" "$UDP_PORT"
set_ini "SteamPort1" "$STEAM_PORT_1"
set_ini "SteamPort2" "$STEAM_PORT_2"

if [[ -n "${WORKSHOP_IDS:-}" ]]; then
    set_ini "WorkshopItems" "${WORKSHOP_IDS}"
fi

if [[ -n "${MOD_IDS:-}" ]]; then
    set_ini "Mods" "${MOD_IDS}"
fi

# -----------------------------------------------------------------------------
# Box64 environment.
# -----------------------------------------------------------------------------

# pzexe invokes "java" by name, so /usr/local/bin must be in PATH.
# /usr/local/bin/java is our Box64 wrapper for the bundled x86_64 JRE.

export PATH="/usr/local/bin:/usr/bin:/bin"

export BOX64_PATH="$SERVER_DIR/jre64/bin:/usr/local/bin:/usr/bin:/bin"

export BOX64_LD_LIBRARY_PATH="$SERVER_DIR/linux64:$SERVER_DIR/natives:$SERVER_DIR/jre64/lib:$SERVER_DIR/jre64/lib/server:${BOX64_LD_LIBRARY_PATH:-}"

export LD_LIBRARY_PATH="$SERVER_DIR/linux64:$SERVER_DIR/natives:$SERVER_DIR/jre64/lib:$SERVER_DIR/jre64/lib/server:${LD_LIBRARY_PATH:-}"

JAVA_BIN="$SERVER_DIR/jre64/bin/java"

if [[ ! -x "$JAVA_BIN" ]]; then
    log "ERROR: bundled 64-bit Java runtime not found at $JAVA_BIN"
    exit 1
fi

if ! command -v java >/dev/null 2>&1; then
    log "ERROR: Java wrapper was not found in PATH"
    exit 1
fi

# -----------------------------------------------------------------------------
# JVM memory configuration.
# -----------------------------------------------------------------------------

if [[ -n "${MEMORY_XMS:-}" ]]; then
    XMS="$MEMORY_XMS"
else
    XMS="$MEMORY"
fi

if [[ -n "${MEMORY_XMX:-}" ]]; then
    XMX="$MEMORY_XMX"
else
    XMX="$MEMORY"
fi

# -----------------------------------------------------------------------------
# Project Zomboid JVM configuration.
# -----------------------------------------------------------------------------

JSON_FILE="$SERVER_DIR/ProjectZomboid64.json"

if [[ -f "$JSON_FILE" ]]; then
    TMP_JSON="${JSON_FILE}.tmp"

    if ! jq \
        --arg xms "$XMS" \
        --arg xmx "$XMX" \
        --arg extra "${JAVA_EXTRA_ARGS:-}" \
        '
        .vmArgs =
            (
                (.vmArgs // [])
                |
                if type == "string"
                then split(" ")
                else .
                end
                |
                map(select(length > 0))
                |
                map(select(
                    (
                        startswith("-Xms")
                        or startswith("-Xmx")
                        or startswith("-XX:")
                    ) | not
                ))
                +
                [
                    "-Xms" + $xms,
                    "-Xmx" + $xmx,
                    "-XX:+UseSerialGC",
                    "-XX:-TieredCompilation",
                    "-XX:CICompilerCount=1",
                    "-XX:-UseCompressedOops",
                    "-XX:-UseCompressedClassPointers"
                ]
                +
                (
                    if ($extra | length) > 0
                    then $extra | split(" ") | map(select(length > 0))
                    else []
                    end
                )
            )
        |
        .initialHeap = $xms
        |
        .maxHeap = $xmx
        ' "$JSON_FILE" > "$TMP_JSON"
    then
        rm -f "$TMP_JSON"
        log "ERROR: Failed to update $JSON_FILE"
        exit 1
    fi

    if ! jq empty "$TMP_JSON" >/dev/null 2>&1; then
        rm -f "$TMP_JSON"
        log "ERROR: Generated invalid JSON in $JSON_FILE"
        exit 1
    fi

    mv "$TMP_JSON" "$JSON_FILE"
fi

# -----------------------------------------------------------------------------
# Verify the bundled JVM through Box64 before starting Project Zomboid.
# -----------------------------------------------------------------------------

log "Java wrapper: $(command -v java)"
log "Bundled Java: $JAVA_BIN"
log "Testing bundled x86_64 Java through Box64..."

if ! java -version 2>&1; then
    log "ERROR: Bundled Java failed to start through Box64"
    exit 1
fi

log "Java runtime successfully started through Box64"

# -----------------------------------------------------------------------------
# Start Project Zomboid.
# -----------------------------------------------------------------------------

cd "$SERVER_DIR"

ARGS=(
    "-cachedir=${CONFIG_DIR}"
    "-servername" "$SERVER_NAME"
    "-port" "$SERVER_PORT"
)

if [[ -n "${ADMIN_USERNAME:-}" ]]; then
    ARGS+=(
        "-adminusername" "$ADMIN_USERNAME"
    )
fi

# Only pass the admin password on first boot.
# Project Zomboid can expose command-line arguments in logs, so repeating the
# password on every restart unnecessarily exposes the secret.

if [[ "$FIRST_BOOT" == "true" && -n "${ADMIN_PASSWORD:-}" ]]; then
    ARGS+=(
        "-adminpassword" "$ADMIN_PASSWORD"
    )
fi

if [[ "${DEBUG:-false}" == "true" ]]; then
    ARGS+=(
        "-debug"
    )
fi

if [[ "${NOSTEAM:-false}" == "true" ]]; then
    ARGS+=(
        "-nosteam"
    )
fi

log "Starting Project Zomboid ${SERVER_NAME}"
log "Game UDP: ${SERVER_PORT}/${UDP_PORT}"
log "Steam UDP: ${STEAM_PORT_1}/${STEAM_PORT_2}"
log "RCON TCP: ${RCON_PORT}"
log "Box64: $(box64 --version 2>&1 | head -n 1)"

# -----------------------------------------------------------------------------
# Graceful Kubernetes shutdown.
#
# Project Zomboid reads commands from stdin. A FIFO allows the SIGTERM handler
# to send "save" and "quit" to the server before the container exits.
# -----------------------------------------------------------------------------

CONSOLE_FIFO="/tmp/pz-console"

rm -f "$CONSOLE_FIFO"
mkfifo "$CONSOLE_FIFO"

exec {CONSOLE_FD}<>"$CONSOLE_FIFO"

SERVER_PID=""

cleanup() {
    rm -f "$CONSOLE_FIFO"
}

shutdown() {
    log "Shutdown requested; asking Project Zomboid to save and quit"

    printf 'save\nquit\n' >&"${CONSOLE_FD}" || true

    if [[ -n "${SERVER_PID:-}" ]]; then
        for _ in {1..60}; do
            if ! kill -0 "$SERVER_PID" 2>/dev/null; then
                return 0
            fi

            sleep 1
        done

        log "Server did not exit after graceful shutdown; sending SIGTERM"

        kill -TERM "$SERVER_PID" 2>/dev/null || true
    fi
}

trap shutdown TERM INT
trap cleanup EXIT

box64 "$SERVER_DIR/ProjectZomboid64" "${ARGS[@]}" <"$CONSOLE_FIFO" &
SERVER_PID=$!

wait "$SERVER_PID"
STATUS=$?

exit "$STATUS"
