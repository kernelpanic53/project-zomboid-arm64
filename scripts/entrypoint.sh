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
MEMORY_XMS="${MEMORY_XMS:-}"
MEMORY_XMX="${MEMORY_XMX:-}"

UPDATE_ON_START="${UPDATE_ON_START:-true}"

SERVER_ADMIN_USERNAME="${SERVER_ADMIN_USERNAME:-admin}"
SERVER_PASSWORD="${SERVER_PASSWORD:-}"

SERVER_DEBUG="${SERVER_DEBUG:-false}"
NO_STEAM="${NO_STEAM:-false}"

WORKSHOP_IDS="${WORKSHOP_IDS:-}"
MOD_IDS="${MOD_IDS:-}"
JAVA_EXTRA_ARGS="${JAVA_EXTRA_ARGS:-}"

HOME="${HOME:-/home/pz}"

SERVER_CONFIG_DIR="${CONFIG_DIR}/Server"
SERVER_INI="${SERVER_CONFIG_DIR}/${SERVER_NAME}.ini"


log() {
    echo "[entrypoint] $*"
}


fail() {
    echo "[entrypoint] ERROR: $*" >&2
    exit 1
}


cleanup() {
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log "Entrypoint exiting with status ${exit_code}"
    fi

    exit "$exit_code"
}


trap cleanup EXIT


require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}


install_server() {
    local depot_args=(
        "-app"
        "380870"
        "-dir"
        "$SERVER_DIR"
        "-branch"
        "$SERVER_BRANCH"
    )

    log "Installing/updating Project Zomboid dedicated server"
    log "AppID: 380870"
    log "Install directory: ${SERVER_DIR}"
    log "Branch: ${SERVER_BRANCH}"

    if [[ -n "${STEAM_USERNAME:-}" ]]; then
        depot_args+=(
            "-username"
            "$STEAM_USERNAME"
        )

        if [[ -n "${STEAM_PASSWORD:-}" ]]; then
            depot_args+=(
                "-password"
                "$STEAM_PASSWORD"
            )
        fi
    fi

    if [[ -n "${STEAM_BRANCH_PASSWORD:-}" ]]; then
        depot_args+=(
            "-branchpassword"
            "$STEAM_BRANCH_PASSWORD"
        )
    fi

    if [[ -n "${STEAM_CMDLINE_ARGS:-}" ]]; then
        # shellcheck disable=SC2206
        depot_args+=( ${STEAM_CMDLINE_ARGS} )
    fi

    "$DEPOTDOWNLOADER_DIR/DepotDownloader" "${depot_args[@]}"

    if [[ ! -x "$SERVER_DIR/ProjectZomboid64" ]]; then
        fail "Project Zomboid server executable was not found at ${SERVER_DIR}/ProjectZomboid64"
    fi

    log "Project Zomboid server installation/update completed"
}


configure_steam_compatibility() {
    # Project Zomboid's Steam networking code expects libsteam.so.
    # The official Linux server distribution provides steamclient.so.
    #
    # Under Box64, provide libsteam.so as a symlink to steamclient.so
    # so the Steam networking libraries can resolve correctly.

    if [[ -f "$SERVER_DIR/linux64/steamclient.so" ]]; then
        ln -sfn "steamclient.so" "$SERVER_DIR/linux64/libsteam.so"
        log "Configured linux64/libsteam.so -> steamclient.so"
    else
        log "WARNING: ${SERVER_DIR}/linux64/steamclient.so not found"
    fi

    # Also provide the compatibility link at the server root.
    if [[ -f "$SERVER_DIR/steamclient.so" ]]; then
        ln -sfn "steamclient.so" "$SERVER_DIR/libsteam.so"
        log "Configured libsteam.so -> steamclient.so"
    fi
}


configure_java() {
    local java_bin="${SERVER_DIR}/jre64/bin/java"
    local jspawnhelper="${SERVER_DIR}/jre64/lib/jspawnhelper"
    local java_output

    if [[ ! -x "$java_bin" ]]; then
        fail "Bundled Java runtime not found at ${java_bin}"
    fi

    if [[ -f "$jspawnhelper" ]]; then
        chmod +x "$jspawnhelper" || true
    fi

    log "Java runtime: ${java_bin}"

    # The /usr/local/bin/java wrapper launches the bundled x86_64
    # Java runtime through Box64.
    if java_output="$(java -version 2>&1)"; then
        log "Java runtime successfully started through Box64"

        while IFS= read -r line; do
            log "Java: ${line}"
        done <<< "$java_output"
    else
        log "Java/Box64 startup failed"
        log "$java_output"
        fail "Unable to start bundled Java runtime through Box64"
    fi
}


set_ini() {
    local key="$1"
    local value="$2"
    local tmp

    tmp="$(mktemp "${SERVER_INI}.XXXXXX")"

    awk -v key="$key" -v value="$value" '
        BEGIN {
            found = 0
        }

        {
            line = $0
            sub(/\r$/, "", line)

            if (line ~ "^" key "=") {
                print key "=" value
                found = 1
            } else {
                print line
            }
        }

        END {
            if (!found) {
                print key "=" value
            }
        }
    ' "$SERVER_INI" > "$tmp"

    mv "$tmp" "$SERVER_INI"
}


configure_server_ini() {
    mkdir -p "$SERVER_CONFIG_DIR"

    if [[ ! -f "$SERVER_INI" ]]; then
        log "Creating server configuration: ${SERVER_INI}"
        touch "$SERVER_INI"
    fi

    set_ini "DefaultPort" "$SERVER_PORT"
    set_ini "UDPPort" "$SERVER_UDP_PORT"
    set_ini "SteamPort1" "$STEAM_PORT_1"
    set_ini "SteamPort2" "$STEAM_PORT_2"
    set_ini "RCONPort" "$RCON_PORT"

    set_ini "Public" "$SERVER_PUBLIC"

    if [[ -n "$SERVER_PASSWORD" ]]; then
        set_ini "Password" "$SERVER_PASSWORD"
    fi

    if [[ -n "$WORKSHOP_IDS" ]]; then
        set_ini "WorkshopItems" "$WORKSHOP_IDS"
    fi

    if [[ -n "$MOD_IDS" ]]; then
        set_ini "Mods" "$MOD_IDS"
    fi

    if [[ -n "$SERVER_ADMIN_USERNAME" ]]; then
        set_ini "AdminUsername" "$SERVER_ADMIN_USERNAME"
    fi

    log "Configured server INI: ${SERVER_INI}"

    log "Relevant server settings:"

    grep -E \
        '^(DefaultPort|UDPPort|SteamPort1|SteamPort2|RCONPort|Public|Password|WorkshopItems|Mods|AdminUsername)=' \
        "$SERVER_INI" || true
}


configure_jvm() {
    local jvm_file="${SERVER_DIR}/ProjectZomboid64.json"
    local tmp

    if [[ ! -f "$jvm_file" ]]; then
        log "No ProjectZomboid64.json found; using server defaults"
        return
    fi

    tmp="$(mktemp "${jvm_file}.XXXXXX")"

    jq \
        --arg xms "$MEMORY_XMS" \
        --arg xmx "$MEMORY_XMX" \
        '
        if ($xms | length) > 0 then
            map(
                if (
                    type == "string"
                    and startswith("-Xms")
                ) then
                    "-Xms" + $xms
                else
                    .
                end
            )
        else
            map(
                select(
                    type != "string"
                    or (startswith("-Xms") | not)
                )
            )
        end
        |
        if ($xmx | length) > 0 then
            map(
                if (
                    type == "string"
                    and startswith("-Xmx")
                ) then
                    "-Xmx" + $xmx
                else
                    .
                end
            )
        else
            map(
                select(
                    type != "string"
                    or (startswith("-Xmx") | not)
                )
            )
        end
        |
        map(
            select(
                type != "string"
                or (startswith("-XX:") | not)
            )
        )
        ' \
        "$jvm_file" > "$tmp"

    mv "$tmp" "$jvm_file"

    log "Configured JVM options in ${jvm_file}"
}


configure_environment() {
    export PZ_SERVER_DIR="$SERVER_DIR"
    export PZ_CONFIG_DIR="$CONFIG_DIR"

    export BOX64_PATH="${SERVER_DIR}/linux64:${SERVER_DIR}"
    export BOX64_LD_LIBRARY_PATH="${SERVER_DIR}/linux64:${SERVER_DIR}"
    export LD_LIBRARY_PATH="${SERVER_DIR}/linux64:${SERVER_DIR}:${LD_LIBRARY_PATH:-}"

    export PATH="/usr/local/bin:/usr/bin:/bin:${SERVER_DIR}:${SERVER_DIR}/linux64"

    log "BOX64_LOG=${BOX64_LOG:-0}"
    log "BOX64_PATH=${BOX64_PATH}"
    log "BOX64_LD_LIBRARY_PATH=${BOX64_LD_LIBRARY_PATH}"
    log "LD_LIBRARY_PATH=${LD_LIBRARY_PATH}"
}


start_server() {
    local server_args=()

    if [[ -n "$JAVA_EXTRA_ARGS" ]]; then
        # shellcheck disable=SC2206
        server_args+=( ${JAVA_EXTRA_ARGS} )
    fi

    if [[ "${SERVER_DEBUG,,}" == "true" ]]; then
        server_args+=(
            "-debug"
        )
    fi

    if [[ "${NO_STEAM,,}" == "true" ]]; then
        server_args+=(
            "-nosteam"
        )
    fi

    log "Starting Project Zomboid server"
    log "Server name: ${SERVER_NAME}"
    log "Server port: ${SERVER_PORT}"
    log "UDP port: ${SERVER_UDP_PORT}"
    log "Steam ports: ${STEAM_PORT_1}, ${STEAM_PORT_2}"
    log "RCON port: ${RCON_PORT}"
    log "Memory: ${MEMORY}"

    cd "$SERVER_DIR"

    exec "$SERVER_DIR/start-server.sh" \
        -servername "$SERVER_NAME" \
        -cachedir="$CONFIG_DIR" \
        -memory "$MEMORY" \
        "${server_args[@]}"
}


main() {
    log "Project Zomboid ARM64 container starting"
    log "Server directory: ${SERVER_DIR}"
    log "Config directory: ${CONFIG_DIR}"

    # Do not check for java here.
    # The bundled Java runtime is downloaded as part of the
    # Project Zomboid server installation.
    require_command curl
    require_command jq

    configure_environment

    if [[ "${UPDATE_ON_START,,}" == "true" || ! -x "$SERVER_DIR/ProjectZomboid64" ]]; then
        install_server
    else
        log "UPDATE_ON_START=false and server files already exist; skipping update"
    fi

    # These must happen after DepotDownloader has populated /opt/zomboid.
    configure_steam_compatibility
    configure_java
    configure_server_ini
    configure_jvm

    # Ensure jspawnhelper remains executable when using the bundled JRE.
    if [[ -f "${SERVER_DIR}/jre64/lib/jspawnhelper" ]]; then
        chmod +x "${SERVER_DIR}/jre64/lib/jspawnhelper" || true
    fi

    log "Project Zomboid configuration complete"

    start_server
}


main "$@"
