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
SERVER_ADMIN_PASSWORD="${SERVER_ADMIN_PASSWORD:-}"
SERVER_PASSWORD="${SERVER_PASSWORD:-}"
SERVER_RCON_PASSWORD="${SERVER_RCON_PASSWORD:-}"

SERVER_DEBUG="${SERVER_DEBUG:-false}"
NO_STEAM="${NO_STEAM:-false}"

WORKSHOP_IDS="${WORKSHOP_IDS:-}"
MOD_IDS="${MOD_IDS:-}"
# JAVA_EXTRA_ARGS are passed to the game (after the main class).
# JVM_EXTRA_ARGS are passed to the JVM (before the main class).
JAVA_EXTRA_ARGS="${JAVA_EXTRA_ARGS:-}"
JVM_EXTRA_ARGS="${JVM_EXTRA_ARGS:-}"

# The x86_64 JVM's JIT generates machine code at runtime that Box64's
# dynarec cannot always translate, causing SIGILL crashes (commonly in
# java.lang.invoke / MethodHandle compiled frames). JAVA_JIT_MODE controls
# the mitigation:
#   interpreter - force -Xint (no JIT; most stable, slowest)
#   c1          - JIT with C1 only, no C2 (-XX:TieredStopAtLevel=1)
#   default     - let the JVM decide (fastest, may SIGILL under Box64)
JAVA_JIT_MODE="${JAVA_JIT_MODE:-interpreter}"

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

    # DepotDownloader writes depot files without the execute bit. We launch
    # the bundled JRE directly (bypassing the pzexe ProjectZomboid64
    # launcher), so the executables we actually need are the Java runtime
    # binaries. Restore the execute bit on them.
    if [[ -f "$SERVER_DIR/jre64/bin/java" ]]; then
        chmod +x "$SERVER_DIR/jre64/bin/java" || true
    fi

    if [[ -f "$SERVER_DIR/jre64/lib/jspawnhelper" ]]; then
        chmod +x "$SERVER_DIR/jre64/lib/jspawnhelper" || true
    fi

    # Validate the real launch artifacts rather than the (unused, and
    # non-executable after download) ProjectZomboid64 pzexe launcher.
    if [[ ! -x "$SERVER_DIR/jre64/bin/java" ]]; then
        fail "Bundled Java runtime not found/executable at ${SERVER_DIR}/jre64/bin/java"
    fi

    if [[ ! -f "$SERVER_DIR/java/projectzomboid.jar" ]]; then
        fail "Project Zomboid server jar not found at ${SERVER_DIR}/java/projectzomboid.jar"
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

    # RCON is disabled by the server unless RCONPassword is set.
    if [[ -n "$SERVER_RCON_PASSWORD" ]]; then
        set_ini "RCONPassword" "$SERVER_RCON_PASSWORD"
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

    # Deliberately exclude Password / RCONPassword from the log to avoid
    # leaking secrets into container logs.
    grep -E \
        '^(DefaultPort|UDPPort|SteamPort1|SteamPort2|RCONPort|Public|WorkshopItems|Mods|AdminUsername)=' \
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


# Derive the Java classpath the stock ProjectZomboid64 (pzexe) launcher
# would use, by reading ProjectZomboid64.json.
#
# We deliberately avoid calling start-server.sh / ProjectZomboid64 here.
# On aarch64 those stock launchers run the native "pzexe" bootstrap, which
# loads libpzexe_jni64.so and performs its own x86_64 arch/JNI detection.
# Under Box64 that detection fails and aborts with "Only 64bit is
# supported" before the game server ever starts. Invoking the bundled
# x86_64 Java directly through the Box64 wrapper bypasses pzexe entirely
# while launching the exact same zombie.network.GameServer main class.
#
# The stock ProjectZomboid64.json stores each JVM option as a full string
# entry, e.g. "-Djava.class.path=java/.:java/projectzomboid.jar". We parse
# that entry to recover the server classpath.
build_classpath() {
    local json_file="${SERVER_DIR}/ProjectZomboid64.json"
    local cp=""

    if [[ -f "$json_file" ]]; then
        cp="$(jq -r '
            [ .[]?
              | select(type == "string")
              | select(startswith("-Djava.class.path="))
              | sub("^-Djava.class.path="; "")
            ] | first // empty
        ' "$json_file" 2>/dev/null || true)"
    fi

    if [[ -z "$cp" ]]; then
        # Verified Build 42 dedicated-server classpath fallback.
        cp="java/.:java/projectzomboid.jar"
    fi

    printf '%s' "$cp"
}


start_server() {
    local server_args=()
    local jvm_mem_args=()
    local classpath
    local xmx="${MEMORY_XMX:-$MEMORY}"
    local xms="${MEMORY_XMS:-$MEMORY}"

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

    # The built-in admin account is created/reset when the server process
    # is given -adminpassword on startup. There is no INI key for it.
    if [[ -n "$SERVER_ADMIN_PASSWORD" ]]; then
        server_args+=(
            "-adminpassword"
            "$SERVER_ADMIN_PASSWORD"
        )
    fi

    classpath="$(build_classpath)"

    # Steam networking under Box64 is unreliable; disable it unless the
    # operator explicitly opts in. GameServer accepts -nosteam.
    if [[ "${NO_STEAM,,}" != "true" ]]; then
        local steam_flag="1"
    else
        local steam_flag="0"
    fi

    jvm_mem_args=(
        "-Xms${xms}"
        "-Xmx${xmx}"
    )

    # Box64 JIT-crash mitigation (see JAVA_JIT_MODE above).
    local jit_args=()
    case "${JAVA_JIT_MODE,,}" in
        interpreter)
            jit_args+=( "-Xint" )
            log "JIT mode: interpreter (-Xint)"
            ;;
        c1)
            jit_args+=( "-XX:TieredStopAtLevel=1" )
            log "JIT mode: C1 only (-XX:TieredStopAtLevel=1)"
            ;;
        default|*)
            log "JIT mode: default (JVM-managed)"
            ;;
    esac

    local extra_jvm_args=()
    if [[ -n "$JVM_EXTRA_ARGS" ]]; then
        # shellcheck disable=SC2206
        extra_jvm_args+=( ${JVM_EXTRA_ARGS} )
    fi

    log "Starting Project Zomboid server"
    log "Server name: ${SERVER_NAME}"
    log "Server port: ${SERVER_PORT}"
    log "UDP port: ${SERVER_UDP_PORT}"
    log "Steam ports: ${STEAM_PORT_1}, ${STEAM_PORT_2}"
    log "RCON port: ${RCON_PORT}"
    log "Memory (Xms/Xmx): ${xms}/${xmx}"
    log "Classpath: ${classpath}"

    cd "$SERVER_DIR"

    # Launch the bundled x86_64 Java runtime directly through the Box64
    # wrapper (/usr/local/bin/java), replicating the stock
    # ProjectZomboid64.json vmArgs for the Build 42 dedicated server but
    # without the pzexe native launcher and its aarch64 arch guard.
    #
    # The library path must point at the server's linux64 and natives
    # directories so the x86_64 native libraries resolve under Box64.
    # PZ resolves its user-data folder (<user.home>/Zomboid) from the
    # user.home system property. The stock StartServer64 launcher sets
    # -Duser.home explicitly. Without it, ZomboidFileSystem.init() resolves
    # a null base path and crashes with a NullPointerException in
    # URI.quote (getRelativeFile). Point it at the container's HOME.
    #
    # -Duser.timezone=UTC avoids the bundled JRE needing to resolve a
    # system timezone name, which can fail under Box64 while reading the
    # JRE's tzdb.dat.
    exec java \
        "${jvm_mem_args[@]}" \
        "${jit_args[@]}" \
        "${extra_jvm_args[@]}" \
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
    log "Project Zomboid ARM64 container starting"
    log "Server directory: ${SERVER_DIR}"
    log "Config directory: ${CONFIG_DIR}"

    # Do not check for java here.
    # The bundled Java runtime is downloaded as part of the
    # Project Zomboid server installation.
    require_command curl
    require_command jq

    configure_environment

    # Use the game jar as the "already installed" marker. ProjectZomboid64
    # is the unused pzexe launcher and is non-executable after download, so
    # it is not a reliable presence check.
    if [[ "${UPDATE_ON_START,,}" == "true" || ! -f "$SERVER_DIR/java/projectzomboid.jar" ]]; then
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
