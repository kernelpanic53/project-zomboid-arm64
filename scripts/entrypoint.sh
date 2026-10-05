#!/bin/bash
set -euo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

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

if [[ ! -x "$DD" ]]; then
  log "ERROR: DepotDownloader not found at $DD"
  exit 1
fi

install_server() {
  local args=(
    -app 380870
    -os linux
    -osarch 64
    -dir "$SERVER_DIR"
    -validate
  )

  if [[ -n "$BRANCH" && "${BRANCH,,}" != "public" ]]; then
    args+=(-branch "$BRANCH")
  fi

  log "Installing/updating Project Zomboid AppID 380870 (branch: ${BRANCH})"
  "$DD" "${args[@]}"

  # DepotDownloader does not preserve executable bits from the depot.
  chmod +x \
    "$SERVER_DIR/ProjectZomboid64" \
    "$SERVER_DIR/start-server.sh" \
    "$SERVER_DIR/jre64/bin"/* 2>/dev/null || true

  if [[ ! -x "$SERVER_DIR/ProjectZomboid64" ]]; then
    log "ERROR: ProjectZomboid64 was not installed"
    exit 1
  fi
}

if [[ "${UPDATE_ON_START,,}" == "true" || ! -x "$SERVER_DIR/ProjectZomboid64" ]]; then
  install_server
else
  log "UPDATE_ON_START=false and server files already exist; skipping update"
fi

# Project Zomboid stores its persistent server/world configuration under
# ~/Zomboid. Keep it outside the game-install PVC so image updates do not touch it.
mkdir -p "$CONFIG_DIR/Server" "$CONFIG_DIR/Saves"

SERVER_INI="$CONFIG_DIR/Server/${SERVER_NAME}.ini"
FIRST_BOOT=false
if [[ ! -f "$SERVER_INI" ]]; then
  FIRST_BOOT=true
fi
touch "$SERVER_INI"

set_ini() {
  local key="$1" value="$2"
  if grep -q "^${key}=" "$SERVER_INI"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$SERVER_INI"
  else
    printf '%s=%s\n' "$key" "$value" >> "$SERVER_INI"
  fi
}

# Preserve the fork's useful environment-driven configuration model.
set_ini "Public" "${SERVER_PUBLIC}"
[[ -n "${SERVER_DISPLAY_NAME:-}" ]] && set_ini "PublicName" "${SERVER_DISPLAY_NAME}"
[[ -n "${SERVER_PASSWORD:-}" ]] && set_ini "Password" "${SERVER_PASSWORD}"
[[ -n "${RCON_PASSWORD:-}" ]] && set_ini "RCONPassword" "${RCON_PASSWORD}"
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

# Project Zomboid's launcher invokes an x86_64 JVM and native server binary.
# Box64 translates both while using the ARM64 host's native libc.
export BOX64_PATH="$SERVER_DIR/jre64/bin:/usr/local/bin:/usr/bin:/bin"
export BOX64_LD_LIBRARY_PATH="$SERVER_DIR/linux64:$SERVER_DIR/natives:$SERVER_DIR/jre64/lib:$SERVER_DIR/jre64/lib/server:${BOX64_LD_LIBRARY_PATH:-}"
export LD_LIBRARY_PATH="$SERVER_DIR/linux64:$SERVER_DIR/natives:$SERVER_DIR/jre64/lib:$SERVER_DIR/jre64/lib/server:${LD_LIBRARY_PATH:-}"

# Build 42's bundled JVM is x86_64. Explicitly invoke the x86_64 launcher through Box64.
JAVA_BIN="$SERVER_DIR/jre64/bin/java"
if [[ ! -x "$JAVA_BIN" ]]; then
  log "ERROR: bundled 64-bit Java runtime not found at $JAVA_BIN"
  exit 1
fi

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

# ProjectZomboid64 reads its JVM settings from ProjectZomboid64.json. Patch the
# bundled configuration rather than passing JVM flags to the native launcher.
JSON_FILE="$SERVER_DIR/ProjectZomboid64.json"
if [[ -f "$JSON_FILE" ]]; then
  TMP_JSON="${JSON_FILE}.tmp"
  jq --arg xms "$XMS" --arg xmx "$XMX" \
    '.vmArgs = ((.vmArgs // []) | if type == "string" then split(" ") else . end | map(select(test("^-Xms|^-Xmx|^-XX:" ) | not)) + ["-Xms" + $xms, "-Xmx" + $xmx, "-XX:+UseSerialGC", "-XX:-TieredCompilation", "-XX:CICompilerCount=1", "-XX:-UseCompressedOops", "-XX:-UseCompressedClassPointers"]) | .initialHeap = $xms | .maxHeap = $xmx' \
    "$JSON_FILE" > "$TMP_JSON" && mv "$TMP_JSON" "$JSON_FILE"
fi

# Let ProjectZomboid64's launcher assemble the game classpath and native setup.
# Running it via Box64 is more reliable than relying on host binfmt_misc.
cd "$SERVER_DIR"

ARGS=(
  "-cachedir=${CONFIG_DIR}"
  "-servername" "$SERVER_NAME"
  "-port" "$SERVER_PORT"
)

[[ -n "${ADMIN_USERNAME:-}" ]] && ARGS+=("-adminusername" "$ADMIN_USERNAME")
# Only pass the admin password on the first boot; Project Zomboid logs command-line
# arguments, so repeating it on every restart unnecessarily exposes the secret.
if [[ "$FIRST_BOOT" == "true" && -n "${ADMIN_PASSWORD:-}" ]]; then
  ARGS+=("-adminpassword" "$ADMIN_PASSWORD")
fi
[[ "${DEBUG:-false}" == "true" ]] && ARGS+=("-debug")
[[ "${NOSTEAM:-false}" == "true" ]] && ARGS+=("-nosteam")

log "Starting Project Zomboid ${SERVER_NAME} on UDP ${SERVER_PORT}/${UDP_PORT}, Steam UDP ${STEAM_PORT_1}/${STEAM_PORT_2}, RCON TCP ${RCON_PORT}"
log "Box64: $(box64 --version 2>&1 | head -n 1)"

# ProjectZomboid64 reads commands from stdin. A FIFO lets Kubernetes SIGTERM
# become the game's `quit` command so the world is saved before the pod exits.
CONSOLE_FIFO="/tmp/pz-console"
rm -f "$CONSOLE_FIFO"
mkfifo "$CONSOLE_FIFO"
exec {CONSOLE_FD}<>"$CONSOLE_FIFO"

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

log "Starting Project Zomboid ${SERVER_NAME} on UDP ${SERVER_PORT}/${UDP_PORT}, Steam UDP ${STEAM_PORT_1}/${STEAM_PORT_2}, RCON TCP ${RCON_PORT}"
log "Box64: $(box64 --version 2>&1 | head -n 1)"

box64 "$SERVER_DIR/ProjectZomboid64" "${ARGS[@]}" <"$CONSOLE_FIFO" &
SERVER_PID=$!
wait "$SERVER_PID"
STATUS=$?
rm -f "$CONSOLE_FIFO"
exit "$STATUS"
