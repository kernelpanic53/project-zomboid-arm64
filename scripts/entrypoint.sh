#!/bin/bash
set -Eeuo pipefail

SERVER_DIR="${PZ_SERVER_DIR:-/opt/zomboid}"
CONFIG_DIR="${PZ_CONFIG_DIR:-/config}"
DEPOTDOWNLOADER_DIR="${DEPOTDOWNLOADER_DIR:-/opt/depotdownloader}"
SERVER_NAME="${SERVER_NAME:-servertest}"
SERVER_BRANCH="${SERVER_BRANCH:-public}"
SERVER_PUBLIC="${SERVER_PUBLIC:-false}"
SERVER_PORT="${SERVER_PORT:-16261}"
SERVER_UDP_PORT="${SERVER_UDP_PORT:-16262}"
STEAM_PORT_1="${STEAM_PORT_1:-8766}"
STEAM_PORT_2="${STEAM_PORT_2:-8767}"
RCON_PORT="${RCON_PORT:-27015}"
MEMORY="${MEMORY:-4G}"
MEMORY_XMS="${MEMORY_XMS:-$MEMORY}"
MEMORY_XMX="${MEMORY_XMX:-$MEMORY}"
UPDATE_ON_START="${UPDATE_ON_START:-true}"
SERVER_ADMIN_USERNAME="${SERVER_ADMIN_USERNAME:-admin}"
SERVER_ADMIN_PASSWORD="${SERVER_ADMIN_PASSWORD:-}"
SERVER_PASSWORD="${SERVER_PASSWORD:-}"
SERVER_RCON_PASSWORD="${SERVER_RCON_PASSWORD:-}"
SERVER_DEBUG="${SERVER_DEBUG:-false}"
NO_STEAM="${NO_STEAM:-false}"
WORKSHOP_IDS="${WORKSHOP_IDS:-}"
MOD_IDS="${MOD_IDS:-}"
JAVA_EXTRA_ARGS="${JAVA_EXTRA_ARGS:-}"
JVM_EXTRA_ARGS="${JVM_EXTRA_ARGS:-}"
FEX_JIT_MODE="${FEX_JIT_MODE:-interpreter}"
HOME="${HOME:-/home/pz}"
SERVER_CONFIG_DIR="${CONFIG_DIR}/Server"
SERVER_INI="${SERVER_CONFIG_DIR}/${SERVER_NAME}.ini"

log() { echo "[entrypoint] $*"; }
fail() { echo "[entrypoint] ERROR: $*" >&2; exit 1; }
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then log "Entrypoint exiting with status ${exit_code}"; fi
    exit "$exit_code"
}
trap cleanup EXIT

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

install_server() {
    local depot_args=("-app" "380870" "-dir" "$SERVER_DIR" "-branch" "$SERVER_BRANCH")
    log "Installing/updating Project Zomboid dedicated server"
    log "AppID: 380870"
    log "Install directory: ${SERVER_DIR}"
    log "Branch: ${SERVER_BRANCH}"

    if [[ -n "${STEAM_USERNAME:-}" ]]; then
        depot_args+=("-username" "$STEAM_USERNAME")
        if [[ -n "${STEAM_PASSWORD:-}" ]]; then depot_args+=("-password" "$STEAM_PASSWORD"); fi
    fi
    if [[ -n "${STEAM_BRANCH_PASSWORD:-}" ]]; then
        depot_args+=("-branchpassword" "$STEAM_BRANCH_PASSWORD")
    fi
    if [[ -n "${STEAM_CMDLINE_ARGS:-}" ]]; then
        # shellcheck disable=SC2206
        depot_args+=( ${STEAM_CMDLINE_ARGS} )
    fi
    "$DEPOTDOWNLOADER_DIR/DepotDownloader" "${depot_args[@]}"

    [[ -f "$SERVER_DIR/jre64/bin/java" ]] || fail "Bundled Java runtime missing: $SERVER_DIR/jre64/bin/java"
    [[ -f "$SERVER_DIR/java/projectzomboid.jar" ]] || fail "Project Zomboid server JAR missing"
    chmod +x "$SERVER_DIR/jre64/bin/java" || true
    [[ ! -f "$SERVER_DIR/jre64/lib/jspawnhelper" ]] || chmod +x "$SERVER_DIR/jre64/lib/jspawnhelper" || true
    log "Project Zomboid server installation/update completed"
}

configure_fex() {
    local rootfs="${HOME}/.fex-emu/RootFS/${FEX_ROOTFS_NAME}"
    [[ -x /usr/bin/FEX ]] || fail "FEX executable not found at /usr/bin/FEX"
    [[ -d "$rootfs" && -x "$rootfs/bin/bash" ]] || fail "FEX x86-64 rootfs is missing or incomplete: ${rootfs}"
    export FEX_MULTIBLOCK="${FEX_MULTIBLOCK:-0}"
    log "FEX rootfs: ${rootfs}"
    log "FEX_MULTIBLOCK=${FEX_MULTIBLOCK}"
}

configure_steam_compatibility() {
    if [[ -f "$SERVER_DIR/linux64/steamclient.so" ]]; then
        ln -sfn "steamclient.so" "$SERVER_DIR/linux64/libsteam.so"
        log "Configured linux64/libsteam.so -> steamclient.so"
    fi
    if [[ -f "$SERVER_DIR/steamclient.so" ]]; then
        ln -sfn "steamclient.so" "$SERVER_DIR/libsteam.so"
    fi
}

set_ini() {
    local key="$1" value="$2" tmp
    tmp="$(mktemp "${SERVER_INI}.XXXXXX")"
    awk -v key="$key" -v value="$value" '
        BEGIN { found = 0 }
        {
            line = $0
            sub(/\r$/, "", line)
            if (line ~ "^" key "=") { print key "=" value; found = 1 }
            else { print line }
        }
        END { if (!found) print key "=" value }
    ' "$SERVER_INI" > "$tmp"
    mv "$tmp" "$SERVER_INI"
}

configure_server_ini() {
    mkdir -p "$SERVER_CONFIG_DIR"
    [[ -f "$SERVER_INI" ]] || touch "$SERVER_INI"
    set_ini "DefaultPort" "$SERVER_PORT"
    set_ini "UDPPort" "$SERVER_UDP_PORT"
    set_ini "SteamPort1" "$STEAM_PORT_1"
    set_ini "SteamPort2" "$STEAM_PORT_2"
    set_ini "RCONPort" "$RCON_PORT"
    set_ini "Public" "$SERVER_PUBLIC"
    [[ -z "$SERVER_PASSWORD" ]] || set_ini "Password" "$SERVER_PASSWORD"
    [[ -z "$SERVER_RCON_PASSWORD" ]] || set_ini "RCONPassword" "$SERVER_RCON_PASSWORD"
    [[ -z "$WORKSHOP_IDS" ]] || set_ini "WorkshopItems" "$WORKSHOP_IDS"
    [[ -z "$MOD_IDS" ]] || set_ini "Mods" "$MOD_IDS"
    [[ -z "$SERVER_ADMIN_USERNAME" ]] || set_ini "AdminUsername" "$SERVER_ADMIN_USERNAME"
    log "Configured server INI: ${SERVER_INI}"
    grep -E '^(DefaultPort|UDPPort|SteamPort1|SteamPort2|RCONPort|Public|WorkshopItems|Mods|AdminUsername)=' "$SERVER_INI" || true
}

configure_jvm() {
    local jvm_file="${SERVER_DIR}/ProjectZomboid64.json" tmp
    [[ -f "$jvm_file" ]] || { log "No ProjectZomboid64.json found; skipping JVM JSON adjustment"; return; }
    tmp="$(mktemp "${jvm_file}.XXXXXX")"
    jq --arg xms "$MEMORY_XMS" --arg xmx "$MEMORY_XMX" '
        if ($xms|length)>0 then
          map(if type=="string" and startswith("-Xms") then "-Xms"+$xms else . end)
        else
          map(select(type!="string" or (startswith("-Xms")|not)))
        end
        | if ($xmx|length)>0 then
          map(if type=="string" and startswith("-Xmx") then "-Xmx"+$xmx else . end)
        else
          map(select(type!="string" or (startswith("-Xmx")|not)))
        end
        | map(select(type!="string" or (startswith("-XX:")|not)))
    ' "$jvm_file" > "$tmp"
    mv "$tmp" "$jvm_file"
    log "Configured JVM options in ${jvm_file}"
}

build_classpath() {
    local cp=""
    if [[ -f "${SERVER_DIR}/ProjectZomboid64.json" ]]; then
        cp="$(jq -r '[.[]? | select(type=="string") | select(startswith("-Djava.class.path=")) | sub("^-Djava.class.path=";"")] | first // empty' "${SERVER_DIR}/ProjectZomboid64.json" 2>/dev/null || true)"
    fi
    printf '%s' "${cp:-java/.:java/projectzomboid.jar}"
}

start_server() {
    local server_args=() jvm_args=() jit_args=() classpath steam_flag
    [[ -z "$JAVA_EXTRA_ARGS" ]] || { # shellcheck disable=SC2206
        server_args+=( ${JAVA_EXTRA_ARGS} )
    }
    if [[ "${SERVER_DEBUG,,}" == "true" ]]; then server_args+=("-debug"); fi
    if [[ "${NO_STEAM,,}" == "true" ]]; then
        server_args+=("-nosteam")
        steam_flag="0"
    else
        steam_flag="1"
    fi
    [[ -z "$SERVER_ADMIN_PASSWORD" ]] || server_args+=("-adminpassword" "$SERVER_ADMIN_PASSWORD")

    jvm_args=("-Xms${MEMORY_XMS}" "-Xmx${MEMORY_XMX}")
    case "${FEX_JIT_MODE,,}" in
        interpreter)
            jit_args+=("-Xint")
            log "FEX JVM mode: interpreter (-Xint); slow but selected as the safer experimental default"
            ;;
        c1)
            jit_args+=("-XX:TieredStopAtLevel=1")
            log "FEX JVM mode: C1-only JIT"
            ;;
        default)
            log "FEX JVM mode: normal JVM JIT (experimental; may crash)"
            ;;
        *)
            fail "FEX_JIT_MODE must be interpreter, c1, or default"
            ;;
    esac
    [[ -z "$JVM_EXTRA_ARGS" ]] || { # shellcheck disable=SC2206
        jvm_args+=( ${JVM_EXTRA_ARGS} )
    }
    classpath="$(build_classpath)"
    log "Starting Project Zomboid server through FEX"
    log "Server name: ${SERVER_NAME}; port: ${SERVER_PORT}; UDP: ${SERVER_UDP_PORT}"
    log "Memory Xms/Xmx: ${MEMORY_XMS}/${MEMORY_XMX}"
    log "Classpath: ${classpath}"
    cd "$SERVER_DIR"

    exec /usr/bin/FEX "$SERVER_DIR/jre64/bin/java" \
        "${jvm_args[@]}" "${jit_args[@]}" \
        -Djava.awt.headless=true \
        "-Dzomboid.steam=${steam_flag}" \
        -Dzomboid.znetlog=1 \
        -Djava.security.egd=file:/dev/urandom \
        -XX:-OmitStackTraceInFastThrow \
        -Duser.home="${HOME}" \
        -Duser.timezone=UTC \
        -Ddeployment.user.cachedir="${CONFIG_DIR}" \
        -Djava.library.path="${SERVER_DIR}/linux64:${SERVER_DIR}/natives:${SERVER_DIR}" \
        -cp "$classpath" \
        zombie.network.GameServer \
        -servername "$SERVER_NAME" \
        -cachedir="$CONFIG_DIR" \
        "${server_args[@]}"
}

main() {
    log "Project Zomboid ARM64 FEX experimental container starting"
    log "Server directory: ${SERVER_DIR}"
    log "Config directory: ${CONFIG_DIR}"
    require_command curl
    require_command jq
    require_command /usr/bin/FEX
    mkdir -p "$SERVER_DIR" "$CONFIG_DIR"
    export PZ_SERVER_DIR="$SERVER_DIR" PZ_CONFIG_DIR="$CONFIG_DIR"
    export PATH="/usr/local/bin:/usr/bin:/bin:${SERVER_DIR}:${SERVER_DIR}/linux64"
    configure_fex
    if [[ "${UPDATE_ON_START,,}" == "true" || ! -f "$SERVER_DIR/java/projectzomboid.jar" ]]; then
        install_server
    else
        log "UPDATE_ON_START=false and server JAR exists; skipping update"
    fi
    configure_steam_compatibility
    configure_server_ini
    configure_jvm
    start_server
}
main "$@"
